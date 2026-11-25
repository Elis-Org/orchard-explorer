import Darwin
import Foundation

/// NATIVE-P15 / MAC-069: counted totals for one top-level entry. Items include
/// folders and links; bytes are regular-file logical sizes.
public struct TransferEntryTotals: Equatable, Sendable {
    public let items: Int
    public let bytes: Int64
    public init(items: Int, bytes: Int64) {
        self.items = items
        self.bytes = bytes
    }
}

public struct TransferTotals: Equatable, Sendable {
    public let entries: [TransferEntryTotals]
    public init(entries: [TransferEntryTotals]) { self.entries = entries }
    public var items: Int { entries.reduce(0) { $0 + $1.items } }
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

public protocol TransferCounting: Sendable {
    /// Read-only. Returns nil when totals cannot be established completely
    /// (unreadable, changed or too large); throws only for a predictable batch
    /// refusal (MAC-066) or cancellation.
    func count(_ entries: [TransferEntry], destination: FileOperationContext,
               kind: TransferKind) async throws -> TransferTotals?
}

public struct LocalTransferCounter: TransferCounting {
    public static let maximumEntries = 1_000_000
    private let maximumEntries: Int

    public init() { maximumEntries = Self.maximumEntries }
    init(maximumEntries: Int) { self.maximumEntries = maximumEntries }

    public func count(_ entries: [TransferEntry], destination: FileOperationContext,
                      kind: TransferKind) async throws -> TransferTotals? {
        let limit = maximumEntries
        let result = try await BlockingIO.run(on: .read) { cancellation -> TransferTotals? in
            // Counting must never download provider placeholders. If that policy
            // cannot be established, totals stay unknown rather than traversing.
            let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            let policySet = previous >= 0 && setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
            defer {
                if policySet {
                    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
                }
            }
            if kind == .move {
                // A cross-volume move must be able to remove the original: refuse a
                // read-only source volume before the first write (MAC-066).
                for entry in entries {
                    try cancellation.checkCancellation()
                    let crossDevice = entry.source.directoryIdentity.device != destination.directoryIdentity.device
                        || entry.item.identity?.device != destination.directoryIdentity.device
                    guard crossDevice else { continue }
                    let readOnly = try? LocalFileOperations.withParent(entry.source) { descriptor, _ -> Bool in
                        var filesystem = statfs()
                        guard fstatfs(descriptor, &filesystem) == 0 else { return false }
                        return filesystem.f_flags & UInt32(MNT_RDONLY) != 0
                    }
                    if readOnly == true {
                        throw FileOperationError.unsupported(
                            "“\(entry.item.name)” is on a read-only volume, so it cannot be moved. Use Copy instead. No files were changed.")
                    }
                }
            }
            var totals: [TransferEntryTotals] = []
            var visited = 0
            let traverse = policySet
            for entry in entries {
                try cancellation.checkCancellation()
                let sameDeviceMove = kind == .move
                    && entry.source.directoryIdentity.device == destination.directoryIdentity.device
                    && entry.item.identity?.device == destination.directoryIdentity.device
                if sameDeviceMove {
                    // An exclusive rename moves the whole item at once; count it as one.
                    totals.append(TransferEntryTotals(items: 1, bytes: 0))
                    continue
                }
                guard traverse, let counted = try? LocalFileOperations.withParent(entry.source, { descriptor, _ in
                    try Self.count(entry.item.name, parent: descriptor, expected: entry.item.identity, device: nil,
                                   visited: &visited, limit: limit, cancellation: cancellation)
                }) else {
                    try cancellation.checkCancellation()
                    return nil
                }
                totals.append(counted)
            }
            return TransferTotals(entries: totals)
        }
        try Task.checkCancellation()
        return result
    }

    private static func count(_ name: String, parent: Int32, expected: LocalFileIdentity?, device: dev_t?,
                              visited: inout Int, limit: Int,
                              cancellation: BlockingIOCancellation) throws -> TransferEntryTotals {
        try cancellation.checkCancellation()
        visited += 1
        guard visited <= limit else { throw FileOperationError.unsupported("Too many items to count.") }
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let expected, LocalFileIdentity.fromStat(value) != expected { throw FileOperationError.staleSource }
        guard device == nil || value.st_dev == device else {
            throw FileOperationError.unsupported("A nested mount cannot be counted.")
        }
        switch value.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            return TransferEntryTotals(items: 1, bytes: Int64(value.st_size))
        case mode_t(S_IFLNK):
            return TransferEntryTotals(items: 1, bytes: 0)
        case mode_t(S_IFDIR):
            guard value.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw FileOperationError.unsupported("A placeholder folder cannot be counted.")
            }
            let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, LocalFileIdentity.fromStat(opened) == LocalFileIdentity.fromStat(value) else {
                close(fd)
                throw FileOperationError.staleSource
            }
            var items = 1
            var bytes: Int64 = 0
            // Hand off only the identity-checked descriptor. Streaming retains
            // one descriptor per recursion level and checks cancellation per entry.
            do {
                try DescriptorIO.forEachDirectoryEntry(consuming: fd, checkpoint: cancellation.checkCancellation) { child, directory in
                    let nested = try count(child, parent: directory, expected: nil, device: value.st_dev,
                                           visited: &visited, limit: limit, cancellation: cancellation)
                    items += nested.items
                    bytes += nested.bytes
                }
            } catch DescriptorIO.DirectoryEntryError.invalidUTF8 {
                throw FileOperationError.unsupported("A filename is not valid UTF-8.")
            }
            // A folder that changed while it was counted makes totals unknown.
            var after = stat()
            guard name.withCString({ fstatat(parent, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                  LocalFileIdentity.fromStat(after) == LocalFileIdentity.fromStat(value),
                  after.st_mtimespec.tv_sec == value.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == value.st_mtimespec.tv_nsec else {
                throw FileOperationError.staleSource
            }
            return TransferEntryTotals(items: items, bytes: bytes)
        default:
            throw FileOperationError.unsupported("Unsupported item type.")
        }
    }
}
