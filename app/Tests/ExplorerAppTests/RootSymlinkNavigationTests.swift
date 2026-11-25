import AppKit
@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

/// Native root-link regression; MAC-008/082/083 and metadata evidence
/// root-symlink-probe-082d3a9d5ccc4796a3472caffbc802ce (macOS 26.7.1).
/// System paths are read-only. Activation requires a real directory-classified
/// row before dispatch, so the failing baseline cannot launch an external app.
@Suite(.serialized) @MainActor
struct RootSymlinkNavigationTests {
    private func rootAlias(_ name: String) throws -> (lexical: URL, identity: LocalFileIdentity) {
        let lexical = URL(fileURLWithPath: "/" + name, isDirectory: false)
        let physical = URL(fileURLWithPath: "/private/" + name, isDirectory: true)
        let linkValues = try lexical.resourceValues(forKeys: [.isSymbolicLinkKey])
        let targetValues = try physical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        try #require(linkValues.isSymbolicLink == true, "The native root fixture must be a symlink")
        try #require(targetValues.isDirectory == true && targetValues.isPackage == false,
                     "The native root target must be an ordinary directory")
        let identity = try #require(try LocalFileIdentity.read(at: physical, ifLocal: true))
        return (lexical, identity)
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func externalRequestOpensRootAliasAsFolder(_ name: String) async throws {
        let route = try rootAlias(name)
        let plan = await OpenRequestPlan.classify([route.lexical])
        try #require(plan.targets.count == 1)
        let target = try #require(plan.targets.first)
        #expect(target.folder.path == route.lexical.path)
        #expect(target.reveal.isEmpty, "A directory-link request opens the folder instead of revealing its link in /")
        #expect(target.folderIdentity == route.identity)
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func loadedRootAliasActivationNavigatesInCurrentTab(_ name: String) async throws {
        let route = try rootAlias(name)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let board = NSPasteboard(name: NSPasteboard.Name("root-link-navigation-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(tab: BrowserTab(url: root), homeURL: root, showHidden: true,
                                  clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await waitForLoad(store)
        let item = try #require(store.activeTab.items.first { $0.name == name })
        // Do not remove this guard: the old false classification would otherwise
        // reach NSWorkspace.open. Native UI validation separately checks app focus.
        try #require(item.isDirectory, "Only a real directory-classified row may be activated in this test")
        #expect(item.isSymbolicLink && item.url.path == route.lexical.path)
        let tabID = store.activeTabID
        store.activate(item)
        try await waitForLoad(store)
        #expect(store.activeTabID == tabID && store.tabs.count == 1)
        #expect(store.activeTab.url.path == route.lexical.path)
        #expect(store.activeTab.directoryIdentity == route.identity)
        #expect(store.activeTab.errorMessage == nil && !store.activeTab.isUnavailable)
        #expect(store.activeTab.history.canGoBack)
        // A Boolean avoids printing system-directory child names on failure.
        let keepsLexicalChildren = store.activeTab.items.allSatisfy {
            $0.url.deletingLastPathComponent().path == route.lexical.path
        }
        #expect(keepsLexicalChildren)
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootAliasCanBePinnedUsingItsLexicalPath(_ name: String) throws {
        let route = try rootAlias(name)
        let pins = PinnedFolderStore()
        #expect(pins.pin(route.lexical))
        #expect(pins.urls.last?.path == route.lexical.path)
        #expect(pins.errorMessage == nil)
    }

    @Test
    func requestForSyntheticLinkToPrivateTmpKeepsTheLinkPath() async throws {
        _ = try rootAlias("tmp")
        let fixture = try RootSymlinkAppFixture()
        let link = fixture.root.appendingPathComponent("TmpLink")
        let physical = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)
        let expectedIdentity = try #require(try LocalFileIdentity.read(at: physical, ifLocal: true))
        let plan = await OpenRequestPlan.classify([link])
        try #require(plan.targets.count == 1)
        let target = try #require(plan.targets.first)
        #expect(target.folder.path == link.standardizedFileURL.path)
        #expect(target.reveal.isEmpty)
        #expect(target.folderIdentity == expectedIdentity)
    }

    @Test
    func incomingFilesPackagesAndNonDirectoryLinksRemainRevealRequests() async throws {
        let fixture = try RootSymlinkAppFixture()
        let manager = FileManager.default
        let file = fixture.root.appendingPathComponent("file.txt")
        let package = fixture.root.appendingPathComponent("Example.app", isDirectory: true)
        try Data("synthetic".utf8).write(to: file)
        try manager.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let links = [("FileLink", "file.txt"), ("PackageLink", "Example.app"), ("DanglingLink", "missing")]
        for (name, destination) in links {
            try manager.createSymbolicLink(atPath: fixture.root.appendingPathComponent(name).path,
                                           withDestinationPath: destination)
        }
        let requested = [file, package] + links.map { fixture.root.appendingPathComponent($0.0) }
        let plan = await OpenRequestPlan.classify(requested)
        try #require(plan.targets.count == 1)
        let target = try #require(plan.targets.first)
        #expect(target.folder.path == fixture.root.standardizedFileURL.path)
        #expect(target.reveal.map(\.lastPathComponent) == ["file.txt", "Example.app", "FileLink", "PackageLink", "DanglingLink"])
    }

    private func waitForLoad(_ store: ExplorerStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading,
                     "The real directory load must settle within the test deadline")
    }
}

private final class RootSymlinkAppFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaxplorerRootSymlinkApp-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
