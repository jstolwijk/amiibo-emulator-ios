import Combine
import Foundation

@MainActor
final class AmiiboManagerViewModel: ObservableObject {
    @Published var selectedSlotID: Int?
    @Published private(set) var progress: FlashProgress?
    @Published private(set) var resultMessage: String?
    @Published private(set) var isFlashing = false

    private let bluetoothManager: ChameleonBluetoothManager
    private let databaseViewModel: AmiiboDatabaseViewModel

    init(
        bluetoothManager: ChameleonBluetoothManager,
        databaseViewModel: AmiiboDatabaseViewModel
    ) {
        self.bluetoothManager = bluetoothManager
        self.databaseViewModel = databaseViewModel
    }

    var selectedSlot: ChameleonSlot? {
        guard let selectedSlotID else { return nil }
        return bluetoothManager.slots.first { $0.id == selectedSlotID }
    }

    func select(entry: AmiiboEntry) {
        guard let slot = selectedSlot, !isFlashing else { return }
        isFlashing = true
        progress = .init(
            stage: .preflight,
            message: "Validating \(entry.name)...",
            completedUnits: 0,
            totalUnits: 1
        )

        Task {
            do {
                let dump = try await databaseViewModel.readAndRevalidate(entry)
                let client = ChameleonFlashClient(transport: bluetoothManager)
                try await client.flash(
                    slot: slot,
                    dump: dump,
                    nickname: entry.name
                ) { [weak self] progress in
                    self?.progress = progress
                }
                resultMessage = "\(entry.name) is ready in slot \(slot.id + 1)."
            } catch {
                resultMessage = error.localizedDescription
            }

            isFlashing = false
            progress = nil
            bluetoothManager.refreshSlots()
        }
    }

    func clearAllSlots() {
        guard !isFlashing else { return }
        isFlashing = true
        selectedSlotID = nil
        progress = .init(
            stage: .configuring,
            message: "Clearing all slots...",
            completedUnits: 0,
            totalUnits: 16
        )

        Task {
            do {
                let client = ChameleonFlashClient(transport: bluetoothManager)
                try await client.clearAllSlots { [weak self] progress in
                    self?.progress = progress
                }
                resultMessage = "All slots are now empty."
            } catch {
                resultMessage = error.localizedDescription
            }

            isFlashing = false
            progress = nil
            bluetoothManager.refreshSlots()
        }
    }

    func clearResult() {
        resultMessage = nil
    }
}
