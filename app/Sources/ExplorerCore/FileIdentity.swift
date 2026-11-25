import Darwin
import Foundation

/// A local, current-filesystem observation, not an authorization or persistent
/// provider identifier. Birth time reduces inode-reuse ambiguity on tested APFS.
/// Identity is unavailable when local-volume capability or birth time is unknown.
public struct LocalFileIdentity: Hashable, Sendable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public let linkCount: UInt64

    public init(device: UInt64, inode: UInt64, birthSeconds: Int64,
                birthNanoseconds: Int64, linkCount: UInt64 = 1) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
        self.linkCount = linkCount
    }

    // Link count is metadata used to reject ambiguous rename remapping. It can
    // change while the underlying object remains the same, so it is not a key.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
            && lhs.birthSeconds == rhs.birthSeconds && lhs.birthNanoseconds == rhs.birthNanoseconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(inode)
        hasher.combine(birthSeconds)
        hasher.combine(birthNanoseconds)
    }

    /// Compare the document a user explicitly opened, including the target of a
    /// filesystem link. Metadata sampling must never materialize its contents.
    public static func document(at url: URL, followingLinks: Bool = true) -> (identity: LocalFileIdentity, volumeUUID: UUID?, documentID: Int?, regularFile: Bool)? {
        try? HydrationMaterializationPolicy().disabled { _ in
            let target = followingLinks ? try FileSystemPath.resolvingExisting(url) : url
            let local = try target.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            guard let status = try sample(at: target, ifLocal: local), status.isRegularFile || status.isDirectory,
                  let identity = status.identity else { return nil }
            if !followingLinks, try target.resourceValues(forKeys: [.isHiddenKey]).isHidden == true { return nil }
            let package = try target.resourceValues(forKeys: [.isPackageKey]).isPackage
            guard status.isRegularFile || (status.isDirectory && package == true) else { return nil }
            let volume = try? target.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            let identifier = try? target.resourceValues(forKeys: [.documentIdentifierKey]).documentIdentifier
            // A replacement between metadata reads must not join the persistent
            // identifier of one file to the sampled physical identity of another.
            guard try read(at: target, ifLocal: local) == identity else { return nil }
            return (identity, volume.flatMap(UUID.init(uuidString:)), identifier.flatMap { $0 > 0 ? $0 : nil },
                    status.isRegularFile && package != true)
        }
    }

    /// An unsupported or unknown volume must not be probed through POSIX merely
    /// to supplement a successful Foundation read. lstat identifies the entry,
    /// rather than a symbolic link's target, only for a confirmed local volume.
    static func read(at url: URL, ifLocal isLocal: Bool?) throws -> LocalFileIdentity? {
        try sample(at: url, ifLocal: isLocal)?.identity
    }

    /// One no-follow sample supplies both operation identity and display-only
    /// availability; listing/search do not need a second stat for cloud badges.
    static func sample(at url: URL, ifLocal isLocal: Bool?) throws -> LocalFileStat? {
        guard isLocal == true else { return nil }
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return Darwin.lstat(path, &value)
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code, userInfo: [NSFilePathErrorKey: url.path])
        }
        return LocalFileStat(value)
    }

    /// Shared normalization for path samples and descriptor-anchored operations.
    static func fromStat(_ value: stat) -> LocalFileIdentity? {
        let seconds = Int64(value.st_birthtimespec.tv_sec)
        let nanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        guard value.st_ino != 0, seconds != 0 || nanoseconds != 0 else { return nil }
        return LocalFileIdentity(device: UInt64(UInt32(bitPattern: value.st_dev)),
                                 inode: UInt64(value.st_ino), birthSeconds: seconds,
                                 birthNanoseconds: nanoseconds, linkCount: UInt64(value.st_nlink))
    }

    /// COPYFILE_STAT can change birth time on a file we just created. The
    /// continuously held descriptor prevents inode reuse; full descriptor/path
    /// equality still rejects a substituted name. Never use this for a reopened
    /// descriptor or an arbitrary preexisting file.
    static func afterMetadataCopy(of original: LocalFileIdentity, descriptor: Int32,
                                  parent: Int32, name: String) throws -> LocalFileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let current = fromStat(value), original.device == current.device, original.inode == current.inode,
              try LocalFileOperations.identity(of: name, in: parent) == current else { throw FileOperationError.staleSource }
        return current
    }
}

/// Exact local content comparison for display evidence, independent of Date's
/// precision, residency and ctime. This value never grants mutation authority.
public struct LocalFileStatusVersion: Hashable, Sendable {
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64

    public init(size: Int64, modificationSeconds: Int64, modificationNanoseconds: Int64) {
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }

    init(_ value: stat) {
        self.init(size: Int64(value.st_size), modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                  modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}

struct LocalFileStat: Sendable {
    let identity: LocalFileIdentity?
    let isDataless: Bool
    let isRegularFile: Bool
    let isDirectory: Bool
    let statusVersion: LocalFileStatusVersion?
    init(_ value: stat) {
        identity = LocalFileIdentity.fromStat(value)
        isDataless = value.st_flags & UInt32(SF_DATALESS) != 0
        isRegularFile = value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        isDirectory = value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        statusVersion = isRegularFile && value.st_size >= 0 ? LocalFileStatusVersion(value) : nil
    }
    func availability(isUbiquitous: Bool) -> FileAvailability {
        if isDataless { return .onlineOnly }
        return isUbiquitous ? .availableLocally : .unknown
    }
}
