import SwiftUI

struct ContentView: View {
    @ObservedObject var bluetoothManager: ChameleonBluetoothManager
    @ObservedObject var databaseViewModel: AmiiboDatabaseViewModel
    @StateObject private var managerViewModel: AmiiboManagerViewModel
    @State private var pickerSlotID: Int?
    @State private var isShowingClearAllConfirmation = false

    init(
        bluetoothManager: ChameleonBluetoothManager,
        databaseViewModel: AmiiboDatabaseViewModel
    ) {
        self.bluetoothManager = bluetoothManager
        self.databaseViewModel = databaseViewModel
        _managerViewModel = StateObject(
            wrappedValue: AmiiboManagerViewModel(
                bluetoothManager: bluetoothManager,
                databaseViewModel: databaseViewModel
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if bluetoothManager.connectedDeviceName == nil {
                    connectionView
                } else {
                    slotsView
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if bluetoothManager.connectedDeviceName != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                bluetoothManager.refreshSlots()
                            } label: {
                                Label("Refresh Slots", systemImage: "arrow.clockwise")
                            }

                            Button(role: .destructive) {
                                isShowingClearAllConfirmation = true
                            } label: {
                                Label("Clear All Slots", systemImage: "trash")
                            }

                            Button(role: .destructive) {
                                bluetoothManager.disconnect()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(bluetoothManager.isLoadingSlots || managerViewModel.isFlashing)
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { pickerSlotID != nil },
                    set: {
                        if !$0 {
                            pickerSlotID = nil
                            databaseViewModel.searchText = ""
                        }
                    }
                )
            ) {
                amiiboPicker
            }
            .alert(
                "Something Went Wrong",
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
            .confirmationDialog(
                "Clear All Slots?",
                isPresented: $isShowingClearAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All Slots", role: .destructive) {
                    managerViewModel.clearAllSlots()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every Amiibo stored on this Chameleon will be removed. This cannot be undone.")
            }
            .alert(
                "Amiibo Manager",
                isPresented: Binding(
                    get: { managerViewModel.resultMessage != nil },
                    set: { if !$0 { managerViewModel.clearResult() } }
                )
            ) {
                Button("OK", role: .cancel) {
                    managerViewModel.clearResult()
                }
            } message: {
                Text(managerViewModel.resultMessage ?? "")
            }
            .overlay {
                if let progress = managerViewModel.progress {
                    flashProgressOverlay(progress)
                }
            }
        }
    }

    private var navigationTitle: String {
        bluetoothManager.connectedDeviceName == nil ? "Amiibo Manager" : "Choose a Slot"
    }

    private var connectionView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 36)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 58))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Connect Your Chameleon")
                        .font(.title2.bold())
                    Text("Turn on your Chameleon, then choose it below.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if bluetoothManager.devices.isEmpty {
                    Button {
                        toggleScanning()
                    } label: {
                        Label(
                            bluetoothManager.isScanning ? "Stop Searching" : "Find My Chameleon",
                            systemImage: bluetoothManager.isScanning
                                ? "stop.circle"
                                : "magnifyingglass"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if bluetoothManager.isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for nearby devices...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nearby")
                            .font(.headline)

                        ForEach(bluetoothManager.devices) { device in
                            Button {
                                bluetoothManager.connect(to: device)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "rectangle.connected.to.line.below")
                                        .font(.title2)
                                        .foregroundStyle(Color.accentColor)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name)
                                            .font(.headline)
                                        Text("Tap to connect")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding()
                                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        Button(bluetoothManager.isScanning ? "Stop Searching" : "Search Again") {
                            toggleScanning()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Text(bluetoothManager.bluetoothState)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private var slotsView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("Select a slot to add or replace an Amiibo.")
                        .font(.headline)
                    Text("Your Chameleon has eight slots.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

                if bluetoothManager.isLoadingSlots {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking your slots...")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                ForEach(bluetoothManager.slots) { slot in
                    slotCard(slot)
                }
            }
            .padding()
        }
        .refreshable {
            bluetoothManager.refreshSlots()
        }
    }

    private func slotCard(_ slot: ChameleonSlot) -> some View {
        Button {
            managerViewModel.selectedSlotID = slot.id
            pickerSlotID = slot.id
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(slot.isAllocated ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 52, height: 52)

                    Image(systemName: slot.isAllocated ? "figure.wave.circle.fill" : "plus.circle")
                        .font(.title2)
                        .foregroundStyle(slot.isAllocated ? Color.accentColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Slot \(slot.id + 1)")
                            .font(.headline)

                        if bluetoothManager.activeSlot == slot.id {
                            Text("IN USE")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(slotDisplayName(slot))
                        .font(.subheadline)
                        .foregroundStyle(slot.isAllocated ? .primary : .secondary)
                        .lineLimit(1)

                    Text(slot.isAllocated ? "Tap to replace" : "Tap to choose an Amiibo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.secondary.opacity(0.18), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bluetoothManager.isLoadingSlots || managerViewModel.isFlashing)
        .accessibilityHint(slot.isAllocated ? "Choose a new Amiibo for this slot" : "Choose an Amiibo for this empty slot")
    }

    private func slotDisplayName(_ slot: ChameleonSlot) -> String {
        if !slot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return slot.nickname
        }
        return slot.isAllocated ? "Amiibo already stored" : "Empty"
    }

    private var amiiboPicker: some View {
        NavigationStack {
            Group {
                if databaseViewModel.entries.isEmpty {
                    databaseEmptyView
                } else if databaseViewModel.filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: databaseViewModel.searchText)
                } else {
                    List(databaseViewModel.filteredEntries) { entry in
                        Button {
                            pickerSlotID = nil
                            databaseViewModel.searchText = ""
                            managerViewModel.select(entry: entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "figure.wave")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(entry.series)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Choose an Amiibo")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $databaseViewModel.searchText,
                prompt: "Search by name or series"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pickerSlotID = nil
                        databaseViewModel.searchText = ""
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var databaseEmptyView: some View {
        ContentUnavailableView {
            Label("Amiibo List Not Ready", systemImage: "arrow.down.circle")
        } description: {
            Text(databaseViewModel.statusText)
        } actions: {
            Button(databaseViewModel.isUpdating ? "Getting Amiibo List..." : "Get Amiibo List") {
                databaseViewModel.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .disabled(databaseViewModel.isUpdating)
        }
    }

    private func toggleScanning() {
        if bluetoothManager.isScanning {
            bluetoothManager.stopScanning()
        } else {
            bluetoothManager.startScanning()
        }
    }

    private func flashProgressOverlay(_ progress: FlashProgress) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.accentColor)

                Text(progressTitle(progress.stage))
                    .font(.headline)

                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)

                Text("Keep your Chameleon nearby and turned on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
        .accessibilityElement(children: .combine)
    }

    private func progressTitle(_ stage: FlashProgress.Stage) -> String {
        switch stage {
        case .preflight:
            "Getting Ready..."
        case .backup:
            "Saving the Current Slot..."
        case .writing:
            "Adding Your Amiibo..."
        case .configuring:
            managerViewModel.selectedSlotID == nil ? "Clearing All Slots..." : "Adding Your Amiibo..."
        case .verifying:
            "Making Sure It Worked..."
        case .rollback:
            "Restoring the Previous Amiibo..."
        case .complete:
            "Amiibo Ready"
        }
    }
}
