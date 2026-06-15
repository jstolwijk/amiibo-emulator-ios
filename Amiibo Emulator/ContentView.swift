import SwiftUI

struct ContentView: View {
    @ObservedObject var bluetoothManager: ChameleonBluetoothManager

    var body: some View {
        NavigationStack {
            List {
                connectionSection

                if bluetoothManager.connectedDeviceName != nil {
                    slotsSection
                } else {
                    devicesSection
                }
            }
            .navigationTitle("Amiibo Emulator")
            .toolbar {
                if bluetoothManager.connectedDeviceName != nil {
                    ToolbarItem {
                        Button {
                            bluetoothManager.refreshSlots()
                        } label: {
                            Label("Refresh Slots", systemImage: "arrow.clockwise")
                        }
                        .disabled(bluetoothManager.isLoadingSlots)
                    }
                }
            }
            .alert(
                "Bluetooth Error",
                isPresented: Binding(
                    get: { bluetoothManager.errorMessage != nil },
                    set: { if !$0 { bluetoothManager.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    bluetoothManager.errorMessage = nil
                }
            } message: {
                Text(bluetoothManager.errorMessage ?? "")
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Status", value: bluetoothManager.bluetoothState)

            if let deviceName = bluetoothManager.connectedDeviceName {
                LabeledContent("Device", value: deviceName)
                Button("Disconnect", role: .destructive) {
                    bluetoothManager.disconnect()
                }
            } else {
                Button {
                    if bluetoothManager.isScanning {
                        bluetoothManager.stopScanning()
                    } else {
                        bluetoothManager.startScanning()
                    }
                } label: {
                    Label(
                        bluetoothManager.isScanning ? "Stop Scanning" : "Scan for Chameleon",
                        systemImage: bluetoothManager.isScanning
                            ? "stop.circle"
                            : "antenna.radiowaves.left.and.right"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        if bluetoothManager.isScanning || !bluetoothManager.devices.isEmpty {
            Section("Nearby Devices") {
                if bluetoothManager.devices.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching...")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(bluetoothManager.devices) { device in
                    Button {
                        bluetoothManager.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Text(device.id.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("\(device.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var slotsSection: some View {
        Section {
            if bluetoothManager.isLoadingSlots {
                HStack {
                    ProgressView()
                    Text("Reading slots...")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(bluetoothManager.slots) { slot in
                slotRow(slot)
            }
        } header: {
            Text("Slots")
        } footer: {
            let allocatedCount = bluetoothManager.slots.filter(\.isAllocated).count
            Text("\(allocatedCount) of 8 slots allocated")
        }
    }

    private func slotRow(_ slot: ChameleonSlot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: slot.isAllocated ? "creditcard.fill" : "creditcard")
                .foregroundStyle(slot.isAllocated ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Slot \(slot.id + 1)")
                        .font(.headline)

                    if bluetoothManager.activeSlot == slot.id {
                        Text("ACTIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

                if slot.isAllocated {
                    slotTypeLabel(name: "HF", type: slot.hfType, enabled: slot.hfEnabled)
                    slotTypeLabel(name: "LF", type: slot.lfType, enabled: slot.lfEnabled)
                } else {
                    Text("Empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func slotTypeLabel(name: String, type: UInt16, enabled: Bool) -> some View {
        if type != 0 {
            Text("\(name) 0x\(String(format: "%04X", type)) · \(enabled ? "Enabled" : "Disabled")")
                .font(.subheadline)
                .foregroundStyle(enabled ? .primary : .secondary)
        }
    }
}

#Preview {
    ContentView(bluetoothManager: ChameleonBluetoothManager())
}
