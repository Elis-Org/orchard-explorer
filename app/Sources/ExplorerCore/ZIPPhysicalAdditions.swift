import Darwin
import Foundation

/// Captures a complete bounded physical subtree before archive staging. Reads
/// reopen only validated components relative to held source parents; every
/// component is no-follow and compared with its captured version.
final class ZIPPhysicalAdditions {
    private final class Root {
        let context: FileOperationContext
        let resolved: URL
        let descriptor: Int32
        var snapshots: [Data: stat] = [:]
        init(_ context: FileOperationContext) throws {
            self.context = context
            let result = try LocalFileOperations.withParent(context) { fd, resolved in
                let owned = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                guard owned >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return (owned, resolved)
            }
            descriptor = result.0; resolved = result.1
        }
        deinit { close(descriptor) }
        func open(_ components: [String]) throws -> Int32 {
            try LocalFileOperations.revalidateRoute(context, resolved: resolved)
            var current = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard current >= 0 else { throw POSIXError(.EBADF) }
            do {
                for index in components.indices {
                    let prefix = Array(components.prefix(index + 1))
                    guard let expected = snapshots[ZIPArchiveManifest.pathKey(prefix)] else { throw FileOperationError.staleSource }
                    let directory = expected.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                    let next = openat(current, components[index], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
                    guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    close(current); current = next
                    var sampled = stat()
                    guard fstat(current, &sampled) == 0, ZIPPhysicalAdditions.sameVersion(expected, sampled) else { throw FileOperationError.staleSource }
                }
                return current
            } catch { close(current); throw error }
        }
    }
    private struct Node {
        let root: Root
        let relative: [String]
        let destination: [String]
        let snapshot: stat
        let origins: ZIPOriginAttributes
        var directory: Bool { snapshot.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
        var hasOrigins: Bool { origins.quarantine != nil || origins.whereFroms != nil }
    }
    private var roots: [Data: Root] = [:]
    private var nodes: [Node] = []
    private(set) var locations: [ArchiveLocation] = []
    private(set) var replacementEdits: [ArchiveEdit] = []
    private(set) var uncompressedBytes: UInt64 = 0
    private let originBudget: ZIPOriginBudget
    var count: Int { nodes.count + nodes.filter(\.hasOrigins).count }
    var minimumHeaderBytes: UInt64 {
        nodes.reduce(0) { total, node in
            let ordinary = UInt64(76 + 2 * (node.destination.joined(separator: "/").utf8.count + (node.directory ? 1 : 0)))
            let origin = node.hasOrigins ? UInt64(76 + 2 * ZIPOriginCompanionIndex.components(for: node.destination).joined(separator: "/").utf8.count) : 0
            return total + ordinary + origin
        }
    }

