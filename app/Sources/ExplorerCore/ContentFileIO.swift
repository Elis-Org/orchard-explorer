import CryptoKit
import Darwin
import Foundation

struct ContentLimits: Sendable {
    var archiveBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    var memberBytes: UInt64 = 1_024 * 1_024 * 1_024
    var transactionBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    var ownedBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    var previewBytes: UInt64 = 512 * 1_024 * 1_024
    var previewSeconds: TimeInterval = 30
    var hydrationSeconds: TimeInterval = 120
    var downloadBytes: UInt64 = CloudDownloadPolicy.maximumBytes
    var downloadSeconds: TimeInterval = CloudDownloadPolicy.timeoutSeconds
    var operationSeconds: TimeInterval = 300
    var retiredSeconds: TimeInterval = 3_600
    var shutdownSeconds: TimeInterval = 5
}

struct ContentDeadline: Sendable {
    let end: UInt64
    init(seconds: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let duration = max(0, min(seconds, 86_400)) * 1_000_000_000
        end = now.addingReportingOverflow(UInt64(duration)).partialValue
    }
    func check() throws {
        guard DispatchTime.now().uptimeNanoseconds < end else { throw ItemContentError.deadlineExceeded }
    }
    var remainingSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < end ? Double(end - now) / 1_000_000_000 : 0
    }
}

/// A stat version, distinct from FileItem's refresh identity. No source digest
/// or immunity to changes after the final check is implied.
struct ContentFileVersion: Equatable, Sendable {
    let identity: LocalFileIdentity
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let owner: UInt32
    let group: UInt32
    let links: UInt64
    let flags: UInt32

    init(_ value: stat) throws {
        guard let identity = LocalFileIdentity.fromStat(value), value.st_size >= 0 else { throw ItemContentError.staleSource }
        self.identity = identity; mode = UInt16(value.st_mode); size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        owner = value.st_uid; group = value.st_gid; links = UInt64(value.st_nlink); flags = value.st_flags
    }

    func validateCurrent(_ value: stat) throws {
        guard LocalFileIdentity.fromStat(value) == identity else { throw ItemContentError.staleSource }
        // Eviction changes the stamp, but is not evidence of a replacement.
        guard value.st_flags & UInt32(SF_DATALESS) == 0 else { throw ItemContentError.cloudNotDownloaded }
        guard try ContentFileVersion(value) == self else { throw ItemContentError.staleSource }
    }
}

enum ContentFileIO {
    static let chunkSize = 64 * 1_024
    static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static func sample(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw failure() }; return value
    }
    static func sample(_ name: String, at parent: Int32) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw failure() }
        return value
    }
    static func requireAvailableSpace(_ bytes: UInt64, at fd: Int32) throws {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw failure() }
        guard filesystem.f_bsize > 0 else { throw ItemContentError.unsupportedType }
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard available.overflow || bytes <= available.partialValue else { throw POSIXError(.ENOSPC) }
        // Advisory only: concurrent writers and quotas can still make a later
        // write fail. Those actual errors remain authoritative.
    }
    static func clearACL(_ fd: Int32) throws {
        try DescriptorIO.clearExtendedACL(fd)
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure() }; offset += written
            }
        }
    }
    static func digest(_ fd: Int32, checkpoint: () throws -> Void) throws -> Data {
        var hash = SHA256(), offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try checkpoint()
            let received = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, offset) }
            if received < 0, errno == EINTR { continue }
            guard received >= 0 else { throw failure() }
            if received == 0 { break }
            hash.update(data: Data(buffer.prefix(received))); offset += off_t(received)
        }
        try checkpoint(); return Data(hash.finalize())
    }
    static func names(_ fd: Int32, checkpoint: () throws -> Void = {}) throws -> [String] {
        var result: [String] = []
        do {
            try DescriptorIO.forEachDirectoryEntry(in: fd, checkpoint: checkpoint) { name in
                guard result.count <= 100_000 else { throw ItemContentError.limitExceeded }
                result.append(name)
            }
        } catch DescriptorIO.DirectoryEntryError.invalidUTF8 { throw ItemContentError.unsupportedType }
        return result
    }
    static func applyMetadata(_ fd: Int32, mode: UInt16, modifiedAt: Date?) throws {
        try clearACL(fd)
        if let modifiedAt {
            let seconds = modifiedAt.timeIntervalSince1970
            guard seconds.isFinite, seconds > Double(Int64.min), seconds < Double(Int64.max) else { throw ItemContentError.corruptContent }
            let whole = floor(seconds)
            var times = [try sample(fd).st_atimespec,
                         timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))]
            guard futimens(fd, &times) == 0 else { throw failure() }
        }
        guard fchmod(fd, mode_t(mode & 0o777)) == 0 else { throw failure() }
    }
    static func path(of fd: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}

