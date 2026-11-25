import Darwin
import Foundation
import Testing
@testable import ExplorerCore

struct FileAvailabilityTests {
    @Test func optInCloudListingTimingDoesNotRequestFileContents() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MAXPLORER_CLOUD_LISTING_PATH"], !path.isEmpty else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let protectedURL: URL?
        if let name = environment["MAXPLORER_CLOUD_UNREAD_FILENAME"], !name.isEmpty,
           name != ".", name != "..", !name.contains("/"), !name.contains("\0") {
            protectedURL = root.appendingPathComponent(name)
        } else { protectedURL = nil }
        let before = try protectedURL.flatMap { try LocalFileIdentity.sample(at: $0, ifLocal: true) }
        let clock = ContinuousClock(), started = ContinuousClock.now
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let elapsed = started.duration(to: clock.now)
        let after = try protectedURL.flatMap { try LocalFileIdentity.sample(at: $0, ifLocal: true) }
        if let before, let after {
            #expect(before.identity == after.identity && before.isDataless == after.isDataless)
        }
        let online = snapshot.items.filter { $0.availability == .onlineOnly }.count
        let local = snapshot.items.filter { $0.availability == .availableLocally }.count
        print("Cloud metadata listing: count=\(snapshot.items.count), onlineOnly=\(online), availableLocally=\(local), unknown=\(snapshot.items.count - online - local), elapsed=\(elapsed)")
    }

    @Test func singleStatProvidesIdentityAndAvailabilityWithoutChangingEqualityAuthority() {
        var value = stat()
        value.st_dev = 3; value.st_ino = 7; value.st_birthtimespec.tv_sec = 10
        value.st_flags = UInt32(SF_DATALESS)
        value.st_mode = mode_t(S_IFREG)
        let sample = LocalFileStat(value)
        #expect(sample.isRegularFile)
        #expect(sample.identity == LocalFileIdentity.fromStat(value))
        #expect(sample.availability(isUbiquitous: false) == .onlineOnly)
        value.st_flags = 0
        let local = LocalFileStat(value)
        #expect(local.availability(isUbiquitous: true) == .availableLocally)
        #expect(local.availability(isUbiquitous: false) == .unknown)
        #expect(local.identity == sample.identity)
    }

    @Test(arguments: [UInt32(S_IFREG), UInt32(S_IFDIR), UInt32(S_IFLNK), UInt32(S_IFIFO), UInt32(S_IFSOCK)])
    func statRegularityRejectsOtherNodeTypes(_ mode: UInt32) {
        var value = stat()
        value.st_mode = mode_t(mode | 0o600)
        value.st_dev = 3; value.st_ino = 7; value.st_birthtimespec.tv_sec = 10
        let observed = LocalFileStat(value)
        #expect(observed.isRegularFile == (mode == UInt32(S_IFREG)))
        #expect(observed.identity == LocalFileIdentity.fromStat(value))
    }

    @Test func regularityComesFromSharedStatWithoutContentRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Regularity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unreadable.txt")
        try Data("contents".utf8).write(to: file)
        try #require(chmod(file.path, 0) == 0)
        defer { _ = chmod(file.path, 0o600) }
        let directory = root.appendingPathComponent("Folder"), package = root.appendingPathComponent("Example.app")
        for url in [directory, package] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var providerCalls = 0
        for (url, regular) in [(file, true), (directory, false), (package, false), (link, false)] {
            let observed = LocalDirectoryLoader.sample(for: url, displayedIn: root, supportsLocalIdentity: true,
                readCloudMetadata: false, cloudMembership: { _ in providerCalls += 1; return true })
            #expect(observed.item.isRegularFile == regular)
            #expect(observed.item.identity == (try LocalFileIdentity.sample(at: url, ifLocal: true))?.identity)
            if url == package { #expect(!observed.item.isDirectory, "A package's file-row presentation does not make its node regular") }
        }
        #expect(providerCalls == 0)
        let unsupported = LocalDirectoryLoader.sample(for: file, displayedIn: root, supportsLocalIdentity: false,
            readCloudMetadata: false)
        #expect(unsupported.item.isRegularFile == nil && unsupported.item.identity == nil)
        let unspecified = FileItem(url: file, name: "unreadable.txt", isDirectory: false, isSymbolicLink: false,
            size: 8, modifiedAt: nil, kind: "Text")
        #expect(unspecified.isRegularFile == nil)
    }

    @Test func optionalCloudFailurePreservesRowAndSearchNeverCallsCloudMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Availability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("contents".utf8).write(to: url)
        var calls = 0
        let failure: (URL) throws -> Bool = { _ in calls += 1; throw CocoaError(.featureUnsupported) }
        let listed = LocalDirectoryLoader.sample(for: url, displayedIn: root,
            supportsLocalIdentity: true, cloudMembership: failure)
        #expect(calls == 1)
        #expect(listed.structureKnown && listed.item.size == 8 && listed.item.identity != nil)
        #expect(listed.item.availability == .unknown)
        let searched = LocalDirectoryLoader.sample(for: url, displayedIn: root,
            supportsLocalIdentity: true, readCloudMetadata: false, cloudMembership: failure)
        #expect(calls == 1)
        #expect(searched.item == listed.item)
        let cloud = LocalDirectoryLoader.sample(for: url, displayedIn: root,
            supportsLocalIdentity: true, cloudMembership: { _ in true })
        #expect(cloud.item.availability == .availableLocally)
        #expect(cloud.item.identity == listed.item.identity)
        #expect(cloud.item != listed.item, "Changed availability invalidates an old captured row.")
        #expect(try Data(contentsOf: url) == Data("contents".utf8))
    }

    @Test func symlinkAndArchiveMembersDoNotInheritCloudMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AvailabilityLink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt"), link = root.appendingPathComponent("link.txt")
        try Data("file".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var calls = 0
        let listed = LocalDirectoryLoader.sample(for: link, displayedIn: root, supportsLocalIdentity: true,
            cloudMembership: { _ in calls += 1; return true })
        #expect(listed.item.isSymbolicLink && listed.item.availability == .unknown && calls == 0)
        let archive = try ArchiveLocation(archiveURL: root.appendingPathComponent("archive.zip"), components: ["file.txt"])
        let item = FileItem(url: archive.url, name: "file.txt", isDirectory: false, isSymbolicLink: false,
                            size: 4, modifiedAt: nil, kind: "File", availability: .onlineOnly, isRegularFile: true)
        #expect(item.availability == .unknown && item.isRegularFile == nil)
    }
}
