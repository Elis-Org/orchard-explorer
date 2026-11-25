import Darwin
import Foundation

/// The ZIP's manifest is the expected content, not a root inode or an export
/// lease. One bounded CRC pass runs immediately before the source exchange.
/// A final metadata walk catches ordinary changes during another claim's read.
/// This cannot make two filesystems atomic or detect deliberately forged CRCs.
struct ZIPCopiedDestinationVerification {
    private struct Node {
        let relative: [String]
        let record: ZIPCentralRecord?
        var key: Data { ZIPArchiveManifest.pathKey(relative) }
        var directory: Bool { record == nil }
    }
    private struct Claim {
        let destination: ArchiveCopiedDestination
        let root: Node
        let children: [Data: [Node]]
    }
    private let claims: [Claim]

    init(edits: [ArchiveEdit], context: ArchiveOperationContext, manifest: ZIPArchiveManifest,
         maximumBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
         maximumEntries: Int = 100_000, checkpoint: () throws -> Void) throws {
        var claims: [Claim] = [], totalBytes: UInt64 = 0, totalEntries = 0
        for edit in edits {
            guard case .removeAfterVerifiedCopy(let source, let destination) = edit else { continue }
            try checkpoint()
            try LocalFileOperations.validateName(destination.name)
            guard source.revision == context.revision, source.location.archiveURL == context.location.archiveURL,
                  !source.location.components.isEmpty,
                  ZIPArchiveManifest.pathKey(Array(source.location.components.dropLast())) == ZIPArchiveManifest.pathKey(context.location.components) else {
                throw ArchiveOperationError.changed
            }
            let selection = try manifest.selection(at: source.location)
            var nodes = selection.directories.map { Node(relative: Array($0.components.dropFirst(selection.components.count)), record: nil) }
            for record in selection.records {
                try checkpoint()
                guard record.kind == .directory || record.kind == .file else { throw ArchiveOperationError.copiedDestinationChanged }
                guard record.kind == .file else { continue }
                guard record.flags & 0x2041 == 0, record.method == 0 || record.method == 8 else { throw ArchiveOperationError.copiedDestinationChanged }
                guard record.uncompressedSize <= 1_024 * 1_024 * 1_024,
                      record.uncompressedSize <= maximumBytes - totalBytes else { throw ZIPListingError.limitExceeded }
                totalBytes += record.uncompressedSize
                nodes.append(Node(relative: Array(record.components.dropFirst(selection.components.count)), record: record))
            }
            guard maximumEntries >= 0, nodes.count <= maximumEntries - totalEntries else { throw ZIPListingError.limitExceeded }
            totalEntries += nodes.count
            guard let root = nodes.first(where: { $0.relative.isEmpty }), root.directory == selection.isDirectory,
                  nodes.allSatisfy({ $0.relative.count <= 128 && $0.relative.allSatisfy(ArchiveLocation.validComponent) }),
                  Set(nodes.map(\.key)).count == nodes.count else { throw ZIPListingError.corrupt }
            let descendants = nodes.filter { !$0.relative.isEmpty }
            let children = Dictionary(grouping: descendants, by: { ZIPArchiveManifest.pathKey(Array($0.relative.dropLast())) })
            claims.append(Claim(destination: destination, root: root, children: children))
        }
        self.claims = claims
    }

    func verify(checkpoint: () throws -> Void) throws {
        var captured: [[Data: stat]] = []
        for claim in claims {
            var versions: [Data: stat] = [:]
            try inspect(claim, expected: nil, captured: &versions, checkpoint: checkpoint)
            captured.append(versions)
        }
        // Only identities and regular-file versions are compared here; a new
        // Finder .DS_Store or directory timestamp is not loss of expected data.
        for (claim, versions) in zip(claims, captured) {
            var ignored: [Data: stat] = [:]
            try inspect(claim, expected: versions, captured: &ignored, checkpoint: checkpoint)
        }
    }

    private func inspect(_ claim: Claim, expected: [Data: stat]?, captured: inout [Data: stat],
                         checkpoint: () throws -> Void) throws {
        try checkpoint()
        do {
            try LocalFileOperations.withParent(claim.destination.parent) { parent, resolved in
                func walk(_ node: Node, parent: Int32, name: String) throws {
                    try checkpoint()
                    var named = stat(), held = stat()
                    guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          named.st_mode & mode_t(S_IFMT) == mode_t(node.directory ? S_IFDIR : S_IFREG),
                          !node.relative.isEmpty || LocalFileIdentity.fromStat(named) == claim.destination.identity else {
                        throw ArchiveOperationError.copiedDestinationChanged
                    }
                    if let expected {
                        guard let before = expected[node.key], Self.same(before, named, directory: node.directory) else {
                            throw ArchiveOperationError.copiedDestinationChanged
                        }
                    }
                    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (node.directory ? O_DIRECTORY : 0))
                    guard fd >= 0 else { throw ArchiveOperationError.copiedDestinationChanged }
                    defer { close(fd) }
                    guard fstat(fd, &held) == 0, Self.same(named, held, directory: node.directory) else {
                        throw ArchiveOperationError.copiedDestinationChanged
                    }
                    if node.directory {
                        for child in claim.children[node.key] ?? [] { try walk(child, parent: fd, name: child.relative.last!) }
                    } else if expected == nil, let record = node.record {
                        guard held.st_size >= 0, UInt64(held.st_size) == record.uncompressedSize else {
                            throw ArchiveOperationError.copiedDestinationChanged
                        }
                        var checksum = ZIPCRC32(), position: UInt64 = 0
                        while position < record.uncompressedSize {
                            try checkpoint()
                            let count = Int(min(65_536, record.uncompressedSize - position))
                            var data = Data(count: count)
                            let received = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(position)) }
                            if received < 0, errno == EINTR { continue }
                            guard received > 0 else { throw ArchiveOperationError.copiedDestinationChanged }
                            data.count = received
                            try checksum.update(data); position += UInt64(received)
                        }
                        var extra: UInt8 = 0
                        var end: Int
                        repeat { try checkpoint(); end = pread(fd, &extra, 1, off_t(position)) } while end < 0 && errno == EINTR
                        guard end == 0, checksum.value == record.crc32 else { throw ArchiveOperationError.copiedDestinationChanged }
                    }
                    try checkpoint()
                    var after = stat(), namedAfter = stat()
                    guard fstat(fd, &after) == 0, fstatat(parent, name, &namedAfter, AT_SYMLINK_NOFOLLOW) == 0,
                          Self.same(held, after, directory: node.directory), Self.same(held, namedAfter, directory: node.directory) else {
                        throw ArchiveOperationError.copiedDestinationChanged
                    }
                    if expected == nil { captured[node.key] = held }
                }
                try walk(claim.root, parent: parent, name: claim.destination.name)
                try LocalFileOperations.revalidateRoute(claim.destination.parent, resolved: resolved)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ArchiveOperationError { throw error }
        catch { throw ArchiveOperationError.copiedDestinationChanged }
    }

    private static func same(_ lhs: stat, _ rhs: stat, directory: Bool) -> Bool {
        guard let identity = LocalFileIdentity.fromStat(lhs), identity == LocalFileIdentity.fromStat(rhs),
              lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT) else { return false }
        if directory { return true }
        return lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
