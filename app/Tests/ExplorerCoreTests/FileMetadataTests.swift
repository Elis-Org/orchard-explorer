import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class MetadataFixture {
    let root: URL
    private var directories: [URL] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerMetadata-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit {
        // Only explicitly created fixture directories can have been restricted.
        for directory in directories {
            _ = directory.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) }
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned metadata fixture cleanup failed: \(root.path): \(error)") }
    }
    func file(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }
    func item(_ name: String, at parent: URL? = nil) async throws -> FileItem {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: parent ?? root)
        return try #require(snapshot.items.first { $0.name == name })
    }
}

private func nativeMetadataStat(_ url: URL) throws -> stat {
    var value = stat()
    guard url.withUnsafeFileSystemRepresentation({ Darwin.lstat($0!, &value) }) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return value
}

private func nativeMetadataDate(_ value: timespec) -> Date {
    Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
}

/// FR-PREVIEW-002 / EV-0277–0279 / AT-PREVIEW-002 metadata subset, with the
/// 4 MiB data-size subset of FR-PREVIEW-003. Allocation is native st_blocks*512,
/// not a reproduction of the Windows fixture's observed zero allocation.
struct FileMetadataTests {
    @Test
    func testRegular24ByteFourMiBAndZeroFilesUseActualNativeAllocation() async throws {
        let fixture = try MetadataFixture()
        let cases = [("move-me.txt", Data("Move operation sample.\r\n".utf8)),
                     ("sample-4MiB.bin", Data(repeating: 0x5a, count: 4 * 1024 * 1024)),
                     ("empty.txt", Data())]
        #expect(cases[0].1.count == 24)
        for (name, bytes) in cases {
            let url = try fixture.file(name, bytes: bytes)
            let item = try await fixture.item(name)
            let independent = try nativeMetadataStat(url)
            let before = Date()
            let result = try await LocalFileMetadataReader().metadata(for: item)
            let after = Date()
            #expect(result.size == Int64(bytes.count))
            #expect(result.allocatedSize == Int64(independent.st_blocks) * 512)
            #expect(result.createdAt == nativeMetadataDate(independent.st_birthtimespec))
            #expect(result.modifiedAt == nativeMetadataDate(independent.st_mtimespec))
            #expect(result.accessedAt == nativeMetadataDate(independent.st_atimespec))
            #expect(result.capturedAt >= before && result.capturedAt <= after)
        }
    }

    @Test
    func testDatesComeFromCurrentStatAndReadingDoesNotChangeTimestamps() async throws {
        let fixture = try MetadataFixture()
        let url = try fixture.file("dates.txt", bytes: Data("owned timestamps".utf8))
        var times = [timespec(tv_sec: 1_700_000_001, tv_nsec: 123_456_789),
                     timespec(tv_sec: 1_700_000_002, tv_nsec: 987_654_321)]
        try #require(url.withUnsafeFileSystemRepresentation { utimensat(AT_FDCWD, $0!, &times, 0) } == 0)
        // Setting an earlier mtime can also move native birth time. Capture the
        // selected identity after fixture setup, as a fresh directory row does.
        let item = try await fixture.item("dates.txt")
        let before = try nativeMetadataStat(url)
        #expect(item.identity == LocalFileIdentity.fromStat(before))
        let result = try await LocalFileMetadataReader().metadata(for: item)
        let after = try nativeMetadataStat(url)
        #expect(result.accessedAt == nativeMetadataDate(before.st_atimespec))
        #expect(result.modifiedAt == nativeMetadataDate(before.st_mtimespec))
        #expect(result.createdAt == nativeMetadataDate(before.st_birthtimespec))
        #expect(before.st_atimespec.tv_sec == after.st_atimespec.tv_sec && before.st_atimespec.tv_nsec == after.st_atimespec.tv_nsec)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        #expect(before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
        #expect(before.st_size == after.st_size && before.st_blocks == after.st_blocks && before.st_flags == after.st_flags)
    }

