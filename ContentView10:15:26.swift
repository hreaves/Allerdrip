import Charts
import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @State private var bluetooth = BluetoothManager()
    @State private var showingAlertSettings = false
    @AppStorage("airQualityTriggerThreshold") private var airQualityTriggerThreshold = 15.0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ConnectionCard(bluetooth: bluetooth)

                    if bluetooth.connectedDeviceID == nil {
                        DevicePicker(bluetooth: bluetooth)
                    } else if let sample = bluetooth.latestAirQualitySample {
                        AirQualityDashboard(
                            bluetooth: bluetooth,
                            sample: sample,
                            airQualityTriggerThreshold: airQualityTriggerThreshold
                        )
                    } else {
                        ContentUnavailableView(
                            "Waiting for sensor data",
                            systemImage: "aqi.medium",
                            description: Text(waitingDescription)
                        )
                        .frame(minHeight: 260)
                    }
                }
                .padding()
            }
            .navigationTitle("Air Monitor")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Alert Settings", systemImage: "slider.horizontal.3") {
                        showingAlertSettings = true
                    }

                    NavigationLink {
                        TechnicalDetailsView(bluetooth: bluetooth)
                    } label: {
                        Label("Technical Details", systemImage: "waveform.path.ecg.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showingAlertSettings) {
                AlertSettingsView(threshold: $airQualityTriggerThreshold)
            }
        }
    }

    private var waitingDescription: String {
        if bluetooth.receivedValues.isEmpty {
            "The sensor is connected, but no Bluetooth data has arrived yet."
        } else {
            "Bluetooth data is arriving. \(bluetooth.parserStatus)."
        }
    }
}

private struct ConnectionCard: View {
    let bluetooth: BluetoothManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: bluetooth.connectedDeviceID == nil ? "antenna.radiowaves.left.and.right" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(bluetooth.connectedDeviceID == nil ? Color.secondary : Color.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(bluetooth.connectedDeviceID == nil ? bluetooth.stateDescription : "Sensor connected")
                    .font(.headline)
                Text(connectionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if bluetooth.connectedDeviceID != nil {
                Button("Disconnect") {
                    bluetooth.disconnect()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))

        if let connectionError = bluetooth.connectionError {
            Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 12))
        }
    }

    private var connectionDetail: String {
        guard bluetooth.connectedDeviceID != nil else {
            return bluetooth.isScanning ? "Searching for nearby devices…" : "Connect to begin monitoring"
        }
        return "Receiving from \(bluetooth.subscribedCharacteristicCount) data channel(s)"
    }
}

private struct DevicePicker: View {
    let bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby devices")
                    .font(.title3.bold())
                Spacer()
                Button(bluetooth.isScanning ? "Stop" : "Scan") {
                    bluetooth.isScanning ? bluetooth.stopScanning() : bluetooth.startScanning()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bluetooth.canScan)
            }

            if bluetooth.devices.isEmpty {
                ContentUnavailableView(
                    bluetooth.isScanning ? "Looking for sensors" : "No devices found",
                    systemImage: bluetooth.isScanning ? "dot.radiowaves.left.and.right" : "sensor"
                )
                .frame(minHeight: 180)
            } else {
                ForEach(bluetooth.devices) { device in
                    Button {
                        bluetooth.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.headline)
                                Text(signalDescription(for: device.rssi))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 16))
    }

    private func signalDescription(for rssi: Int) -> String {
        switch rssi {
        case (-60)...: "Strong signal"
        case (-75)...: "Good signal"
        default: "Weak signal"
        }
    }
}

private struct AirQualityDashboard: View {
    let bluetooth: BluetoothManager
    let sample: AirQualitySample
    let airQualityTriggerThreshold: Double

    private var level: AirQualityLevel { AirQualityLevel(pm25: sample.pm25) }
    private var airQualityAlertTriggered: Bool { sample.pm25 >= airQualityTriggerThreshold }
    private var recentSamples: [AirQualitySample] { Array(bluetooth.airQualitySamples.suffix(90)) }

