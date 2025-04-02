import CocoaAsyncSocket
import CoreBluetooth
import Foundation
import OSLog
import UIKit

protocol CommProtocol {
    func sendCommand(
        _ command: String,
        retries: Int,
        oilerObdSetting: OneObdSetting
    ) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(
        timeout: TimeInterval,
        peripheral: CBPeripheral?,
        oilerObdSetting: OneObdSetting
    )
        async throws
    func scanForPeripherals(oilerObdSetting: OneObdSetting) async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
    func reset()
}

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
    case timeout
    case preparingTimeout
    case connectionInProgress
    case backgroundCancelled
    case forcingDisconnect
}

class WifiManager: NSObject, CommProtocol, GCDAsyncSocketDelegate {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher {
        $connectionState
    }
    weak var obdDelegate: OBDServiceDelegate?

    private let logger: Logger = {
        let bundleId = IAPViewController.sabilandAppBundleId
        return Logger(subsystem: bundleId, category: "WifiManager")
    }()

    private var socket: GCDAsyncSocket?
    private var isConnecting = false
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private let connectionLock = NSLock()
    private var timeoutTask: Task<Void, Never>?
    private var watchdogTimer: DispatchSourceTimer?
    private var isCancelled = false
    private var appIsInBackground = false
    private var responseContinuation: CheckedContinuation<String, Error>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        socket?.disconnect()
        timeoutTask?.cancel()
        cancelWatchdogTimer()
    }

    @objc private func handleDidEnterBackground() {
        appIsInBackground = true
        logger.warning("App entered background.")
        if isConnecting {
            cancelConnection(with: .backgroundCancelled)
        }
    }

    @objc private func handleDidBecomeActive() {
        appIsInBackground = false
        logger.info("App became active.")
    }

    @objc private func handleWillResignActive() {
        logger.warning("App will resign active.")
        if isConnecting {
            cancelConnection(with: .backgroundCancelled)
        }
    }

    func withTimeout<T>(
        seconds: TimeInterval,
        oilerObdSetting: OneObdSetting,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        seconds * Double(oilerObdSetting.oneSecondNanoseconds)
                    )
                )
                throw CommunicationError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func connectAsync(
        timeout: TimeInterval,
        peripheral: CBPeripheral? = nil,
        oilerObdSetting: OneObdSetting
    )
        async throws
    {
        if appIsInBackground {
            throw CommunicationError.backgroundCancelled
        }

        try connectionLock.withLock {
            guard !isConnecting else {
                throw CommunicationError.connectionInProgress
            }
            isConnecting = true
            connectionState = .connecting
            isCancelled = false
        }

        guard let port = UInt16(exactly: oilerObdSetting.wifiPort)
        else {
            reset()
            throw CommunicationError.invalidData
        }

        let host = oilerObdSetting.wifiIp
        logger.info("connectAsync => GCDAsyncSocket")

        // 01042025
        connectionLock.withLock {
            responseContinuation?.resume(
                throwing: CommunicationError.forcingDisconnect
            )
            responseContinuation = nil
        }

        //socket = GCDAsyncSocket(delegate: self, delegateQueue: .main)
        socket = GCDAsyncSocket(
            delegate: self,
            delegateQueue: DispatchQueue(label: "wifi.socket.queue")
        )

        try await withTimeout(
            seconds: timeout,
            oilerObdSetting: oilerObdSetting
        ) {
            try await withCheckedThrowingContinuation { continuation in
                self.connectionLock.withLock {
                    if self.connectionContinuation != nil {
                        self.logger.warning(
                            "⚠️ Overwriting existing connectionContinuation."
                        )
                        self.connectionContinuation?.resume(
                            throwing: CommunicationError.forcingDisconnect
                        )
                    }
                    self.connectionContinuation = continuation
                }

                do {
                    try self.socket?.connect(
                        toHost: host,
                        onPort: port,
                        withTimeout: -1
                    )
                } catch {
                    self.cancelConnection(with: .errorOccurred(error))
                }

                // watchdog is still good to have
                self.startWatchdogTimer(
                    timeout: timeout
                        * oilerObdSetting.timeoutMultiplyCustomTimeouts
                )
            }
        }
    }

    @objc func socket(
        _ sock: GCDAsyncSocket,
        didConnectToHost host: String,
        port: UInt16
    ) {
        logger.info("Connected to \(host):\(port)")
        cancelTimeoutTask()
        cancelWatchdogTimer()
        resumeContinuationSuccessfully()
    }

    @objc func socketDidDisconnect(
        _ sock: GCDAsyncSocket,
        withError err: Error?
    ) {
        logger.warning(
            "Socket disconnected: \(err?.localizedDescription ?? "nil")"
        )

        failResponseContinuation(
            CommunicationError.errorOccurred(
                err ?? NSError(domain: "Disconnected", code: -1)
            )
        )

        cancelConnection(
            with: .errorOccurred(
                err ?? NSError(domain: "Disconnected", code: -1)
            )
        )
    }

    // 01042025
    @objc func socket(
        _ sock: GCDAsyncSocket,
        didRead data: Data,
        withTag tag: Int
    ) {
        connectionLock.withLock {
            guard let cont = responseContinuation else {
                logger.warning(
                    "❗ responseContinuation already nil in didRead — ignoring"
                )
                return
            }

            guard let response = String(data: data, encoding: .utf8) else {
                cont.resume(throwing: CommunicationError.invalidData)
                responseContinuation = nil
                return
            }

            cont.resume(returning: response)
            responseContinuation = nil
        }
    }

    @objc func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        logger.debug("Command sent.")
    }

    func sendCommand(
        _ command: String,
        retries: Int,
        oilerObdSetting: OneObdSetting
    ) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        for attempt in 1...retries {
            do {
                let response = try await sendAndReceiveData(
                    data,
                    oilerObdSetting: oilerObdSetting
                )
                if let lines = processResponse(response) {
                    return lines
                }
            } catch {
                if attempt == retries {
                    throw error
                }
                logger.warning("Retrying \(attempt)/\(retries): \(error)")
                try await Task.sleep(
                    nanoseconds: UInt64(
                        oilerObdSetting
                            .delayNanosecondsWifiRetryCommand
                    )
                )
            }
        }

        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(
        _ data: Data,
        oilerObdSetting: OneObdSetting
    ) async throws -> String {
        guard let socket = socket, socket.isConnected else {
            throw CommunicationError.invalidData
        }

        return try await withCheckedThrowingContinuation {
            [weak self] continuation in
            guard let self = self else {
                continuation.resume(
                    throwing: CommunicationError.errorOccurred(
                        NSError(domain: "SelfDeinit", code: 0)
                    )
                )
                return
            }

            connectionLock.withLock {
                if self.responseContinuation != nil {
                    self.logger.warning(
                        "❗ Overwriting existing responseContinuation."
                    )
                    self.responseContinuation?.resume(
                        throwing: CommunicationError.forcingDisconnect
                    )
                }
                self.responseContinuation = continuation
            }

            let timeout = oilerObdSetting.connectionTimeoutSeconds
            socket.write(data, withTimeout: timeout, tag: 0)
            socket.readData(
                to: Data([UInt8(ascii: ">")]),
                withTimeout: timeout,
                tag: 0
            )
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        let lines = response.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0 != ">" }
        return lines.isEmpty ? nil : lines
    }

    func scanForPeripherals(oilerObdSetting: OneObdSetting) async throws {}

    func disconnectPeripheral() {
        cancelConnection(with: .backgroundCancelled)
    }

    func reset() {
        connectionLock.withLock {
            isConnecting = false
            connectionContinuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            socket?.disconnect()
            socket = nil
            isCancelled = false
        }

        forceDisconnect()

        connectionState = .disconnected
    }

    private func forceDisconnect() {
        logger.warning("Force disconnect.")
        socket?.disconnect()
        socket = nil
        cancelTimeoutTask()
        cancelWatchdogTimer()
        isConnecting = false
        isCancelled = true
        connectionState = .disconnected
        // 01042025
        failResponseContinuation(CommunicationError.forcingDisconnect)
    }

    // 01042025
    private func failResponseContinuation(_ error: Error) {
        var cont: CheckedContinuation<String, Error>?
        connectionLock.withLock {
            cont = responseContinuation
            responseContinuation = nil
        }
        if let cont {
            cont.resume(throwing: error)
        } else {
            logger.warning(
                "❗ Tried to fail responseContinuation but it was already nil."
            )
        }
    }

    private func cancelConnection(with error: CommunicationError) {
        var cont: CheckedContinuation<Void, Error>?
        connectionLock.withLock {
            guard connectionContinuation != nil else { return }
            isCancelled = true
            cont = connectionContinuation
            connectionContinuation = nil
            connectionState = .disconnected
        }
        forceDisconnect()
        if let cont {
            logger.warning("Resuming continuation due to: \(error)")
            cont.resume(throwing: error)
        }
    }

    private func resumeContinuationSuccessfully() {
        var cont: CheckedContinuation<Void, Error>?
        connectionLock.withLock {
            guard !isCancelled, let continuation = connectionContinuation else {
                reset()
                return
            }
            cont = continuation
            connectionContinuation = nil
        }

        logger.info("Resuming continuation successfully.")
        cont?.resume(returning: ())

        DispatchQueue.main.async {
            self.connectionState = .connectedToAdapter
        }
    }

    private func startWatchdogTimer(timeout: TimeInterval) {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.logger.warning("Watchdog fired. Forcing disconnect.")
            self?.cancelConnection(with: .timeout)
            self?.watchdogTimer?.cancel()
            self?.watchdogTimer = nil
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func cancelTimeoutTask() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func cancelWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }
}
