import Darwin
import Foundation
import UniformTypeIdentifiers

/// NATIVE-P16 / MAC-070/073: the existing destination entry as it was compared.
/// Replace may proceed only while the entry still matches every recorded field.
public struct ReplacementTarget: Equatable, Sendable {
    public let name: String
    public let identity: LocalFileIdentity
    public let fileType: UInt16
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public init(name: String, identity: LocalFileIdentity, fileType: UInt16, size: Int64,
                modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.name = name
        self.identity = identity
        self.fileType = fileType
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    init?(name: String, stat value: stat) {
        guard let identity = LocalFileIdentity.fromStat(value) else { return nil }
        self.init(name: name, identity: identity, fileType: UInt16(value.st_mode & mode_t(S_IFMT)),
                  size: Int64(value.st_size), modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                  modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }

    func matches(_ value: stat) -> Bool {
        self == ReplacementTarget(name: name, stat: value)
    }

    /// MAC-071: only non-folders (regular files or symbolic links) can be replaced.
    public var isReplaceable: Bool {
        fileType == UInt16(S_IFREG) || fileType == UInt16(S_IFLNK)
    }
}

public enum ConflictEntryKind: Equatable, Sendable { case file, folder, symbolicLink, other }

/// What the conflict window shows for the existing item (no content is read).
public struct ConflictEntry: Equatable, Sendable {
    public let target: ReplacementTarget
    public let kind: ConflictEntryKind
    public let kindDescription: String
    public let size: Int64?
    public let modifiedAt: Date?

    public init(target: ReplacementTarget, kind: ConflictEntryKind, kindDescription: String,
                size: Int64?, modifiedAt: Date?) {
        self.target = target
        self.kind = kind
        self.kindDescription = kindDescription
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public enum TransferReplacementError: LocalizedError, Equatable, Sendable {
    /// MAC-073: the existing item differs from what was compared; ask again.
    case destinationChanged(String)
    case notReplaceable(String)

    public var errorDescription: String? {
        switch self {
        case .destinationChanged(let name):
            return "“\(name)” in the destination changed after it was compared. Review it again before replacing."
        case .notReplaceable(let name):
            return "“\(name)” can't be replaced: folders can't be replaced or merged."
        }
    }
}

public protocol ConflictInspecting: Sendable {
    func inspect(name: String, in context: FileOperationContext) async throws -> ConflictEntry
}

/// Read-only, no-follow sample of one destination entry on the read lane.
public struct LocalConflictInspector: ConflictInspecting {
    public init() {}

    public func inspect(name: String, in context: FileOperationContext) async throws -> ConflictEntry {
        let entry = try await BlockingIO.run(on: .read) { cancellation -> ConflictEntry in
            try cancellation.checkCancellation()
            try LocalFileOperations.validateName(name)
            return try LocalFileOperations.withParent(context) { descriptor, resolved in
                var value = stat()
                guard name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw LocalFileOperations.failure(errno, operation: "Inspect existing item", name: name)
                }
                guard let target = ReplacementTarget(name: name, stat: value) else {
                    throw FileOperationError.unsupported("The existing item has no supported local identity.")
                }
                let type = value.st_mode & mode_t(S_IFMT)
                let kind: ConflictEntryKind
                let description: String
                switch type {
                case mode_t(S_IFREG):
                    kind = .file
                    // Same source as the listing's Kind column (presentation only;
                    // identity and type come from the no-follow fstatat above).
                    let values = try? resolved.appendingPathComponent(name, isDirectory: false)
                        .resourceValues(forKeys: [.localizedTypeDescriptionKey])
                    description = values?.localizedTypeDescription
                        ?? UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "Document"
                case mode_t(S_IFDIR):
                    kind = .folder
                    description = "Folder"
                case mode_t(S_IFLNK):
                    kind = .symbolicLink
                    description = "Symbolic link"
                default:
                    kind = .other
                    description = "Other item"
                }
                let modified = Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                                    + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
                return ConflictEntry(target: target, kind: kind, kindDescription: description,
                                     size: type == mode_t(S_IFREG) ? Int64(value.st_size) : nil, modifiedAt: modified)
            }
        }
        try Task.checkCancellation()
        return entry
    }
}
