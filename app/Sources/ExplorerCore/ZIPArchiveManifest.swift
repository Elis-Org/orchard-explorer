import CoreFoundation
import Foundation

struct ZIPByteRange: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64
}

enum ZIPEntryKind: Equatable, Sendable { case file, directory, symbolicLink, unsupported }

/// Ordinals identify explicit records within one manifest/revision, not across refreshes.
struct ZIPCentralRecord: Sendable {
    let id: Int
    let components: [String]
    let pathKey: Data
    let kind: ZIPEntryKind
    let flags: UInt16
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let versionMadeBy: UInt16
    let versionNeeded: UInt16
    let dosDate: UInt16
    let dosTime: UInt16
    let internalAttributes: UInt16
    let externalAttributes: UInt32
    let modifiedAt: Date?
    let unixPermissions: UInt16?
    // Slices into one copy-on-write central buffer, rather than member-sized data.
    let centralBytes: Data
    let centralRange: Range<Int>
    let nameRange: Range<Int>
    let extraRange: Range<Int>
    let commentRange: Range<Int>

    var nameBytes: Data { centralBytes.subdata(in: nameRange) }
    var extraBytes: Data { centralBytes.subdata(in: extraRange) }
    var commentBytes: Data { centralBytes.subdata(in: commentRange) }
}

struct ZIPDirectoryEntry: Sendable {
    let components: [String]
    let pathKey: Data
    let isExplicit: Bool
    let recordIDs: [Int]
    let modifiedAt: Date?
    let unixPermissions: UInt16?
}

struct ZIPSelection: Sendable {
    let components: [String]
    let isDirectory: Bool
    /// Includes the selected directory itself, implicit children and explicit empty directories.
    let directories: [ZIPDirectoryEntry]
    /// Every explicit selected record, including repeated explicit directories.
    let records: [ZIPCentralRecord]
}

struct ZIPArchiveEnvelope: Sendable {
    let directoryRange: ZIPByteRange
    let endRecordRange: ZIPByteRange
    let zip64RecordRange: ZIPByteRange?
    let zip64LocatorRange: ZIPByteRange?
    let rawEndRecord: Data
    let rawZIP64Record: Data?
    let rawZIP64Locator: Data?
}

struct ZIPArchiveManifest: Sendable {
    let revision: ArchiveRevision
    let records: [ZIPCentralRecord]
    let directories: [ZIPDirectoryEntry]
    let envelope: ZIPArchiveEnvelope
    let archiveComment: Data

    static func read(from reader: any ZIPPositionalReading,
                     limits: ZIPListingLimits = ZIPListingLimits(),
                     checkpoint: @escaping () throws -> Void = {}) throws -> ZIPArchiveManifest {
        var parser = ZIPManifestParser(reader: reader, limits: limits, checkpoint: checkpoint)
        return try parser.parse()
    }

