import CoreBluetooth
import Observation

struct DiscoveredBluetoothDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct ReceivedBluetoothValue: Identifiable, Equatable {
    let id = UUID()
    let characteristicUUID: String
    let timestamp: Date
    let byteCount: Int
    let text: String?
    let hexadecimal: String

    init(characteristicUUID: CBUUID, data: Data) {
        self.characteristicUUID = characteristicUUID.uuidString
        timestamp = Date()
        byteCount = data.count
        hexadecimal = data.map { String(format: "%02X", $0) }.joined(separator: " ")

        if let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !decoded.isEmpty {
            text = decoded
        } else {
            text = nil
        }
    }
}

@Observable
final class BluetoothManager: NSObject {
    private(set) var state: CBManagerState = .unknown
    private(set) var devices: [DiscoveredBluetoothDevice] = []
    private(set) var isScanning = false
    private(set) var connectedDeviceID: UUID?
    private(set) var connectionError: String?
    private(set) var receivedValues: [ReceivedBluetoothValue] = []
    private(set) var subscribedCharacteristicCount = 0

    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]

    var stateDescription: String {
        switch state {
        case .unknown:
            "Checking Bluetooth…"
        case .resetting:
            "Bluetooth is resetting"
        case .unsupported:
            "Bluetooth Low Energy is not supported"
        case .unauthorized:
            "Bluetooth access is not authorized"
        case .poweredOff:
            "Bluetooth is turned off"
        case .poweredOn:
            "Bluetooth is ready"
        @unknown default:
            "Bluetooth status is unavailable"
        }
    }

    var canScan: Bool {
        state == .poweredOn
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning(serviceUUIDs: [CBUUID]? = nil) {
        guard state == .poweredOn, let centralManager else {
            return
        }

        connectionError = nil
        devices.removeAll()
        peripheralsByID.removeAll()
        centralManager.scanForPeripherals(withServices: serviceUUIDs)
        isScanning = centralManager.isScanning
    }

    func stopScanning() {
        centralManager?.stopScan()
        isScanning = false
    }

    func connect(to device: DiscoveredBluetoothDevice) {
        guard let peripheral = peripheralsByID[device.id],
              peripheral.state == .disconnected else {
            return
        }

        connectionError = nil
        receivedValues.removeAll()
        subscribedCharacteristicCount = 0
        centralManager?.connect(peripheral)
    }

    func disconnect() {
        guard let connectedDeviceID,
              let peripheral = peripheralsByID[connectedDeviceID] else {
            return
        }

        centralManager?.cancelPeripheralConnection(peripheral)
    }

    func clearReceivedValues() {
        receivedValues.removeAll()
    }

    private func report(_ error: (any Error)?, fallback: String) {
        connectionError = error?.localizedDescription ?? fallback
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        isScanning = central.isScanning

        if central.state != .poweredOn {
            devices.removeAll()
            peripheralsByID.removeAll()
            connectedDeviceID = nil
            subscribedCharacteristicCount = 0
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let displayName = advertisedName ?? peripheral.name ?? "Unnamed device"
        let device = DiscoveredBluetoothDevice(id: id, name: displayName, rssi: RSSI.intValue)

        peripheralsByID[id] = peripheral

        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDeviceID = peripheral.identifier
        connectionError = nil
        stopScanning()

        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        report(error, fallback: "Could not connect to the device.")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        if connectedDeviceID == peripheral.identifier {
            connectedDeviceID = nil
            subscribedCharacteristicCount = 0
        }

        if let error {
            connectionError = error.localizedDescription
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            report(error, fallback: "Could not discover Bluetooth services.")
            return
        }

        guard let services = peripheral.services else {
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if let error {
            report(error, fallback: "Could not discover Bluetooth characteristics.")
            return
        }

        guard let characteristics = service.characteristics else {
            return
        }

        for characteristic in characteristics {
            let supportsUpdates = characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate)

            if supportsUpdates {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            report(error, fallback: "Could not subscribe to Bluetooth data.")
            return
        }

        if characteristic.isNotifying {
            subscribedCharacteristicCount += 1
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            report(error, fallback: "Could not read Bluetooth data.")
            return
        }

        guard let data = characteristic.value else {
            return
        }

        let value = ReceivedBluetoothValue(
            characteristicUUID: characteristic.uuid,
            data: data
        )
        receivedValues.insert(value, at: 0)

        if receivedValues.count > 200 {
            receivedValues.removeLast(receivedValues.count - 200)
        }
    }
}
