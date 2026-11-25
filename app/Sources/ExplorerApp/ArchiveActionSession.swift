import ExplorerCore
import Foundation

struct ArchiveDeleteConfirmation: Identifiable {
    let id = UUID()
    let tabID: UUID
    let generation: UUID?
    let context: ArchiveOperationContext
    let entries: [ItemOperationEntry]
}

/// External applications outlive the originating window and preview. Registry
/// shutdown owns final unchanged-only cleanup; window teardown cannot revoke it.
@MainActor
final class ExternalOpenContents {
    static let shared = ExternalOpenContents()
    private var leases: [any MaterializedContentLease] = []
    var retainedCount: Int { leases.count }
    func retain(_ lease: any MaterializedContentLease) { leases.append(lease) }
    func endSession() { leases.removeAll() }
}