    func selection(at location: ArchiveLocation) throws -> ZIPSelection {
        let key = Self.pathKey(location.components)
        if !location.components.isEmpty, !directories.contains(where: { $0.pathKey == key }) {
            guard let record = records.first(where: { $0.pathKey == key }) else { throw ZIPListingError.missingFolder }
            return ZIPSelection(components: location.components, isDirectory: false, directories: [], records: [record])
        }
        return ZIPSelection(components: location.components, isDirectory: true,
            directories: directories.filter { Self.contains($0.pathKey, in: key) },
            records: records.filter { Self.contains($0.pathKey, in: key) })
    }
    static func pathKey(_ components: [String]) -> Data { Data(components.joined(separator: "/").utf8) }
    static func contains(_ path: Data, in parent: Data) -> Bool {
        if parent.isEmpty || path == parent { return true }
        var prefix = parent; prefix.append(47)
        return path.starts(with: prefix)
    }
    func items(in location: ArchiveLocation, showHidden: Bool, checkpoint: () throws -> Void) throws -> [FileItem] {
        let parent = Self.pathKey(location.components)
        guard parent.isEmpty || directories.contains(where: { $0.pathKey == parent }) else { throw ZIPListingError.missingFolder }
        func immediate(_ components: [String]) -> Bool {
            components.count == location.components.count + 1 && Self.pathKey(Array(components.dropLast())) == parent
                && (showHidden || !(components.last?.hasPrefix(".") ?? false))
        }
        var items: [FileItem] = []
        for directory in directories where immediate(directory.components) {
            try checkpoint()
            let url = try ArchiveLocation(archiveURL: location.archiveURL, components: directory.components).url
            items.append(FileItem(url: url, name: directory.components.last!, isDirectory: true, isSymbolicLink: false,
                size: nil, modifiedAt: directory.modifiedAt, kind: "File folder", archiveRevision: revision))
        }
        for record in records where record.kind != .directory && immediate(record.components) {
            try checkpoint()
            let url = try ArchiveLocation(archiveURL: location.archiveURL, components: record.components).url
            let link = record.kind == .symbolicLink
            items.append(FileItem(url: url, name: record.components.last!, isDirectory: false, isSymbolicLink: link,
                size: link ? nil : Int64(record.uncompressedSize), modifiedAt: record.modifiedAt,
                kind: link ? "Symbolic link" : "Archived file", archiveRevision: revision))
        }
        return items
    }

}

enum ZIPValidationScope {
    case content(recordIDs: Set<Int>)
    case mutation
}

struct ZIPRecordLayout: Sendable {
    let recordID: Int
    let localHeaderRange: ZIPByteRange
    let nameRange: ZIPByteRange
    let extraRange: ZIPByteRange
    let payloadRange: ZIPByteRange
    let descriptorRange: ZIPByteRange?
    let completeRange: ZIPByteRange
    let modifiedAt: Date?
    let unixPermissions: UInt16?
}

struct ZIPValidatedLayout: Sendable {
    let records: [Int: ZIPRecordLayout]
}

struct ZIPOriginAttributes: Sendable, Equatable {
    let quarantine: Data?
    let whereFroms: Data?
}