    init(edits: [ArchiveEdit], context: ArchiveOperationContext, manifest: ZIPArchiveManifest,
         originBudget: ZIPOriginBudget = ZIPOriginBudget(), checkpoint: () throws -> Void) throws {
        self.originBudget = originBudget
        var destinations: [ArchiveLocation] = [], total: UInt64 = 0, pathBytes = 0
        var topNames: Set<Data> = []
        for edit in edits {
            guard case .add(let source, let destination, let replacement) = edit else { continue }
            try checkpoint()
            guard destination.archiveURL == context.location.archiveURL,
                  ZIPArchiveManifest.pathKey(Array(destination.components.dropLast())) == ZIPArchiveManifest.pathKey(context.location.components),
                  destination.components.count == context.location.components.count + 1 else { throw ArchiveOperationError.changed }
            let key = ZIPArchiveManifest.pathKey(destination.components)
            guard topNames.insert(key).inserted else { throw ArchiveOperationError.collision(destination.components.last!) }
            let exists = manifest.records.contains { $0.pathKey == key } || manifest.directories.contains { $0.pathKey == key }
            if let replacement {
                guard exists, replacement.member.location == destination, replacement.member.revision == context.revision else { throw ArchiveOperationError.changed }
                replacementEdits.append(.remove(source: replacement.member))
            } else if exists { throw ArchiveOperationError.collision(destination.components.last!) }
            let parentKey = Data(source.source.directoryURL.path.utf8)
            let root: Root
            if let existing = roots[parentKey] {
                guard existing.context == source.source else { throw FileOperationError.staleParent }
                root = existing
            } else { root = try Root(source.source); roots[parentKey] = root }
            try ServiceStage.verify(source.item, context: source.source, parent: root.descriptor)
            func walk(parent: Int32, name: String, relative: [String], target: [String]) throws {
                try checkpoint()
                guard ArchiveLocation.validComponent(name), target.count <= 128,
                      target.joined(separator: "/").utf8.count <= 4_096, nodes.count < 100_000 else { throw ZIPListingError.limitExceeded }
                var before = stat()
                guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw FileOperationError.staleSource }
                let type = before.st_mode & mode_t(S_IFMT), directory = type == mode_t(S_IFDIR)
                guard directory || type == mode_t(S_IFREG) else {
                    throw ArchiveOperationError.unsupported("ZIP additions support regular files and folders, not links or special files.")
                }
                guard UInt64(UInt32(bitPattern: before.st_dev)) == root.context.directoryIdentity.device else {
                    throw ArchiveOperationError.unsupported("ZIP additions do not cross mounted filesystem boundaries.")
                }
                guard !(UInt64(UInt32(bitPattern: before.st_dev)) == context.revision.device && UInt64(before.st_ino) == context.revision.inode) else {
                    throw ArchiveOperationError.unsupported("An archive cannot be added to itself or to a folder containing it.")
                }
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(fd) }
                var sampled = stat()
                guard fstat(fd, &sampled) == 0, Self.sameVersion(before, sampled) else { throw FileOperationError.staleSource }
                if !directory {
                    guard sampled.st_size >= 0, sampled.st_size <= 1_024 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
                    total += UInt64(sampled.st_size)
                    guard total <= 4 * 1_024 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
                }
                pathBytes += target.joined(separator: "/").utf8.count
                let origins = try ZIPMemberOrigins.capture(from: fd, budget: originBudget)
                if origins.quarantine != nil || origins.whereFroms != nil {
                    let companion = ZIPOriginCompanionIndex.components(for: target)
                    guard companion.count <= 128, companion.joined(separator: "/").utf8.count <= 4_096 else { throw ZIPListingError.limitExceeded }
                    pathBytes += companion.joined(separator: "/").utf8.count
                }
                guard pathBytes <= 64 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
                var afterOrigins = stat()
                guard fstat(fd, &afterOrigins) == 0, Self.sameVersion(sampled, afterOrigins) else { throw FileOperationError.staleSource }
                root.snapshots[ZIPArchiveManifest.pathKey(relative)] = sampled
                nodes.append(Node(root: root, relative: relative, destination: target, snapshot: sampled, origins: origins))
                if directory {
                    for child in try ContentFileIO.names(fd, checkpoint: checkpoint).sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }) {
                        try walk(parent: fd, name: child, relative: relative + [child], target: target + [child])
                    }
                    var after = stat()
                    guard fstat(fd, &after) == 0, Self.sameVersion(sampled, after) else { throw FileOperationError.staleSource }
                }
            }
            try walk(parent: root.descriptor, name: source.item.name, relative: [source.item.name], target: destination.components)
            destinations.append(destination)
        }
        guard count <= 100_000 else { throw ZIPListingError.limitExceeded }
        uncompressedBytes = total
        locations = destinations
    }

    func validate(checkpoint: () throws -> Void) throws {
        for node in nodes {
            try checkpoint()
            let fd = try node.root.open(node.relative)
            defer { close(fd) }
            guard try ZIPMemberOrigins.capture(from: fd, budget: originBudget) == node.origins else { throw FileOperationError.staleSource }
            var after = stat()
            guard fstat(fd, &after) == 0, Self.sameVersion(node.snapshot, after) else { throw FileOperationError.staleSource }
        }
    }

    /// Only relevant paths participate. Foreign AppleDouble elsewhere never
    /// blocks Add; replacing an associated item is checked by the raw planner.
    func validateDestinations(manifest: ZIPArchiveManifest, removed: Set<Int>, renamed: [Int: [String]] = [:],
                              checkpoint: () throws -> Void = {}) throws {
        let retained = manifest.records.filter { !removed.contains($0.id) }.map { renamed[$0.id] ?? $0.components }
        var companions: [Data: Data] = [:], planned = nodes.map(\.destination)
        for node in nodes where node.hasOrigins {
            let companion = ZIPOriginCompanionIndex.components(for: node.destination)
            let key = ZIPArchiveManifest.pathKey(companion)
            guard companions[key] == nil else { throw ArchiveOperationError.collision(companion.last!) }
            companions[key] = ZIPArchiveManifest.pathKey(node.destination)
            planned.append(companion)
        }
        try ZIPOriginCompanionIndex.validateDestinations(introduced: nodes.map(\.destination), retained: retained,
            planned: planned, companions: companions, checkpoint: checkpoint)
        var occupied: [Data: Bool] = [:]
        for record in manifest.records where !removed.contains(record.id) {
            let components = renamed[record.id] ?? record.components
            for end in 1..<components.count {
                occupied[ZIPArchiveManifest.pathKey(Array(components.prefix(end)))] = true
            }
            occupied[ZIPArchiveManifest.pathKey(components)] = record.kind == .directory
        }
        func reserve(_ components: [String], directory: Bool) throws {
            let key = ZIPArchiveManifest.pathKey(components)
            guard occupied[key] == nil else { throw ArchiveOperationError.collision(components.last!) }
            for end in 1..<components.count {
                let prefix = ZIPArchiveManifest.pathKey(Array(components.prefix(end)))
                guard occupied[prefix] != false else { throw ArchiveOperationError.collision(components[end - 1]) }
                occupied[prefix] = true
            }
            occupied[key] = directory
        }
        for node in nodes { try reserve(node.destination, directory: node.directory) }
        for node in nodes where node.hasOrigins { try reserve(ZIPOriginCompanionIndex.components(for: node.destination), directory: false) }
    }

    func entries(scratchDirectory: Int32, checkpoint: @escaping () throws -> Void) throws -> [ZIPFoundationAddAdapter.Entry] {
        var entries = nodes.map { node in
            let date = Date(timeIntervalSince1970: TimeInterval(node.snapshot.st_mtimespec.tv_sec))
            return ZIPFoundationAddAdapter.Entry(path: node.destination.joined(separator: "/") + (node.directory ? "/" : ""),
                directory: node.directory, size: node.directory ? 0 : UInt64(node.snapshot.st_size), modifiedAt: date,
                permissions: UInt16(node.snapshot.st_mode & 0o777), compressed: !node.directory, provider: { position, count in
                    try checkpoint()
                    let fd = try node.root.open(node.relative)
                    defer { close(fd) }
                    if node.directory { return Data() }
                    let reader = try ZIPFileReader(duplicating: fd, url: node.root.resolved, validatesPath: false)
                    let data = try reader.read(offset: UInt64(position), count: count)
                    try reader.validateUnchanged()
                    let check = try node.root.open(node.relative); close(check)
                    return data
                })
        }
        for node in nodes where node.hasOrigins {
            try checkpoint()
            let data = try ZIPMemberOrigins.pack(node.origins, scratchDirectory: scratchDirectory, budget: originBudget, checkpoint: checkpoint)
            let budget = originBudget
            entries.append(ZIPFoundationAddAdapter.Entry(path: ZIPOriginCompanionIndex.components(for: node.destination).joined(separator: "/"),
                directory: false, size: UInt64(data.count), modifiedAt: Date(timeIntervalSince1970: TimeInterval(node.snapshot.st_mtimespec.tv_sec)),
                permissions: 0o600, compressed: false, provider: { position, count in
                    try checkpoint()
                    guard position >= 0, position <= data.count, count >= 0, count <= data.count - Int(position) else { throw ZIPListingError.corrupt }
                    try budget.charge(count)
                    return data.subdata(in: Int(position)..<(Int(position) + count))
                }))
        }
        return entries
    }

    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        LocalFileIdentity.fromStat(a) == LocalFileIdentity.fromStat(b) && a.st_mode == b.st_mode
            && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
