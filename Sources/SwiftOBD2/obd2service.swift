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
    public func startConnection(lastObdInfo: OBDInfo?) async throws -> OBDInfo {
        // 09042025 !!!
        clearAllDataNecessaryForCleanStartingConnectionProcess()
        let preferedProtocol: PROTOCOL? = oilerObdSetting.obdProtocol
        let timeout: TimeInterval = oilerObdSetting.connectionTimeoutSeconds
        do {
            try await elm327.connectToAdapter(
                timeout: timeout,
                oilerObdSetting: oilerObdSetting
            )
            let adapterVersion = try await elm327.adapterInitialization(
                preferredProtocol: preferedProtocol,
                oilerObdSetting: oilerObdSetting
            )
            var obdInfo = try await initializeVehicle(
                preferedProtocol,
                lastObdInfo: lastObdInfo
            )
            // 30042025
            obdInfo.adapterVersion = adapterVersion.sanitizedOBDResponse()
            // !!! 30042025
            Vibration.vibrateDefault()
            return obdInfo
        } catch {
            throw OBDServiceError.adapterConnectionFailed(
                underlyingError: error
            )  // Propagate
        }
    }

    // SABI TWEAK 27042025
    public func startConnectionTryOnly() async throws {
        // 30042025
        clearAllDataNecessaryForCleanStartingConnectionProcess()
        let timeout: TimeInterval = oilerObdSetting.connectionTimeoutSeconds
        do {
            try await elm327.connectToAdapter(
                timeout: timeout,
                oilerObdSetting: oilerObdSetting
            )
            // !!! 30042025
            Vibration.vibrateDefault()
        } catch {
            throw OBDServiceError.adapterConnectionFailed(
                underlyingError: error
            )
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors if the vehicle initialization process fails.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?, lastObdInfo: OBDInfo?)
        async throws
        -> OBDInfo
    {
        let obd2info = try await elm327.setupVehicle(
            preferredProtocol: preferedProtocol,
            oilerObdSetting: oilerObdSetting,
            lastObdInfo: lastObdInfo
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

    /// Adds an OBD2 command to the list of commands to be requested.
    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    /// Removes an OBD2 command from the list of commands to be requested.
    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    private func clearAllDataNecessaryForCleanStartingConnectionProcess() {
        // !!!
        self.optimizedContinuousUpdatesDelay = nil
    }

    private var optimizedContinuousUpdatesDelay: TimeInterval?
    // 05042025
    public func startContinuousUpdatesWithoutTimer(
        _ pids: [OBDCommand],
        parallel: Bool,
        unit: MeasurementUnit = .metric,
        delayBeforeNextUpdate: TimeInterval,
        dynamicOptimize: Bool
    ) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Deferred {
            Future<[OBDCommand: MeasurementResult], Error> {
                [weak self] promise in
                guard let self else {
                    deliverToMain(
                        Result<[OBDCommand: MeasurementResult], Error>.failure(
                            OBDServiceError.notConnectedToVehicle
                        ),
                        promise
                    )
                    return
                }

                Task(priority: .userInitiated) {
                    let startTime = CFAbsoluteTimeGetCurrent()

                    if self.optimizedContinuousUpdatesDelay == nil {
                        self.optimizedContinuousUpdatesDelay =
                            delayBeforeNextUpdate
                    }

                    let results =
                        parallel
                        ? await self.requestPIDsBetterParallel(pids, unit: unit)
                        : await self.requestPIDsBetter(pids, unit: unit)

                    if results.isEmpty {
                        deliverToMain(
                            .failure(OBDServiceError.notConnectedToVehicle),
                            promise
                        )
                        return
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    if dynamicOptimize {
                        let clamped = min(
                            elapsed
                                * self.oilerObdSetting
                                .delayOptimizationSafetyFactor,
                            self.oilerObdSetting.delayOptimizationCap
                        )
                        self.optimizedContinuousUpdatesDelay = max(
                            self.oilerObdSetting.delayOptimizationLowLimit,
                            clamped
                        )
                    }

                    deliverToMain(.success(results), promise)
                }
            }
        }
        .flatMap {
            [weak self] result -> AnyPublisher<
                [OBDCommand: MeasurementResult], Error
            > in
            guard let self else {
                // clean exit when self is nil
                return Empty().eraseToAnyPublisher()
            }

            let effectiveDelay =
                self.optimizedContinuousUpdatesDelay ?? delayBeforeNextUpdate
            return Just(result)
                .setFailureType(to: Error.self)
                .append(
                    Just(())
                        .delay(
                            for: .seconds(effectiveDelay),
                            scheduler: RunLoop.main
                        )
                        .flatMap { _ in
                            self.startContinuousUpdatesWithoutTimer(
                                pids,
                                parallel: parallel,
                                unit: unit,
                                delayBeforeNextUpdate: effectiveDelay,
                                dynamicOptimize: dynamicOptimize
                            )
                        }
                )
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    public func requestPIDsBetter(
        _ commands: [OBDCommand],
        unit: MeasurementUnit
    ) async -> [OBDCommand: MeasurementResult] {
        var results: [OBDCommand: MeasurementResult] = [:]

        for command in commands {
            do {
                let response = try await self.sendCommandInternal(
                    command.properties.command,
                    retries: OBDService.retryCountRequestPIDs
                )

                guard
                    let data = try self.elm327.canProtocol?.parse(response)
                        .first?.data
                else {
                    continue
                }

                var batched = BatchedResponse(response: data, unit)
                guard let measurement = batched.extractValue(command) else {
                    continue
                }

                results[command] = measurement
            } catch {
                continue
            }
        }

        return results
    }

    public func requestPIDsBetterParallel(
        _ commands: [OBDCommand],
        unit: MeasurementUnit
    ) async -> [OBDCommand: MeasurementResult] {
        var results: [OBDCommand: MeasurementResult] = [:]

        await withTaskGroup(of: Optional<(OBDCommand, MeasurementResult)>.self)
        { group in
            for command in commands {
                group.addTask { () -> (OBDCommand, MeasurementResult)? in
                    do {
                        let response = try await self.sendCommandInternal(
                            command.properties.command,
                            retries: OBDService.retryCountRequestPIDs
                        )

                        guard
                            let data = try self.elm327.canProtocol?.parse(
                                response
                            ).first?.data
                        else {
                            return nil
                        }

                        var batched = BatchedResponse(response: data, unit)
                        guard let measurement = batched.extractValue(command)
                        else {
                            return nil  // ✅ Prevent returning Optional inside tuple
                        }

                        return (command, measurement)  // ✅ Fully non-optional inside optional tuple

                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let (command, measurement) = result {
                    results[command] = measurement
                }
            }
        }

        return results
    }

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

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: measurement result
    /// - Throws: Errors that might occur during the request process.
    public func requestPIDs(
        _ commands: [OBDCommand],
        unit: MeasurementUnit
    )
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

public struct VINResults: Codable {
    public let Results: [VINInfo]
}

public struct VINInfo: Codable, Hashable {

    static func fetchVINInfoGeneric(vin: String) async throws -> VINResults {
        let url =
            "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"
        return try await URLHelper.fetchDecoded(from: url, as: VINResults.self)
    }

    public static func getVINInfo(vin: String, timeout: TimeInterval = 5)
        async throws -> VINResults
    {
        let endpoint =
            "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"

        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VINResults.self, from: data)
        return decoded
    }

    public let ABS: String?
    public let ActiveSafetySysNote: String?
    public let AdaptiveCruiseControl: String?
    public let AdaptiveDrivingBeam: String?
    public let AdaptiveHeadlights: String?
    public let AdditionalErrorText: String?
    public let AirBagLocCurtain: String?
    public let AirBagLocFront: String?
    public let AirBagLocKnee: String?
    public let AirBagLocSeatCushion: String?
    public let AirBagLocSide: String?
    public let AutoReverseSystem: String?
    public let AutomaticPedestrianAlertingSound: String?
    public let AxleConfiguration: String?
    public let Axles: String?
    public let BasePrice: String?
    public let BatteryA: String?
    public let BatteryA_to: String?
    public let BatteryCells: String?
    public let BatteryInfo: String?
    public let BatteryKWh: String?
    public let BatteryKWh_to: String?
    public let BatteryModules: String?
    public let BatteryPacks: String?
    public let BatteryType: String?
    public let BatteryV: String?
    public let BatteryV_to: String?
    public let BedLengthIN: String?
    public let BedType: String?
    public let BlindSpotIntervention: String?
    public let BlindSpotMon: String?
    public let BodyCabType: String?
    public let BodyClass: String?
    public let BrakeSystemDesc: String?
    public let BrakeSystemType: String?
    public let BusFloorConfigType: String?
    public let BusLength: String?
    public let BusType: String?
    public let CAN_AACN: String?
    public let CIB: String?
    public let CashForClunkers: String?
    public let ChargerLevel: String?
    public let ChargerPowerKW: String?
    public let CombinedBrakingSystem: String?
    public let CoolingType: String?
    public let CurbWeightLB: String?
    public let CustomMotorcycleType: String?
    public let DaytimeRunningLight: String?
    public let DestinationMarket: String?
    public let DisplacementCC: String?
    public let DisplacementCI: String?
    public let DisplacementL: String?
    public let Doors: String?
    public let DriveType: String?
    public let DriverAssist: String?
    public let DynamicBrakeSupport: String?
    public let EDR: String?
    public let ESC: String?
    public let EVDriveUnit: String?
    public let ElectrificationLevel: String?
    public let EngineConfiguration: String?
    public let EngineCycles: String?
    public let EngineCylinders: String?
    public let EngineHP: String?
    public let EngineHP_to: String?
    public let EngineKW: String?
    public let EngineManufacturer: String?
    public let EngineModel: String?
    public let EntertainmentSystem: String?
    public let ErrorCode: String?
    public let ErrorText: String?
    public let ForwardCollisionWarning: String?
    public let FuelInjectionType: String?
    public let FuelTankMaterial: String?
    public let FuelTankType: String?
    public let FuelTypePrimary: String?
    public let FuelTypeSecondary: String?
    public let GCWR: String?
    public let GCWR_to: String?
    public let GVWR: String?
    public let GVWR_to: String?
    public let KeylessIgnition: String?
    public let LaneCenteringAssistance: String?
    public let LaneDepartureWarning: String?
    public let LaneKeepSystem: String?
    public let LowerBeamHeadlampLightSource: String?
    public let Make: String?
    public let MakeID: String?
    public let Manufacturer: String?
    public let ManufacturerId: String?
    public let Model: String?
    public let ModelID: String?
    public let ModelYear: String?
    public let MotorcycleChassisType: String?
    public let MotorcycleSuspensionType: String?
    public let NCSABodyType: String?
    public let NCSAMake: String?
    public let NCSAMapExcApprovedBy: String?
    public let NCSAMapExcApprovedOn: String?
    public let NCSAMappingException: String?
    public let NCSAModel: String?
    public let NCSANote: String?
    public let NonLandUse: String?
    public let Note: String?
    public let OtherBusInfo: String?
    public let OtherEngineInfo: String?
    public let OtherMotorcycleInfo: String?
    public let OtherRestraintSystemInfo: String?
    public let OtherTrailerInfo: String?
    public let ParkAssist: String?
    public let PedestrianAutomaticEmergencyBraking: String?
    public let PlantCity: String?
    public let PlantCompanyName: String?
    public let PlantCountry: String?
    public let PlantState: String?
    public let PossibleValues: String?
    public let Pretensioner: String?
    public let RearAutomaticEmergencyBraking: String?
    public let RearCrossTrafficAlert: String?
    public let RearVisibilitySystem: String?
    public let SAEAutomationLevel: String?
    public let SAEAutomationLevel_to: String?
    public let SeatBeltsAll: String?
    public let SeatRows: String?
    public let Seats: String?
    public let SemiautomaticHeadlampBeamSwitching: String?
    public let Series: String?
    public let Series2: String?
    public let SteeringLocation: String?
    public let SuggestedVIN: String?
    public let TPMS: String?
    public let TopSpeedMPH: String?
    public let TrackWidth: String?
    public let TractionControl: String?
    public let TrailerBodyType: String?
    public let TrailerLength: String?
    public let TrailerType: String?
    public let TransmissionSpeeds: String?
    public let TransmissionStyle: String?
    public let Trim: String?
    public let Trim2: String?
    public let Turbo: String?
    public let VIN: String?
    public let ValveTrainDesign: String?
    public let VehicleDescriptor: String?
    public let VehicleType: String?
    public let WheelBaseLong: String?
    public let WheelBaseShort: String?
    public let WheelBaseType: String?
    public let WheelSizeFront: String?
    public let WheelSizeRear: String?
    public let WheelieMitigation: String?
    public let Wheels: String?
    public let Windows: String?
}

extension VINInfo {
    public var displayableItems: [VINInfoDisplayItem] {
        let mirror = Mirror(reflecting: self)

        return mirror.children.compactMap { child in
            guard let key = child.label else { return nil }
            if let value = child.value as? String, !value.isEmpty {
                return VINInfoDisplayItem(
                    label: key,
                    value: value
                )
            }
            return nil
        }
    }
}

public struct VINInfoDisplayItem: Identifiable {
    public let id = UUID()
    public let label: String
    public let value: String
}

extension String {
    public func camelCaseToWords() -> String {
        return unicodeScalars.dropFirst().reduce(String(prefix(1))) {
            CharacterSet.uppercaseLetters.contains($1)
                ? $0 + " " + String($1)
                : $0 + String($1)
        }
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
    }
}
