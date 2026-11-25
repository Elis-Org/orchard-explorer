import Foundation
import zlib

struct ZIPCRC32 {
    private(set) var value: UInt32 = UInt32(zlib.crc32(0, nil, 0))
    mutating func update(_ data: Data) throws {
        guard data.count <= Int(UInt32.max) else { throw ZIPListingError.limitExceeded }
        value = data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(uLong(value), buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
    static func checksum(_ data: Data) throws -> UInt32 {
        var checksum = ZIPCRC32(); try checksum.update(data); return checksum.value
    }
}

/// Bounded scalar access is used only after its enclosing header has been checked.
enum ZIPBytes {
    static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(u16(b, p)) | UInt32(u16(b, p + 2)) << 16 }
    static func u64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(u32(b, p)) | UInt64(u32(b, p + 4)) << 32 }
    static func put16(_ v: UInt16, into b: inout [UInt8], at p: Int) {
        b[p] = UInt8(truncatingIfNeeded: v); b[p + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    static func put32(_ v: UInt32, into b: inout [UInt8], at p: Int) {
        put16(UInt16(truncatingIfNeeded: v), into: &b, at: p)
        put16(UInt16(truncatingIfNeeded: v >> 16), into: &b, at: p + 2)
    }
    static func put64(_ v: UInt64, into b: inout [UInt8], at p: Int) {
        put32(UInt32(truncatingIfNeeded: v), into: &b, at: p)
        put32(UInt32(truncatingIfNeeded: v >> 32), into: &b, at: p + 4)
    }
}

struct ZIPExtraField {
    let tag: UInt16
    let range: Range<Int>
    let dataRange: Range<Int>
}

enum ZIPExtraFields {
    enum Timestamp { case absent, invalid, valid(Date) }
    static func parse(_ data: Data) throws -> [ZIPExtraField] {
        let bytes = Array(data); var position = 0, result: [ZIPExtraField] = []
        while position < bytes.count {
            guard bytes.count - position >= 4 else { throw ZIPListingError.corrupt }
            let length = Int(ZIPBytes.u16(bytes, position + 2)), start = position
            guard length <= bytes.count - position - 4 else { throw ZIPListingError.corrupt }
            position += 4 + length
            result.append(ZIPExtraField(tag: ZIPBytes.u16(bytes, start), range: start..<position,
                                        dataRange: (start + 4)..<position))
        }
        return result
    }

    static func modificationDate(_ data: Data, central: Bool) -> Timestamp {
        guard let fields = try? parse(data) else { return .invalid }
        let timestamps = fields.filter { $0.tag == 0x5455 }
        if timestamps.isEmpty { return .absent }
        guard timestamps.count == 1, let field = timestamps.first else { return .invalid }
        let value = Array(data[field.dataRange])
        guard value.count >= 5, value[0] & 1 != 0, value[0] & 0xf8 == 0 else { return .invalid }
        // Central UT carries only mtime, even when flags also describe the local
        // atime/ctime fields (the normal Info-ZIP producer form).
        let count = central ? 5 : 1 + 4 * value[0].nonzeroBitCount
        guard value.count == count else { return .invalid }
        return .valid(Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: ZIPBytes.u32(value, 1)))))
    }
    static func modificationDate(central: Data, local: Data, fallback: Date?) -> Date? {
        switch (modificationDate(central, central: true), modificationDate(local, central: false)) {
        case (.invalid, _), (_, .invalid): return fallback
        case (.valid(let a), .valid(let b)): return a == b ? a : fallback
        case (.valid(let date), .absent), (.absent, .valid(let date)): return date
        case (.absent, .absent): return fallback
        }
    }
}

