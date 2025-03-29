import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
    case demo = "Demo"
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

struct Command: Codable {
    var bytes: Int
    var command: String
    var decoder: String
    var description: String
    var live: Bool
    var maxValue: Int
    var minValue: Int
}

public class ConfigurationService {
    static var shared = ConfigurationService()
    var connectionType: ConnectionType {
        get {
            let rawValue =
                UserDefaults.standard.string(forKey: "connectionType")
                ?? "Bluetooth"
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: "connectionType"
            )
        }
    }
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
public class OBDService: ObservableObject, OBDServiceDelegate {
    static let retryCountSendCommand: Int = 3
    static let retryCountRequestPIDs: Int = 10
    public static let intervalContinuousUpdate: CGFloat = 0.3

    var oilerObdSetting: OneObdSetting

    @Published public private(set) var connectionState: ConnectionState =
        .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var peripherals: [CBPeripheral] = []
    @Published public private(set) var connectedPeripheral: CBPeripheral?
    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    deinit {
        Helper.sabipr("OBDService deinit")
    }

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    private var cancellables = Set<AnyCancellable>()

    /// Initializes the OBDService object.
    ///
    /// - Parameter connectionType: The desired connection type (default is Bluetooth).
    ///
    ///
    init(
        connectionType: ConnectionType = .bluetooth,
        oilerObdSetting: OneObdSetting
    ) {
        self.connectionType = connectionType
        self.oilerObdSetting = oilerObdSetting

        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
            bleManager.peripheralPublisher
                .sink { [weak self] peripheral in
                    self?.peripherals.append(peripheral)
                }
                .store(in: &cancellables)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }

