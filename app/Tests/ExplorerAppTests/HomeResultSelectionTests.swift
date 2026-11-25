import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

@MainActor
struct HomeResultSelectionTests {
    private let firstID = LocalFileIdentity(device: 1, inode: 10, birthSeconds: 100, birthNanoseconds: 1)
    private let nextID = LocalFileIdentity(device: 1, inode: 30, birthSeconds: 200, birthNanoseconds: 4)

    private func item(_ path: String, tags: [String]) throws -> FinderTagItem {
        try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/tmp/home-test/" + path),
                                   tags: tags, contentTypes: ["public.text"]))
    }

    private func store() -> ExplorerStore {
        let choices = FinderTagShortcuts()
        choices.setShowsAllTagged(true)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: choices)
        store.selectHomeSection(.tags)
        return store
    }

    @Test func rangeIncludesEveryDisplayedOccurrenceAndInspectorDeduplicatesFiles() throws {
        let store = store()
        let scope = try #require(store.homeResultScope)
        let first = try item("a.txt", tags: ["A", "B"])
        let second = try item("b.txt", tags: ["A"])
        let a1 = HomeResultRow(item: first, group: "A"), a2 = HomeResultRow(item: second, group: "A")
        let b1 = HomeResultRow(item: first, group: "B")
        store.replaceHomeTagSnapshot(FinderTagsSnapshot(names: [], items: [first, second]), in: scope)
        #expect(store.activeTab.homeResults.rows == [a1, a2, b1])
        store.bindHomeResultIdentity(firstID, for: a1, in: scope)
        store.bindHomeResultIdentity(firstID, for: b1, in: scope)
        store.selectHomeResult(a1, in: scope)
        store.selectHomeResult(b1, in: scope, toggling: true)
        #expect(store.activeTab.homeResults.selection.selectedIDs == [a1.id, b1.id])
        #expect(store.homeInspectorTargets?.map(\.url) == [first.url])
        store.selectHomeResult(a1, in: scope)
        store.selectHomeResult(b1, in: scope, extending: true)
        #expect(store.activeTab.homeResults.selection.selectedIDs == [a1.id, a2.id, b1.id])
        #expect(store.homeInspectorTargets?.map(\.url) == [first.url, second.url])
        #expect(store.selectedOperationEntries == nil)
        #expect(store.homeOperationEntries == nil)
    }

    @Test func disappearanceOrChangedProofRevokesPendingRowActionsAndSelection() throws {
        let store = store()
        let scope = try #require(store.homeResultScope)
        let file = try item("replace.txt", tags: ["A"])
        let row = HomeResultRow(item: file, group: "A")
        store.replaceHomeResults([row], in: scope)
        store.bindHomeResultIdentity(firstID, for: row, in: scope)
        store.selectHomeResult(row, in: scope)
        let initial = try #require(store.homeResultMembership(row, in: scope))
        store.bindHomeResultIdentity(nextID, for: row, in: scope)
        #expect(store.homeResultMembership(row, in: scope) != initial)
        #expect(store.activeTab.homeResults.selection.selectedIDs.isEmpty)
        store.performHomeResultAction(.editTags, row: row, in: scope, identity: firstID)
        #expect(store.finderTagEditor == nil)
        let beforeRemoval = try #require(store.homeResultMembership(row, in: scope))
        store.replaceHomeResults([], in: scope)
        store.replaceHomeResults([row], in: scope)
        store.bindHomeResultIdentity(firstID, for: row, in: scope, membership: beforeRemoval)
        #expect(store.activeTab.homeResults.target(of: row)?.identity == nil)
    }

    @Test func singleFileInMultipleGroupsNeedsOneConsistentIdentity() throws {
        let store = store()
        let scope = try #require(store.homeResultScope)
        let file = try item("two-tags.txt", tags: ["A", "B"])
        let first = HomeResultRow(item: file, group: "A"), second = HomeResultRow(item: file, group: "B")
        store.replaceHomeTagSnapshot(FinderTagsSnapshot(names: [], items: [file]), in: scope)
        store.bindHomeResultIdentity(firstID, for: second, in: scope)
        store.selectHomeResult(first, in: scope)
        store.selectHomeResult(second, in: scope, extending: true)
        #expect(store.homeInspectorTargets?.first?.identity == firstID)
        store.bindHomeResultIdentity(nextID, for: first, in: scope)
        #expect(store.homeInspectorTargets?.count == 1 && store.homeInspectorTargets?.first?.identity == nil)
    }

    @Test func returningToTabRetainsTagSnapshotAndDuplicateStartsEmpty() throws {
        let store = store()
        let original = store.activeTabID
        let originalScope = try #require(store.homeResultScope)
        let tagged = try item("chosen.txt", tags: ["A"])
        let row = HomeResultRow(item: tagged, group: "A")
        let source = FinderTagsSnapshot(names: [], items: [tagged])
        store.replaceHomeTagSnapshot(source, in: originalScope)
        store.selectHomeResult(row, in: originalScope)
        store.duplicateTab(original)
        #expect(store.homeTagSnapshot == nil && store.homeInspectorTargets?.isEmpty == true)
        store.replaceHomeTagSnapshot(FinderTagsSnapshot(names: [], items: []), in: originalScope)
        store.activateTab(original)
        #expect(store.homeTagSnapshot == source)
        #expect(store.activeTab.homeResults.selection.selectedIDs == [row.id])
        let currentScope = try #require(store.homeResultScope)
        store.replaceHomeTagSnapshot(FinderTagsSnapshot(names: [], items: []), in: currentScope)
        #expect(store.activeTab.homeResults.selection.selectedIDs.isEmpty)
    }

    @Test func changingOnlyRecentOrderPreservesAnchorAndRepresentedTarget() throws {
        let store = ExplorerStore(initialURL: BrowserPage.home.url)
        let scope = try #require(store.homeResultScope)
        let volume = UUID()
        let a = RecentDocument(url: URL(fileURLWithPath: "/tmp/home-test/a"), identity: firstID,
                               volumeUUID: volume, regularFile: true, openedAt: .distantPast)
        let b = RecentDocument(url: URL(fileURLWithPath: "/tmp/home-test/b"), identity: nextID,
                               volumeUUID: volume, regularFile: true, openedAt: .distantPast)
        store.recentDocuments.replaceSystemRecents([a, b])
        store.replaceHomeResults([HomeResultRow(recent: a), HomeResultRow(recent: b)], in: scope)
        let row = HomeResultRow(recent: a)
        store.selectHomeResult(row, in: scope)
        let original = store.homeResultMembership(row, in: scope)
        let generation = store.homeInspectorGeneration
        var newer = a
        newer.openedAt = .now
        store.replaceHomeResults([HomeResultRow(recent: b), HomeResultRow(recent: newer)], in: scope)
        #expect(store.homeResultMembership(row, in: scope) == original)
        #expect(store.homeInspectorGeneration == generation)
        #expect(store.activeTab.homeResults.selection.anchorID == row.id)
        #expect(store.homeInspectorTargets?.map(\.url) == [a.url])
    }
}
