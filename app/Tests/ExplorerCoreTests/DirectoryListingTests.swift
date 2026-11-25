import Foundation
import Testing
@testable import ExplorerCore

/// Native filesystem integration. Windows provider strings are deliberately not asserted here.
/// FR-VIEW-004 / EV-0100 / AT-VIEW-004; FR-NAV-009 / EV-0208 / AT-NAV-009.
final class DirectoryListingTests {
    private var root: URL!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @Test
    func testRealFilesHaveBytesWhileFolderSizeIsUnspecified() async throws {
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("zero bytes.txt"))
        let payload = Data("twenty-two-byte sample".utf8)
        #expect(payload.count == 22)
        try payload.write(to: root.appendingPathComponent("Alpha 2.txt"))

        let items = try await LocalDirectoryLoader().contents(of: root, showHidden: false)
        #expect(Set(items.map(\.name)) == ["Empty", "zero bytes.txt", "Alpha 2.txt"])
        let folder = try #require(items.first { $0.name == "Empty" })
        #expect(folder.isDirectory)
        #expect(folder.size == nil)
        let zero = try #require(items.first { $0.name == "zero bytes.txt" })
        #expect(!(zero.isDirectory))
        #expect(zero.size == 0)
        #expect(items.first { $0.name == "Alpha 2.txt" }?.size == 22)
        #expect(try Data(contentsOf: root.appendingPathComponent("Alpha 2.txt")) == payload, "Enumeration must not mutate the source bytes")
    }

    @Test
    func packageRemainsSelectableWithoutInventingItsContentsSize() async throws {
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(repeating: 7, count: 4194304).write(to: package.appendingPathComponent("payload.bin"))
        let items = try await LocalDirectoryLoader().contents(of: root, showHidden: false)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(!item.isDirectory, "Packages remain selectable file-like entries")
        #expect(item.size == nil, "Directory metadata is not the package's recursive contents size")
    }

    @Test
    func testHiddenFilesRequireExplicitVisibilityAndDoNotChangeDisk() async throws {
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        let loader = LocalDirectoryLoader()
        let visible = try await loader.contents(of: root, showHidden: false)
        let all = try await loader.contents(of: root, showHidden: true)
        #expect(visible.map(\.name) == ["visible.txt"])
        #expect(Set(all.map(\.name)) == ["visible.txt", ".hidden.txt"])
        #expect(try Data(contentsOf: root.appendingPathComponent(".hidden.txt")) == Data("hidden".utf8))
    }

    @Test
    func testUnicodeFilenameRemainsAnIOCapableURL() async throws {
        let name = "Café 東京 (v1) [draft].txt"
        let payload = Data([0, 1, 254, 255])
        try payload.write(to: root.appendingPathComponent(name))
        let items = try await LocalDirectoryLoader().contents(of: root, showHidden: false)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.name == name)
        #expect(item.name == item.url.lastPathComponent)
        #expect(try Data(contentsOf: item.url) == payload)
        #expect(item.size == 4)
    }

    @Test
    func testDirectorySymlinkKeepsEntryIdentityAndCanBeNavigatedExplicitly() async throws {
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: target.appendingPathComponent("child.txt"))
        let link = root.appendingPathComponent("Linked folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let loader = LocalDirectoryLoader()
        let items = try await loader.contents(of: root, showHidden: false)
        let linked = try #require(items.first { $0.name == "Linked folder" })
        let original = try #require(items.first { $0.name == "Target" })
        #expect(linked.isSymbolicLink)
        #expect(linked.isDirectory)
        #expect(linked.url.standardizedFileURL.path == link.standardizedFileURL.path)
        #expect(linked.id != original.id)
        let children = try await loader.contents(of: linked.url, showHidden: false)
        #expect(children.map(\.name) == ["child.txt"])
        #expect(children.first?.url.path == link.appendingPathComponent("child.txt").path,
                "Navigation through a directory link must retain the requested lexical route")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("child.txt").path))
    }

    @Test
    func testDanglingSymlinkDoesNotPreventSiblingEnumeration() async throws {
        try Data("ok".utf8).write(to: root.appendingPathComponent("healthy.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("missing"))
        let items = try await LocalDirectoryLoader().contents(of: root, showHidden: false)
        #expect(items.contains { $0.name == "healthy.txt" })
        let dangling = try #require(items.first { $0.name == "dangling" })
        #expect(dangling.isSymbolicLink)
        #expect(!(dangling.isDirectory))
    }

    @Test
    func testMissingDirectoryFailsInsteadOfAppearingEmpty() async throws {
        do {
            _ = try await LocalDirectoryLoader().contents(of: root.appendingPathComponent("missing"), showHidden: false)
            Issue.record("An unavailable directory must report failure, not an empty listing")
        } catch {
            #expect(!(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path)))
        }
    }

    @Test
    func testRegularFileIsRejectedAsNavigationDestination() async throws {
        let file = root.appendingPathComponent("file.txt")
        let payload = Data("unchanged".utf8)
        try payload.write(to: file)
        do {
            _ = try await LocalDirectoryLoader().contents(of: file, showHidden: false)
            Issue.record("Navigation accepts directory destinations only")
        } catch {
            #expect(try Data(contentsOf: file) == payload)
        }
    }

    @Test
    func testRefreshObservesExternalAdditionAndRemoval() async throws {
        let loader = LocalDirectoryLoader()
        let initial = try await loader.contents(of: root, showHidden: false)
        #expect(initial.isEmpty)
        let file = root.appendingPathComponent("external.txt")
        try Data("new".utf8).write(to: file)
        let added = try await loader.contents(of: root, showHidden: false)
        #expect(added.map(\.name) == ["external.txt"])
        try FileManager.default.removeItem(at: file)
        let removed = try await loader.contents(of: root, showHidden: false)
        #expect(removed.isEmpty)
    }
}