        //        #if targetEnvironment(simulator)
        //            elm327 = ELM327(comm: MOCKComm())
        //        #else
        //            switch connectionType {
        //            case .bluetooth:
        //                let bleManager = BLEManager()
        //                elm327 = ELM327(comm: bleManager)
        //                bleManager.peripheralPublisher
        //                    .sink { [weak self] peripheral in
        //                        self?.peripherals.append(peripheral)
        //                    }
        //                    .store(in: &cancellables)
        //            case .wifi:
        //                elm327 = ELM327(comm: WifiManager())
        //            case .demo:
        //                elm327 = ELM327(comm: MOCKComm())
        //            }
        //        #endif
        elm327.obdDelegate = self
    }

    // MARK: - Connection Handling

    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors that might occur during the connection process.
    public func startConnection() async throws -> OBDInfo {
        let preferedProtocol: PROTOCOL? = oilerObdSetting.obdProtocol
        let timeout: TimeInterval = oilerObdSetting.connectionTimeoutSeconds

        do {
            try await elm327.connectToAdapter(
                timeout: timeout,
                oilerObdSetting: oilerObdSetting
            )
            try await elm327.adapterInitialization(
                preferredProtocol: preferedProtocol,
                oilerObdSetting: oilerObdSetting
            )
            let obdInfo = try await initializeVehicle(preferedProtocol)
            return obdInfo
        } catch {
            throw OBDServiceError.adapterConnectionFailed(
                underlyingError: error
            )  // Propagate
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors if the vehicle initialization process fails.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws
        -> OBDInfo
    {
        let obd2info = try await elm327.setupVehicle(
            preferredProtocol: preferedProtocol,
            oilerObdSetting: oilerObdSetting
        )
        return obd2info
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        elm327.stopConnection()
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    ///
    /// - Parameter connectionType: The new desired connection type.
    private func switchConnectionType(_ connectionType: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
            bleManager.peripheralPublisher
                .sink { [weak self] peripheral in
                    self?.peripherals.append(peripheral)
                }
                .store(in: &cancellables)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }
        elm327.obdDelegate = self
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    /// Sends an OBD2 command to the vehicle and returns a publisher with the result.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: A publisher with the measurement result.
    /// - Throws: Errors that might occur during the request process.
    public func startContinuousUpdates(
        _ pids: [OBDCommand],
        unit: MeasurementUnit = .metric,
        interval: TimeInterval = OBDService.intervalContinuousUpdate
    ) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap {
                [weak self] _ -> Future<[OBDCommand: MeasurementResult], Error>
                in
                Future { promise in
                    guard let self = self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }
                    Task(priority: .userInitiated) {
                        do {
                            let results = try await self.requestPIDs(
                                pids,
                                unit: unit
                            )
                            promise(.success(results))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }

    /// Adds an OBD2 command to the list of commands to be requested.
    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    /// Removes an OBD2 command from the list of commands to be requested.
    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: measurement result
    /// - Throws: Errors that might occur during the request process.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit)
        async throws -> [OBDCommand: MeasurementResult]
    {
        let response = try await sendCommandInternal(
            "01"
                + commands.compactMap { $0.properties.command.dropFirst(2) }
                .joined(),
            retries: OBDService.retryCountRequestPIDs
        )

        guard
            let responseData = try elm327.canProtocol?.parse(response).first?
                .data
        else { return [:] }

        var batchedResponse = BatchedResponse(response: responseData, unit)

        let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]
        ) { result, command in
            let measurement = batchedResponse.extractValue(command)
            result[command] = measurement
        }

        return results
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///  - Parameter command: The OBD2 command to send.
    ///  - Returns: The raw response from the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<
        DecodeResult, DecodeError
    > {
        do {
            let response = try await sendCommandInternal(
                command.properties.command,
                retries: OBDService.retryCountSendCommand
            )
            guard
                let responseData = try elm327.canProtocol?.parse(response)
                    .first?.data
            else {
                return .failure(.noData)
            }
            return command.properties.decode(data: responseData.dropFirst())
        } catch {
            throw OBDServiceError.commandFailed(
                command: command.properties.command,
                error: error
            )
        }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///   - Parameter command: The OBD2 command to send.
    ///   - Returns: The raw response from the vehicle.
    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs(oilerObdSetting: oilerObdSetting)
    }

    ///  Scans for trouble codes and returns the result.
    ///  - Returns: The trouble codes found on the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    public func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        do {
            return try await elm327.scanForTroubleCodes(
                oilerObdSetting: oilerObdSetting
            )
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    /// Clears the trouble codes found on the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    ///     - `OBDServiceError.notConnectedToVehicle` if the adapter is not connected to a vehicle.
    public func clearTroubleCodes() async throws {
        do {
            try await elm327.clearTroubleCodes(oilerObdSetting: oilerObdSetting)
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    /// Returns the vehicle's status.
    ///  - Returns: The vehicle's status.
    ///  - Throws: Errors that might occur during the request process.
    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        do {
            return try await elm327.getStatus(oilerObdSetting: oilerObdSetting)
        } catch {
            throw error
        }
    }

    //    public func switchToDemoMode(_ isDemoMode: Bool) {
    //        elm327.switchToDemoMode(isDemoMode)
    //    }

    /// Sends a raw command to the vehicle and returns the raw response.
    /// - Parameter message: The raw command to send.
    /// - Returns: The raw response from the vehicle.
    /// - Throws: Errors that might occur during the request process.
    public func sendCommandInternal(_ message: String, retries: Int)
        async throws -> [String]
    {
        do {
            return try await elm327.sendCommand(
                message,
                retries: retries,
                oilerObdSetting: oilerObdSetting
            )
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        do {
            try await elm327.connectToAdapter(
                timeout: 5,
                peripheral: peripheral,
                oilerObdSetting: oilerObdSetting
            )
        } catch {
            throw OBDServiceError.adapterConnectionFailed(
                underlyingError: error
            )
        }
    }

    public func scanForPeripherals() async throws {
        do {
            self.isScanning = true
            try await elm327.scanForPeripherals(
                oilerObdSetting: oilerObdSetting
            )
            self.isScanning = false
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    //    public func test() {
    //        if let resourcePath = Bundle.module.resourcePath {
    //               print("Bundle resources path: \(resourcePath)")
    //               let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath)
    //               print("Files in bundle: \(files ?? [])")
    //           }
    //        // Get the path for the JSON file within the app's bundle
    //        guard let path = Bundle.module.path(forResource: "commands", ofType: "json") else {
    //            print("Error: commands.json file not found in the bundle.")
    //            return
    //        }
    //
    //        // Load the file data
    //        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    //            print("Error: Unable to load data from commands.json.")
    //            return
    //        }
    //
    //        do {
    //                // Load the JSON
    //                let data = try Data(contentsOf: URL(fileURLWithPath: path))
    //
    //                // Decode the JSON into an array of dictionaries to handle flexible structures
    //                guard var rawCommands = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
    //                    print("Error: Invalid JSON format.")
    //                    return
    //                }
    //
    //                // Edit the `decoder` field
    //                rawCommands = rawCommands.map { command in
    //                    var updatedCommand = command
    //                    if let decoder = command["decoder"] as? [String: Any], let firstKey = decoder.keys.first {
    //                        updatedCommand["decoder"] = firstKey // Set the first key as the string value
    //                    } else {
    //                        updatedCommand["decoder"] = "none" // Default to "none" if no keys exist
    //                    }
    //                    return updatedCommand
    //                }
    //
    //                // Convert back to JSON data
    //                let updatedData = try JSONSerialization.data(withJSONObject: rawCommands, options: .prettyPrinted)
    //
    //                // Save the updated JSON to a file
    //                let outputPath = FileManager.default.temporaryDirectory.appendingPathComponent("commands_updated.json")
    //                try updatedData.write(to: outputPath)
    //
    //                print("Modified commands.json saved to: \(outputPath.path)")
    //            } catch {
    //                print("Error processing commands.json: \(error)")
    //            }
    //    }

}

public enum OBDServiceError: Error {
    case noAdapterFound
    case notConnectedToVehicle
    case adapterConnectionFailed(underlyingError: Error)
    case scanFailed(underlyingError: Error)
    case clearFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)
}

public struct MeasurementResult: Equatable {
    public let value: Double
    public let unit: Unit
}

public func getVINInfo(vin: String) async throws -> VINResults {
    let endpoint =
        "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"

    guard let url = URL(string: endpoint) else {
        throw URLError(.badURL)
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VINResults.self, from: data)
    return decoded
}

public struct VINResults: Codable {
    public let Results: [VINInfo]
}

public struct VINInfo: Codable, Hashable {
    public let Make: String
    public let Model: String
    public let ModelYear: String
    public let EngineCylinders: String
}
