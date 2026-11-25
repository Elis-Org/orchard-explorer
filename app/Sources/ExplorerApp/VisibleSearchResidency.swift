import ExplorerCore
import Foundation

/// Supplemental metadata for visible search hits. The shared policy cache owns
/// verification. This store drops its local residency sample with the viewport.
@MainActor
final class VisibleSearchResidency {
    struct Key: Hashable {
        let entry: OneDriveStatusKey
        let generation: UUID
        let namespaceEpoch: UInt64
    }
    private struct Demand {
        let entries: [Key: TransferEntry]
        let changed: @MainActor (Set<String>) -> Void
    }
    private let read: @Sendable (TransferEntry) async -> FileAvailability
    private var owners = [UUID: Demand]()
    private var samples = [Key: FileAvailability]()
    private var pending = [Key: TransferEntry]()
    private var request: Task<Void, Never>?
    private var active: Key?

    init(read: @escaping @Sendable (TransferEntry) async -> FileAvailability = { await LocalDirectoryLoader.visibleCloudAvailability($0) }) {
        self.read = read
    }
    func availability(for key: Key) -> FileAvailability? { samples[key] }
    func update(_ owner: UUID, entries: [Key: TransferEntry], changed: @escaping @MainActor (Set<String>) -> Void) {
        if entries.isEmpty { owners.removeValue(forKey: owner) }
        else { owners[owner] = Demand(entries: entries, changed: changed) }
        reconcile()
    }
    func remove(_ owner: UUID) {
        guard owners.removeValue(forKey: owner) != nil else { return }
        reconcile()
    }
    private func reconcile() {
        pending = owners.values.reduce(into: [:]) { $0.merge($1.entries) { first, _ in first } }
        samples = samples.filter { pending[$0.key] != nil }
        if let active, pending[active] == nil { request?.cancel() }
        startNext()
    }
    private func startNext() {
        guard request == nil, let (key, entry) = pending.first(where: { samples[$0.key] == nil }) else { return }
        let read = self.read
        active = key
        request = Task { [weak self] in
            // An already-started filesystem lookup can outlive cancellation.
            // Keep its worker slot until it really returns and discard its result.
            let sample = await Task.detached(priority: .utility) { await read(entry) }.value
            guard let self else { return }
            self.request = nil
            self.active = nil
            if !Task.isCancelled, self.pending[key] != nil {
                self.samples[key] = sample
                if sample != .unknown {
                    for demand in Array(self.owners.values) where demand.entries[key] != nil {
                        demand.changed([key.entry.file])
                    }
                }
            }
            self.startNext()
        }
    }
    deinit { request?.cancel() }
}
