import CoreBluetooth
import Foundation
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

struct AirQualitySample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let pm1: Double
    let pm25: Double
    let pm10: Double
    let particleCounts: [Int]
}

enum AirQualityLevel: String, CaseIterable {
    case good = "Good"
    case moderate = "Moderate"
    case unhealthyForSensitiveGroups = "Unhealthy for sensitive groups"
    case unhealthy = "Unhealthy"
    case veryUnhealthy = "Very unhealthy"
    case hazardous = "Hazardous"

    init(pm25: Double) {
        switch pm25 {
        case ...9.0:
            self = .good
        case ...35.4:
            self = .moderate
        case ...55.4:
            self = .unhealthyForSensitiveGroups
        case ...125.4:
            self = .unhealthy
        case ...225.4:
            self = .veryUnhealthy
        default:
            self = .hazardous
        }
    }
}

private struct PM25DataParser {
    private enum ReportSection {
        case unknown
        case standardConcentrations
        case environmentalConcentrations
        case particleCounts
        case aqi
    }

    private var binaryBuffer = Data()
    private var textBuffer = ""
    private var reportSection = ReportSection.unknown
    private(set) var status = "Waiting for sensor data"

    mutating func append(_ data: Data) -> [AirQualitySample] {
        var samples = parseBinary(data)
        if !samples.isEmpty {
            status = "Plantower binary values recognized"
        }

        if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) {
            textBuffer.append(text)
            if status == "Waiting for sensor data" {
                status = "Receiving Adafruit text report"
            }
            samples.append(contentsOf: parseCompletedLines())

            if !textBuffer.contains(where: { $0.isNewline }),
               let sample = parseStandaloneText(textBuffer) {
                samples.append(sample)
                textBuffer.removeAll(keepingCapacity: true)
                status = "PM values recognized"
            }

            if textBuffer.count > 2_048 {
                textBuffer = String(textBuffer.suffix(2_048))
            }
        }
        return samples
    }

    private mutating func parseCompletedLines() -> [AirQualitySample] {
        var samples: [AirQualitySample] = []

        while let lineEnding = textBuffer.firstIndex(where: { $0.isNewline }) {
            let line = String(textBuffer[..<lineEnding])
            var nextIndex = textBuffer.index(after: lineEnding)

            while nextIndex < textBuffer.endIndex, textBuffer[nextIndex].isNewline {
                nextIndex = textBuffer.index(after: nextIndex)
            }

            textBuffer.removeSubrange(textBuffer.startIndex..<nextIndex)
            if let sample = parseReportLine(line) {
                samples.append(sample)
            }
        }

        return samples
    }

    private mutating func parseReportLine(_ line: String) -> AirQualitySample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        if normalized.contains("concentration units (standard)") {
            reportSection = .standardConcentrations
            status = "Reading standard concentration section"
            return nil
        }
        if normalized.contains("concentration units (environmental)") {
            reportSection = .environmentalConcentrations
            status = "Reading environmental concentration section"
            return nil
        }
        if normalized.hasPrefix("particles") {
            reportSection = .particleCounts
            return nil
        }
        if normalized == "aqi" || normalized.hasPrefix("aqi ") {
            reportSection = .aqi
            return nil
        }

        if reportSection == .environmentalConcentrations,
           let sample = parseAdafruitConcentrationRow(trimmed) {
            status = "Environmental PM values recognized"
            return sample
        }

        // Preserve support for compact JSON, CSV, and labeled messages that
        // aren't part of the multiline Adafruit console report.
        if reportSection == .unknown, let sample = parseStandaloneText(trimmed) {
            status = "PM values recognized"
            return sample
        }

        return nil
    }

    private mutating func parseBinary(_ data: Data) -> [AirQualitySample] {
        binaryBuffer.append(data)
        var samples: [AirQualitySample] = []

        while binaryBuffer.count >= 4 {
            guard let headerIndex = binaryBuffer.indices.dropLast().first(where: {
                binaryBuffer[$0] == 0x42 && binaryBuffer[$0 + 1] == 0x4D
            }) else {
                let possibleHeader = binaryBuffer.last == 0x42
                binaryBuffer.removeAll(keepingCapacity: true)
                if possibleHeader {
                    binaryBuffer.append(0x42)
                }
                break
            }

            if headerIndex > binaryBuffer.startIndex {
                binaryBuffer.removeSubrange(binaryBuffer.startIndex..<headerIndex)
            }

            guard binaryBuffer.count >= 4 else { break }
            let payloadLength = Int(binaryBuffer[2]) << 8 | Int(binaryBuffer[3])
            let frameLength = payloadLength + 4

            guard payloadLength == 28 else {
                binaryBuffer.removeFirst()
                continue
            }
            guard binaryBuffer.count >= frameLength else { break }

            let frame = Data(binaryBuffer.prefix(frameLength))
            let expectedChecksum = UInt16(frame[30]) << 8 | UInt16(frame[31])
            let checksum = frame.prefix(30).reduce(UInt16(0)) { $0 &+ UInt16($1) }

            if checksum == expectedChecksum {
                samples.append(
                    AirQualitySample(
                        timestamp: Date(),
                        pm1: Double(value(at: 10, in: frame)),
                        pm25: Double(value(at: 12, in: frame)),
                        pm10: Double(value(at: 14, in: frame)),
                        particleCounts: stride(from: 16, through: 26, by: 2).map {
                            Int(value(at: $0, in: frame))
                        }
                    )
                )
                binaryBuffer.removeFirst(frameLength)
            } else {
                binaryBuffer.removeFirst()
            }
        }

        return samples
    }

    private func parseStandaloneText(_ text: String) -> AirQualitySample? {
        if let jsonData = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let pm1 = number(in: object, keys: ["pm1", "pm1.0", "pm10_env"]),
           let pm25 = number(in: object, keys: ["pm25", "pm2.5", "pm2_5", "pm25_env"]),
           let pm10 = number(in: object, keys: ["pm10", "pm10.0", "pm100_env"]) {
            return sample(pm1: pm1, pm25: pm25, pm10: pm10)
        }

        if let pm1 = labeledNumber(in: text, labels: ["pm\\s*1(?:\\.0)?"]),
           let pm25 = labeledNumber(in: text, labels: ["pm\\s*2(?:\\.5)?", "pm25", "pm2_5"]),
           let pm10 = labeledNumber(in: text, labels: ["pm\\s*10(?:\\.0)?"]) {
            return sample(pm1: pm1, pm25: pm25, pm10: pm10)
        }

        let pieces = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if pieces.count == 3 {
            return sample(pm1: pieces[0], pm25: pieces[1], pm10: pieces[2])
        }

        return nil
    }

    private func parseAdafruitConcentrationRow(_ text: String) -> AirQualitySample? {
        let pattern = "(?i)PM\\s*1(?:\\.0)?\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)"
            + ".*?PM\\s*2(?:\\.5)?\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)"
            + ".*?PM\\s*10(?:\\.0)?\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let pm1 = capturedNumber(at: 1, from: match, in: text),
              let pm25 = capturedNumber(at: 2, from: match, in: text),
              let pm10 = capturedNumber(at: 3, from: match, in: text) else {
            return nil
        }
        return sample(pm1: pm1, pm25: pm25, pm10: pm10)
    }

    private func number(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    private func labeledNumber(in text: String, labels: [String]) -> Double? {
        for labelPattern in labels {
            let pattern = "(?i)(?:^|[^a-z0-9])\(labelPattern)\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)"
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ), let value = capturedNumber(at: 1, from: match, in: text) else {
                continue
            }
            return value
        }
        return nil
    }

    private func capturedNumber(
        at index: Int,
        from match: NSTextCheckingResult,
        in text: String
    ) -> Double? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Double(text[range])
    }

    private func sample(pm1: Double, pm25: Double, pm10: Double) -> AirQualitySample {
        AirQualitySample(
            timestamp: Date(),
            pm1: pm1,
            pm25: pm25,
            pm10: pm10,
            particleCounts: []
        )
    }

    private func value(at offset: Int, in frame: Data) -> UInt16 {
        UInt16(frame[offset]) << 8 | UInt16(frame[offset + 1])
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
    private(set) var airQualitySamples: [AirQualitySample] = []
    private(set) var subscribedCharacteristicCount = 0
    private(set) var parserStatus = "Waiting for sensor data"

    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var frameParsers: [CBUUID: PM25DataParser] = [:]

    var latestAirQualitySample: AirQualitySample? {
        airQualitySamples.last
    }

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
        airQualitySamples.removeAll()
        frameParsers.removeAll()
        parserStatus = "Waiting for sensor data"
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
        airQualitySamples.removeAll()
        frameParsers.removeAll()
        parserStatus = "Waiting for sensor data"
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

        var parser = frameParsers[characteristic.uuid] ?? PM25DataParser()
        let parsedSamples = parser.append(data)
        airQualitySamples.append(contentsOf: parsedSamples)
        parserStatus = parser.status
        frameParsers[characteristic.uuid] = parser

        if airQualitySamples.count > 300 {
            airQualitySamples.removeFirst(airQualitySamples.count - 300)
        }

        if receivedValues.count > 200 {
            receivedValues.removeLast(receivedValues.count - 200)
        }
    }
}