    @Test
    func testFolderAndPackageSizesStayUnavailableWithoutEnumeratingContents() async throws {
        let fixture = try MetadataFixture()
        for name in ["Folder", "Fixture.app"] {
            let folder = try fixture.directory(name)
            try Data(repeating: 0x41, count: 1024 * 1024).write(to: folder.appendingPathComponent("nested.bin"))
            let item = try await fixture.item(name)
            try #require(folder.withUnsafeFileSystemRepresentation { chmod($0!, 0) } == 0)
            // lstat of this entry is allowed; enumeration/content access is not.
            let result = try await LocalFileMetadataReader().metadata(for: item)
            #expect(result.size == nil)
            #expect(result.allocatedSize == nil)
            #expect(result.modifiedAt != nil)
            try #require(folder.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) } == 0)
        }
    }

    @Test
    func testFileDirectoryAndDanglingSymlinksReportOnlyTheirOwnMetadata() async throws {
        let fixture = try MetadataFixture()
        let target = try fixture.file("target.bin", bytes: Data(repeating: 0x42, count: 1024 * 1024))
        let directory = try fixture.directory("TargetFolder")
        for (name, destination) in [("FileLink", target.path), ("DirectoryLink", directory.path), ("DanglingLink", "missing-target")] {
            let url = fixture.root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
            let item = try await fixture.item(name)
            let ownStat = try nativeMetadataStat(url)
            #expect(ownStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
            let targetBefore = try nativeMetadataStat(target)
            let result = try await LocalFileMetadataReader().metadata(for: item)
            #expect(result.size == nil && result.allocatedSize == nil)
            #expect(result.createdAt == nativeMetadataDate(ownStat.st_birthtimespec))
            #expect(result.modifiedAt == nativeMetadataDate(ownStat.st_mtimespec))
            #expect(result.accessedAt == nativeMetadataDate(ownStat.st_atimespec))
            let targetAfter = try nativeMetadataStat(target)
            #expect(targetBefore.st_atimespec.tv_sec == targetAfter.st_atimespec.tv_sec && targetBefore.st_atimespec.tv_nsec == targetAfter.st_atimespec.tv_nsec)
            #expect(targetBefore.st_mtimespec.tv_sec == targetAfter.st_mtimespec.tv_sec && targetBefore.st_mtimespec.tv_nsec == targetAfter.st_mtimespec.tv_nsec)
        }
    }

    @Test
    func testDirectoryHintCannotMakeMetadataFollowASymbolicLink() async throws {
        let fixture = try MetadataFixture()
        let folder = try fixture.directory("Target")
        let link = fixture.root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
        let entry = try await fixture.item("Link")
        let hinted = FileItem(url: URL(fileURLWithPath: link.path + "/", isDirectory: true), name: entry.name,
            isDirectory: true, isSymbolicLink: true, size: nil, modifiedAt: nil, kind: "Symbolic link", identity: entry.identity)
        let actual = try nativeMetadataStat(link)
        let result = try await LocalFileMetadataReader().metadata(for: hinted)
        #expect(result.createdAt == nativeMetadataDate(actual.st_birthtimespec))
        #expect(result.size == nil && result.allocatedSize == nil)
    }

    @Test
    func testCachedListingValuesAreNotUsedAsCurrentMetadata() async throws {
        let fixture = try MetadataFixture()
        let url = try fixture.file("fresh.txt", bytes: Data("current bytes".utf8))
        let original = try await fixture.item("fresh.txt")
        let staleDisplay = FileItem(url: original.url, name: original.name, isDirectory: false, isSymbolicLink: false,
            size: 999_999, modifiedAt: .distantPast, kind: "File", identity: original.identity)
        let actual = try nativeMetadataStat(url)
        let result = try await LocalFileMetadataReader().metadata(for: staleDisplay)
        #expect(result.size == Int64(actual.st_size))
        #expect(result.modifiedAt == nativeMetadataDate(actual.st_mtimespec))
    }

