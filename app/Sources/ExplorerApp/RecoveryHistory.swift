import Combine
import ExplorerCore
import Foundation

/// Receipts for this app session only; this is not an inventory of the user's Trash.
/// A main-actor claim prevents two windows from restoring the same receipt at once.
@MainActor
final class RecoveryHistory: ObservableObject {
    @Published private(set) var entries: [TrashReceipt] = []
    @Published private(set) var claimedIDs: Set<UUID> = []

    func record(_ receipt: TrashReceipt) {
        guard !entries.contains(where: { $0.id == receipt.id }) else { return }
        entries.insert(receipt, at: 0)
    }

    func claim(_ id: UUID) -> TrashReceipt? {
        guard !claimedIDs.contains(id), let receipt = entries.first(where: { $0.id == id }) else { return nil }
        claimedIDs.insert(id)
        return receipt
    }

    func release(_ id: UUID) {
        guard claimedIDs.contains(id) else { return }
        claimedIDs.remove(id)
    }

    func remove(_ id: UUID) {
        if entries.contains(where: { $0.id == id }) { entries.removeAll { $0.id == id } }
        release(id)
    }
}
