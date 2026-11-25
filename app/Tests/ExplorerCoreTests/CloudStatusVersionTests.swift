import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// CSR-03/06: a display Date must not erase an observed raw content-version change.
struct CloudStatusVersionTests {
    @Test func visibleSearchMembershipRequiresPositivePerFileEvidenceAndAnUnchangedLeaf() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OneDrive-Unmanaged-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic.txt")
        try Data("synthetic".utf8).write(to: file)
        let sampledParent = try LocalFileIdentity.read(at: folder, ifLocal: true)
        let parent = try #require(sampledParent)
        let row = LocalDirectoryLoader.sample(for: file, displayedIn: folder, supportsLocalIdentity: true,
            readCloudMetadata: false, cloudMembership: { _ in Issue.record("Search must skip per-file membership during enumeration"); return true }).item
        #expect(row.availability == .unknown)
        let entry = TransferEntry(source: .init(directoryURL: folder, directoryIdentity: parent), item: row)
        #expect(try LocalDirectoryLoader.visibleCloudAvailability(entry, membership: { _ in false }) == .unknown)
        #expect(try LocalDirectoryLoader.visibleCloudAvailability(entry, membership: { _ in true }) == .availableLocally)
        #expect(throws: OneDriveRetentionError.self) {
            try LocalDirectoryLoader.visibleCloudAvailability(entry) { _ in
                try Data("replacement".utf8).write(to: file, options: .atomic)
                return true
            }
        }
    }

    @Test func stampUsesRawStatAndOnlyRegularLocalRows() throws {
        var raw = stat()
        raw.st_mode = mode_t(S_IFREG) | 0o600
        raw.st_size = 19
        raw.st_mtimespec = timespec(tv_sec: 1_700_000_002, tv_nsec: 123_456_701)
        let expected = LocalFileStatusVersion(size: 19, modificationSeconds: 1_700_000_002,
                                             modificationNanoseconds: 123_456_701)
        #expect(LocalFileStat(raw).statusVersion == expected)
        raw.st_flags |= UInt32(SF_DATALESS)
        raw.st_ctimespec.tv_nsec += 1
        #expect(LocalFileStat(raw).statusVersion == expected, "Residency and ctime are not content version")
        for type in [S_IFDIR, S_IFLNK] {
            raw.st_mode = mode_t(type) | 0o700
            #expect(LocalFileStat(raw).statusVersion == nil)
        }
        let virtual = FileItem(url: URL(string: "archive:///synthetic.txt")!, name: "synthetic.txt",
            isDirectory: false, isSymbolicLink: false, size: 19, modifiedAt: nil, kind: "Text",
            statusVersion: expected)
        #expect(virtual.statusVersion == nil)
    }

    @Test(arguments: [false, true])
    func nanosecondOnlyChangeUpdatesListingAndSearchRows(search: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StatusVersion-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic.txt")
        try Data("synthetic".utf8).write(to: file)
        func row(nanoseconds: Int) throws -> FileItem {
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0),
                         timespec(tv_sec: 1_700_000_002, tv_nsec: nanoseconds)]
            try #require(file.withUnsafeFileSystemRepresentation { utimensat(AT_FDCWD, $0!, &times, 0) } == 0)
            var raw = stat()
            try #require(lstat(file.path, &raw) == 0)
            try #require(raw.st_mtimespec.tv_nsec == nanoseconds)
            return LocalDirectoryLoader.sample(for: URL(fileURLWithPath: file.path), displayedIn: folder,
                supportsLocalIdentity: true, readCloudMetadata: !search, cloudMembership: { _ in false }).item
        }
        let before = try row(nanoseconds: 123_456_700)
        let after = try row(nanoseconds: 123_456_701)
        #expect(before.id == after.id)
        #expect(before.identity == after.identity)
        #expect(before.modifiedAt == after.modifiedAt, "The two raw times intentionally round to one display Date")
        #expect(before.statusVersion?.modificationNanoseconds == 123_456_700)
        #expect(after.statusVersion?.modificationNanoseconds == 123_456_701)
        #expect(before != after, "Raw nanoseconds must participate in row equality independently of Date")
        #expect(Set([before, after]).count == 2)
    }
}
