import Foundation
@testable import ExplorerCore

/// Valid local headers and payloads, unlike the listing-only synthetic fixtures.
/// The reference CRC implementation is intentionally independent of system libz.
struct ZIPOperationTestEntry {
    var name: Data
    var contents: Data
    var compressedContents: Data
    var flags: UInt16
    var method: UInt16
    var attributes: UInt32
    var extra: Data
    var comment: Data

    init(_ name: String, contents: Data = Data(), compressed: Data? = nil,
         flags: UInt16 = 0x800, method: UInt16 = 0,
         attributes: UInt32 = UInt32(0o100644) << 16,
         extra: Data = Data(), comment: Data = Data()) {
        self.name = Data(name.utf8); self.contents = contents
        self.compressedContents = compressed ?? contents
        self.flags = flags; self.method = method; self.attributes = attributes
        self.extra = extra; self.comment = comment
    }
}

struct ZIPOperationTestArchive {
    let bytes: Data
    let directoryOffset: Int
    let localOffsets: [Int]

    init(entries: [ZIPOperationTestEntry], comment: Data = Data(), zip64: Bool = false) {
        var local = Data(), central = Data(), offsets: [Int] = []
        for entry in entries {
            let offset = local.count; offsets.append(offset)
            let crc = zipOperationReferenceCRC(entry.contents)
            let date: UInt16 = UInt16(2026 - 1980) << 9 | 1 << 5 | 2
            local.op32(0x04034b50); local.op16(20); local.op16(entry.flags); local.op16(entry.method)
            local.op16(0); local.op16(date); local.op32(crc)
            local.op32(UInt32(entry.compressedContents.count)); local.op32(UInt32(entry.contents.count))
            local.op16(UInt16(entry.name.count)); local.op16(UInt16(entry.extra.count))
            local.append(entry.name); local.append(entry.extra); local.append(entry.compressedContents)

            central.op32(0x02014b50); central.op16(0x0314); central.op16(20)
            central.op16(entry.flags); central.op16(entry.method); central.op16(0); central.op16(date)
            central.op32(crc); central.op32(UInt32(entry.compressedContents.count)); central.op32(UInt32(entry.contents.count))
            central.op16(UInt16(entry.name.count)); central.op16(UInt16(entry.extra.count)); central.op16(UInt16(entry.comment.count))
            central.op16(0); central.op16(0); central.op32(entry.attributes); central.op32(UInt32(offset))
            central.append(entry.name); central.append(entry.extra); central.append(entry.comment)
        }
        directoryOffset = local.count; localOffsets = offsets
        var result = local; result.append(central)
        if zip64 {
            let recordOffset = result.count
            result.op32(0x06064b50); result.op64(44); result.op16(45); result.op16(45)
            result.op32(0); result.op32(0); result.op64(UInt64(entries.count)); result.op64(UInt64(entries.count))
            result.op64(UInt64(central.count)); result.op64(UInt64(local.count))
            result.op32(0x07064b50); result.op32(0); result.op64(UInt64(recordOffset)); result.op32(1)
        }
        result.op32(0x06054b50); result.op16(0); result.op16(0)
        result.op16(UInt16(clamping: entries.count)); result.op16(UInt16(clamping: entries.count))
        result.op32(UInt32(central.count)); result.op32(UInt32(local.count)); result.op16(UInt16(comment.count))
        result.append(comment); bytes = result
    }
}

final class ZIPOperationTestFixture {
    let root: URL
    let url: URL
    let bytes: Data

    init(entries: [ZIPOperationTestEntry], comment: Data = Data(), zip64: Bool = false) throws {
        bytes = ZIPOperationTestArchive(entries: entries, comment: comment, zip64: zip64).bytes
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-zip-operations-" + UUID().uuidString, isDirectory: true)
        root = directory; url = directory.appendingPathComponent("fixture.zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try bytes.write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func location(_ components: [String] = []) throws -> ArchiveLocation {
        try ArchiveLocation(archiveURL: url, components: components)
    }
    func context(_ components: [String] = []) async throws -> ArchiveOperationContext {
        let location = try location(components)
        let snapshot = try await LocalZIPDirectoryLoader().snapshot(of: location.url, showHidden: true)
        guard let revision = snapshot.archiveRevision else { throw ZIPListingError.changed }
        return ArchiveOperationContext(location: location, revision: revision)
    }
}

func zipOperationReferenceCRC(_ data: Data) -> UInt32 {
    var value = UInt32.max
    for byte in data {
        value ^= UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
    }
    return value ^ UInt32.max
}

private extension Data {
    mutating func op16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func op32(_ value: UInt32) {
        op16(UInt16(truncatingIfNeeded: value)); op16(UInt16(truncatingIfNeeded: value >> 16))
    }
    mutating func op64(_ value: UInt64) {
        op32(UInt32(truncatingIfNeeded: value)); op32(UInt32(truncatingIfNeeded: value >> 32))
    }
}
