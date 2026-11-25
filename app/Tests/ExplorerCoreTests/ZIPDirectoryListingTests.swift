import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// Synthetic central-directory fixtures intentionally contain uninterpreted
/// member bytes. No test extractor or external application is invoked.
@Suite struct ZIPDirectoryListingTests {
    @Test func listsNestedImplicitEmptyAndAttributeDirectoriesWithoutLocalAuthority() async throws {
        let fixture = try ZIPTestFixture(entries: [
            ZIPTestEntry("inside/nested/note.txt", size: 25), ZIPTestEntry("root.txt", size: 7),
            ZIPTestEntry("empty/"), ZIPTestEntry("attr-dir", attributes: 0x10),
            ZIPTestEntry("link", attributes: 0xA1FF << 16), ZIPTestEntry("nested.zip"),
            ZIPTestEntry(".hidden"), ZIPTestEntry("__MACOSX/meta")])
        let loader = LocalZIPDirectoryLoader()
        let root = try await loader.snapshot(of: fixture.location().url, showHidden: false)
        #expect(Set(root.items.map(\.name)) == ["inside", "root.txt", "empty", "attr-dir", "link", "nested.zip", "__MACOSX"])
        #expect(root.directoryIdentity == nil)
        #expect(root.archiveRevision != nil)
        #expect(root.items.allSatisfy { $0.identity == nil && !$0.url.isFileURL && $0.archiveRevision == root.archiveRevision })
        #expect(root.items.first { $0.name == "attr-dir" }?.isDirectory == true)
        #expect(root.items.first { $0.name == "link" }?.isSymbolicLink == true)
        #expect(root.items.first { $0.name == "link" }?.isDirectory == false)
        #expect(root.items.first { $0.name == "nested.zip" }?.isDirectory == false)
        let deep = try await loader.snapshot(of: fixture.location(["inside", "nested"]).url, showHidden: true)
        #expect(deep.items.map(\.name) == ["note.txt"])
        #expect(deep.items.first?.size == 25)
        let modified = try #require(deep.items.first?.modifiedAt)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        #expect(calendar.component(.year, from: modified) == 2026)
        #expect(calendar.component(.month, from: modified) == 1)
        #expect(calendar.component(.day, from: modified) == 2)
        #expect(try await loader.contents(of: fixture.location(["empty"]).url, showHidden: true).isEmpty)
        #expect(try await loader.contents(of: fixture.location().url, showHidden: true).contains { $0.name == ".hidden" })
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func metadataAcceptsEncryptionCompressionMethodsBackslashAndExactUnicodeNames() async throws {
        var cp437 = ZIPTestEntry("cafe.txt"); cp437.name = Array("caf".utf8) + [0x82] + Array(".txt".utf8); cp437.flags = 0
        let fixture = try ZIPTestFixture(entries: [cp437, ZIPTestEntry("locked", flags: 1),
            ZIPTestEntry("future", method: 255), ZIPTestEntry("a\\b\\note"),
            ZIPTestEntry("café"), ZIPTestEntry("cafe\u{301}"), ZIPTestEntry("Case"), ZIPTestEntry("case")])
        let snapshot = try await LocalZIPDirectoryLoader().snapshot(of: fixture.location().url, showHidden: true)
        #expect(snapshot.items.count == 8)
        #expect(snapshot.items.contains { $0.name == "café.txt" })
        #expect(Set(snapshot.items.map(\.id)).count == 8)
        let nested = try await LocalZIPDirectoryLoader().contents(of: fixture.location(["a", "b"]).url, showHidden: true)
        #expect(nested.map(\.name) == ["note"])
    }

    @Test func malformedNamesDuplicatesAndConflictsFailDeterministically() async throws {
        for name in ["/absolute", "\\absolute", "C:/drive", "a/../escape", "a/./dot", "a//empty", "a\0nul"] {
            let fixture = try ZIPTestFixture(entries: [ZIPTestEntry(name)])
            await expectFailure(fixture, .invalidPath)
        }
        for entries in [[ZIPTestEntry("same"), ZIPTestEntry("same")],
                        [ZIPTestEntry("a"), ZIPTestEntry("a/child")],
                        [ZIPTestEntry("a/child"), ZIPTestEntry("a")]] {
            let fixture = try ZIPTestFixture(entries: entries)
            await expectFailure(fixture, .duplicatePath)
        }
        let directories = try ZIPTestFixture(entries: [ZIPTestEntry("empty/"), ZIPTestEntry("empty/")])
        #expect(try await LocalZIPDirectoryLoader().contents(of: directories.location().url, showHidden: true).count == 1)
        var invalid = ZIPTestEntry("bad"); invalid.name = [0xFF]
        await expectFailure(try ZIPTestFixture(entries: [invalid]), .invalidEncoding)
    }

    @Test func encryptedCentralDirectoryAndMultipleDisksAreRefused() async throws {
        await expectFailure(try ZIPTestFixture(entries: [ZIPTestEntry("masked", flags: 0x2000)]), .encryptedDirectory)
        let fixture = try ZIPTestFixture(entries: [ZIPTestEntry("one")], disk: 1)
        await expectFailure(fixture, .multipleDisks)
    }

    @Test func recordCountLengthsOffsetsAndTruncationAreValidated() async throws {
        let good = ZIPTestArchive(entries: [ZIPTestEntry("one")])
        var variants: [Data] = []
        var count = good.bytes; count.zipWrite16(2, at: count.count - 22 + 8); count.zipWrite16(2, at: count.count - 22 + 10); variants.append(count)
        var name = good.bytes; name.zipWrite16(65_535, at: good.directoryOffset + 28); variants.append(name)
        var extra = good.bytes; extra.zipWrite16(65_535, at: good.directoryOffset + 30); variants.append(extra)
        var offset = good.bytes; offset.zipWrite32(UInt32.max - 1, at: offset.count - 22 + 16); variants.append(offset)
        var comment = good.bytes; comment.zipWrite16(1, at: comment.count - 2); variants.append(comment)
        variants.append(Data(good.bytes.dropLast()))
        for bytes in variants { await expectFailure(try ZIPTestFixture(bytes: bytes), .corrupt) }
    }

    @Test func zip64UsesSaturatedFieldsAndBoundedMetadataRecords() async throws {
        let fixture = try ZIPTestFixture(entries: [ZIPTestEntry("large", size: 5_000_000_000)], zip64: true)
        let snapshot = try await LocalZIPDirectoryLoader().snapshot(of: fixture.location().url, showHidden: true)
        #expect(snapshot.items.first?.size == 5_000_000_000)
        var broken = fixture.bytes
        broken.zipWrite64(UInt64.max, at: broken.count - 22 - 20 + 8)
        await expectFailure(try ZIPTestFixture(bytes: broken), .corrupt)
        await expectFailure(try ZIPTestFixture(entries: [ZIPTestEntry("too-large", size: UInt64(Int64.max) + 1)], zip64: true), .unsupportedMetadata)
    }

    @Test func limitsApplyToRecordsSynthesizedNodesNameDepthAndDirectoryBytes() async throws {
        let fixture = try ZIPTestFixture(entries: [ZIPTestEntry("a/b/c"), ZIPTestEntry("two")])
        for limits in [ZIPListingLimits(maximumEntries: 1), ZIPListingLimits(maximumNodes: 2),
                       ZIPListingLimits(maximumNameBytes: 2), ZIPListingLimits(maximumDepth: 2),
                       ZIPListingLimits(maximumDirectoryBytes: 30), ZIPListingLimits(maximumPathBytes: 2)] {
            await expectFailure(fixture, .limitExceeded, loader: LocalZIPDirectoryLoader(limits: limits))
        }
    }

    @Test func selectionSurvivesSameRevisionAndClearsAfterPhysicalReplacement() async throws {
        let fixture = try ZIPTestFixture(entries: [ZIPTestEntry("one")])
        let loader = LocalZIPDirectoryLoader(), location = try fixture.location().url
        let first = try await loader.snapshot(of: location, showHidden: true)
        var selection = SelectionState(); selection.selectAll(first.items.map(\.id))
        let again = try await loader.snapshot(of: location, showHidden: true)
        selection.reconcile(previous: first, current: again)
        #expect(selection.selectedIDs.count == 1)
        let oldRevision = try #require(first.archiveRevision)
        #expect(await oldRevision.isCurrent(at: fixture.url))
        let other = fixture.root.appendingPathComponent("replacement")
        try fixture.bytes.write(to: other)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.moveItem(at: other, to: fixture.url)
        let replacement = try await loader.snapshot(of: location, showHidden: true)
        #expect(replacement.items.first?.id == first.items.first?.id)
        #expect(replacement.archiveRevision != first.archiveRevision)
        #expect(await oldRevision.isCurrent(at: fixture.url) == false)
        selection.reconcile(previous: first, current: replacement)
        #expect(selection.selectedIDs.isEmpty && selection.focusedID == nil && selection.anchorID == nil)
    }

    @Test func instrumentedReaderProvesTailExceptionAndIndexOnlySubsequentReads() async throws {
        let archive = ZIPTestArchive(entries: [ZIPTestEntry("one")], prefixBytes: 90_000, commentBytes: 200)
        let reader = ZIPTestReader(bytes: archive.bytes)
        let loader = LocalZIPDirectoryLoader(readerFactory: { _ in reader })
        let url = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/unused.zip")).url
        _ = try await loader.snapshot(of: url, showHidden: true)
        let reads = reader.reads
        try #require(reads.count == 2)
        #expect(reads[0].0 == UInt64(archive.bytes.count - min(65_557, archive.bytes.count)))
        #expect(reads[0].1 == 65_557)
        #expect(reads[1].0 == UInt64(archive.directoryOffset))
        #expect(reads[1].1 == archive.directorySize)
        #expect(reads.reduce(0, { $0 + $1.1 }) == 65_557 + archive.directorySize)
        #expect(reader.validationCount == 1)
    }

    @Test func zip64ReadsOnlyExactTailLocatorFixedRecordAndDirectoryRanges() async throws {
        let archive = ZIPTestArchive(entries: [ZIPTestEntry("large", size: 5_000_000_000)],
                                     zip64: true, prefixBytes: 90_000, commentBytes: 200)
        // Independently hand-counted: 90,000 prefix + 63 CD + 56 ZIP64 record
        // + 20 locator + 22 EOCD + 200 comment = 90,361 bytes.
        #expect(archive.bytes.count == 90_361)
        let expected: [(UInt64, Int)] = [(24_804, 65_557), (90_119, 20), (90_063, 56), (90_000, 63)]
        let url = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/unused.zip")).url
        let reader = ZIPTestReader(bytes: archive.bytes)
        _ = try await LocalZIPDirectoryLoader(readerFactory: { _ in reader }).snapshot(of: url, showHidden: true)
        #expect(reader.reads.count == 4)
        for (actual, wanted) in zip(reader.reads, expected) {
            #expect(actual.0 == wanted.0 && actual.1 == wanted.1)
        }
        #expect(reader.reads.reduce(0, { $0 + $1.1 }) == 65_696)

        var badOffset = archive.bytes; badOffset.zipWrite64(1, at: 90_119 + 8)
        var hugeOffset = archive.bytes; hugeOffset.zipWrite64(UInt64.max, at: 90_119 + 8)
        var extendedRecord = archive.bytes; extendedRecord.zipWrite64(45, at: 90_063 + 4)
        var badLocator = archive.bytes; badLocator.zipWrite32(0, at: 90_119)
        var badDirectory = archive.bytes; badDirectory.zipWrite64(UInt64.max, at: 90_063 + 48)
        for (bytes, allowedReads) in [(badOffset, 2), (hugeOffset, 2), (extendedRecord, 3), (badLocator, 2), (badDirectory, 3)] {
            let badReader = ZIPTestReader(bytes: bytes)
            do {
                _ = try await LocalZIPDirectoryLoader(readerFactory: { _ in badReader }).snapshot(of: url, showHidden: true)
                Issue.record("Malformed ZIP64 metadata was accepted")
            } catch is ZIPListingError {}
            #expect(badReader.reads.count == allowedReads)
            for (actual, wanted) in zip(badReader.reads, expected.prefix(allowedReads)) {
                #expect(actual.0 == wanted.0 && actual.1 == wanted.1)
            }
            #expect(badReader.validationCount == 0)
        }
    }

    @Test func cancellationWhileDirectoryReadIsPendingNeverPublishesASnapshot() async throws {
        let archive = ZIPTestArchive(entries: [ZIPTestEntry("one")])
        let reader = ZIPBlockingTestReader(bytes: archive.bytes)
        let url = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/unused.zip")).url
        let loader = LocalZIPDirectoryLoader(readerFactory: { _ in reader })
        let task = Task { try await loader.snapshot(of: url, showHidden: true) }
        defer { task.cancel(); reader.release.signal() }
        for _ in 0..<1_000 {
            if reader.isBlocked { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reader.isBlocked, "The read worker must reach the directory read before cancellation")
        task.cancel()
        reader.release.signal()
        do { _ = try await task.value; Issue.record("Cancelled listing published a snapshot") }
        catch is CancellationError {}
    }

    @Test func cancellationAndChangedDescriptorDoNotPublishSnapshot() async throws {
        let archive = ZIPTestArchive(entries: [ZIPTestEntry("one")])
        let reader = ZIPTestReader(bytes: archive.bytes); reader.changed = true
        let loader = LocalZIPDirectoryLoader(readerFactory: { _ in reader })
        let url = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/unused.zip")).url
        do { _ = try await loader.snapshot(of: url, showHidden: true); Issue.record("Changed archive accepted") }
        catch ZIPListingError.changed {}
        let task = Task { try Task.checkCancellation(); return try await loader.snapshot(of: url, showHidden: true) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation accepted") } catch is CancellationError {}
    }

    @Test func nonRegularArchiveIsRefusedWithoutBlocking() async throws {
        let fixture = try ZIPTestFixture(entries: [])
        try FileManager.default.removeItem(at: fixture.url)
        #expect(mkfifo(fixture.url.path, 0o600) == 0)
        await expectFailure(fixture, .notRegularFile)
    }

    @Test func syntheticArchiveSymlinkToCharacterDeviceIsRefused() async throws {
        let fixture = try ZIPTestFixture(entries: [])
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createSymbolicLink(atPath: fixture.url.path, withDestinationPath: "/dev/null")
        await expectFailure(fixture, .notRegularFile)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path) == "/dev/null")
    }

    @Test func dosDatesPreserveValidLocalTimeAndOmitInvalidFields() async throws {
        let archive = ZIPTestArchive(entries: [ZIPTestEntry("dated")])
        // February 29, 2024 at 13:14:16, encoded independently of the parser.
        var leapDay = archive.bytes
        leapDay.zipWrite16(UInt16((44 << 9) | (2 << 5) | 29), at: archive.directoryOffset + 14)
        leapDay.zipWrite16(UInt16((13 << 11) | (14 << 5) | 8), at: archive.directoryOffset + 12)
        let fixture = try ZIPTestFixture(bytes: leapDay)
        let item = try #require(try await LocalZIPDirectoryLoader().contents(of: fixture.location().url, showHidden: true).first)
        let modified = try #require(item.modifiedAt)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        #expect(parts.year == 2024 && parts.month == 2 && parts.day == 29)
        #expect(parts.hour == 13 && parts.minute == 14 && parts.second == 16)
        // February 31, month zero, hour 31, minute 63 and second 62 are not dates.
        for (date, time) in [(UInt16((44 << 9) | (2 << 5) | 31), UInt16(0)),
                             (UInt16(0), UInt16(0)), (UInt16(0x5C22), UInt16(31 << 11)),
                             (UInt16(0x5C22), UInt16(63 << 5)), (UInt16(0x5C22), UInt16(31))] {
            var invalid = archive.bytes
            invalid.zipWrite16(date, at: archive.directoryOffset + 14)
            invalid.zipWrite16(time, at: archive.directoryOffset + 12)
            let badFixture = try ZIPTestFixture(bytes: invalid)
            let badItem = try #require(try await LocalZIPDirectoryLoader().contents(of: badFixture.location().url, showHidden: true).first)
            #expect(badItem.modifiedAt == nil)
        }
    }

    @Test func hundredThousandEntryListingRecordsNativeTiming() async throws {
        let entries = (0..<100_000).map { ZIPTestEntry("item-\($0).txt") }
        let fixture = try ZIPTestFixture(entries: entries, zip64: true)
        let start = ContinuousClock.now
        let snapshot = try await LocalZIPDirectoryLoader().snapshot(of: fixture.location().url, showHidden: true)
        let elapsed = start.duration(to: .now)
        print("ZIP100K entries=\(snapshot.items.count) archiveBytes=\(fixture.bytes.count) elapsed=\(elapsed)")
        #expect(snapshot.items.count == 100_000)
    }

    private func expectFailure(_ fixture: ZIPTestFixture, _ expected: ZIPListingError,
                               loader: LocalZIPDirectoryLoader = LocalZIPDirectoryLoader()) async {
        do { _ = try await loader.snapshot(of: fixture.location().url, showHidden: true); Issue.record("Invalid ZIP accepted: \(expected)") }
        catch let error as ZIPListingError { #expect(error == expected) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private struct ZIPTestEntry {
    var name: [UInt8]
    var size: UInt64
    var flags: UInt16
    var method: UInt16
    var attributes: UInt32
    init(_ name: String, size: UInt64 = 0, flags: UInt16 = 0x800, method: UInt16 = 0, attributes: UInt32 = 0) {
        self.name = Array(name.utf8); self.size = size; self.flags = flags; self.method = method; self.attributes = attributes
    }
}

private struct ZIPTestArchive {
    let bytes: Data
    let directoryOffset: Int
    let directorySize: Int
    init(entries: [ZIPTestEntry], zip64: Bool = false, disk: UInt16 = 0, prefixBytes: Int = 30, commentBytes: Int = 0) {
        var data = Data(repeating: 0xA5, count: prefixBytes)
        directoryOffset = data.count
        for entry in entries {
            var extra = Data()
            let large = entry.size > UInt64(UInt32.max)
            if large { extra.zip16(1); extra.zip16(8); extra.zip64(entry.size) }
            data.zip32(0x02014B50); data.zip16(0x0314); data.zip16(large ? 45 : 20)
            data.zip16(entry.flags); data.zip16(entry.method); data.zip16(0); data.zip16(0x5C22)
            data.zip32(0); data.zip32(0); data.zip32(large ? UInt32.max : UInt32(entry.size))
            data.zip16(UInt16(entry.name.count)); data.zip16(UInt16(extra.count)); data.zip16(0); data.zip16(0)
            data.zip16(0); data.zip32(entry.attributes); data.zip32(0); data.append(contentsOf: entry.name); data.append(extra)
        }
        directorySize = data.count - directoryOffset
        if zip64 {
            let recordOffset = data.count
            data.zip32(0x06064B50); data.zip64(44); data.zip16(45); data.zip16(45); data.zip32(0); data.zip32(0)
            data.zip64(UInt64(entries.count)); data.zip64(UInt64(entries.count)); data.zip64(UInt64(directorySize)); data.zip64(UInt64(directoryOffset))
            data.zip32(0x07064B50); data.zip32(0); data.zip64(UInt64(recordOffset)); data.zip32(1)
        }
        data.zip32(0x06054B50); data.zip16(disk); data.zip16(disk)
        data.zip16(zip64 ? UInt16.max : UInt16(entries.count)); data.zip16(zip64 ? UInt16.max : UInt16(entries.count))
        data.zip32(zip64 ? UInt32.max : UInt32(directorySize)); data.zip32(zip64 ? UInt32.max : UInt32(directoryOffset))
        data.zip16(UInt16(commentBytes)); data.append(Data(repeating: 0x78, count: commentBytes))
        bytes = data
    }
}

private final class ZIPTestFixture {
    let root: URL, url: URL, bytes: Data
    convenience init(entries: [ZIPTestEntry], zip64: Bool = false, disk: UInt16 = 0) throws {
        try self.init(bytes: ZIPTestArchive(entries: entries, zip64: zip64, disk: disk).bytes)
    }
    init(bytes: Data) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPTests-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("fixture.zip"); self.bytes = bytes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); try bytes.write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func location(_ components: [String] = []) throws -> ArchiveLocation { try ArchiveLocation(archiveURL: url, components: components) }
}

private final class ZIPTestReader: ZIPPositionalReading, @unchecked Sendable {
    let bytes: Data
    var length: UInt64 { UInt64(bytes.count) }
    let revision = ArchiveRevision(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7)
    private(set) var reads: [(UInt64, Int)] = []
    private(set) var validationCount = 0
    var changed = false
    init(bytes: Data) { self.bytes = bytes }
    func read(offset: UInt64, count: Int) throws -> Data {
        reads.append((offset, count)); guard offset <= length, UInt64(count) <= length - offset else { throw ZIPListingError.corrupt }
        return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
    }
    func validateUnchanged() throws { validationCount += 1; if changed { throw ZIPListingError.changed } }
}

/// Pauses only the second injected I/O operation, after EOCD parsing. It
/// exercises cancellation of running read work without extracting any data.
private final class ZIPBlockingTestReader: ZIPPositionalReading, @unchecked Sendable {
    let bytes: Data
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readCount = 0
    private var blocked = false
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    var length: UInt64 { UInt64(bytes.count) }
    let revision = ArchiveRevision(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7)
    init(bytes: Data) { self.bytes = bytes }
    func read(offset: UInt64, count: Int) throws -> Data {
        lock.lock(); readCount += 1; let shouldBlock = readCount == 2
        if shouldBlock { blocked = true }; lock.unlock()
        if shouldBlock { release.wait() }
        guard offset <= length, UInt64(count) <= length - offset else { throw ZIPListingError.corrupt }
        return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
    }
    func validateUnchanged() throws {}
}

private extension Data {
    mutating func zip16(_ n: UInt16) { append(UInt8(n & 255)); append(UInt8(n >> 8)) }
    mutating func zip32(_ n: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((n >> shift) & 255)) } }
    mutating func zip64(_ n: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8((n >> shift) & 255)) } }
    mutating func zipWrite16(_ n: UInt16, at offset: Int) { self[offset] = UInt8(n & 255); self[offset + 1] = UInt8(n >> 8) }
    mutating func zipWrite32(_ n: UInt32, at offset: Int) { for i in 0..<4 { self[offset + i] = UInt8((n >> (8 * i)) & 255) } }
    mutating func zipWrite64(_ n: UInt64, at offset: Int) { for i in 0..<8 { self[offset + i] = UInt8((n >> (8 * i)) & 255) } }
}
