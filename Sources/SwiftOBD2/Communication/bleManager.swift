import Combine
import CoreBluetooth
import Foundation
import OSLog

// MARK: - BLE UUIDs Enum
enum BLEUUIDs {
    // Services
    static let serviceVeepeak = CBUUID(string: "FFE0")
    static let serviceOBDLinkCX = CBUUID(string: "FFF0")
    static let serviceVGate = CBUUID(string: "18F0")
    static let serviceOBDLinkCXFallback = CBUUID(
        string: "0000FFF0-0000-1000-8000-00805F9B34FB"
    )
    static let serviceDeviceInfo = CBUUID(string: "180A")

    // Characteristics
    static let charVeepeak = CBUUID(string: "FFE1")
    static let charOBDLinkCXRead = CBUUID(string: "FFF1")
    static let charOBDLinkCXWrite = CBUUID(string: "FFF2")
    static let charVGateRead = CBUUID(string: "2AF0")
    static let charVGateWrite = CBUUID(string: "2AF1")
    static let charFirmwareRevision = CBUUID(string: "2A26")
    static let charSoftwareRevision = CBUUID(string: "2A28")
    static let charManufacturerName = CBUUID(string: "2A29")
}
// MARK: - BLEManager Class Documentation

/// The BLEManager class is a wrapper around the CoreBluetooth framework. It is responsible for managing the connection to the OBD2 adapter,
/// scanning for peripherals, and handling the communication with the adapter.
///
/// **Key Responsibilities:**
/// - Scanning for peripherals
/// - Connecting to peripherals
/// - Managing the connection state
/// - Handling the communication with the adapter
/// - Processing the characteristics of the adapter
/// - Sending messages to the adapter
/// - Receiving messages from the adapter
/// - Parsing the received messages
/// - Handling errors

public enum ConnectionState {
    case disconnected
    case connectedToAdapter
    case connectedToVehicle
    case connecting
}

class BLEManager: NSObject, CommProtocol {

    func reset() {}

    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()

