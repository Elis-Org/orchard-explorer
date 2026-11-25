import Foundation

/// Factual local availability, not a sync or pinning guarantee. Unknown is
/// intentionally blank for ordinary local files and unrecognized providers.
public enum FileAvailability: String, Hashable, Sendable {
    case unknown, onlineOnly, availableLocally
}

/// A displayed directory entry, identified by its lexical URL rather than its resolved target.
/// This preserves distinct hard-link and symbolic-link entries. Optional local
/// identity supports conservative refresh reconciliation without replacing this URL ID.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modifiedAt: Date?
    public let kind: String
    public let identity: LocalFileIdentity?
    /// Archive provenance is independent of row ID and never grants local
    /// filesystem authority. Captured menu rows retain the revision they showed.
    public let archiveRevision: ArchiveRevision?
    public let availability: FileAvailability
    /// No-follow SF_DATALESS on the regular file itself. A clear bit establishes
    /// resident contents but does not establish provider membership.
    public let isDataless: Bool?
    /// No-follow local stat fact for capability presentation. Nil is unknown;
    /// a file row may represent a package and is not proof of a regular node.
    public let isRegularFile: Bool?
    /// Raw no-follow listing stamp. It participates in equality even when the
    /// display date rounds two different native timestamps to the same value.
    public let statusVersion: LocalFileStatusVersion?

    public init(url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool,
                size: Int64?, modifiedAt: Date?, kind: String, identity: LocalFileIdentity? = nil,
                archiveRevision: ArchiveRevision? = nil, availability: FileAvailability = .unknown,
                isRegularFile: Bool? = nil, statusVersion: LocalFileStatusVersion? = nil,
                isDataless: Bool? = nil) {
        self.url = url.isFileURL ? url.standardizedFileURL : url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.identity = url.isFileURL ? identity : nil
        self.archiveRevision = archiveRevision
        self.availability = url.isFileURL ? availability : .unknown
        self.isDataless = url.isFileURL && isRegularFile == true && !isSymbolicLink ? isDataless : nil
        self.isRegularFile = url.isFileURL ? isRegularFile : nil
        self.statusVersion = url.isFileURL ? statusVersion : nil
    }
}
