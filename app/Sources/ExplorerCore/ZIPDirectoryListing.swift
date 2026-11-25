import Darwin
import Foundation

public enum ZIPListingError: Error, LocalizedError, Equatable, Sendable {
    case corrupt, invalidPath, invalidEncoding, duplicatePath, multipleDisks
    case encryptedDirectory, unsupportedMetadata, limitExceeded, notRegularFile, changed, missingFolder
    public var errorDescription: String? {
        switch self {
        case .corrupt: return "The ZIP directory is damaged or incomplete."
        case .invalidPath: return "The ZIP contains an invalid or unsafe entry path."
        case .invalidEncoding: return "The ZIP contains a filename that cannot be decoded."
        case .duplicatePath: return "The ZIP contains conflicting entries with the same path."
        case .multipleDisks: return "ZIP archives split across multiple disks are not supported."
        case .encryptedDirectory: return "This ZIP has an encrypted directory that cannot be browsed."
        case .unsupportedMetadata: return "This ZIP uses directory metadata that is not supported."
        case .limitExceeded: return "The ZIP directory exceeds the browsing limits."
        case .notRegularFile: return "The archive location is not a regular file."
        case .changed: return "The ZIP changed while it was being read. Refresh to try again."
        case .missingFolder: return "This folder is no longer present in the ZIP."
        }
    }
}

/// Provenance only, never LocalFileIdentity or mutation authority. On a
/// filesystem with coarse metadata, an undetectable same-size in-place rewrite
/// can retain this fingerprint; no content-authenticity claim is made.
public struct ArchiveRevision: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: UInt64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
    }
    init(_ value: stat) throws {
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size >= 0 else { throw ZIPListingError.notRegularFile }
        self.init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), size: UInt64(value.st_size),
                  modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                  changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    /// Used by captured browsing menus; no central-directory or payload read.
    public func isCurrent(at archiveURL: URL) async -> Bool {
        (try? await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let reader = try ZIPFileReader(url: archiveURL)
            guard reader.revision == self else { return false }
            try reader.validateUnchanged()
            try cancellation.checkCancellation()
            return true
        }) ?? false
    }
}

/// Internal injection boundary records actual positional reads. The production
/// implementation owns one descriptor for its lifetime and never writes.
protocol ZIPPositionalReading {
    var length: UInt64 { get }
    var revision: ArchiveRevision { get }
    func read(offset: UInt64, count: Int) throws -> Data
    func validateUnchanged() throws
}

