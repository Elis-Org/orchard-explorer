import Foundation

/// One completed shallow enumeration. directoryIdentity scopes reconciliation so
/// a replacement folder at the same lexical URL cannot inherit a previous selection.
public struct DirectorySnapshot: Equatable, Sendable {
    public let items: [FileItem]
    public let directoryIdentity: LocalFileIdentity?
    public let archiveRevision: ArchiveRevision?
    public let isStructureComplete: Bool

    public init(items: [FileItem], directoryIdentity: LocalFileIdentity? = nil,
                archiveRevision: ArchiveRevision? = nil, isStructureComplete: Bool = false) {
        self.items = items
        self.directoryIdentity = archiveRevision == nil ? directoryIdentity : nil
        self.archiveRevision = archiveRevision
        self.isStructureComplete = isStructureComplete
    }
}
