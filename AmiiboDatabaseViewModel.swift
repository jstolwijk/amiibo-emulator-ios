import Combine
import Foundation

@MainActor
final class AmiiboDatabaseViewModel: ObservableObject {
    enum State: Equatable {
        case loading(String)
        case ready
        case unavailable
        case failed(String)
    }

    @Published private(set) var entries: [AmiiboEntry] = []
    @Published private(set) var state: State = .loading("Loading cached database...")
    @Published var searchText = ""

    private let service: AmiiboDatabaseService?

    var filteredEntries: [AmiiboEntry] {
        entries.filter { $0.matches(searchText) }
    }

    var isUpdating: Bool {
        if case .loading = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .loading(let message):
            message
        case .ready:
            "\(entries.count) validated Amiibo"
        case .unavailable:
            "No Amiibo database is installed."
        case .failed(let message):
            message
        }
    }

    init() {
        do {
            service = try AmiiboDatabaseService()
        } catch {
            service = nil
            state = .failed(error.localizedDescription)
            return
        }

        Task {
            await loadCacheAndCheckForUpdates()
        }
    }

    func checkForUpdates() {
        guard !isUpdating else { return }
        Task {
            await update(force: true)
        }
    }

    func readAndRevalidate(_ entry: AmiiboEntry) async throws -> ValidatedAmiiboDump {
        guard let service else {
            throw AmiiboDatabaseError.cacheUnavailable
        }
        return try await service.readAndRevalidate(entry)
    }

    private func loadCacheAndCheckForUpdates() async {
        guard let service else { return }
        do {
            if let index = try await service.loadCachedIndex() {
                entries = index.entries
                state = .ready
            } else {
                state = .unavailable
            }

            if try await service.shouldCheckForUpdates() {
                await update(force: false)
            }
        } catch {
            state = entries.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }

    private func update(force: Bool) async {
        guard let service else { return }
        state = .loading("Checking AmiiboDB...")

        do {
            let result = try await service.updateIfNeeded(force: force)
            switch result {
            case .current(let index), .updated(let index):
                entries = index.entries
            }
            state = .ready
        } catch {
            if entries.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                state = .ready
            }
        }
    }
}
