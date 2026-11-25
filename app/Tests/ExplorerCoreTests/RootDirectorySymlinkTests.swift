import CoreServices
import Foundation
import Testing
@testable import ExplorerCore

/// Root-link navigation regression: native metadata evidence
/// root-symlink-probe-082d3a9d5ccc4796a3472caffbc802ce, macOS 26.7.1.
/// System paths are metadata/listing inputs only; every mutation is confined to
/// the synthetic UUID fixture. No application launch or UI verdict is implied.
@Suite(.serialized)
struct RootDirectorySymlinkTests {
    private func rootAlias(_ name: String) throws -> (lexical: URL, physical: URL) {
        let lexical = URL(fileURLWithPath: "/" + name, isDirectory: false)
        let physical = URL(fileURLWithPath: "/private/" + name, isDirectory: true)
        let linkValues = try lexical.resourceValues(forKeys: [.isSymbolicLinkKey])
        let targetValues = try physical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        try #require(linkValues.isSymbolicLink == true, "The native root-alias fixture must be a symlink")
        try #require(targetValues.isDirectory == true && targetValues.isPackage == false,
                     "The native root-alias target must be an ordinary directory")
        return (lexical, physical)
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootListingKeepsDirectoryAliasesNavigable(_ name: String) async throws {
        let route = try rootAlias(name)
        let items = try await LocalDirectoryLoader().contents(of: URL(fileURLWithPath: "/", isDirectory: true), showHidden: true)
        let item = try #require(items.first { $0.name == name })
        #expect(item.isDirectory)
        #expect(item.isSymbolicLink)
        #expect(item.url.path == route.lexical.path)
        let linkIdentity = try #require(try LocalFileIdentity.read(at: route.lexical, ifLocal: true))
        let targetIdentity = try #require(try LocalFileIdentity.read(at: route.physical, ifLocal: true))
        #expect(item.identity == linkIdentity)
        #expect(item.identity != targetIdentity, "The displayed entry remains the link, not its target")
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootAliasSnapshotsLoadTargetAndKeepLexicalChildren(_ name: String) async throws {
        let route = try rootAlias(name)
        let targetIdentity = try #require(try LocalFileIdentity.read(at: route.physical, ifLocal: true))
        let snapshot = try await LocalDirectoryLoader().snapshot(of: route.lexical, showHidden: false)
        #expect(snapshot.directoryIdentity == targetIdentity)
        // Assert a Boolean so a failure does not print system-directory contents.
        let keepsLexicalChildren = snapshot.items.allSatisfy {
            $0.url.deletingLastPathComponent().path == route.lexical.path
        }
        #expect(keepsLexicalChildren)
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootAliasWatchScopeAcceptsTargetWithoutWholeVolumeWatch(_ name: String) throws {
        let route = try rootAlias(name)
        let scope = try DirectoryWatchScope(url: route.lexical)
        #expect(scope.logicalURL.path == route.lexical.path)
        #expect(scope.roots.contains(route.physical.path))
        #expect(scope.routeLinks.contains(route.lexical.path))
        #expect(!scope.watchedPaths.contains("/"), "Root aliases must not create a whole-volume FSEvents subscription")
        #expect(scope.change(for: route.physical.appendingPathComponent("synthetic-event-name").path,
                             flags: UInt32(kFSEventStreamEventFlagItemCreated)) == .children(["synthetic-event-name"]))
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootAliasRoutingUsesTheTargetDirectoryIdentity(_ name: String) async throws {
        let route = try rootAlias(name)
        let targetIdentity = try #require(try LocalFileIdentity.read(at: route.physical, ifLocal: true))
        #expect(RoutingTargetValidation.folderIdentity(of: route.lexical) == targetIdentity)
        #expect(await RoutingTargetValidation.isCurrentFolder(route.lexical, identity: targetIdentity))
    }

    @Test(arguments: ["etc", "tmp", "var"])
    func rootFolderSuggestionsIncludeDirectoryAliases(_ name: String) async throws {
        let route = try rootAlias(name)
        let suggestions = try await LocalFolderSuggester().folders(
            in: URL(fileURLWithPath: "/", isDirectory: true), prefix: name, showHidden: true)
        let includesLexicalAlias = suggestions.urls.contains { $0.path == route.lexical.path }
        #expect(includesLexicalAlias)
    }

    @Test
    func suggestionsInsideRootAliasReadItsDirectoryTarget() async throws {
        let route = try rootAlias("etc")
        let suggestions = try await LocalFolderSuggester().folders(in: route.lexical,
            prefix: "Maxplorer-nonexistent-" + UUID().uuidString, showHidden: false)
        #expect(suggestions.urls.isEmpty)
    }

    @Test
    func currentFolderSearchAcceptsRootAliasTargetIdentity() async throws {
        let route = try rootAlias("etc")
        let identity = try #require(try LocalFileIdentity.read(at: route.physical, ifLocal: true))
        let query = try #require(FilenameSearchQuery(text: "Maxplorer-nonexistent-" + UUID().uuidString, scope: .currentFolder))
        let request = FilenameSearchRequest(root: route.lexical, rootIdentity: identity, query: query, showHidden: false)
        var finished = false
        for try await event in LocalFilenameSearcher().search(request) {
            switch event {
            case .progress(let results, _):
                #expect(results.isEmpty)
            case .finished(let coverage):
                finished = true
                #expect(coverage.foldersSearched == 1, "Only the requested directory is searched")
            }
        }
        #expect(finished)
    }

    @Test
    func currentFolderSearchResultUnderRootAliasKeepsValidatedParent() async throws {
        let fixture = try RootLinkFixture()
        let route = try rootAlias("tmp")
        let identity = try #require(try LocalFileIdentity.read(at: route.physical, ifLocal: true))
        let query = try #require(FilenameSearchQuery(text: fixture.root.lastPathComponent, scope: .currentFolder))
        let request = FilenameSearchRequest(root: route.lexical, rootIdentity: identity, query: query, showHidden: false)
        var matches: [FilenameSearchResult] = []
        for try await event in LocalFilenameSearcher().search(request) {
            if case .progress(let results, _) = event { matches.append(contentsOf: results) }
        }
        let ownedMatches = matches.filter { $0.item.name == fixture.root.lastPathComponent }
        #expect(ownedMatches.count == 1)
        let result = try #require(ownedMatches.first)
        #expect(result.item.url.path == route.lexical.appendingPathComponent(fixture.root.lastPathComponent).path)
        #expect(result.parent?.directoryIdentity == identity)
        #expect(try await FilenameSearchValidation.isCurrent(result))
    }

    @Test
    func syntheticPrivateTmpLinkChainKeepsEntryAndTargetIdentitiesSeparate() async throws {
        let fixture = try RootLinkFixture()
        let target = fixture.root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("synthetic child".utf8).write(to: target.appendingPathComponent("child.txt"))
        let relative = fixture.root.appendingPathComponent("Relative")
        let chain = fixture.root.appendingPathComponent("Chain")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "Target")
        try FileManager.default.createSymbolicLink(atPath: chain.path, withDestinationPath: "Relative")
        let items = try await LocalDirectoryLoader().contents(of: fixture.root, showHidden: true)
        let item = try #require(items.first { $0.name == "Chain" })
        #expect(item.isDirectory && item.isSymbolicLink)
        #expect(item.url.path == chain.standardizedFileURL.path)
        let entryIdentity = try #require(try LocalFileIdentity.read(at: chain, ifLocal: true))
        let targetIdentity = try #require(try LocalFileIdentity.read(at: target, ifLocal: true))
        #expect(item.identity == entryIdentity && item.identity != targetIdentity)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: item.url, showHidden: true)
        #expect(snapshot.directoryIdentity == targetIdentity)
        #expect(snapshot.items.map(\.name) == ["child.txt"])
        #expect(snapshot.items.first?.url.path == item.url.appendingPathComponent("child.txt").path)
        #expect(RoutingTargetValidation.folderIdentity(of: item.url) == targetIdentity)
        #expect(await RoutingTargetValidation.isCurrent(item))
    }

    @Test
    func syntheticFilePackageAndDanglingLinksRemainFileLike() async throws {
        let fixture = try RootLinkFixture()
        let manager = FileManager.default
        try Data("synthetic".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try manager.createDirectory(at: fixture.root.appendingPathComponent("Example.app/Contents"), withIntermediateDirectories: true)
        for (name, destination) in [("FileLink", "file.txt"), ("PackageLink", "Example.app"), ("DanglingLink", "missing")] {
            try manager.createSymbolicLink(atPath: fixture.root.appendingPathComponent(name).path, withDestinationPath: destination)
        }
        let items = try await LocalDirectoryLoader().contents(of: fixture.root, showHidden: true)
        for name in ["FileLink", "PackageLink", "DanglingLink"] {
            let item = try #require(items.first { $0.name == name })
            #expect(item.isSymbolicLink)
            #expect(!item.isDirectory)
            #expect(item.identity == (try LocalFileIdentity.read(at: fixture.root.appendingPathComponent(name), ifLocal: true)))
        }
    }
}

private final class RootLinkFixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MaxplorerRootLinkTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
