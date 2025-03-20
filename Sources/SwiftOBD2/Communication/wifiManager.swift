//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import CoreBluetooth
import Foundation
import Network
import OSLog
import UIKit

protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?)
        async throws
    func scanForPeripherals() async throws
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
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher {
        $connectionState
    }

    weak var obdDelegate: OBDServiceDelegate?

    private let logger: Logger = {
        let bundleId =
            Bundle.main.bundleIdentifier
            ?? IAPViewController.sabilandAppBundleId
        return Logger(subsystem: bundleId, category: "WifiManager")
    }()

    private var tcp: NWConnection?
    private var isConnecting = false
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private let connectionLock = NSLock()
    private var timeoutTask: Task<Void, Never>?
    private var isCancelled = false
    private var appIsInBackground = false

    // MARK: - Watchdog Timer Property
    private var watchdogTimer: DispatchSourceTimer?

    init() {
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
    }

    // MARK: - App Lifecycle

    @objc private func handleDidEnterBackground() {
        appIsInBackground = true
        logger.warning("App entered background, cancelling connection.")
        cancelConnection(with: .backgroundCancelled)
    }

    @objc private func handleDidBecomeActive() {
        appIsInBackground = false
        logger.info("App became active.")
    }

    // MARK: - Connection Lifecycle

    private func cancelConnection(with error: CommunicationError) {
        var continuationToResume: CheckedContinuation<Void, Error>?
        connectionLock.withLock {
            guard !isCancelled else { return }
            isCancelled = true

            // Grab the continuation and clear it
            continuationToResume = connectionContinuation
            connectionContinuation = nil

            // Force disconnection
            forceDisconnect()
        }
        guard let continuation = continuationToResume else { return }
        continuation.resume(throwing: error)
        Task {
            await Obd2EngineViewController.makeGenericObd2DebugMessage(
                m:
                    "Continuation resumed with error: \(error.localizedDescription)."
            )
        }
    }

    func forceDisconnect() {
        logger.warning("Forcing disconnection...")
        tcp?.cancel()
        tcp = nil
        cancelTimeoutTask()
        cancelWatchdogTimer()
        isConnecting = false
        isCancelled = true
    }

    func reset() {
        connectionLock.withLock {
            isConnecting = false
            connectionContinuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            tcp?.cancel()
            tcp = nil
            isCancelled = false
        }
    }

    /// Establishes a connection to the OBD Wifi adapter.
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil)
        async throws
    {
        if appIsInBackground {
            throw CommunicationError.backgroundCancelled
        }

        // Acquire lock
        try connectionLock.withLock {
            guard !isConnecting else {
                throw CommunicationError.connectionInProgress
            }
            isConnecting = true
            isCancelled = false
        }

        let host = NWEndpoint.Host(OBDService.oilerObdSetting.wifiIp)
        guard
            let port = NWEndpoint.Port(
                String(OBDService.oilerObdSetting.wifiPort))
        else {
            reset()
            throw CommunicationError.invalidData
        }

        logger.info("connectAsync => NWConnection")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(timeout)
        tcpOptions.enableFastOpen = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowFastOpen = true  // Allow fast TCP connection
        params.preferNoProxies = true

        tcp = NWConnection(host: host, port: port, using: params)

        // Single custom timeout using a detached task
        timeoutTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        timeout
                            * Double(
                                OBDService.oilerObdSetting.oneSecondNanoseconds)
                    ))
            } catch {
                return
            }
            guard let self = self else { return }
            if !self.isCancelled {
                self.logger.warning(
                    "Custom timeout fired => cancelling connection")
                self.tcp?.cancel()  // <-- Ensure TCP is canceled
                self.cancelConnection(with: .timeout)
            }
        }

        // Start the watchdog timer to force cancellation if NWConnection is stuck.
        self.startWatchdogTimer(timeout: timeout)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connectionLock.withLock {
                connectionContinuation = continuation
            }

            tcp?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.logger.info(
                        "Connection => .ready => success => cancelTimeout & resume."
                    )
                    self.cancelTimeoutTask()
                    self.cancelWatchdogTimer()
                    self.resumeContinuationSuccessfully()

                case .failed(let error):
                    self.logger.error(
                        "Connection => .failed => \(error.localizedDescription)"
                    )
                    self.cancelWatchdogTimer()
                    self.cancelConnection(with: .errorOccurred(error))

                case .cancelled:
                    self.logger.warning(
                        "Connection => .cancelled => no forced cancelConnection call."
                    )
                    self.cancelWatchdogTimer()

                case .waiting(let error):
                    self.logger.warning(
                        "Connection => .waiting => \(error.localizedDescription). If stuck, single custom timeout fires eventually."
                    )
                    Task.detached { [weak self] in
                        try? await Task.sleep(
                            nanoseconds: UInt64(
                                (timeout
                                    * OBDService.oilerObdSetting
                                    .timeoutMultiplyFactorStateWaitingPreparing)
                                    * Double(
                                        OBDService.oilerObdSetting
                                            .oneSecondNanoseconds)))
                        guard let self = self else { return }
                        if case .waiting = self.tcp?.state {
                            self.logger.warning(
                                "Connection stuck in waiting. Forcing disconnection."
                            )
                            self.cancelConnection(with: .timeout)
                        }
                    }

                case .preparing:
                    self.logger.info("Connection => .preparing")
                    Task.detached { [weak self] in
                        try? await Task.sleep(
                            nanoseconds: UInt64(
                                (timeout
                                    * OBDService.oilerObdSetting
                                    .timeoutMultiplyFactorStateWaitingPreparing)
                                    * Double(
                                        OBDService.oilerObdSetting
                                            .oneSecondNanoseconds)))
                        guard let self = self, self.tcp?.state == .preparing
                        else { return }
                        self.logger.warning(
                            "Connection stuck in preparing. Forcing disconnection."
                        )
                        self.cancelConnection(with: .timeout)
                    }
                default:
                    break
                }
            }

            tcp?.start(queue: .global(qos: .userInitiated))
        }
    }

    private func cancelTimeoutTask() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func resumeContinuationSuccessfully() {
        connectionLock.withLock {
            guard !isCancelled, let continuation = connectionContinuation else {
                reset()
                return
            }
            connectionContinuation = nil
            reset()
            DispatchQueue.main.async {
                continuation.resume(returning: ())
            }
        }
    }

    func disconnectPeripheral() {
        cancelConnection(with: .backgroundCancelled)
    }

    // MARK: - Command Send

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        for attempt in 1...retries {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                }
            } catch {
                if attempt == retries {
                    throw error
                }
                logger.warning(
                    "Retrying \(attempt)/\(retries) => \(error.localizedDescription)"
                )
                try await Task.sleep(
                    nanoseconds: UInt64(
                        OBDService.oilerObdSetting
                            .delayNanosecondsWifiRetryCommand))
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
            throw CommunicationError.invalidData
        }

        return try await withCheckedThrowingContinuation { continuation in
            let operationTimeout: TimeInterval = 5
            let timeoutTask = Task.detached(priority: .userInitiated) {
                [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            operationTimeout
                                * Double(
                                    OBDService.oilerObdSetting
                                        .oneSecondNanoseconds)))
                } catch {
                    return
                }
                self?.logger.warning(
                    "sendAndReceiveData timeout fired => cancelling operation")
                self?.tcp?.cancel()
                continuation.resume(throwing: CommunicationError.timeout)
            }

            tcpConnection.send(
                content: data,
                completion: .contentProcessed { sendError in
                    if let error = sendError {
                        timeoutTask.cancel()
                        continuation.resume(
                            throwing: CommunicationError.errorOccurred(error))
                        return
                    }
                    tcpConnection.receive(
                        minimumIncompleteLength: 1, maximumLength: 500
                    ) { data, _, _, receiveError in
                        timeoutTask.cancel()
                        if let error = receiveError {
                            continuation.resume(
                                throwing: CommunicationError.errorOccurred(
                                    error))
                            return
                        }
                        guard let data = data,
                            let responseString = String(
                                data: data, encoding: .utf8)
                        else {
                            continuation.resume(
                                throwing: CommunicationError.invalidData)
                            return
                        }
                        continuation.resume(returning: responseString)
                    }
                })
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        let lines = response.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != ">" }
        return lines.isEmpty ? nil : lines
    }

    func scanForPeripherals() async throws {
        // Implement if needed
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tcp?.cancel()
        timeoutTask?.cancel()
        cancelWatchdogTimer()
    }

    // MARK: - Watchdog Timer Methods

    private func startWatchdogTimer(timeout: TimeInterval) {
        watchdogTimer?.cancel()
        watchdogTimer = nil

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(
            deadline: .now()
                + (timeout
                    * OBDService.oilerObdSetting.timeoutMultiplyFactorWatchdog))  // Ensure it schedules
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.logger.warning(
                "Watchdog timer fired: Forcing connection cancellation.")
            self.cancelConnection(with: .timeout)
            timer.cancel()
            self.watchdogTimer = nil
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func cancelWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }
}

extension WifiManager {
    // Simple NSLock wrapper for convenience
    func withLock(_ block: () -> Void) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        block()
    }
}
