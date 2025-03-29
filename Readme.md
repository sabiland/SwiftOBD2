![Header](https://github.com/kkonteh97/SwiftOBD2/blob/main/Sources/Assets/github-header-image.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/kkonteh97/SwiftOBD2/blob/main/LICENSE) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)  ![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20-lightgrey) ![Swift Version](https://img.shields.io/badge/swift-5.0-orange) ![iOS Version](https://img.shields.io/badge/iOS-^14.0-blue) ![macOS Version](https://img.shields.io/badge/macOS-11.0%20%7C%2012.0-blue)

------------

NOTE: This is my fork/implementation. I use 2 global static objets for specific (bluetooth or wifi) configuration. I inject custom `OneObdSetting` object into `OBDService` init for `wifi` and `bluetooth` configuration.

```
enum OneObdSettingType: Codable {
    case connection
    case sensorsSelectedPIDs
}

final class OneObdSetting: Codable {
    let name: String
    var delayNanosecondsTimeoutAdapterInitialization: Int64
    var delayNanosecondsWifiRetryCommand: Int64
    var delayNanosecondsTimeoutDetectProtocolAutomatically: Int64
    var wifiIp: String
    var wifiPort: Int
    var connectionTimeoutSeconds: CGFloat
    var customData: String
    var obdProtocol: PROTOCOL?
    var obdConnectionName: String?
    // 20032025
    var oneSecondNanoseconds: Int64 = 1_000_000_000
    var delayNanosecondsBTPeripherals: Int64
    var bt: Bool
    var wifi: Bool {
        !bt
    }
    // Timeout factors
    var timeoutMultiplyCustomTimeouts: CGFloat = 3
    // 21032025
    var timeoutSecondsSendCommandBT: CGFloat
    // 26032025
    var settingType: OneObdSettingType
    var lastUsedSensorsPIDs = [PIDData]()
    // 27032025
    var sensorsMonitoringUnit: MeasurementUnit = .metric
    var sensorsMonitoringInterval: TimeInterval = 0.3

    convenience init(
        name: String,
        lastUsedSensorsPIDs: [PIDData]
    ) {
        self.init(
            name: name,
            delayNanosecondsTimeoutAdapterInitialization: 0,
            delayNanosecondsTimeoutDetectProtocolAutomatically: 0,
            connectionTimeoutSeconds: 0,
            bt: false
        )
        self.lastUsedSensorsPIDs = lastUsedSensorsPIDs
        self.settingType = .sensorsSelectedPIDs
    }

    // 26032025
    func updateLastMonitoredPIDs(lastUsedSensorsPIDs: [PIDData]) {
        self.lastUsedSensorsPIDs = lastUsedSensorsPIDs
        // STORE
        OilerHelper.masterOilerSettings.storeOilerSettings()
    }

    init(
        name: String,
        delayNanosecondsTimeoutAdapterInitialization: Int64,
        delayNanosecondsTimeoutDetectProtocolAutomatically: Int64,
        connectionTimeoutSeconds: CGFloat,
        bt: Bool,
        delayNanosecondsWifiRetryCommand: Int64 = 0,
        delayNanosecondsBTPeripherals: Int64 = 0,
        wifiIp: String = String(),
        wifiPort: Int = 0,
        timeoutSecondsSendCommandBT: CGFloat = 3,
        settingType: OneObdSettingType = .connection
    ) {
        self.name = name
        self.delayNanosecondsTimeoutAdapterInitialization =
            delayNanosecondsTimeoutAdapterInitialization
        self.delayNanosecondsWifiRetryCommand =
            delayNanosecondsWifiRetryCommand
        self.delayNanosecondsTimeoutDetectProtocolAutomatically =
            delayNanosecondsTimeoutDetectProtocolAutomatically
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.wifiIp = wifiIp.fullTrim()
        self.wifiPort = wifiPort
        self.customData = "\(self.wifiIp):\(self.wifiPort)"
        self.delayNanosecondsBTPeripherals = delayNanosecondsBTPeripherals
        self.bt = bt
        self.timeoutSecondsSendCommandBT = timeoutSecondsSendCommandBT
        self.settingType = settingType
    }

    // 11032025
    func resetWifiAndPort() {
        updateWifiIpAndPort(
            ipAndPort: "\(Obd2Helper.mainIp):\(Obd2Helper.mainPort)"
        )
    }

    func updateWifiIpAndPort(ipAndPort: String) {
        let pair = ipAndPort.generateIpAndPort()
        self.wifiIp = pair.ip
        self.wifiPort = Int(pair.port)!
        self.customData = "\(self.wifiIp):\(self.wifiPort)"
        // STORE
        OilerHelper.masterOilerSettings.storeOilerSettings()
    }

    func updateObdProtocol(obdProtocol: PROTOCOL?) {
        self.obdProtocol = obdProtocol
        // STORE
        OilerHelper.masterOilerSettings.storeOilerSettings()
    }

    // 12032025
    func updateObdConnectionName(connectionName: String?) {
        self.obdConnectionName = connectionName
        // STORE
        OilerHelper.masterOilerSettings.storeOilerSettings()
    }

}
```

------------

SwiftOBD2 is a Swift package designed to simplify communication with vehicles using an ELM327 OBD2 adapter. It provides a straightforward and powerful interface for interacting with your vehicle's onboard diagnostics system, allowing you to retrieve real-time data and perform diagnostics. [Sample App](https://github.com/kkonteh97/SwiftOBD2App).

### Requirements

- iOS 14.0+ / macOS 11.0+
- Xcode 13.0+
- Swift 5.0+

### Key Features

* Connection Management:
    * Establishes connections to the OBD2 adapter via Bluetooth or Wi-Fi.
    * Handles the initialization of the adapter and the vehicle connection process.
    * Manages connection states (disconnected, connectedToAdapter, connectedToVehicle).Command Interface: Send and receive OBD2 commands for powerful interaction with your vehicle.
    
* Data Retrieval:
    * Supports requests for real-time vehicle data (RPM, speed, etc.) using standard OBD2 PIDs (Parameter IDs).
    * Provides functions to continuously poll and retrieve updated measurements.
    * Can get a list of supported PIDs from the vehicle.
    
* Diagnostics:
    * Retrieves and clears diagnostic trouble codes (DTCs).
    * Gets the overall status of the vehicle's onboard systems.Sensor Monitoring: Retrieve and view data from various vehicle sensors in real time.
    
* Adaptability and Configuration
    * Can switch between Bluetooth and Wi-Fi communication seamlessly.
    * Allows for testing and development with a demo mode.
    

### Roadmap

- [x] Connect to an OBD2 adapter via Bluetooth Low Energy (BLE) 
- [x] Retrieve error codes (DTCs) stored in the vehicle's OBD2 system
- [x] Retrieve various OBD2 Parameter IDs (PIDs) for monitoring vehicle parameters
- [x] Retrieve real-time vehicle data (RPM, speed, etc.) using standard OBD2 PIDs
- [x] Get supported PIDs from the vehicle
- [x] Clear error codes (DTCs) stored in the vehicle's OBD2 system
- [ ] Run tests on the OBD2 system
- [ ] Retrieve vehicle status since DTCs cleared
- [ ] Connect to an OBD2 adapter via WIFI
- [ ] Add support for custom PIDs
    
    
### Setting Up a Project

1. Create a New Swift Project:
    * Open Xcode and start a new iOS project (You can use a simple "App" template).

2. Add the SwiftOBD2 Package:
    * In Xcode, navigate to File > Add Packages...
    * Enter this repository's URL: https://github.com/kkonteh97/SwiftOBD2/
    * Select the desired dependency rule (version, branch, or commit).

3. Permissions and Capabilities:
    * If your app will use Bluetooth, you need to request the appropriate permissions and capabilities:
        * Add NSBluetoothAlwaysUsageDescription to your Info.plist file with a brief description of why your app needs to use Bluetooth.
        * Navigate to the Signing & Capabilities tab in your project settings and add the Background Modes capability. Enable the Uses Bluetooth LE Accessories option.
        
### Key Concepts

* SwiftUI & Combine: Your code leverages the SwiftUI framework for building the user interface and Combine for reactive handling of updates from the OBDService.
* OBDService: This is the core class within the SwiftOBD2 package. It handles communication with the OBD-II adapter and processes data from the vehicle.
* OBDServiceDelegate: This protocol is crucial for receiving updates about the connection state and other events from the OBDService.
* OBDCommand: These represent specific requests you can make to the vehicle's ECU (Engine Control Unit) for data.

### Usage

1. Import and Setup
    * Begin by importing the necessary modules:


```Swift
import SwiftUI
import SwiftOBD2
import Combine
```

2. ViewModel
    * Create a ViewModel class that conforms to the ObservableObject protocol. This allows your SwiftUI views to observe changes in the ViewModel.
    * Inside the ViewModel:
        * Define a @Published property measurements to store the collected data.
        * Initialize an OBDService instance, setting the desired connection type (e.g., Bluetooth, Wi-Fi).

3. Connection Handling
    * Implement the connectionStateChanged method from the OBDServiceDelegate protocol. Update the UI based on connection state changes (disconnected, connected, etc.) or handle any necessary logic.
    
4. Starting the Connection
    * Create a startConnection function (ideally using async/await) to initiate the connection process with the OBD-II adapter. The OBDService's startConnection method will return useful OBDInfo about the vehicle. Like the Supported PIDs, Protocol, etc.
    
5. Stopping the Connection
    * Create a stopConnection function to cleanly disconnect the service.
    
6. Retrieving Information
    * Use the OBDService's methods to retrieve data from the vehicle, such as getting the vehicle's status, scanning for trouble codes, or requesting specific PIDs.
        * getTroubleCodes: Retrieve diagnostic trouble codes (DTCs) from the vehicle's OBD-II system.
        * getStatus: Retrieves Status since DTCs cleared.

7. Continuous Updates
    * Use the startContinuousUpdates method to continuously poll and retrieve updated measurements from the vehicle. This method returns a Combine publisher that you can subscribe to for updates.
    * Can also add PIDs to the continuous updates using the addPID method.
    
### Code Example
```Swift
class ViewModel: ObservableObject {
    @Published var measurements: [OBDCommand: MeasurementResult] = [:]
    @Published var connectionState: ConnectionState = .disconnected

    var cancellables = Set<AnyCancellable>()
    var requestingPIDs: [OBDCommand] = [.mode1(.rpm)] {
        didSet {
            addPID(command: requestingPIDs[-1])
        }
    }
    
    init() {
        obdService.$connectionState
            .assign(to: &$connectionState)
    }

    let obdService = OBDService(connectionType: .bluetooth)

    func startContinousUpdates() {
        obdService.startContinuousUpdates([.mode1(.rpm)]) // You can add more PIDs
            .sink { completion in
                print(completion)
            } receiveValue: { measurements in
                self.measurements = measurements
            }
            .store(in: &cancellables)
    }

    func addPID(command: OBDCommand) {
        obdService.addPID(command)
    }

    func stopContinuousUpdates() {
        cancellables.removeAll()
    }

    func startConnection() async throws  {
        let obd2info = try await obdService.startConnection(preferedProtocol: .protocol6)
        print(obd2info)
    }

    func stopConnection() {
        obdService.stopConnection()
    }

    func switchConnectionType() {
        obdService.switchConnectionType(.wifi)
    }

    func getStatus() async {
        let status = try? await obdService.getStatus()
        print(status ?? "nil")
    }

    func getTroubleCodes() async {
        let troubleCodes = try? await obdService.scanForTroubleCodes()
        print(troubleCodes ?? "nil")
    }
}

struct ContentView: View {
    @ObservedObject var viewModel = ViewModel()
    var body: some View {
        VStack(spacing: 20) {
            Text("Connection State: \(viewModel.connectionState.rawValue)")
            ForEach(viewModel.requestingPIDs, id: \.self) { pid in
                Text("\(pid.properties.description): \(viewModel.measurements[pid]?.value ?? 0) \(viewModel.measurements[pid]?.unit.symbol ?? "")")
            }
            Button("Connect") {
                Task {
                    do {
                        try await viewModel.startConnection()
                        viewModel.startContinousUpdates()
                    } catch {
                        print(error)
                    }
                }
            }
            .buttonStyle(.bordered)

            Button("Stop") {
                viewModel.stopContinuousUpdates()
            }
            .buttonStyle(.bordered)

            Button("Add PID") {
                viewModel.requestingPIDs.append(.mode1(.speed))
            }
        }
        .padding()
    }
}

```

### Supported OBD2 Commands

A comprehensive list of supported OBD2 commands will be available in the full documentation (coming soon).

### Important Considerations

* Ensure you have a compatible ELM327 OBD2 adapter.
* Permissions: If using Bluetooth, your app may need to request Bluetooth permissions from the user.
* Error Handling:  Implement robust error handling mechanisms to gracefully handle potential communication issues.
* Background Updates (Optional): If your app needs background OBD2 data updates, explore iOS background fetch capabilities and fine-tune your library and app to work effectively in the background.


## Contributing

This project welcomes your contributions! Feel free to open issues for bug reports or feature requests. To contribute code:

1. Fork the repository.
2. Create your feature branch.
3. Commit your changes with descriptive messages.
4. Submit a pull request for review.

## License

The Swift OBD package is distributed under the MIT license. See the [LICENSE](https://github.com/kkonteh97/SwiftOBD2/blob/main/LICENSE) file for more details.

------------

##### Give this package a ⭐️ if you find it useful!