    var body: some View {
        StatusBanner(level: level, isAlertTriggered: airQualityAlertTriggered)

        VStack(spacing: 8) {
            Text("PM2.5")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sample.pm25, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("µg/m³")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("Live sensor reading · \(sample.timestamp, format: .dateTime.hour().minute().second())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(level.color.opacity(0.12), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)

        HStack(spacing: 12) {
            MeasurementCard(title: "PM1.0", value: sample.pm1)
            MeasurementCard(title: "PM10", value: sample.pm10)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live PM2.5")
                        .font(.headline)
                    Text("Latest \(recentSamples.count) readings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Trigger \(airQualityTriggerThreshold, format: .number) µg/m³", systemImage: "bell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(recentSamples) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("PM2.5", reading.pm25)
                    )
                    .foregroundStyle(level.color)
                    .interpolationMethod(.linear)
                }

                RuleMark(y: .value("Alert threshold", airQualityTriggerThreshold))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .chartYAxisLabel("µg/m³")
            .frame(height: 190)
            .accessibilityLabel("Live PM2.5 history")
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 16))
    }
}

private struct StatusBanner: View {
    let level: AirQualityLevel
    let isAlertTriggered: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(isAlertTriggered ? level.alertHeadline : level.rawValue)
                    .font(.headline)
                Text(level.guidance)
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: isAlertTriggered ? "exclamationmark.triangle.fill" : level.symbol)
                .font(.title2)
        }
        .foregroundStyle(level.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(level.color.opacity(0.14), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct MeasurementCard: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.title.bold())
                .contentTransition(.numericText())
            Text("µg/m³")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct AlertSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var threshold: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("Trigger Settings") {
                    LabeledContent("PM2.5 threshold", value: "\(threshold.formatted()) µg/m³")
                    Slider(value: $threshold, in: 5...100, step: 5)
                    Text("The alert reacts to a single PM2.5 reading at or above this threshold. Lower values trigger more easily.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Quick presets") {
                    Button("Very sensitive · 10 µg/m³") { threshold = 10 }
                    Button("Demo default · 15 µg/m³") { threshold = 15 }
                    Button("EPA sensitive-groups boundary · 35.5 µg/m³") { threshold = 35.5 }
                }

                Section {
                    Text("This immediate trigger is intended for demonstration and is not an official AQI or certified safety alarm.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Alert Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TechnicalDetailsView: View {
    let bluetooth: BluetoothManager

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Bluetooth", value: bluetooth.stateDescription)
                LabeledContent("Data channels", value: "\(bluetooth.subscribedCharacteristicCount)")
                LabeledContent("Parsed samples", value: "\(bluetooth.airQualitySamples.count)")
                LabeledContent("Parser", value: bluetooth.parserStatus)
            }

            Section {
                if bluetooth.receivedValues.isEmpty {
                    Text("No packets received")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bluetooth.receivedValues) { value in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(value.characteristicUUID)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(value.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                            }
                            Text(value.hexadecimal.isEmpty ? "Empty value" : value.hexadecimal)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            if let text = value.text {
                                Text(text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            Text("\(value.byteCount) bytes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Raw packets")
                    Spacer()
                    if !bluetooth.receivedValues.isEmpty {
                        Button("Clear") { bluetooth.clearReceivedValues() }
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Device & Data")
    }
}

private extension AirQualityLevel {
    var alertHeadline: String {
        switch self {
        case .good: "Elevated PM2.5 detected"
        case .moderate: "Moderate air quality detected"
        case .unhealthyForSensitiveGroups: "Unhealthy air quality for sensitive groups"
        case .unhealthy: "Unhealthy air quality detected"
        case .veryUnhealthy: "Very unhealthy air quality detected"
        case .hazardous: "Hazardous air quality detected"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .moderate: .yellow
        case .unhealthyForSensitiveGroups: .orange
        case .unhealthy: .red
        case .veryUnhealthy: .purple
        case .hazardous: .brown
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .moderate: "minus.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    var guidance: String {
        switch self {
        case .good: "Air quality looks good."
        case .moderate: "Air quality is acceptable."
        case .unhealthyForSensitiveGroups: "Sensitive people may want to reduce exposure."
        case .unhealthy: "Consider reducing exposure."
        case .veryUnhealthy: "Avoid prolonged exposure."
        case .hazardous: "Move away from the source if it is safe to do so."
        }
    }
}

#Preview {
    ContentView()
}
