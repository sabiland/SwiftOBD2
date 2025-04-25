// MARK: - ELM327 Class Documentation

/// `Author`: Kemo Konteh
/// The `ELM327` class provides a comprehensive interface for interacting with an ELM327-compatible
/// OBD-II adapter. It handles adapter setup, vehicle connection, protocol detection, and
/// communication with the vehicle's ECU.
///
/// **Key Responsibilities:**
/// * Manages communication with a BLE OBD-II adapter
/// * Automatically detects and establishes the appropriate OBD-II protocol
/// * Sends commands to the vehicle's ECU
/// * Parses and decodes responses from the ECU
/// * Retrieves vehicle information (e.g., VIN)
/// * Monitors vehicle status and retrieves diagnostic trouble codes (DTCs)

import Combine
import CoreBluetooth
import Foundation
import OSLog

enum ELM327Error: Error, LocalizedError {
    case noProtocolFound
    case invalidResponse(message: String)
    case adapterInitializationFailed
    case ignitionOff
    case invalidProtocol
    case timeout
    case connectionFailed(reason: String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .noProtocolFound:
            return "No compatible OBD protocol found."
        case let .invalidResponse(message):
            return "Invalid response received: \(message)"
        case .adapterInitializationFailed:
            return "Failed to initialize adapter."
        case .ignitionOff:
            return "Vehicle ignition is off."
        case .invalidProtocol:
            return "Invalid or unsupported OBD protocol."
        case .timeout:
            return "Operation timed out."
        case let .connectionFailed(reason):
            return "Connection failed: \(reason)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

class ELM327 {
    //    private var obdProtocol: PROTOCOL = .NONE
    var canProtocol: CANProtocol?

    private let logger = Logger(
        subsystem: IAPViewController.sabilandAppBundleId,
        category: "ELM327"
    )
    private var comm: CommProtocol

    private var cancellables = Set<AnyCancellable>()

    weak var obdDelegate: OBDServiceDelegate? {
        didSet {
            comm.obdDelegate = obdDelegate
        }
    }

    private var r100: [String] = []

    var connectionState: ConnectionState = .disconnected {
        didSet {
            obdDelegate?.connectionStateChanged(state: connectionState)
        }
    }

    deinit {
        Helper.sabipr("ELM327 deinit")
    }

    init(comm: CommProtocol) {
        self.comm = comm
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.obdDelegate?.connectionStateChanged(state: state)
                self?.logger.debug(
                    "Connection state updated: \(state.hashValue)"
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferedProtocol: An optional preferred protocol to attempt first.
    /// - Returns: A tuple containing the established OBD protocol and the vehicle's VIN (if available).
    /// - Throws:
    ///     - `SetupError.noECUCharacteristic` if the required OBD characteristic is not found.
    ///     - `SetupError.invalidResponse(message: String)` if the adapter's response is unexpected.
    ///     - `SetupError.noProtocolFound` if no compatible protocol can be established.
    ///     - `SetupError.adapterInitFailed` if initialization of adapter failed.
    ///     - `SetupError.timeout` if a response times out.
    ///     - `SetupError.peripheralNotFound` if the peripheral could not be found.
    ///     - `SetupError.ignitionOff` if the vehicle's ignition is not on.
    ///     - `SetupError.invalidProtocol` if the protocol is not recognized.
    func setupVehicle(
        preferredProtocol: PROTOCOL?,
        oilerObdSetting: OneObdSetting,
        lastObdInfo: OBDInfo?
    ) async throws -> OBDInfo {
        let detectedProtocol = try await detectProtocol(
            preferredProtocol: preferredProtocol,
            oilerObdSetting: oilerObdSetting
        )
        canProtocol = protocols[detectedProtocol]
        // NOTE: 04042025 - SUPER OPTIMIZATION
        if let lastObdInfo {
            return lastObdInfo
        } else {
            let vin = await requestVin(oilerObdSetting: oilerObdSetting)
            let supportedPIDs = await getSupportedPIDs(
                oilerObdSetting: oilerObdSetting
            )
            guard let messages = try canProtocol?.parse(r100) else {
                throw ELM327Error.invalidResponse(
                    message: "Invalid response to 0100"
                )
            }
            let ecuMap = populateECUMap(messages)
            connectionState = .connectedToVehicle
            return OBDInfo(
                vin: vin,
                supportedPIDs: supportedPIDs,
                obdProtocol: detectedProtocol,
                ecuMap: ecuMap
            )
        }
    }

    // MARK: - Protocol Selection

    /// Detects the appropriate OBD protocol by attempting preferred and fallback protocols.
    /// - Parameter preferredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected `PROTOCOL`.
    /// - Throws: `ELM327Error` if detection fails.
    private func detectProtocol(
        preferredProtocol: PROTOCOL? = nil,
        oilerObdSetting: OneObdSetting
    ) async throws
        -> PROTOCOL
    {
        logger.info("Starting protocol detection...")

        if let protocolToTest = preferredProtocol {
            logger.info(
                "Attempting preferred protocol: \(protocolToTest.description)"
            )

            // Test the preferred protocol without reinitializing the adapter
            if await testProtocol(
                protocolToTest,
                oilerObdSetting: oilerObdSetting
            ) {
                return protocolToTest
            } else {
                logger.warning(
                    "Preferred protocol \(protocolToTest.description) failed. Falling back to automatic detection."
                )
            }
        }

        // Fallback to automatic or manual detection
        do {
            return try await detectProtocolAutomatically(
                oilerObdSetting: oilerObdSetting
            )
        } catch {
            return try await detectProtocolManually(
                oilerObdSetting: oilerObdSetting
            )
        }
    }

    /// Attempts to detect the OBD protocol automatically.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolAutomatically(oilerObdSetting: OneObdSetting)
        async throws -> PROTOCOL
    {
        self.logger.info("detectProtocolAutomatically")

        _ = try await okResponse(
            OBDCommand.Protocols.ATSP0.properties.command,
            oilerObdSetting: oilerObdSetting
        )

        let delay: UInt64 = UInt64(
            oilerObdSetting
                .delayNanosecondsTimeoutDetectProtocolAutomatically
        )

        try? await Task.sleep(nanoseconds: delay)
        _ = try await sendCommand(
            OBDCommand.Mode1.pidsA.properties.command,
            oilerObdSetting: oilerObdSetting
        )

        let obdProtocolNumber = try await sendCommand(
            OBDCommand.General.ATDPN.properties.command,
            oilerObdSetting: oilerObdSetting
        )

        guard
            let obdProtocol = PROTOCOL(
                rawValue: String(obdProtocolNumber[0].dropFirst())
            )
        else {
            throw ELM327Error.invalidResponse(
                message: "Invalid protocol number: \(obdProtocolNumber)"
            )
        }

        _ = await testProtocol(obdProtocol, oilerObdSetting: oilerObdSetting)

        return obdProtocol
    }

    /// Attempts to detect the OBD protocol manually.
    /// - Parameter desiredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolManually(oilerObdSetting: OneObdSetting)
        async throws -> PROTOCOL
    {
        self.logger.info("detectProtocolManually")
        for protocolOption in PROTOCOL.allCases where protocolOption != .NONE {
            self.logger.info("Testing protocol: \(protocolOption.description)")
            _ = try await okResponse(
                protocolOption.cmd,
                oilerObdSetting: oilerObdSetting
            )
            if await testProtocol(
                protocolOption,
                oilerObdSetting: oilerObdSetting
            ) {
                return protocolOption
            }
        }
        /// If we reach this point, no protocol was found
        logger.error("No protocol found")
        throw ELM327Error.noProtocolFound
    }

    // MARK: - Protocol Testing

    /// Tests a given protocol by sending a 0100 command and checking for a valid response.
    /// - Parameter obdProtocol: The protocol to test.
    /// - Throws: Various setup-related errors.
    private func testProtocol(
        _ obdProtocol: PROTOCOL,
        oilerObdSetting: OneObdSetting
    ) async -> Bool {
        // First, set the protocol on the adapter before sending the test command
        let protocolCommand = "ATSP\(obdProtocol.rawValue)"
        logger.info("Setting protocol: \(protocolCommand)")

        do {
            _ = try await sendCommand(
                protocolCommand,
                oilerObdSetting: oilerObdSetting
            )  // Set the desired protocol
        } catch {
            logger.error(
                "Failed to set protocol \(obdProtocol.description): \(error.localizedDescription)"
            )
            oilerObdSetting.updateObdProtocol(obdProtocol: nil)
            return false
        }

        // Now send the 0100 command and check for a valid response
        let response = try? await sendCommand(
            OBDCommand.Mode1.pidsA.properties.command,
            retries: OBDService.retryCountSendCommand,
            oilerObdSetting: oilerObdSetting
        )

        if let response = response,
            response.contains(where: {
                $0.range(of: #"41\s*00"#, options: .regularExpression) != nil
            })
        {
            // Update protocol setting
            oilerObdSetting.updateObdProtocol(
                obdProtocol: obdProtocol
            )

            logger.info("Protocol \(obdProtocol.description) is valid.")
            r100 = response
            return true
        } else {
            logger.warning(
                "Protocol \(obdProtocol.rawValue) did not return valid 0100 response."
            )
            // Log invalid response
            if let response = response {
                logger.warning("Protocol response not valid \(response).")
            }
            oilerObdSetting.updateObdProtocol(obdProtocol: nil)
            return false
        }
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(
        timeout: TimeInterval,
        peripheral: CBPeripheral? = nil,
        oilerObdSetting: OneObdSetting
    ) async throws {
        try await comm.connectAsync(
            timeout: timeout,
            peripheral: peripheral,
            oilerObdSetting: oilerObdSetting
        )
    }

    /// Initializes the adapter by sending a series of commands.
    /// - Parameter setupOrder: A list of commands to send in order.
    /// - Throws: Various setup-related errors.
    func adapterInitialization(
        preferredProtocol: PROTOCOL? = nil,
        oilerObdSetting: OneObdSetting
    ) async throws {
        logger.info("Initializing ELM327 adapter...")

        let baseDelay: UInt64 = UInt64(
            oilerObdSetting.delayNanosecondsTimeoutAdapterInitialization
        )

        let delayReset = UInt64(Double(baseDelay) * oilerObdSetting.multReset)
        let delayEcho = UInt64(Double(baseDelay) * oilerObdSetting.multEcho)
        let delayHeaders = UInt64(
            Double(baseDelay) * oilerObdSetting.multHeaders
        )
        let delayProtocolSet = UInt64(
            Double(baseDelay) * oilerObdSetting.multProtocolSet
        )
        let delayATI = UInt64(Double(baseDelay) * oilerObdSetting.multATI)

        do {
            // ⚡ 1. Reset the adapter fully
            _ = try await sendCommand(
                OBDCommand.General.ATZ.properties.command,
                oilerObdSetting: oilerObdSetting
            )
            try await Task.sleep(nanoseconds: delayReset)

            // ⚡ 2. Disable all extra text formatting
            _ = try await okResponse(
                OBDCommand.General.ATE0.properties.command,
                oilerObdSetting: oilerObdSetting
            )  // echo off
            try await Task.sleep(nanoseconds: delayEcho)

            _ = try await okResponse(
                OBDCommand.General.ATL0.properties.command,
                oilerObdSetting: oilerObdSetting
            )  // linefeeds off
            try await Task.sleep(nanoseconds: delayEcho)

            _ = try await okResponse(
                OBDCommand.General.ATS0.properties.command,
                oilerObdSetting: oilerObdSetting
            )  // spaces off
            try await Task.sleep(nanoseconds: delayEcho)

            // ⚡ 3. Optional: Enable headers only if your parser needs them
            _ = try await okResponse(
                OBDCommand.General.ATH1.properties.command,
                oilerObdSetting: oilerObdSetting
            )
            try await Task.sleep(nanoseconds: delayHeaders)

            // ⚡ 4. Adaptive protocol setup
            if let preferredProtocol = preferredProtocol {
                logger.info(
                    "Using preferred protocol: \(preferredProtocol.description)"
                )
                _ = try await okResponse(
                    preferredProtocol.cmd,
                    oilerObdSetting: oilerObdSetting
                )
                try await Task.sleep(nanoseconds: delayProtocolSet)
            } else {
                _ = try await okResponse(
                    OBDCommand.Protocols.ATSP0.properties.command,
                    oilerObdSetting: oilerObdSetting
                )
                try await Task.sleep(nanoseconds: delayProtocolSet)
            }

            // ⚡ 5. Confirm adapter is ready (optional sanity)
            let adapterVersion = try await sendCommand(
                OBDCommand.General.ATI.properties.command,
                oilerObdSetting: oilerObdSetting
            )
            try await Task.sleep(nanoseconds: delayATI)

            logger.info(
                "Adapter Version: \(adapterVersion.joined(separator: " "))"
            )
            logger.info("ELM327 adapter initialized successfully.")
        } catch {
            logger.error(
                "Adapter initialization failed: \(error.localizedDescription)"
            )
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String, oilerObdSetting: OneObdSetting)
        async throws
    {
        _ = try await okResponse(
            "AT SH " + header,
            oilerObdSetting: oilerObdSetting
        )
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
        comm.reset()
    }

    // MARK: - Message Sending

    func sendCommand(
        _ message: String,
        retries: Int = OBDService.retryCountSendCommand,
        oilerObdSetting: OneObdSetting
    ) async throws
        -> [String]
    {
        try await comm.sendCommand(
            message,
            retries: retries,
            oilerObdSetting: oilerObdSetting
        )
    }

    private func okResponse(_ message: String, oilerObdSetting: OneObdSetting)
        async throws -> [String]
    {
        let response = try await sendCommand(
            message,
            oilerObdSetting: oilerObdSetting
        )
        if response.containsIgnoringCase("OK") {
            return response
        } else {
            logger.error("Invalid response: \(response)")
            throw ELM327Error.invalidResponse(
                message:
                    "message: \(message), \(String(describing: response.first))"
            )
        }
    }

    func getStatus(oilerObdSetting: OneObdSetting) async throws -> Result<
        DecodeResult, DecodeError
    > {
        logger.info("Getting status")
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(
            statusCommand.properties.command,
            oilerObdSetting: oilerObdSetting
        )
        logger.debug("Status response: \(statusResponse)")
        guard
            let statusData = try canProtocol?.parse(statusResponse).first?.data
        else {
            return .failure(.noData)
        }
        return statusCommand.properties.decode(data: statusData)
    }

    func scanForTroubleCodes(oilerObdSetting: OneObdSetting) async throws
        -> [ECUID: [TroubleCode]]
    {
        var dtcs: [ECUID: [TroubleCode]] = [:]
        logger.info("Scanning for trouble codes")
        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendCommand(
            dtcCommand.properties.command,
            oilerObdSetting: oilerObdSetting
        )

        guard let messages = try canProtocol?.parse(dtcResponse) else {
            return [:]
        }
        for message in messages {
            guard let dtcData = message.data else {
                continue
            }
            let decodedResult = dtcCommand.properties.decode(data: dtcData)

            let ecuId = message.ecu
            switch decodedResult {
            case let .success(result):
                dtcs[ecuId] = result.troubleCode

            case let .failure(error):
                logger.error("Failed to decode DTC: \(error)")
            }
        }

        return dtcs
    }

    func clearTroubleCodes(oilerObdSetting: OneObdSetting) async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC
        _ = try await sendCommand(
            command.properties.command,
            oilerObdSetting: oilerObdSetting
        )
    }

    func scanForPeripherals(oilerObdSetting: OneObdSetting) async throws {
        try await comm.scanForPeripherals(oilerObdSetting: oilerObdSetting)
    }

    // SABI TWEAK
    // 25042025 - ChatGpt improved
    func requestVin(oilerObdSetting: OneObdSetting) async -> String? {
        let command = OBDCommand.Mode9.VIN

        guard
            let vinResponse = try? await sendCommand(
                command.properties.command,
                oilerObdSetting: oilerObdSetting
            )
        else {
            return nil
        }

        guard let parsed = try? canProtocol?.parse(vinResponse) else {
            return nil
        }

        // Flatten all bytes
        let vinBytes = parsed.compactMap { $0.data }.flatMap { $0 }

        // Drop metadata bytes if present
        let cleanBytes =
            vinBytes.count > 2 ? vinBytes.dropFirst(2) : vinBytes[...]

        // Extract VIN payload: only 0–9 and A–Z ASCII, exactly 17 characters
        let vinPayload: [UInt8] = Array(
            cleanBytes
                .filter {
                    (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
                }
                .prefix(17)
        )

        guard vinPayload.count == 17 else { return nil }
        guard let vinString = String(bytes: vinPayload, encoding: .utf8) else {
            return nil
        }

        return vinString
    }

}

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8:
        ECUID]?
    {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        // If there are no messages, return an empty map
        guard !messages.isEmpty else {
            return nil
        }

        // If there is only one message, assume it's from the engine
        if messages.count == 1 {
            ecuMap[messages.first?.ecu.rawValue ?? 0] = .engine
            return ecuMap
        }

        // Find the engine and transmission ECU based on TXID
        var foundEngine = false

        for message in messages {
            let txID = message.ecu.rawValue

            if txID == engineTXID {
                ecuMap[txID] = .engine
                foundEngine = true
            } else if txID == transmissionTXID {
                ecuMap[txID] = .transmission
            }
        }

        // If engine ECU is not found, choose the one with the most bits
        if !foundEngine {
            var bestBits = 0
            var bestTXID: UInt8?

            for message in messages {
                guard let bits = message.data?.bitCount() else {
                    logger.error("parse_frame failed to extract data")
                    continue
                }
                if bits > bestBits {
                    bestBits = bits
                    bestTXID = message.ecu.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        // Assign transmission ECU to messages without an ECU assignment
        for message in messages where ecuMap[message.ecu.rawValue] == nil {
            ecuMap[message.ecu.rawValue] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {
    /// Get the supported PIDs
    /// - Returns: Array of supported PIDs
    func getSupportedPIDs(oilerObdSetting: OneObdSetting) async -> [OBDCommand]
    {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        for pidGetter in pidGetters {
            do {
                logger.info(
                    "Getting supported PIDs for \(pidGetter.properties.command)"
                )
                let response = try await sendCommand(
                    pidGetter.properties.command,
                    oilerObdSetting: oilerObdSetting
                )
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                guard let supportedPidsByECU = parseResponse(response) else {
                    continue
                }

                let supportedCommands = OBDCommand.allCommands
                    .filter {
                        supportedPidsByECU.contains(
                            String($0.properties.command.dropFirst(2))
                        )
                    }
                    .map { $0 }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                logger.error("\(error.localizedDescription)")
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    private func parseResponse(_ response: [String]) -> Set<String>? {
        guard let parsed = try? canProtocol?.parse(response),
            let first = parsed.first
        else {
            print("❌ Failed to parse any CAN response")
            return nil
        }

        guard let ecuData = first.data else {
            print("❌ Parsed message has no data")
            return nil
        }

        print(
            "📦 Raw data: \(ecuData.map { String(format: "%02X", $0) }.joined(separator: " "))"
        )

        // Try both with and without dropFirst()
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        // let binaryData = BitArray(data: ecuData).binaryArray

        let pids = extractSupportedPIDs(binaryData)
        print("🧮 Extracted PIDs: \(pids)")
        return pids
    }

    /*
    private func parseResponse(_ response: [String]) -> Set<String>? {
        guard let ecuData = try? canProtocol?.parse(response).first?.data else {
            return nil
        }
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData)
    }
     */

    func extractSupportedPIDs(_ binaryData: [Int]) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", index + 1)
                supportedPIDs.insert(pid)
            }
        }
        return supportedPIDs
    }
}

struct BatchedResponse {
    private var response: Data
    private var unit: MeasurementUnit
    init(response: Data, _ unit: MeasurementUnit) {
        self.response = response
        self.unit = unit
    }

    mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
        let properties = cmd.properties
        let size = properties.bytes
        guard response.count >= size else { return nil }
        let valueData = response.prefix(size)

        response.removeFirst(size)
        //        print("Buffer: \(buffer.compactMap { String(format: "%02X ", $0) }.joined())")
        let result = cmd.properties.decode(data: valueData, unit: unit)

        switch result {
        case let .success(measurementResult):
            return measurementResult.measurementResult
        case let .failure(error):
            print(
                "Failed to decode \(cmd.properties.command): \(error.localizedDescription)"
            )
            return nil
        }
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0..<count / 2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position...index(after: position)], radix: 16)
        }
    }

    var isHex: Bool {
        !isEmpty && allSatisfy(\.isHexDigit)
    }

    var cleanedHex: String {
        let hex = self.uppercased().filter { "0123456789ABCDEF".contains($0) }
        return hex.count % 2 == 0 ? hex : String(hex.dropLast())  // ⚠️ drop odd trailing char
    }

    var isLikelyHex: Bool {
        return !self.isEmpty && self.count % 2 == 0
            && self.allSatisfy { $0.isHexDigit }
    }
}

extension Data {
    func bitCount() -> Int {
        count * 8
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

// Possible setup errors
// enum SetupError: Error {
//    case noECUCharacteristic
//    case invalidResponse(message: String)
//    case noProtocolFound
//    case adapterInitFailed
//    case timeout
//    case peripheralNotFound
//    case ignitionOff
//    case invalidProtocol
// }

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