    @Test
    func testSamePathReplacementAndMissingEntryAreStaleSelections() async throws {
        let fixture = try MetadataFixture()
        let url = try fixture.file("selected.txt", bytes: Data("original".utf8))
        let item = try await fixture.item("selected.txt")
        let original = fixture.root.appendingPathComponent("displaced.txt")
        try FileManager.default.moveItem(at: url, to: original)
        try Data("replacement".utf8).write(to: url)
        do { _ = try await LocalFileMetadataReader().metadata(for: item); Issue.record("Replacement metadata was accepted") }
        catch FileMetadataError.staleSelection {}
        try FileManager.default.removeItem(at: url)
        do { _ = try await LocalFileMetadataReader().metadata(for: item); Issue.record("Missing entry metadata was accepted") }
        catch FileMetadataError.staleSelection {}
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test
    func testUnknownIdentityAndNonFileURLsAreExplicitlyUnsupported() async throws {
        let fixture = try MetadataFixture()
        let url = try fixture.file("known.txt", bytes: Data("known".utf8))
        let unknown = FileItem(url: url, name: "known.txt", isDirectory: false, isSymbolicLink: false,
            size: nil, modifiedAt: nil, kind: "File")
        do { _ = try await LocalFileMetadataReader().metadata(for: unknown); Issue.record("Unknown identity was probed") }
        catch FileMetadataError.missingIdentity {}
        let known = try await fixture.item("known.txt")
        // FileItem's standardizedFileURL preserves non-file schemes but strips
        // a file URL's host; a remote-host rejection cannot be modeled here.
        let unsupported = FileItem(url: URL(string: "https://example.invalid/item")!, name: "item",
            isDirectory: false, isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "File", identity: known.identity)
        #expect(!unsupported.url.isFileURL)
        do { _ = try await LocalFileMetadataReader().metadata(for: unsupported); Issue.record("Unsupported URL was probed") }
        catch FileMetadataError.unsupportedLocation {}
    }

    @Test
    func testUnreadableFileStillHasMetadataWithoutContentAccess() async throws {
        let fixture = try MetadataFixture()
        let url = try fixture.file("unreadable.txt", bytes: Data("metadata only".utf8))
        let item = try await fixture.item("unreadable.txt")
        try #require(url.withUnsafeFileSystemRepresentation { chmod($0!, 0) } == 0)
        let result = try await LocalFileMetadataReader().metadata(for: item)
        #expect(result.size == Int64("metadata only".utf8.count))
        #expect(try nativeMetadataStat(url).st_mode & mode_t(0o777) == 0)
    }

    @Test
    func testDeniedAncestorPreservesNativePermissionError() async throws {
        let fixture = try MetadataFixture()
        let gate = try fixture.directory("Gate")
        let file = gate.appendingPathComponent("selected.txt")
        try Data("owned denied metadata".utf8).write(to: file)
        let item = try await fixture.item("selected.txt", at: gate)
        try #require(gate.withUnsafeFileSystemRepresentation { chmod($0!, 0) } == 0)
        do { _ = try await LocalFileMetadataReader().metadata(for: item); Issue.record("Denied ancestor permitted metadata lookup") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        try #require(gate.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) } == 0)
        let result = try await LocalFileMetadataReader().metadata(for: item)
        #expect(result.size == Int64("owned denied metadata".utf8.count))
    }

    @Test
    func testCancelledCallReturnsCancellation() async throws {
        let fixture = try MetadataFixture()
        _ = try fixture.file("selected.txt", bytes: Data("cancel fixture".utf8))
        let item = try await fixture.item("selected.txt")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalFileMetadataReader().metadata(for: item)
        }
        do { _ = try await task.value; Issue.record("Cancelled metadata read succeeded") }
        catch is CancellationError {}
    }

    @Test
    func testUnavailableBirthAndInvalidAllocationStayUnavailable() {
        var value = stat()
        value.st_mode = mode_t(S_IFREG) | mode_t(0o600)
        value.st_size = 24
        value.st_blocks = Int64.max
        let captured = Date(timeIntervalSince1970: 123)
        let overflow = FileMetadata(stat: value, capturedAt: captured)
        #expect(overflow.size == 24)
        #expect(overflow.allocatedSize == nil)
        #expect(overflow.createdAt == nil)
        #expect(overflow.modifiedAt == Date(timeIntervalSince1970: 0))
        #expect(overflow.accessedAt == Date(timeIntervalSince1970: 0))
        #expect(overflow.capturedAt == captured)
        value.st_blocks = -1
        #expect(FileMetadata(stat: value, capturedAt: captured).allocatedSize == nil)
        value.st_blocks = 0
        #expect(FileMetadata(stat: value, capturedAt: captured).allocatedSize == 0)
    }
}
