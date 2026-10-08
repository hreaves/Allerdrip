import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @State private var bluetooth = BluetoothManager()

    var body: some View {
        NavigationStack {
            List {
                BluetoothStatusSection(bluetooth: bluetooth)
                ReceivedDataSection(bluetooth: bluetooth)
                NearbyDevicesSection(bluetooth: bluetooth)
            }
            .navigationTitle("Bluetooth")
        }
    }
}

private struct BluetoothStatusSection: View {
    let bluetooth: BluetoothManager

    var body: some View {
        Section("Bluetooth") {
            Label(bluetooth.stateDescription, systemImage: statusSymbol)

            if let connectionError = bluetooth.connectionError {
                Text(connectionError)
                    .foregroundStyle(.red)
            }

            if bluetooth.connectedDeviceID != nil {
                LabeledContent("Data channels", value: "\(bluetooth.subscribedCharacteristicCount)")
            }

            Button(bluetooth.isScanning ? "Stop Scanning" : "Scan for Devices") {
                if bluetooth.isScanning {
                    bluetooth.stopScanning()
                } else {
                    bluetooth.startScanning()
                }
            }
            .disabled(!bluetooth.canScan)
        }
    }

    private var statusSymbol: String {
        switch bluetooth.state {
        case .poweredOn:
            "antenna.radiowaves.left.and.right"
        case .poweredOff:
            "antenna.radiowaves.left.and.right.slash"
        default:
            "exclamationmark.triangle"
        }
    }
}

private struct ReceivedDataSection: View {
    let bluetooth: BluetoothManager

    var body: some View {
        Section {
            if bluetooth.connectedDeviceID == nil {
                Text("Connect to a device to receive data.")
                    .foregroundStyle(.secondary)
            } else if bluetooth.receivedValues.isEmpty {
                Text("Connected. Waiting for characteristic data…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.receivedValues) { value in
                    ReceivedValueRow(value: value)
                }
            }
        } header: {
            HStack {
                Text("Received Data")
                Spacer()
                if !bluetooth.receivedValues.isEmpty {
                    Button("Clear") {
                        bluetooth.clearReceivedValues()
                    }
                    .textCase(nil)
                }
            }
        }
    }
}

private struct ReceivedValueRow: View {
    let value: ReceivedBluetoothValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(value.characteristicUUID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let text = value.text {
                Text(text)
                    .textSelection(.enabled)
            }

            Text(value.hexadecimal.isEmpty ? "Empty value" : value.hexadecimal)
                .font(.caption.monospaced())
                .foregroundStyle(value.text == nil ? .primary : .secondary)

            Text("\(value.byteCount) bytes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct NearbyDevicesSection: View {
    let bluetooth: BluetoothManager

    var body: some View {
        Section("Nearby Devices") {
            if bluetooth.devices.isEmpty {
                Text(bluetooth.isScanning ? "Looking for Bluetooth LE devices…" : "No devices found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.devices) { device in
                    Button {
                        if bluetooth.connectedDeviceID == device.id {
                            bluetooth.disconnect()
                        } else {
                            bluetooth.connect(to: device)
                        }
                    } label: {
                        BluetoothDeviceRow(
                            device: device,
                            isConnected: bluetooth.connectedDeviceID == device.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BluetoothDeviceRow: View {
    let device: DiscoveredBluetoothDevice
    let isConnected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                Text("Signal: \(device.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
            }
        }
        .contentShape(.rect)
    }
}

#Preview {
    ContentView()
}