/// Held persistent root. Existing directories are never chmodded or ACL-edited.
/// Creation follows a canonical route and opens every component without links.
final class ContentRoot: @unchecked Sendable {
    let requestedURL: URL
    let url: URL
    let fd: Int32
    let identity: LocalFileIdentity

    /// Resolve the deepest existing ancestor with the repository's realpath
    /// helper, then append only missing lexical components. Foundation may
    /// deliberately turn /private/var back into the /var symlink on this host.
    static func resolvingForCreation(_ requested: URL) throws -> URL {
        var ancestor = requested
        var missing: [String] = []
        while true {
            do {
                let existing = try FileSystemPath.resolvingExisting(ancestor)
                let path = existing.path + (missing.isEmpty ? "" : "/" + missing.reversed().joined(separator: "/"))
                return path.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: true, relativeTo: nil) }
            } catch let error as POSIXError where error.code == .ENOENT {
                guard ancestor.path != "/", ArchiveLocation.validComponent(ancestor.lastPathComponent) else { throw error }
                missing.append(ancestor.lastPathComponent); ancestor = ancestor.deletingLastPathComponent()
            }
        }
    }

    init(_ requestedURL: URL) throws {
        guard ArchiveLocation.validPhysicalURL(requestedURL), requestedURL.path != "/" else { throw ItemContentError.unsupportedType }
        self.requestedURL = requestedURL.standardizedFileURL
        url = try Self.resolvingForCreation(requestedURL)
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw ContentFileIO.failure() }
        do {
            for component in url.path.split(separator: "/").map(String.init) {
                var created = false
                if component.withCString({ mkdirat(current, $0, 0o700) }) == 0 { created = true }
                else if errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO,
                        userInfo: [NSFilePathErrorKey: url.path, "ContentOperation": "Create root component", "ContentComponent": component])
                }
                let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO,
                        userInfo: [NSFilePathErrorKey: url.path, "ContentOperation": "Open root component", "ContentComponent": component])
                }
                do { if created { try ContentFileIO.clearACL(next) } }
                catch { close(next); throw error }
                close(current); current = next
            }
            let value = try ContentFileIO.sample(current)
            guard value.st_uid == geteuid(), value.st_mode & 0o777 == 0o700,
                  let identity = LocalFileIdentity.fromStat(value) else { throw ItemContentError.unsupportedType }
            var filesystem = statfs()
            guard fstatfs(current, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ItemContentError.unsupportedType }
            self.identity = identity; fd = current
        } catch { close(current); throw error }
        try validate()
    }
    deinit { close(fd) }
    func validate() throws {
        guard try FileSystemPath.resolvingExisting(requestedURL).path.utf8.elementsEqual(url.path.utf8),
              LocalFileIdentity.fromStat(try ContentFileIO.sample(fd)) == identity else { throw ItemContentError.staleSource }
        var value = stat()
        guard lstat(url.path, &value) == 0, LocalFileIdentity.fromStat(value) == identity,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_uid == geteuid(),
              value.st_mode & 0o777 == 0o700 else { throw ItemContentError.staleSource }
    }
}

struct ContentOwnedNode {
    let components: [String]
    let isDirectory: Bool
    var version: ContentFileVersion
    var digest: Data?
}

