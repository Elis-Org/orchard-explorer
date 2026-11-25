import Foundation
import Testing
@testable import ExplorerApp

@MainActor
struct SidebarLayoutMigrationTests {
    @Test func homeAndThisMacAreDestinationsAndAllPinnedFoldersArePeers() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pins = PinnedFolderStore()
        let model = SidebarModel(homeURL: home, pins: pins)
        defer { model.cancelLoads() }
        #expect(model.roots.first?.url?.absoluteString == "maxplorer-page://home")
        #expect(model.roots.last?.url?.absoluteString == "maxplorer-page://this-mac")
        #expect(model.roots.compactMap { $0.url?.isFileURL == true ? $0.title : nil } ==
            ["Home folder", "Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"])
        #expect(!model.roots.contains { ["Favorites", "Quick access", "Volumes"].contains($0.title) })
    }

    @Test func repinningDocumentsRecoversItsShortcutAndAnAliasKeepsItsOwnRoute() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let alias = home.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
        let pins = PinnedFolderStore(homeURL: home)
        let first = SidebarModel(homeURL: home, pins: pins)
        let second = SidebarModel(homeURL: home, pins: pins)
        defer { first.cancelLoads(); second.cancelLoads() }
        pins.unpin(documents)
        #expect(!second.roots.contains { $0.key == "favorite:Documents" })
        try #require(pins.pin(alias))
        try #require(pins.pin(documents))
        #expect(pins.entries.suffix(2).map(\.id) == ["pin:" + alias.path, "favorite:Documents"])
        for model in [first, second] {
            #expect(model.roots.filter { $0.url?.path == documents.path }.map(\.key) == ["favorite:Documents"])
        }
    }

    @Test func legacyPinsMigrateOnceAndRemovingEveryDefaultSurvivesRelaunch() throws {
        let suite = "SidebarLayoutMigrationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let documents = home.appendingPathComponent("Documents")
        let missing = "/Volumes/Missing-" + UUID().uuidString + "/Pinned"
        let alias = "/private/tmp/Alias-" + UUID().uuidString
        let legacy = [missing, documents.path, alias, missing]
        defaults.set(legacy, forKey: PinnedFolderStore.preferencesKey)
        let pins = PinnedFolderStore(defaults: defaults)
        let initial = [home.path] + ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"]
            .map { home.appendingPathComponent($0).path } + [missing, alias]
        #expect(pins.urls.map(\.path) == initial)
        let first = SidebarModel(homeURL: home, pins: pins)
        let second = SidebarModel(homeURL: home, pins: pins)
        defer { first.cancelLoads(); second.cancelLoads() }
        #expect(first.roots.contains { $0.key == "favorite:Documents" })
        for url in pins.urls { pins.unpin(url) }
        #expect(!second.roots.contains { $0.key == "favorite:Documents" })
        #expect(PinnedFolderStore(defaults: defaults).urls.isEmpty)
        #expect(defaults.stringArray(forKey: PinnedFolderStore.preferencesKey) == legacy)
    }
}
