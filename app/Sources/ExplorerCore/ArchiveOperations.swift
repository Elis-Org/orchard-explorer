import Foundation

/// Captured provenance; constructors do not grant authority or perform I/O.
public struct ArchiveOperationContext: Equatable, Sendable {
    public let location: ArchiveLocation
    public let revision: ArchiveRevision
    public init(location: ArchiveLocation, revision: ArchiveRevision) {
        self.location = location; self.revision = revision
    }
}

public enum ItemOperationContext: Equatable, Sendable {
    case filesystem(FileOperationContext)
    case archive(ArchiveOperationContext)
}

public struct ItemOperationEntry: Sendable {
    public let item: FileItem
    public let context: ItemOperationContext
    public init(item: FileItem, context: ItemOperationContext) {
        self.item = item; self.context = context
    }
    public init(_ entry: TransferEntry) {
        self.init(item: entry.item, context: .filesystem(entry.source))
    }
}

public struct ArchiveMemberTarget: Equatable, Sendable {
    public let location: ArchiveLocation
    public let revision: ArchiveRevision
    public init(location: ArchiveLocation, revision: ArchiveRevision) {
        self.location = location; self.revision = revision
    }
}

public struct ArchiveReplacementTarget: Equatable, Sendable {
    public let member: ArchiveMemberTarget
    public init(member: ArchiveMemberTarget) { self.member = member }
}

/// A destination claim from an actual publication, not proof of its contents.
/// Core compares every expected node against the source ZIP before removal.
public struct ArchiveCopiedDestination: Equatable, Sendable {
    public let parent: FileOperationContext
    public let name: String
    public let identity: LocalFileIdentity
    public init(parent: FileOperationContext, name: String, identity: LocalFileIdentity) {
        self.parent = parent; self.name = name; self.identity = identity
    }
}

public enum ArchiveEdit: Sendable {
    case add(source: TransferEntry, destination: ArchiveLocation, replacing: ArchiveReplacementTarget?)
    case rename(source: ArchiveMemberTarget, newName: String)
    case remove(source: ArchiveMemberTarget)
    case removeAfterVerifiedCopy(source: ArchiveMemberTarget, destination: ArchiveCopiedDestination)
}

public struct ArchiveRenameMapping: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL; self.destinationURL = destinationURL
    }
}

public struct ArchiveRecoveryReceipt: Equatable, Sendable {
    public let archiveURL: URL
    public let retainedURLs: [URL]
    public let reason: String
    public init(archiveURL: URL, retainedURLs: [URL], reason: String) {
        self.archiveURL = archiveURL; self.retainedURLs = retainedURLs; self.reason = reason
    }
}

/// Issued only after the committed archive and all expected added entries were verified.
/// Action-time validation is still required before a move removes its source.
public struct ArchiveVerifiedDestinationReceipt: Sendable {
    public let archiveURL: URL
    public let revision: ArchiveRevision
    public let locations: [ArchiveLocation]
    public init(archiveURL: URL, revision: ArchiveRevision, locations: [ArchiveLocation]) {
        self.archiveURL = archiveURL; self.revision = revision; self.locations = locations
    }
}

public struct ArchiveMutationResult: Sendable {
    public let archiveURL: URL
    public let previousRevision: ArchiveRevision
    public let revision: ArchiveRevision?
    public let changedLocations: [URL]
    public let renamedLocations: [ArchiveRenameMapping]
    public let warning: String?
    public let recovery: ArchiveRecoveryReceipt?
    public let verifiedDestination: ArchiveVerifiedDestinationReceipt?

    public init(archiveURL: URL, previousRevision: ArchiveRevision, revision: ArchiveRevision?,
                changedLocations: [URL] = [], renamedLocations: [ArchiveRenameMapping] = [],
                warning: String? = nil, recovery: ArchiveRecoveryReceipt? = nil,
                verifiedDestination: ArchiveVerifiedDestinationReceipt? = nil) {
        self.archiveURL = archiveURL; self.previousRevision = previousRevision; self.revision = revision
        self.changedLocations = changedLocations; self.renamedLocations = renamedLocations
        self.warning = warning; self.recovery = recovery; self.verifiedDestination = verifiedDestination
    }
}

public enum ArchiveOperationError: LocalizedError, Equatable, Sendable {
    case unsupported(String)
    case changed
    case invalidName(String)
    case collision(String)
    case contentMismatch
    case copiedDestinationChanged
    case limitExceeded(String)
    case recoveryRequired(ArchiveRecoveryReceipt)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return detail
        case .changed: return "The archive or selected item changed. Refresh before trying again."
        case .invalidName(let detail): return detail
        case .collision(let name): return "An item named “\(name)” already exists in the archive."
        case .contentMismatch: return "The archive member's content did not match its recorded size or checksum."
        case .copiedDestinationChanged: return "The destination copy is incomplete, changed, or could not be verified. The ZIP originals were retained."
        case .limitExceeded(let detail): return detail
        case .recoveryRequired(let receipt):
            return ([receipt.reason] + receipt.retainedURLs.map(\.path)).joined(separator: "\n")
        }
    }
}

public protocol ArchiveModifying: Sendable {
    func modify(_ edits: [ArchiveEdit], in context: ArchiveOperationContext,
                control: TransferControl,
                onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ArchiveMutationResult
}

public struct LocalArchiveOperations: ArchiveModifying {
    private let hooks: ArchiveMutationHooks
    public init() { hooks = ArchiveMutationHooks() }
    init(hooks: ArchiveMutationHooks) { self.hooks = hooks }
    public func modify(_ edits: [ArchiveEdit], in context: ArchiveOperationContext,
                       control: TransferControl,
                       onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ArchiveMutationResult {
        try await BlockingIO.run(on: .archiveMutation, onCancel: { control.cancel() }) { cancellation in
            let deadline = Date().addingTimeInterval(300)
            let checkpoint = {
                try cancellation.checkCancellation(); try control.checkpoint()
                guard Date() <= deadline else { throw ArchiveOperationError.limitExceeded("The archive operation exceeded its five-minute limit.") }
            }
            return try ArchiveMutationTransaction.run(edits: edits, context: context, hooks: hooks,
                                                        checkpoint: checkpoint, onProgress: onProgress)
        }
    }
}