/// Exactly one private export tree. Its only cleanup traversal is the recorded
/// ledger; unexpected names, changed nodes and route uncertainty are retained.
final class ContentOwnedStage: @unchecked Sendable {
    let root: ContentRoot
    let name: String
    let fd: Int32
    let identity: LocalFileIdentity
    var nodes: [Data: ContentOwnedNode] = [:]
    var url: URL { root.url.appendingPathComponent(name, isDirectory: true) }
    // Reports use normal display URL spelling; all authority stays descriptor
    // based and route validation compares the unstandardized realpath spelling.
    var reportingURL: URL { (ContentFileIO.path(of: fd) ?? url).standardizedFileURL }

    init(root: ContentRoot, id: UUID) throws {
        self.root = root; name = "content-" + id.uuidString
        try root.validate()
        guard name.withCString({ mkdirat(root.fd, $0, 0o700) }) == 0 else { throw ContentFileIO.failure() }
        let opened = name.withCString { openat(root.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard opened >= 0 else { throw ContentFileIO.failure() }
        do {
            try ContentFileIO.clearACL(opened)
            guard let identity = LocalFileIdentity.fromStat(try ContentFileIO.sample(opened)) else { throw ItemContentError.staleSource }
            self.identity = identity; fd = opened
        } catch { close(opened); throw error }
    }
    deinit { close(fd) }
    static func key(_ components: [String]) -> Data { Data(components.joined(separator: "/").utf8) }
    func validate() throws {
        try root.validate()
        let held = try ContentFileIO.sample(fd), named = try ContentFileIO.sample(name, at: root.fd)
        guard LocalFileIdentity.fromStat(held) == identity, LocalFileIdentity.fromStat(named) == identity,
              held.st_mode & 0o777 == 0o700, named.st_mode & 0o777 == 0o700,
              held.st_uid == geteuid(), named.st_uid == geteuid() else { throw ItemContentError.staleSource }
    }
    func parent<T>(of components: [String], _ body: (Int32, String) throws -> T) throws -> T {
        guard let name = components.last, components.allSatisfy(ArchiveLocation.validComponent) else { throw ItemContentError.unsupportedType }
        try validate()
        var current = dup(fd)
        guard current >= 0 else { throw ContentFileIO.failure() }
        defer { close(current) }
        var prefix: [String] = []
        for component in components.dropLast() {
            prefix.append(component)
            guard let expected = nodes[Self.key(prefix)], expected.isDirectory else { throw ItemContentError.staleSource }
            let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw ContentFileIO.failure() }
            guard LocalFileIdentity.fromStat(try ContentFileIO.sample(next)) == expected.version.identity else {
                close(next); throw ItemContentError.staleSource
            }
            close(current); current = next
        }
        return try body(current, name)
    }
    func create(_ components: [String], directory: Bool) throws -> Int32 {
        try parent(of: components) { parent, name in
            let child: Int32
            if directory {
                guard name.withCString({ mkdirat(parent, $0, 0o700) }) == 0 else { throw ContentFileIO.failure() }
                child = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            } else {
                child = name.withCString { openat(parent, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            }
            guard child >= 0 else { throw ContentFileIO.failure() }
            do {
                let version = try ContentFileVersion(ContentFileIO.sample(child))
                nodes[Self.key(components)] = ContentOwnedNode(components: components, isDirectory: directory, version: version, digest: nil)
                try ContentFileIO.clearACL(child); return child
            } catch { close(child); throw error }
        }
    }
    func seal(_ components: [String], fd: Int32, digest: Data?, reconcilingMetadata: Bool = false) throws {
        let key = Self.key(components)
        guard var node = nodes[key] else { throw ItemContentError.staleSource }
        let version = try ContentFileVersion(ContentFileIO.sample(fd))
        try parent(of: components) { parent, name in
            if reconcilingMetadata {
                // Only the metadata writer calls this while its descriptor is
                // continuously held. APFS may lower birth time when futimens
                // applies an older mtime. Reuse the same device/inode + current
                // named-entry reconciliation as physical COPYFILE_STAT.
                let identity = try LocalFileIdentity.afterMetadataCopy(of: node.version.identity,
                    descriptor: fd, parent: parent, name: name)
                guard identity == version.identity else { throw ItemContentError.staleSource }
            } else {
                guard node.version.identity == version.identity else { throw ItemContentError.staleSource }
            }
            guard try ContentFileVersion(ContentFileIO.sample(name, at: parent)) == version else { throw ItemContentError.staleSource }
        }
        node.version = version; node.digest = digest; nodes[key] = node
    }
    private func revalidateParent(_ held: Int32, of components: [String]) throws {
        let identity = LocalFileIdentity.fromStat(try ContentFileIO.sample(held))
        try parent(of: components) { current, _ in
            guard let identity, LocalFileIdentity.fromStat(try ContentFileIO.sample(current)) == identity else {
                throw ItemContentError.staleSource
            }
        }
    }
    func validateContents() throws {
        try validate()
        var children: [Data: Set<Data>] = [:]
        for node in nodes.values {
            guard let name = node.components.last else { throw ItemContentError.staleSource }
            children[Self.key(Array(node.components.dropLast())), default: []].insert(Data(name.utf8))
        }
        func verifyChildren(_ parent: Int32, prefix: [String]) throws {
            let actual = Set(try ContentFileIO.names(parent).map { Data($0.utf8) })
            guard actual == children[Self.key(prefix), default: []] else { throw ItemContentError.staleSource }
        }
        try verifyChildren(fd, prefix: [])
        for node in nodes.values {
            try parent(of: node.components) { parent, name in
                guard try ContentFileVersion(ContentFileIO.sample(name, at: parent)) == node.version else { throw ItemContentError.staleSource }
                if node.isDirectory {
                    let child = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    guard child >= 0 else { throw ContentFileIO.failure() }
                    defer { close(child) }
                    guard try ContentFileVersion(ContentFileIO.sample(child)) == node.version else { throw ItemContentError.staleSource }
                    try verifyChildren(child, prefix: node.components)
                }
            }
        }
    }
    func cleanup(deadline: ContentDeadline,
                 deleting: (_ operation: () throws -> Void) throws -> Void = { try $0() }) -> [RetainedContentArtifact] {
        var retained: [RetainedContentArtifact] = []
        do { try deadline.check(); try validate() }
        catch { return [RetainedContentArtifact(url: reportingURL, reason: "The content location could not be verified: \(error.localizedDescription)")] }
        var protected = Set<Data>(), missing = Set<Data>()
        func beneath(_ components: [String], keys: Set<Data>) -> Bool {
            guard !keys.isEmpty else { return false }
            return (1...components.count).contains { keys.contains(Self.key(Array(components.prefix($0)))) }
        }
        // Capture external directory changes before our own unlinks alter their
        // mtime/ctime. A changed ancestor protects its complete remaining tree;
        // a missing ancestor is skipped without chasing its new location.
        for node in nodes.values.filter(\.isDirectory).sorted(by: { $0.components.count < $1.components.count }) {
            if beneath(node.components, keys: protected) || beneath(node.components, keys: missing) { continue }
            do {
                try deadline.check()
                try parent(of: node.components) { parent, name in
                    guard try ContentFileVersion(ContentFileIO.sample(name, at: parent)) == node.version else { throw ItemContentError.staleSource }
                }
            } catch {
                if let error = error as? POSIXError, error.code == .ENOENT { missing.insert(Self.key(node.components)); continue }
                protected.insert(Self.key(node.components))
                let location = node.components.reduce(reportingURL) { $0.appendingPathComponent($1) }
                retained.append(RetainedContentArtifact(url: location, reason: "The directory changed or could not be verified; its remaining contents were preserved."))
            }
            if retained.count >= 128 {
                return [RetainedContentArtifact(url: reportingURL, reason: "Multiple changed or unverifiable directories were preserved in this content folder.")]
            }
        }
        // Deepest nodes first. No enumerate-and-delete or recursive pathname API.
        for node in nodes.values.sorted(by: { $0.components.count > $1.components.count }) {
            if beneath(node.components, keys: protected) || beneath(node.components, keys: missing) { continue }
            do { try deadline.check() }
            catch {
                retained.append(RetainedContentArtifact(url: reportingURL, reason: "Cleanup reached its time limit; remaining entries were preserved."))
                return retained
            }
            if retained.count >= 128 {
                return [RetainedContentArtifact(url: reportingURL, reason: "Multiple changed or unverifiable entries were preserved in this content folder.")]
            }
            let location = node.components.reduce(reportingURL) { $0.appendingPathComponent($1) }
            do {
                try deadline.check()
                try parent(of: node.components) { parent, name in
                    var named = stat()
                    guard name.withCString({ fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                        if errno == ENOENT { return }; throw ContentFileIO.failure()
                    }
                    if node.isDirectory {
                        guard LocalFileIdentity.fromStat(named) == node.version.identity,
                              UInt16(named.st_mode) == node.version.mode,
                              named.st_uid == node.version.owner, named.st_gid == node.version.group,
                              named.st_flags == node.version.flags else { throw ItemContentError.staleSource }
                        let child = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                        guard child >= 0 else { throw ContentFileIO.failure() }
                        defer { close(child) }
                        guard LocalFileIdentity.fromStat(try ContentFileIO.sample(child)) == node.version.identity,
                              try ContentFileIO.names(child, checkpoint: deadline.check).isEmpty else { throw ItemContentError.staleSource }
                    } else {
                        guard try ContentFileVersion(named) == node.version else { throw ItemContentError.staleSource }
                        let child = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                        guard child >= 0 else { throw ContentFileIO.failure() }
                        defer { close(child) }
                        guard try ContentFileVersion(ContentFileIO.sample(child)) == node.version else { throw ItemContentError.staleSource }
                        if let digest = node.digest {
                            guard try ContentFileIO.digest(child, checkpoint: deadline.check) == digest else { throw ItemContentError.staleSource }
                        }
                        guard try ContentFileVersion(ContentFileIO.sample(child)) == node.version else { throw ItemContentError.staleSource }
                    }
                    try deleting {
                        try deadline.check(); try validate()
                        // Hashing can take time. Reopen the recorded ancestor
                        // route before unlinking through this held parent, so a
                        // consumer-moved directory is not followed out of scope.
                        try revalidateParent(parent, of: node.components)
                        let latest = try ContentFileIO.sample(name, at: parent)
                        guard LocalFileIdentity.fromStat(latest) == node.version.identity else { throw ItemContentError.staleSource }
                        if !node.isDirectory, try ContentFileVersion(latest) != node.version { throw ItemContentError.staleSource }
                        if node.isDirectory {
                            guard UInt16(latest.st_mode) == node.version.mode,
                                  latest.st_uid == node.version.owner, latest.st_gid == node.version.group,
                                  latest.st_flags == node.version.flags else { throw ItemContentError.staleSource }
                        }
                        guard name.withCString({ unlinkat(parent, $0, node.isDirectory ? AT_REMOVEDIR : 0) }) == 0 else { throw ContentFileIO.failure() }
                    }
                }
            } catch {
                // A recorded directory moved away: descendants are no longer
                // reachable through our namespace. Never chase or invent a
                // retained path for those missing descendants.
                if let error = error as? POSIXError, error.code == .ENOENT { continue }
                retained.append(RetainedContentArtifact(url: location, reason: "Preserved because unchanged ownership could not be proven: \(error.localizedDescription)"))
            }
        }
        do {
            try deleting {
                try deadline.check(); try validate()
                guard try ContentFileIO.names(fd, checkpoint: deadline.check).isEmpty else { throw ItemContentError.staleSource }
                guard name.withCString({ unlinkat(root.fd, $0, AT_REMOVEDIR) }) == 0 else { throw ContentFileIO.failure() }
            }
        } catch {
            retained.append(RetainedContentArtifact(url: reportingURL, reason: "The private content folder was retained: \(error.localizedDescription)"))
        }
        return retained
    }
}