enum ZIPRecordValidation {
    static func validate(manifest: ZIPArchiveManifest, reader: any ZIPPositionalReading,
                         scope: ZIPValidationScope,
                         checkpoint: () throws -> Void = {}) throws -> ZIPValidatedLayout {
        guard reader.revision == manifest.revision else { throw ZIPListingError.changed }
        let selected: Set<Int>, mutation: Bool
        switch scope {
        case .content(let ids): selected = ids; mutation = false
        case .mutation: selected = Set(manifest.records.map(\.id)); mutation = true
        }
        guard selected.isSubset(of: Set(manifest.records.map(\.id))) else { throw ZIPListingError.corrupt }
        let boundary = manifest.envelope.directoryRange.offset
        var headerBytes = 0
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try checkpoint()
            guard count >= 0, count <= 64 * 1_024 * 1_024 - headerBytes,
                  offset <= boundary, UInt64(count) <= boundary - offset else { throw ZIPListingError.corrupt }
            headerBytes += count
            let value = try reader.read(offset: offset, count: count)
            guard value.count == count else { throw ZIPListingError.corrupt }
            return value
        }
        let ordered = manifest.records.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        if mutation, ordered.map(\.id) != manifest.records.map(\.id) { throw ZIPListingError.unsupportedMetadata }
        var previousEnd: UInt64 = 0, result: [Int: ZIPRecordLayout] = [:]
        for record in ordered {
            try checkpoint()
            let offset = record.localHeaderOffset
            guard offset >= previousEnd else { throw ZIPListingError.corrupt }
            if mutation, offset != previousEnd { throw ZIPListingError.unsupportedMetadata }
            let fixed = Array(try read(offset, 30))
            guard ZIPBytes.u32(fixed, 0) == 0x04034b50 else { throw ZIPListingError.corrupt }
            let flags = ZIPBytes.u16(fixed, 6), method = ZIPBytes.u16(fixed, 8)
            let nameLength = UInt64(ZIPBytes.u16(fixed, 26)), extraLength = UInt64(ZIPBytes.u16(fixed, 28))
            let headerLength = 30 + nameLength + extraLength
            guard headerLength <= boundary - offset else { throw ZIPListingError.corrupt }
            let dataOffset = offset + headerLength
            guard record.compressedSize <= boundary - dataOffset else { throw ZIPListingError.corrupt }
            let dataEnd = dataOffset + record.compressedSize
            var descriptor: ZIPByteRange?
            if record.flags & 8 != 0 {
                let first = Array(try read(dataEnd, 16))
                guard ZIPBytes.u32(first, 0) == 0x08074b50,
                      ZIPBytes.u32(first, 4) == record.crc32 else { throw ZIPListingError.unsupportedMetadata }
                let zip64Sizes = ZIPBytes.u32(fixed, 18) == UInt32.max || ZIPBytes.u32(fixed, 22) == UInt32.max
                    || record.compressedSize >= UInt64(UInt32.max) || record.uncompressedSize >= UInt64(UInt32.max)
                if !zip64Sizes, UInt64(ZIPBytes.u32(first, 8)) == record.compressedSize,
                   UInt64(ZIPBytes.u32(first, 12)) == record.uncompressedSize {
                    descriptor = ZIPByteRange(offset: dataEnd, length: 16)
                } else {
                    guard record.versionNeeded >= 45 else { throw ZIPListingError.corrupt }
                    let tail = Array(try read(dataEnd + 16, 8)), all = first + tail
                    guard ZIPBytes.u64(all, 8) == record.compressedSize,
                          ZIPBytes.u64(all, 16) == record.uncompressedSize else { throw ZIPListingError.corrupt }
                    descriptor = ZIPByteRange(offset: dataEnd, length: 24)
                }
            }
            let end = dataEnd + (descriptor?.length ?? 0)
            guard end <= boundary else { throw ZIPListingError.corrupt }
            previousEnd = end
            guard selected.contains(record.id) else { continue }
            guard flags == record.flags, method == record.method,
                  ZIPBytes.u16(fixed, 4) == record.versionNeeded else { throw ZIPListingError.corrupt }
            guard flags & (1 | 0x40 | 0x2000) == 0,
                  method == 0 || method == 8,
                  record.kind == .file || record.kind == .directory else {
                throw ArchiveOperationError.unsupported("This archive member uses encryption, compression or an entry type that cannot be processed.")
            }
            let name = try read(offset + 30, Int(nameLength))
            guard name == record.nameBytes else { throw ZIPListingError.corrupt }
            let extra = try read(offset + 30 + nameLength, Int(extraLength))
            let fields = try ZIPExtraFields.parse(extra)
            var localCompressed = UInt64(ZIPBytes.u32(fixed, 18)), localSize = UInt64(ZIPBytes.u32(fixed, 22))
            if localCompressed == UInt64(UInt32.max) || localSize == UInt64(UInt32.max) {
                let zip64 = fields.filter { $0.tag == 1 }
                guard zip64.count == 1, let field = zip64.first else { throw ZIPListingError.corrupt }
                let values = Array(extra[field.dataRange]); var cursor = 0
                if localSize == UInt64(UInt32.max) {
                    guard values.count >= cursor + 8 else { throw ZIPListingError.corrupt }
                    localSize = ZIPBytes.u64(values, cursor); cursor += 8
                }
                if localCompressed == UInt64(UInt32.max) {
                    guard values.count >= cursor + 8 else { throw ZIPListingError.corrupt }
                    localCompressed = ZIPBytes.u64(values, cursor)
                }
            }
            if flags & 8 == 0 {
                guard ZIPBytes.u32(fixed, 14) == record.crc32,
                      localCompressed == record.compressedSize, localSize == record.uncompressedSize else { throw ZIPListingError.corrupt }
            }
            if method == 0, record.compressedSize != record.uncompressedSize { throw ZIPListingError.corrupt }
            if record.kind == .directory, record.uncompressedSize != 0 || record.crc32 != 0 { throw ZIPListingError.corrupt }
            let modified = ZIPExtraFields.modificationDate(central: record.extraBytes, local: extra, fallback: record.modifiedAt)
            result[record.id] = ZIPRecordLayout(recordID: record.id,
                localHeaderRange: ZIPByteRange(offset: offset, length: headerLength),
                nameRange: ZIPByteRange(offset: offset + 30, length: nameLength),
                extraRange: ZIPByteRange(offset: offset + 30 + nameLength, length: extraLength),
                payloadRange: ZIPByteRange(offset: dataOffset, length: record.compressedSize),
                descriptorRange: descriptor, completeRange: ZIPByteRange(offset: offset, length: end - offset),
                modifiedAt: modified, unixPermissions: record.unixPermissions)
        }
        if mutation, previousEnd != boundary { throw ZIPListingError.unsupportedMetadata }
        try reader.validateUnchanged()
        return ZIPValidatedLayout(records: result)
    }
}
