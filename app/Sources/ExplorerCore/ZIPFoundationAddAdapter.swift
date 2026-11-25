import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

/// The sole ZIPFoundation boundary. It accepts owned descriptors and provider
/// bytes, never user pathnames, library extraction, Remove, or `.create`.
enum ZIPFoundationAddAdapter {
    struct Entry {
        let path: String
        let directory: Bool
        let size: UInt64
        let modifiedAt: Date
        let permissions: UInt16
        let compressed: Bool
        let provider: (Int64, Int) throws -> Data
    }
    struct VerifiedEntry {
        let pathKey: Data
        let size: UInt64
        let crc32: UInt32
        let digest: Data
        let directory: Bool
        let method: UInt16
        let permissions: UInt16
        let dosDate: UInt16
        let dosTime: UInt16
    }
    struct Result {
        let manifest: ZIPArchiveManifest
        let entries: [VerifiedEntry]
    }
    private final class Lifetime { weak var archive: Archive? }

    static func add(_ entries: [Entry], to descriptor: Int32, diagnosticURL: URL,
                    checkpoint: @escaping () throws -> Void,
                    afterLibrary: () throws -> Void = {}) throws -> Result {
        let reader = try ZIPFileReader(duplicating: descriptor, url: diagnosticURL, validatesPath: false)
        guard fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDWR,
              reader.length <= 2 * 1_024 * 1_024 * 1_024 else { throw ArchiveOperationError.unsupported("The ZIP candidate is not an owned writable regular file.") }
        let before = try ZIPArchiveManifest.read(from: reader, checkpoint: checkpoint)
        _ = try ZIPRecordValidation.validate(manifest: before, reader: reader, scope: .mutation, checkpoint: checkpoint)
        // The library's scanner accepts the first backward signature without our
        // exact-tail check. Do not let comment bytes redirect its allocating CD read.
        let tailLength = Int(min(reader.length, 65_557)), tailOffset = reader.length - UInt64(tailLength)
        let tail = Array(try reader.read(offset: tailOffset, count: tailLength))
        let libraryEnd = stride(from: tail.count - 22, through: 0, by: -1).first { ZIPBytes.u32(tail, $0) == 0x06054b50 }
        guard libraryEnd.map({ tailOffset + UInt64($0) }) == before.envelope.endRecordRange.offset else {
            throw ArchiveOperationError.unsupported("This archive's end comment is ambiguous to the Add writer.")
        }
        // The pinned library omits an optional ZIP64 envelope without truncating
        // old trailing bytes. Refuse that transition before provider invocation.
        guard before.envelope.rawZIP64Record == nil || before.records.count + entries.count >= Int(UInt16.max) else {
            throw ArchiveOperationError.unsupported("Adding to this optional ZIP64 envelope is not supported safely.")
        }
        guard entries.count <= 100_000 - before.records.count else { throw ZIPListingError.limitExceeded }
        let retainedRange = ZIPByteRange(offset: 0, length: before.envelope.directoryRange.offset)
        let retainedDigest = try ZIPStructuralRewrite.digest(reader: reader, range: retainedRange, checkpoint: checkpoint)
        var names = Set(before.records.map(\.pathKey) + before.directories.map(\.pathKey))
        var cumulative: UInt64 = 0, totalSize: UInt64 = 0
        for entry in entries {
            let name = entry.directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty, components.count <= 128, components.allSatisfy(ArchiveLocation.validComponent),
                  entry.path.utf8.count <= 4_096, entry.size <= 1_024 * 1_024 * 1_024,
                  !entry.directory || entry.size == 0 else { throw ZIPListingError.limitExceeded }
            let key = ZIPArchiveManifest.pathKey(components)
            guard names.insert(key).inserted else { throw ArchiveOperationError.collision(entry.path) }
            totalSize += entry.size
            guard totalSize <= 4 * 1_024 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
            // Conservative bound: each Add may rewrite the current index and
            // grow by its full input plus bounded headers. No quadratic surprise.
            cumulative += reader.length + totalSize + UInt64(entries.count * 8_192)
            guard cumulative <= 64 * 1_024 * 1_024 * 1_024 else {
                throw ArchiveOperationError.limitExceeded("Adding these entries exceeds the archive rewrite-work limit.")
            }
        }
        try checkpoint()
        let (lifetime, verified) = try append(entries, descriptor: descriptor, checkpoint: checkpoint)
        guard lifetime.archive == nil else { throw ArchiveOperationError.unsupported("The archive writer did not release its stream.") }
        try afterLibrary()
        // The dependency ignores fflush/fclose errors. Durable FD flush plus
        // independent complete payload validation is mandatory before publication.
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let resultReader = try ZIPFileReader(duplicating: descriptor, url: diagnosticURL, validatesPath: false)
        guard resultReader.length <= 2 * 1_024 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
        let manifest = try ZIPArchiveManifest.read(from: resultReader, checkpoint: checkpoint)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: resultReader, scope: .mutation, checkpoint: checkpoint)
        guard manifest.records.count == before.records.count + verified.count,
              manifest.archiveComment == before.archiveComment else { throw ZIPListingError.corrupt }
        guard try ZIPStructuralRewrite.digest(reader: resultReader, range: retainedRange, checkpoint: checkpoint) == retainedDigest else { throw ZIPListingError.corrupt }
        for (old, actual) in zip(before.records, manifest.records) {
            guard old.centralBytes.subdata(in: old.centralRange) == actual.centralBytes.subdata(in: actual.centralRange) else { throw ZIPListingError.corrupt }
        }
        for (expected, actual) in zip(verified, manifest.records.dropFirst(before.records.count)) {
            try checkpoint()
            guard actual.pathKey == expected.pathKey, actual.flags & 0x800 != 0,
                  actual.uncompressedSize == expected.size, actual.crc32 == expected.crc32,
                  actual.kind == (expected.directory ? .directory : .file), actual.method == expected.method,
                  actual.unixPermissions == expected.permissions, actual.dosDate == expected.dosDate, actual.dosTime == expected.dosTime,
                  let member = layout.records[actual.id] else { throw ZIPListingError.corrupt }
            if actual.kind == .file {
                let digest = try ZIPContentExtraction.extract(record: actual, layout: member, reader: resultReader,
                    maximumBytes: 1_024 * 1_024 * 1_024, checkpoint: checkpoint, consume: { _ in })
                guard digest == expected.digest else { throw ArchiveOperationError.contentMismatch }
            } else {
                guard actual.kind == .directory, expected.size == 0 else { throw ZIPListingError.corrupt }
            }
        }
        try resultReader.validateUnchanged()
        return Result(manifest: manifest, entries: verified)
    }

    /// Separate nonescaping scope makes the weak-reference lifetime assertion
    /// meaningful before owner fsync or validation touches the candidate.
    @inline(never)
    private static func append(_ entries: [Entry], descriptor: Int32,
                               checkpoint: () throws -> Void) throws -> (Lifetime, [VerifiedEntry]) {
        let alias = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        let archive = try Archive(url: alias, accessMode: .update)
        let lifetime = Lifetime(); lifetime.archive = archive
        var verified: [VerifiedEntry] = []
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        for entry in entries {
            try checkpoint()
            var count: UInt64 = 0, crc = ZIPCRC32(), digest = SHA256()
            let timestamp = try dosTimestamp(entry.modifiedAt, calendar: calendar)
            let path = entry.directory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
            try archive.addEntry(with: path, type: entry.directory ? .directory : .file,
                uncompressedSize: Int64(entry.size), modificationDate: timestamp.libraryDate,
                permissions: entry.permissions & 0o777, compressionMethod: entry.compressed ? .deflate : .none,
                bufferSize: 65_536, provider: { position, requested in
                    try checkpoint()
                    guard position >= 0, UInt64(position) == count, requested >= 0,
                          UInt64(requested) <= entry.size - count else { throw ArchiveOperationError.contentMismatch }
                    let data = try entry.provider(position, requested)
                    guard data.count == requested else { throw ArchiveOperationError.contentMismatch }
                    count += UInt64(data.count); try crc.update(data); digest.update(data: data)
                    return data
                })
            guard count == entry.size else { throw ArchiveOperationError.contentMismatch }
            let components = path.split(separator: "/").map(String.init)
            verified.append(VerifiedEntry(pathKey: ZIPArchiveManifest.pathKey(components), size: count,
                crc32: crc.value, digest: Data(digest.finalize()), directory: entry.directory,
                method: entry.directory || !entry.compressed ? 0 : 8, permissions: entry.permissions & 0o777,
                dosDate: timestamp.date, dosTime: timestamp.time))
        }
        return (lifetime, verified)
    }

    private static func dosTimestamp(_ date: Date, calendar: Calendar) throws -> (libraryDate: Date, date: UInt16, time: UInt16) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = parts.year, (1980...2099).contains(year), let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
            throw ArchiveOperationError.unsupported("The source date is outside the Add writer's supported 1980–2099 range.")
        }
        // ZIPFoundation uses gmtime. Our established DOS policy is local wall
        // time, so translate only at this dependency boundary.
        let adjusted = date.addingTimeInterval(TimeInterval(calendar.timeZone.secondsFromGMT(for: date)))
        return (adjusted, UInt16((year - 1980) << 9 | month << 5 | day), UInt16(hour << 11 | minute << 5 | second / 2))
    }
}
