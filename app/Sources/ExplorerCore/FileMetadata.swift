import Darwin
import Foundation

public struct FileMetadata: Equatable, Sendable {
    public let size: Int64?
    public let allocatedSize: Int64?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let accessedAt: Date?
    public let capturedAt: Date

    public init(size: Int64?, allocatedSize: Int64?, createdAt: Date?, modifiedAt: Date?,
                accessedAt: Date?, capturedAt: Date = Date()) {
        self.size = size
        self.allocatedSize = allocatedSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.capturedAt = capturedAt
    }

    init(stat value: stat, capturedAt: Date) {
        let regular = value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        size = regular && value.st_size >= 0 ? Int64(value.st_size) : nil
        // Darwin st_blocks counts allocated 512-byte blocks. A zero allocation
        // is valid; negative/overflowed values are unavailable, never estimates.
        let blocks = Int64(value.st_blocks)
        let allocation = blocks.multipliedReportingOverflow(by: 512)
        allocatedSize = regular && blocks >= 0 && !allocation.overflow ? allocation.partialValue : nil
        let birth = value.st_birthtimespec
        createdAt = birth.tv_sec == 0 && birth.tv_nsec == 0 ? nil : Self.date(birth)
        modifiedAt = Self.date(value.st_mtimespec)
        accessedAt = Self.date(value.st_atimespec)
        self.capturedAt = capturedAt
    }

    private static func date(_ value: timespec) -> Date? {
        guard value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000)
    }
}

public enum FileMetadataError: LocalizedError, Equatable, Sendable {
    case missingIdentity
    case staleSelection
    case unsupportedLocation

    public var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "Properties are available only for supported local files and folders."
        case .staleSelection:
            return "The selected entry changed or disappeared. Refresh the folder and open Properties again."
        case .unsupportedLocation:
            return "Metadata is available only for local file URLs."
        }
    }
}

public protocol FileMetadataReading: Sendable {
    func metadata(for item: FileItem) async throws -> FileMetadata
}

/// FR-PREVIEW-002 / EV-0277–0279 / AT-PREVIEW-002 General-properties data subset.
/// One lstat supplies both identity and metadata. No contents, recursive size,
/// thumbnail, target-link metadata, or provider capability probing is performed.
public struct LocalFileMetadataReader: FileMetadataReading {
    public init() {}

    public func metadata(for item: FileItem) async throws -> FileMetadata {
        let result = try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let url = item.url
            guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  !url.path.contains("\0") else { throw FileMetadataError.unsupportedLocation }
            guard let expected = item.identity else { throw FileMetadataError.missingIdentity }
            var path = url.path
            // A trailing slash can make POSIX resolve a directory symlink even
            // with lstat. Inspect the lexical entry regardless of URL directory hint.
            while path.count > 1 && path.last == "/" { path.removeLast() }
            var value = stat()
            guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR { throw FileMetadataError.staleSelection }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
            }
            let capturedAt = Date()
            guard LocalFileIdentity.fromStat(value) == expected else { throw FileMetadataError.staleSelection }
            try cancellation.checkCancellation()
            return FileMetadata(stat: value, capturedAt: capturedAt)
        }
        try Task.checkCancellation()
        return result
    }
}