private struct ZIPManifestParser {
    struct IndexRange { let offset: UInt64; let size: Int; let count: Int }
    struct Node {
        let components: [String]
        var directory: Bool
        var symbolicLink: Bool
        var size: Int64?
        var modified: Date?
        var explicit: Bool
        var recordIDs: [Int]
        var unixPermissions: UInt16?
    }
    let reader: any ZIPPositionalReading
    let limits: ZIPListingLimits
    let checkpoint: () throws -> Void
    var envelope: ZIPArchiveEnvelope?
    var bytesRead = 0
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }()
    init(reader: any ZIPPositionalReading, limits: ZIPListingLimits, checkpoint: @escaping () throws -> Void) {
        self.reader = reader; self.limits = limits; self.checkpoint = checkpoint
    }
    // At most one tail, one locator (20), one fixed ZIP64 record (56), one CD.
    private var maximumReadBytes: Int { 65_557 + max(0, limits.maximumDirectoryBytes) + 76 }

    mutating func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        try checkpoint()
        guard count >= 0, offset <= reader.length, UInt64(count) <= reader.length - offset,
              count <= maximumReadBytes - bytesRead else { throw ZIPListingError.corrupt }
        bytesRead += count
        let bytes = try reader.read(offset: offset, count: count)
        guard bytes.count == count else { throw ZIPListingError.corrupt }
        return Array(bytes)
    }

    mutating func indexRange() throws -> IndexRange {
        guard reader.length >= 22 else { throw ZIPListingError.corrupt }
        let tailCount = Int(min(reader.length, 65_557))
        let tailOffset = reader.length - UInt64(tailCount)
        let tail = try read(tailOffset, tailCount)
        var found: Int?
        for position in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, position) == 0x06054B50,
               Int(u16(tail, position + 20)) == tail.count - position - 22 {
                found = position; break
            }
        }
        guard let end = found else { throw ZIPListingError.corrupt }
        let endOffset = tailOffset + UInt64(end)
        var rawZIP64: Data?, rawLocator: Data?, zip64Offset: UInt64?
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0 else { throw ZIPListingError.multipleDisks }
        let diskCount = u16(tail, end + 8), totalCount = u16(tail, end + 10)
        let size32 = u32(tail, end + 12), offset32 = u32(tail, end + 16)
        var count = UInt64(totalCount), size = UInt64(size32), offset = UInt64(offset32), directoryEnd = endOffset
        let saturated = diskCount == .max || totalCount == .max || size32 == .max || offset32 == .max
        // A non-saturated ZIP64 locator may still be present. Its known position
        // is inspected in the existing tail, never by probing member data.
        let hasLocator = end >= 20 && u32(tail, end - 20) == 0x07064B50
        if saturated || hasLocator {
            guard endOffset >= 20 else { throw ZIPListingError.corrupt }
            let locator = try read(endOffset - 20, 20)
            rawLocator = Data(locator)
            guard u32(locator, 0) == 0x07064B50 else { throw ZIPListingError.corrupt }
            guard u32(locator, 4) == 0, u32(locator, 16) == 1 else { throw ZIPListingError.multipleDisks }
            let recordOffset = u64(locator, 8)
            // v1 is the fixed 56-byte record. Do not read an attacker-sized
            // extensible record or guess an offset correction for an SFX prefix.
            guard recordOffset <= endOffset - 20, endOffset - 20 - recordOffset == 56 else { throw ZIPListingError.corrupt }
            let record = try read(recordOffset, 56)
            rawZIP64 = Data(record); zip64Offset = recordOffset
            guard u32(record, 0) == 0x06064B50, u64(record, 4) == 44 else { throw ZIPListingError.unsupportedMetadata }
            guard u32(record, 16) == 0, u32(record, 20) == 0 else { throw ZIPListingError.multipleDisks }
            guard u64(record, 24) == u64(record, 32) else { throw ZIPListingError.corrupt }
            count = u64(record, 32); size = u64(record, 40); offset = u64(record, 48); directoryEnd = recordOffset
            guard (diskCount == .max || UInt64(diskCount) == count),
                  (totalCount == .max || UInt64(totalCount) == count),
                  (size32 == .max || UInt64(size32) == size),
                  (offset32 == .max || UInt64(offset32) == offset) else { throw ZIPListingError.corrupt }
        } else if diskCount != totalCount { throw ZIPListingError.corrupt }
        guard offset <= directoryEnd, size == directoryEnd - offset else { throw ZIPListingError.corrupt }
        guard size <= UInt64(max(0, limits.maximumDirectoryBytes)), count <= UInt64(max(0, limits.maximumEntries)) else { throw ZIPListingError.limitExceeded }
        guard count <= size / 46 else { throw ZIPListingError.corrupt }
        envelope = ZIPArchiveEnvelope(directoryRange: ZIPByteRange(offset: offset, length: size),
            endRecordRange: ZIPByteRange(offset: endOffset, length: UInt64(tail.count - end)),
            zip64RecordRange: zip64Offset.map { ZIPByteRange(offset: $0, length: 56) },
            zip64LocatorRange: rawLocator.map { _ in ZIPByteRange(offset: endOffset - 20, length: 20) },
            rawEndRecord: Data(tail[end...]), rawZIP64Record: rawZIP64, rawZIP64Locator: rawLocator)
        return IndexRange(offset: offset, size: Int(size), count: Int(count))
    }

    mutating func parse() throws -> ZIPArchiveManifest {
        let range = try indexRange()
        let bytes = try read(range.offset, range.size)
        let centralData = Data(bytes)
        var records: [ZIPCentralRecord] = []; records.reserveCapacity(range.count)
        var position = 0, nodes: [Data: Node] = [:], totalPathBytes = 0
        nodes.reserveCapacity(min(range.count, limits.maximumNodes))
        func key(_ components: [String]) -> Data { Data(components.joined(separator: "/").utf8) }
        for ordinal in 0..<range.count {
            try checkpoint()
            guard position <= bytes.count, bytes.count - position >= 46,
                  u32(bytes, position) == 0x02014B50 else { throw ZIPListingError.corrupt }
            let flags = u16(bytes, position + 8)
            guard flags & 0x2000 == 0 else { throw ZIPListingError.encryptedDirectory }
            let nameCount = Int(u16(bytes, position + 28)), extraCount = Int(u16(bytes, position + 30))
            let commentCount = Int(u16(bytes, position + 32))
            let recordCount = 46 + nameCount + extraCount + commentCount
            guard recordCount <= bytes.count - position else { throw ZIPListingError.corrupt }
            guard nameCount <= limits.maximumNameBytes else { throw ZIPListingError.limitExceeded }
            let nameBytes = Data(bytes[(position + 46)..<(position + 46 + nameCount)])
            let encoding = flags & 0x800 != 0 ? String.Encoding.utf8
                : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
            guard let rawName = String(data: nameBytes, encoding: encoding) else { throw ZIPListingError.invalidEncoding }
            let normalized = rawName.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.hasPrefix("/"), !normalized.contains("\0") else { throw ZIPListingError.invalidPath }
            let hasDirectorySuffix = normalized.hasSuffix("/")
            let path = hasDirectorySuffix ? String(normalized.dropLast()) : normalized
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty, components.allSatisfy(ArchiveLocation.validComponent),
                  !(components[0].count >= 2 && components[0].dropFirst().first == ":") else { throw ZIPListingError.invalidPath }
            guard components.count <= limits.maximumDepth else { throw ZIPListingError.limitExceeded }
            var uncompressed = UInt64(u32(bytes, position + 24)), compressed = UInt64(u32(bytes, position + 20))
            var localOffset = UInt64(u32(bytes, position + 42)), disk = UInt32(u16(bytes, position + 34))
            let needsSize = uncompressed == UInt64(UInt32.max), needsCompressed = compressed == UInt64(UInt32.max)
            let needsOffset = localOffset == UInt64(UInt32.max), needsDisk = disk == UInt32(UInt16.max)
            var sawZIP64 = false, extraPosition = position + 46 + nameCount
            let extraEnd = extraPosition + extraCount
            while extraPosition < extraEnd {
                guard extraEnd - extraPosition >= 4 else { throw ZIPListingError.corrupt }
                let tag = u16(bytes, extraPosition), length = Int(u16(bytes, extraPosition + 2))
                extraPosition += 4
                guard length <= extraEnd - extraPosition else { throw ZIPListingError.corrupt }
                if tag == 1 {
                    guard !sawZIP64 else { throw ZIPListingError.corrupt }; sawZIP64 = true
                    var field = extraPosition
                    func take64() throws -> UInt64 {
                        guard extraPosition + length - field >= 8 else { throw ZIPListingError.corrupt }
                        defer { field += 8 }; return u64(bytes, field)
                    }
                    if needsSize { uncompressed = try take64() }
                    if needsCompressed { compressed = try take64() }
                    if needsOffset { localOffset = try take64() }
                    if needsDisk {
                        guard extraPosition + length - field >= 4 else { throw ZIPListingError.corrupt }
                        disk = u32(bytes, field)
                    }
                }
                // Unicode path 0x7075 and extra timestamp fields are explicitly
                // ignored in v1; their bounded envelope is still validated.
                extraPosition += length
            }
            guard !(needsSize || needsCompressed || needsOffset || needsDisk) || sawZIP64 else { throw ZIPListingError.corrupt }
            guard disk == 0 else { throw ZIPListingError.multipleDisks }
            guard localOffset < range.offset, compressed <= range.offset - localOffset else { throw ZIPListingError.corrupt }
            guard uncompressed <= UInt64(Int64.max) else { throw ZIPListingError.unsupportedMetadata }
            let attributes = u32(bytes, position + 38), mode = (attributes >> 16) & 0xF000
            let creator = u16(bytes, position + 4) >> 8
            let unix = creator == 3 || creator == 19
            let symbolicLink = unix && mode == 0xA000
            let directory = !symbolicLink && (hasDirectorySuffix || attributes & 0x10 != 0 || (unix && mode == 0x4000))
            let modified = dosDate(u16(bytes, position + 14), u16(bytes, position + 12))
            let permissions: UInt16? = unix && mode != 0 ? UInt16((attributes >> 16) & 0o777) : nil
            let kind: ZIPEntryKind = symbolicLink ? .symbolicLink : directory ? .directory
                : unix && mode != 0 && mode != 0x8000 ? .unsupported : .file
            records.append(ZIPCentralRecord(id: ordinal, components: components, pathKey: key(components),
                kind: kind, flags: flags, method: u16(bytes, position + 10), crc32: u32(bytes, position + 16),
                compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: localOffset,
                versionMadeBy: u16(bytes, position + 4), versionNeeded: u16(bytes, position + 6),
                dosDate: u16(bytes, position + 14), dosTime: u16(bytes, position + 12),
                internalAttributes: u16(bytes, position + 36), externalAttributes: attributes,
                modifiedAt: modified, unixPermissions: permissions, centralBytes: centralData,
                centralRange: position..<(position + recordCount), nameRange: (position + 46)..<(position + 46 + nameCount),
                extraRange: (position + 46 + nameCount)..<extraEnd,
                commentRange: extraEnd..<(position + recordCount)))
            for depth in 1...components.count {
                let prefix = Array(components.prefix(depth)), pathKey = key(prefix), leaf = depth == components.count
                if var existing = nodes[pathKey] {
                    if !leaf {
                        guard existing.directory else { throw ZIPListingError.duplicatePath }
                    } else {
                        guard existing.directory && directory else { throw ZIPListingError.duplicatePath }
                        if !existing.explicit { existing.explicit = true; existing.modified = modified; existing.unixPermissions = permissions }
                        existing.recordIDs.append(ordinal); nodes[pathKey] = existing
                    }
                } else {
                    guard nodes.count < limits.maximumNodes,
                          pathKey.count <= limits.maximumPathBytes - totalPathBytes else { throw ZIPListingError.limitExceeded }
                    totalPathBytes += pathKey.count
                    nodes[pathKey] = Node(components: prefix, directory: leaf ? directory : true,
                                          symbolicLink: leaf && symbolicLink, size: leaf && !directory && !symbolicLink ? Int64(uncompressed) : nil,
                                          modified: leaf ? modified : nil, explicit: leaf,
                                          recordIDs: leaf ? [ordinal] : [], unixPermissions: leaf ? permissions : nil)
                }
            }
            position += recordCount
        }
        guard position == bytes.count else { throw ZIPListingError.corrupt }
        guard let envelope else { throw ZIPListingError.corrupt }
        let directories = nodes.values.filter(\.directory).map {
            ZIPDirectoryEntry(components: $0.components, pathKey: key($0.components), isExplicit: $0.explicit,
                recordIDs: $0.recordIDs, modifiedAt: $0.modified, unixPermissions: $0.unixPermissions)
        }
        return ZIPArchiveManifest(revision: reader.revision, records: records, directories: directories,
            envelope: envelope, archiveComment: envelope.rawEndRecord.subdata(in: 22..<envelope.rawEndRecord.count))
    }

    private func dosDate(_ date: UInt16, _ time: UInt16) -> Date? {
        let year = Int(date >> 9) + 1980, month = Int((date >> 5) & 15), day = Int(date & 31)
        let hour = Int(time >> 11), minute = Int((time >> 5) & 63), second = Int(time & 31) * 2
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let result = calendar.date(from: parts) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        return result
    }
}

// Callers validate the containing record/range before reading these little-endian
// scalar fields. Byte assembly avoids alignment assumptions and pointer rebinding.
private func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
private func u32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24 }
private func u64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(u32(b, p)) | UInt64(u32(b, p + 4)) << 32 }
