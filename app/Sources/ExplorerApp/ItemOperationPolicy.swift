import ExplorerCore
import Foundation

extension ItemOperationContext {
    var directoryURL: URL {
        switch self {
        case .filesystem(let context): return context.directoryURL
        case .archive(let context): return context.location.url
        }
    }
}

extension ItemOperationEntry {
    var archiveTarget: ArchiveMemberTarget? {
        guard case .archive(let context) = context,
              item.archiveRevision == context.revision,
              let location = ArchiveLocation(url: item.url),
              let parent = ArchiveLocation(url: location.parentURL), parent == context.location,
              !item.isSymbolicLink else { return nil }
        return ArchiveMemberTarget(location: location, revision: context.revision)
    }
    var physicalEntry: TransferEntry? {
        guard case .filesystem(let context) = context, item.identity != nil,
              BrowsingPresentation.isPhysical(item),
              item.url.deletingLastPathComponent().standardizedFileURL == context.directoryURL.standardizedFileURL else { return nil }
        return TransferEntry(source: context, item: item)
    }
    var isValid: Bool { archiveTarget != nil || physicalEntry != nil }
    func acceptsContent(_ lease: any MaterializedContentLease, for purpose: ContentPurpose) -> Bool {
        guard lease.fileURL.isFileURL && lease.physicalEntry.item.url == lease.fileURL
            && lease.sourceURL.absoluteString == item.url.absoluteString
            && lease.archiveRevision == item.archiveRevision else { return false }
        let original = lease.originalPhysicalEntry
        if purpose != .preview && purpose != .download {
            guard lease.hydrationReconciliation == nil else { return false }
            if let original, !Self.samePhysicalOrigin(original, lease.physicalEntry) { return false }
        }
        if lease.isBorrowed {
            guard let expected = physicalEntry, let original,
                  Self.samePhysicalOrigin(expected, original) else { return false }
        }
        return true
    }
    private static func samePhysicalOrigin(_ lhs: TransferEntry, _ rhs: TransferEntry) -> Bool {
        lhs.source == rhs.source && lhs.item.url.absoluteString.utf8.elementsEqual(rhs.item.url.absoluteString.utf8)
            && lhs.item.name == rhs.item.name && lhs.item.identity != nil && lhs.item.identity == rhs.item.identity
    }
}

/// Action availability is independent of icon type and of unrelated physical
/// commands. Writers still validate the captured entry at action time.
struct ItemOperationCapabilities {
    let entries: [ItemOperationEntry]
    var canTransfer: Bool { !entries.isEmpty && entries.allSatisfy(\.isValid) }
    var isArchive: Bool { !entries.isEmpty && entries.allSatisfy { $0.archiveTarget != nil } }
    var isPhysical: Bool { !entries.isEmpty && entries.allSatisfy { $0.physicalEntry != nil } }
    var canRename: Bool { entries.count == 1 && canTransfer }
    func canPaste(into destination: ItemOperationContext) -> Bool {
        guard canTransfer else { return false }
        if case .archive = destination { return isPhysical }
        return true
    }
}

/// Weak, application-local invalidation. Core reports committed facts; it does
/// not own UI notifications or turn a new revision into old mutation authority.
@MainActor
final class ArchiveMutationBroadcaster {
    static let shared = ArchiveMutationBroadcaster()
    private struct Observation { weak var store: ExplorerStore? }
    private var observers: [Observation] = []
    func observe(_ store: ExplorerStore) {
        observers.removeAll { $0.store == nil }
        if !observers.contains(where: { $0.store === store }) { observers.append(Observation(store: store)) }
    }
    func publish(_ result: ArchiveMutationResult, origin: ExplorerStore?, selecting: [URL] = []) {
        observers.removeAll { $0.store == nil }
        for observer in observers {
            observer.store?.archiveDidCommit(result, selecting: observer.store === origin ? selecting : [])
        }
    }
}