    var peripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        peripheralSubject.eraseToAnyPublisher()
    }

    static let services = [
        BLEUUIDs.serviceVeepeak,
        BLEUUIDs.serviceOBDLinkCX,
        BLEUUIDs.serviceVGate,  // e.g. VGate iCar Pro
        BLEUUIDs.serviceOBDLinkCXFallback,  // OBDLink CX (fallback)
    ]

    let logger = Logger(
        subsystem: IAPViewController.sabilandAppBundleId,
        category: "BLEManager"
    )

    static let RestoreIdentifierKey: String = "OBD2Adapter"

    deinit {
        logger.debug("BLEManager deinitialized. Cleaning up.")
        sendMessageCompletion = nil
        foundPeripheralCompletion = nil
        connectionCompletion = nil
        connectedPeripheral = nil
        centralManager?.delegate = nil
    }

    // MARK: Properties

    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedPeripheral: CBPeripheral?

    var connectionStatePublisher: Published<ConnectionState>.Publisher {
        $connectionState
    }

    private var isBluetoothPoweredOn: Bool {
        centralManager?.state == .poweredOn
    }

    var isReadyToUse: Bool {
        isBluetoothPoweredOn && connectionState == .connectedToAdapter
    }

    private var centralManager: CBCentralManager!
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?

    private var buffer = Data()

    private var sendMessageCompletion: (([String]?, Error?) -> Void)?
    private var foundPeripheralCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?

    public weak var obdDelegate: OBDServiceDelegate?

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: BLEManager
                    .RestoreIdentifierKey,
            ]
        )
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        guard isBluetoothPoweredOn else {
            logger.warning(
                "startScanning skipped: Bluetooth is not powered on."
            )
            return
        }
        let scanOption = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        centralManager?.scanForPeripherals(
            withServices: serviceUUIDs,
            options: scanOption
        )
    }

    func stopScan() {
        centralManager?.stopScan()
    }

    func disconnectPeripheral() {
        guard let connectedPeripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    // MARK: - Central Manager Delegate Methods

    func didUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.debug("Bluetooth is On.")
            guard let device = connectedPeripheral else {
                startScanning(Self.services)
                return
            }

            connect(to: device)
        case .poweredOff:
            logger.warning("Bluetooth is currently powered off.")
            connectedPeripheral = nil
            connectionState = .disconnected
        case .unsupported:
            logger.error("This device does not support Bluetooth Low Energy.")
            resetConfigure()
        case .unauthorized:
            logger.error(
                "This app is not authorized to use Bluetooth Low Energy."
            )
        case .resetting:
            logger.warning("Bluetooth is resetting.")
            resetConfigure()
        default:
            logger.error("Bluetooth is not powered on.")
            fatalError()
        }
    }

    func didDiscover(
        _: CBCentralManager,
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        //        connect(to: peripheral)
        appendFoundPeripheral(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: rssi
        )
        if foundPeripheralCompletion != nil {
            foundPeripheralCompletion?(peripheral, nil)
        }
    }

    @Published var foundPeripherals: [CBPeripheral] = []

    func appendFoundPeripheral(
        peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi: NSNumber
    ) {
        if rssi.intValue >= 0 { return }
        if let index = foundPeripherals.firstIndex(where: {
            $0.identifier.uuidString == peripheral.identifier.uuidString
        }) {
            foundPeripherals[index] = peripheral
        } else {
            peripheralSubject.send(peripheral)
            foundPeripherals.append(peripheral)
        }
    }

    func connect(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot connect: Bluetooth is not powered on.")
            return
        }
        logger.info("Connecting to: \(peripheral.name ?? "")")
        centralManager.connect(
            peripheral,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        )
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_: CBCentralManager, peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectedPeripheral?.discoverServices(Self.services)
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripheralAsync(
        _ timeout: TimeInterval,
        oilerObdSetting: OneObdSetting
    ) async throws
        -> CBPeripheral?
    {
        // returns a single peripheral with the specified services
        try await Timeout(seconds: timeout, oilerObdSetting: oilerObdSetting) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CBPeripheral, Error>) in
                self.foundPeripheralCompletion = { peripheral, error in
                    if let peripheral = peripheral {
                        continuation.resume(returning: peripheral)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                    self.foundPeripheralCompletion = nil
                }
                self.startScanning(Self.services)
            }
        }
    }

    // MARK: - Peripheral Delegate Methods

    func didDiscoverServices(_ peripheral: CBPeripheral, error _: Error?) {
        for service in peripheral.services ?? [] {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            switch service.uuid {
            case BLEUUIDs.serviceVeepeak:
                peripheral.discoverCharacteristics(
                    [BLEUUIDs.charVeepeak],
                    for: service
                )
            case BLEUUIDs.serviceOBDLinkCX:
                peripheral.discoverCharacteristics(
                    [BLEUUIDs.charOBDLinkCXRead, BLEUUIDs.charOBDLinkCXWrite],
                    for: service
                )
            case BLEUUIDs.serviceVGate:
                peripheral.discoverCharacteristics(
                    [BLEUUIDs.charVGateRead, BLEUUIDs.charVGateWrite],
                    for: service
                )
            default:
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func didDiscoverCharacteristics(
        _ peripheral: CBPeripheral,
        service: CBService,
        error _: Error?
    ) {
        guard let characteristics = service.characteristics,
            !characteristics.isEmpty
        else {
            return
        }

        for characteristic in characteristics {
            logger.info(
                "Characteristic discovered: \(characteristic.uuid.uuidString), properties: \(String(describing: characteristic.properties))"
            )

            switch characteristic.uuid.uuidString {
            case BLEUUIDs.charVeepeak.uuidString:  // for service FFE0
                ecuWriteCharacteristic = characteristic
                ecuReadCharacteristic = characteristic
            case BLEUUIDs.charOBDLinkCXRead.uuidString:  // for service FFF0
                ecuReadCharacteristic = characteristic
            case BLEUUIDs.charOBDLinkCXWrite.uuidString:  // for service FFF0
                ecuWriteCharacteristic = characteristic
            case BLEUUIDs.charVGateRead.uuidString:  // for service 18F0
                ecuReadCharacteristic = characteristic
            case BLEUUIDs.charVGateWrite.uuidString:  // for service 18F0
                ecuWriteCharacteristic = characteristic
            default:
                // Dynamic fallback if UUIDs don't match known ones
                if ecuWriteCharacteristic == nil,
                    characteristic.properties.contains(.write)
                {
                    ecuWriteCharacteristic = characteristic
                    logger.info("Assigned write characteristic dynamically")
                }
                if ecuReadCharacteristic == nil,
                    characteristic.properties.contains(.read)
                        || characteristic.properties.contains(.notify)
                {
                    ecuReadCharacteristic = characteristic
                    logger.info("Assigned read characteristic dynamically")
                }
            }

            /*
             •    Notifications are only enabled on the correct read characteristic
             •    Supports OBDLink, Veepeak, VGate, or any fallback device
             •    Avoids noisy or incorrect notifications
             */
            // SABI TWEAK ChatGPT suggestion (AFTER switch block)
            // ✅ Now that ecuReadCharacteristic may be set, safely enable notify:
            if characteristic.uuid == ecuReadCharacteristic?.uuid,
                characteristic.properties.contains(.notify)
            {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if connectionCompletion != nil,
            ecuWriteCharacteristic != nil,
            ecuReadCharacteristic != nil
        {
            connectionCompletion?(peripheral, nil)
        }
    }

    func didUpdateValue(
        _: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            logger.error(
                "Error reading characteristic value: \(error.localizedDescription)"
            )
            return
        }

        guard let characteristicValue = characteristic.value else {
            return
        }

        switch characteristic {
        case ecuReadCharacteristic:
            processReceivedData(
                characteristicValue,
                completion: sendMessageCompletion
            )
        default:
            if let responseString = String(
                data: characteristicValue,
                encoding: .utf8
            ) {
                logger.info(
                    "Unknown characteristic: \(characteristic)\nResponse: \(responseString)"
                )
            }
        }
    }

    func didFailToConnect(
        _: CBCentralManager,
        peripheral: CBPeripheral,
        error _: Error?
    ) {
        logger.error(
            "Failed to connect to peripheral: \(peripheral.name ?? "Unnamed")"
        )
        resetConfigure()
    }

    func didDisconnect(
        _: CBCentralManager,
        peripheral: CBPeripheral,
        error _: Error?
    ) {
        logger.info(
            "Disconnected from peripheral: \(peripheral.name ?? "Unnamed")"
        )
        resetConfigure()
    }

    func willRestoreState(_: CBCentralManager, dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral], let peripheral = peripherals.first
        {
            logger.debug(
                "Restoring peripheral: \(peripherals[0].name ?? "Unnamed")"
            )
            connectedPeripheral = peripheral
            connectedPeripheral?.delegate = self
        }
    }

    func connectionEventDidOccur(
        _: CBCentralManager,
        event: CBConnectionEvent,
        peripheral _: CBPeripheral
    ) {
        logger.error("Connection event occurred: \(event.rawValue)")
    }

    // MARK: - Async Methods

    func connectAsync(
        timeout: TimeInterval,
        peripheral _: CBPeripheral? = nil,
        oilerObdSetting: OneObdSetting
    )
        async throws
    {
        if connectionState != .disconnected {
            return
        }
        guard
            let peripheral = try await scanForPeripheralAsync(
                timeout,
                oilerObdSetting: oilerObdSetting
            )
        else {
            throw BLEManagerError.peripheralNotFound
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            self.connectionCompletion = { peripheral, error in
                if peripheral != nil {
                    continuation.resume()
                } else if let error = error {
                    continuation.resume(throwing: error)
                }

                self.connectionCompletion = nil
            }
            connect(to: peripheral)
        }
        connectionCompletion = nil
    }

    /// Sends a message to the connected peripheral and returns the response.
    /// - Parameter message: The message to send.
    /// - Returns: The response from the peripheral.
    /// - Throws:
    ///     `BLEManagerError.sendingMessagesInProgress` if a message is already being sent.
    ///     `BLEManagerError.missingPeripheralOrCharacteristic` if the peripheral or ecu characteristic is missing.
    ///     `BLEManagerError.incorrectDataConversion` if the data cannot be converted to ASCII.
    ///     `BLEManagerError.peripheralNotConnected` if the peripheral is not connected.
    ///     `BLEManagerError.timeout` if the operation times out.
    ///     `BLEManagerError.unknownError` if an unknown error occurs.
    func sendCommand(
        _ command: String,
        retries _: Int = 3,
        oilerObdSetting: OneObdSetting
    ) async throws
        -> [String]
    {
        guard sendMessageCompletion == nil else {
            throw BLEManagerError.sendingMessagesInProgress
        }

        guard isBluetoothPoweredOn else {
            logger.error("Bluetooth is off. Cannot send command.")
            throw BLEManagerError.peripheralNotConnected
        }

        guard connectionState == .connectedToAdapter else {
            logger.error("Not connected to adapter.")
            throw BLEManagerError.peripheralNotConnected
        }

        logger.info("Sending command: \(command)")

        guard let connectedPeripheral = connectedPeripheral,
            let characteristic = ecuWriteCharacteristic,
            let data = "\(command)\r".data(using: .ascii)
        else {
            logger.error("Error: Missing peripheral or ecu characteristic.")
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        return try await Timeout(
            seconds: oilerObdSetting.timeoutSecondsSendCommandBT,
            oilerObdSetting: oilerObdSetting
        ) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String], Error>) in
                // Set up a timeout timer
                self.sendMessageCompletion = { response, error in
                    if let response = response {
                        continuation.resume(returning: response)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                    self.sendMessageCompletion = nil
                }
                connectedPeripheral.writeValue(
                    data,
                    for: characteristic,
                    type: .withResponse
                )
            }
        }
    }

    /// Processes the received data from the peripheral.
    /// - Parameters:
    ///  - data: The data received from the peripheral.
    ///  - completion: The completion handler to call when the data has been processed.
    func processReceivedData(
        _ data: Data,
        completion _: (([String]?, Error?) -> Void)?
    ) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            return
        }

        if string.contains(">") {
            var lines =
                string
                .components(separatedBy: .newlines)
                .filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

            // remove the last line
            lines.removeLast()
            logger.debug("Response: \(lines)")

            if let sendMessageCompletion {
                if let firstLine = lines.first,
                    firstLine.containsCaseInsensitive(
                        c: Obd2Helper.obdServiceSpecificsResponseNoData
                    )
                {
                    // SABI TWEAK
                    logger.info("SABI TWEAK: sendMessageCompletion?([], nil)")
                    sendMessageCompletion([], nil)
                } else {
                    sendMessageCompletion(lines, nil)
                }
            }
            buffer.removeAll()
        }
    }

    func scanForPeripherals(oilerObdSetting: OneObdSetting) async throws {
        startScanning(nil)
        try await Task.sleep(
            nanoseconds: UInt64(
                oilerObdSetting.delayNanosecondsBTPeripherals
            )
        )
        stopScan()
    }

    // MARK: - Utility Methods

    /// Cancels the current operation and throws a timeout error.
    func Timeout<R>(
        seconds: TimeInterval,
        oilerObdSetting: OneObdSetting,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            // Start actual work.
            group.addTask {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            // Start timeout child task.
            group.addTask {
                if seconds > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            seconds
                                * Double(
                                    oilerObdSetting
                                        .oneSecondNanoseconds
                                )
                        )
                    )
                }
                try Task.checkCancellation()
                // We’ve reached the timeout.
                if self.foundPeripheralCompletion != nil {
                    self.foundPeripheralCompletion?(
                        nil,
                        BLEManagerError.scanTimeout
                    )
                }
                throw BLEManagerError.timeout
            }
            // First finished child task wins, cancel the other task.
            let result = try await group.next()!
            group.cancelAll()
            self.sendMessageCompletion = nil
            self.foundPeripheralCompletion = nil
            self.connectionCompletion = nil
            return result
        }
    }

    private func resetConfigure() {
        stopScan()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
        sendMessageCompletion = nil
        foundPeripheralCompletion = nil
        connectionCompletion = nil
    }
}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate

/// Extension to conform to CBCentralManagerDelegate and CBPeripheralDelegate
/// and handle the delegate methods.
extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        didDiscover(
            central,
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        didConnect(central, peripheral: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        didFailToConnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        didDisconnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        willRestoreState(central, dict: dict)
    }
}

enum BLEManagerError: Error, CustomStringConvertible {
    case missingPeripheralOrCharacteristic
    case unknownCharacteristic
    case scanTimeout
    case sendMessageTimeout
    case stringConversionFailed
    case noData
    case incorrectDataConversion
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout
    case peripheralNotFound

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return
                "Error: Device not connected. Make sure the device is correctly connected."
        case .scanTimeout:
            return
                "Error: Scan timed out. Please try to scan again or check the device's Bluetooth connection."
        case .sendMessageTimeout:
            return
                "Error: Send message timed out. Please try to send the message again or check the device's Bluetooth connection."
        case .stringConversionFailed:
            return
                "Error: Failed to convert string. Please make sure the string is in the correct format."
        case .noData:
            return "Error: No Data"
        case .unknownCharacteristic:
            return "Error: Unknown characteristic"
        case .incorrectDataConversion:
            return "Error: Incorrect data conversion"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        }
    }
}