final class ZIPFileReader: ZIPPositionalReading {
    private let descriptor: Int32
    private let url: URL
    private let validatesPath: Bool
    let revision: ArchiveRevision
    var length: UInt64 { revision.size }
    init(url: URL) throws {
        guard ArchiveLocation.validPhysicalURL(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.url = url
        self.validatesPath = true
        // Avoid opening an already-observable device/FIFO target. This follows
        // links like open does, but is only a preflight: a route may change before
        // open, so descriptor fstat below remains authoritative.
        var candidate = stat()
        guard url.withUnsafeFileSystemRepresentation({ path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return fstatat(AT_FDCWD, path, &candidate, 0)
        }) == 0 else { throw Self.nativeError(url) }
        _ = try ArchiveRevision(candidate)
        // A FIFO named .zip must not block before the regular-file fstat check.
        descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { errno = EINVAL; return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw Self.nativeError(url) }
        do {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw Self.nativeError(url) }
            revision = try ArchiveRevision(value)
        } catch { close(descriptor); throw error }
    }
    /// Mutation stages already own their descriptors. Duplicating preserves that
    /// ownership; route checks are explicit at the transaction's swap boundary.
    init(duplicating source: Int32, url: URL, validatesPath: Bool = true) throws {
        self.url = url; self.validatesPath = validatesPath
        descriptor = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw Self.nativeError(url) }
        do {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw Self.nativeError(url) }
            revision = try ArchiveRevision(value)
        } catch { close(descriptor); throw error }
    }
    deinit { close(descriptor) }
    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= length, UInt64(count) <= length - offset,
              offset <= UInt64(Int64.max) else { throw ZIPListingError.corrupt }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < count {
                let received = Darwin.pread(descriptor, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if received < 0, errno == EINTR { continue }
                guard received >= 0 else { throw Self.nativeError(url) }
                guard received > 0 else { throw ZIPListingError.changed }
                done += received
            }
        }
        return data
    }
    func validateUnchanged() throws {
        var descriptorValue = stat(), pathValue = stat()
        guard fstat(descriptor, &descriptorValue) == 0,
              (try? ArchiveRevision(descriptorValue)) == revision else { throw ZIPListingError.changed }
        if validatesPath {
            guard url.withUnsafeFileSystemRepresentation({ path -> Int32 in
                  guard let path else { return -1 }
                  return fstatat(AT_FDCWD, path, &pathValue, 0)
              }) == 0,
              (try? ArchiveRevision(pathValue)) == revision else { throw ZIPListingError.changed }
        }
    }
    /// An absent attribute is nil; unreadable, changing or oversized values fail closed.
    func originAttributes(maximumBytesPerValue: Int = 256 * 1_024) throws -> ZIPOriginAttributes {
        guard maximumBytesPerValue >= 0 else { throw ZIPListingError.limitExceeded }
        let bound = min(maximumBytesPerValue, 256 * 1_024)
        return try originAttributes(budget: ZIPOriginBudget(maximumAttributeBytes: bound, maximumTotalBytes: bound * 2))
    }
    func originAttributes(budget: ZIPOriginBudget) throws -> ZIPOriginAttributes {
        try validateUnchanged()
        let values = try ZIPMemberOrigins.capture(from: descriptor, budget: budget)
        try validateUnchanged()
        return values
    }
    private static func nativeError(_ url: URL) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// Engineering resource limits; they are not Windows fidelity claims.
struct ZIPListingLimits: Sendable {
    let maximumDirectoryBytes: Int, maximumEntries: Int, maximumNodes: Int
    let maximumNameBytes: Int, maximumDepth: Int, maximumPathBytes: Int
    init(maximumDirectoryBytes: Int = 64 * 1_024 * 1_024, maximumEntries: Int = 100_000,
         maximumNodes: Int = 100_000, maximumNameBytes: Int = 4_096,
         maximumDepth: Int = 128, maximumPathBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumDirectoryBytes = maximumDirectoryBytes; self.maximumEntries = maximumEntries
        self.maximumNodes = maximumNodes; self.maximumNameBytes = maximumNameBytes
        self.maximumDepth = maximumDepth; self.maximumPathBytes = maximumPathBytes
    }
}

/// NATIVE-P20 / FR-EXT-005/007. Reads the bounded EOCD discovery tail and ZIP
/// directory metadata only. The tail may overlap member bytes; no member data
/// is interpreted, decompressed, opened externally or extracted. Format source:
/// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT (6.3.10).
public struct LocalZIPDirectoryLoader: DirectoryListing {
    private let limits: ZIPListingLimits
    private let readerFactory: @Sendable (URL) throws -> any ZIPPositionalReading
    public init() { self.init(limits: ZIPListingLimits()) }
    init(limits: ZIPListingLimits = ZIPListingLimits(),
         readerFactory: @escaping @Sendable (URL) throws -> any ZIPPositionalReading = { try ZIPFileReader(url: $0) }) {
        self.limits = limits; self.readerFactory = readerFactory
    }
    public func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    public func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard let location = ArchiveLocation(url: url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let result = try await BlockingIO.run(on: .read) { cancellation in
            let reader = try readerFactory(location.archiveURL)
            let manifest = try ZIPArchiveManifest.read(from: reader, limits: limits, checkpoint: { try cancellation.checkCancellation() })
            let items = try manifest.items(in: location, showHidden: showHidden, checkpoint: { try cancellation.checkCancellation() })
            try cancellation.checkCancellation()
            try reader.validateUnchanged()
            return DirectorySnapshot(items: items, archiveRevision: reader.revision)
        }
        try Task.checkCancellation()
        return result
    }
}
