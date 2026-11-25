import Combine
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Exercises the real store with explicitly completed reads, including reads that ignore cancellation.
private actor ControlledDirectoryLoader: DirectoryListing {
    struct Request: Sendable {
        let url: URL
        let showHidden: Bool
    }
    private(set) var requests: [Request] = []
    private var completions: [Int: CheckedContinuation<[FileItem], Error>] = [:]

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(Request(url: url, showHidden: showHidden))
            completions[index] = continuation
        }
    }

    func succeed(_ index: Int, items: [FileItem] = []) {
        completions.removeValue(forKey: index)?.resume(returning: items)
    }

    func fail(_ index: Int) {
        completions.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoSuchFile))
    }
}

@MainActor
final class ExplorerStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-store-fixture", isDirectory: true)

    private func item(_ name: String, under url: URL) -> FileItem {
        FileItem(url: url.appendingPathComponent(name), name: name, isDirectory: false,
                 isSymbolicLink: false, size: 22, modifiedAt: Date(timeIntervalSince1970: 0), kind: "Text Document")
    }

    private func waitForRequests(_ count: Int, loader: ControlledDirectoryLoader) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await loader.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let actual = await loader.requests.count
        try #require(actual >= count, "Store did not dispatch the expected read")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(predicate(), "Store did not reach expected state")
    }

    /// FR-NAV-007 / EV-0298 / AT-NAV-007. Tests state preservation, not modal styling/focus.
    @Test
    func testFailedNavigationRetainsLocationRowsSelectionAndHistory() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        let original = item("original.txt", under: root)
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0, items: [original])
        try await waitUntil { !store.activeTab.isLoading }
        store.setSelection([original.id], focusedID: original.id)
        let history = store.activeTab.history
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        store.navigate(to: missing)
        #expect(store.activeTab.url == root, "Breadcrumb must keep describing the displayed rows during a read")
        try await waitForRequests(2, loader: loader)
        await loader.fail(1)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == root)
        #expect(store.activeTab.items == [original])
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        #expect(store.activeTab.history == history)
        #expect(store.activeTab.errorMessage?.contains("missing") == true)
        store.dismissError()
        #expect(store.activeTab.errorMessage == nil)
    }

    /// FR-NAV-007 / EV-0298 / AT-NAV-007; retry is a native recovery adaptation.
    @Test
    func testRetryReattemptsFailedDestinationAndCommitsHistoryOnlyAfterSuccess() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0)
        try await waitUntil { !store.activeTab.isLoading }
        let destination = root.appendingPathComponent("temporarily unavailable", isDirectory: true)
        store.navigate(to: destination)
        try await waitForRequests(2, loader: loader)
        await loader.fail(1)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == root)
        #expect(!(store.activeTab.history.canGoBack))

        store.retry()
        try await waitForRequests(3, loader: loader)
        let requests = await loader.requests
        #expect(requests[2].url == destination)
        #expect(store.activeTab.url == root)
        let recovered = item("recovered.txt", under: destination)
        await loader.succeed(2, items: [recovered])
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == destination)
        #expect(store.activeTab.items == [recovered])
        #expect(store.activeTab.history.backStack == [root])
        #expect(store.activeTab.errorMessage == nil)
    }

    /// Native concurrency invariant supporting FR-NAV-009 and FR-TAB-005; no Windows timing claim.
    @Test
    func testLateReadCannotReplaceNewerNavigationEvenWhenLoaderIgnoresCancellation() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0)
        try await waitUntil { !store.activeTab.isLoading }
        let oldURL = root.appendingPathComponent("old", isDirectory: true)
        let latestURL = root.appendingPathComponent("latest", isDirectory: true)
        store.navigate(to: oldURL)
        try await waitForRequests(2, loader: loader)
        store.navigate(to: latestURL)
        try await waitForRequests(3, loader: loader)
        let latestItem = item("latest.txt", under: latestURL)
        await loader.succeed(2, items: [latestItem])
        try await waitUntil { !store.activeTab.isLoading }

        try await confirmation("An obsolete result must publish no state changes", expectedCount: 0) { change in
            let observer = store.objectWillChange.sink { change() }
            await loader.succeed(1, items: [item("stale.txt", under: oldURL)])
            // Bounded observation window for an incorrectly accepted asynchronous completion.
            try await Task.sleep(nanoseconds: 50_000_000)
            withExtendedLifetime(observer) {}
        }
        #expect(store.activeTab.url == latestURL)
        #expect(store.activeTab.items == [latestItem])
        #expect(store.activeTab.history.backStack == [root])
    }

    /// FR-TAB-003/005/006 / EV-0290, EV-0247 / AT-TAB-003/005/006 (model subset).
    @Test
    func testClosingLoadingTabCannotResurrectItOrContaminateOtherTab() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0)
        try await waitUntil { !store.activeTab.isLoading }
        let firstID = store.activeTabID
        store.openTab(at: root)
        let closedID = store.activeTabID
        try await waitForRequests(2, loader: loader)
        store.closeTab(closedID)
        try await confirmation("Closed-tab read must publish no state changes", expectedCount: 0) { change in
            let observer = store.objectWillChange.sink { change() }
            await loader.fail(1)
            try await Task.sleep(nanoseconds: 50_000_000)
            withExtendedLifetime(observer) {}
        }
        #expect(store.tabs.map(\.id) == [firstID])
        #expect(store.activeTabID == firstID)
        #expect(store.activeTab.errorMessage == nil)
    }

    @Test
    func testBackgroundTabCompletionChangesOnlyOwningTab() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0)
        try await waitUntil { !store.activeTab.isLoading }
        let firstID = store.activeTabID
        let source = root.appendingPathComponent("Source", isDirectory: true)
        store.navigate(to: source)
        try await waitForRequests(2, loader: loader)
        store.openTab(at: root)
        let secondID = store.activeTabID
        try await waitForRequests(3, loader: loader)
        await loader.succeed(2)
        await loader.succeed(1, items: [item("source.txt", under: source)])
        try await waitUntil { store.tabs.allSatisfy { !$0.isLoading && !$0.isRefreshing } }
        #expect(store.activeTabID == secondID)
        #expect(store.activeTab.url == root)
        store.activateTab(firstID)
        #expect(store.activeTab.url == source)
        #expect(store.activeTab.items.map(\.name) == ["source.txt"])
        #expect(store.activeTab.history.backStack == [root])
        #expect(store.tabs.first { $0.id == secondID }?.history.backStack == [])
    }

    /// FR-SEL-007, FR-VIEW-009 / EV-0213, EV-0334 / AT-SEL-007, AT-VIEW-009.
    @Test
    func testSortRetainsSelectionAndRefreshRemovesOnlyDisappearedIDs() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        let first = item("Alpha 2.txt", under: root)
        let second = item("Alpha 10.txt", under: root)
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0, items: [second, first])
        try await waitUntil { !store.activeTab.isLoading }
        store.setSelection([first.id, second.id], focusedID: first.id)
        store.sort(by: .name)
        #expect(store.sortedItems.map(\.id) == [second.id, first.id])
        #expect(store.activeTab.selection.selectedIDs == [first.id, second.id])
        store.refresh()
        try await waitForRequests(2, loader: loader)
        await loader.succeed(1, items: [second])
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.selection.selectedIDs == [second.id])
        #expect(store.activeTab.selection.focusedID != first.id)
    }

    @Test
    func testVisibilityChangeRefreshesEveryTabUsingNewSetting() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.succeed(0)
        try await waitUntil { !store.activeTab.isLoading }
        store.openTab(at: root)
        try await waitForRequests(2, loader: loader)
        await loader.succeed(1)
        try await waitUntil { !store.activeTab.isLoading }
        store.toggleHidden()
        try await waitForRequests(4, loader: loader)
        let requests = await loader.requests
        #expect(requests.suffix(2).map(\.showHidden) == [true, true])
        await loader.succeed(2)
        await loader.succeed(3)
        try await waitUntil { store.tabs.allSatisfy { !$0.isLoading && !$0.isRefreshing } }
    }

    @Test
    func testInitialFailureNeverBecomesFalseEmptyAfterDismissingError() async throws {
        let loader = ControlledDirectoryLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForRequests(1, loader: loader)
        await loader.fail(0)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(!store.activeTab.hasLoaded)
        #expect(store.activeTab.errorMessage != nil)
        store.dismissError()
        #expect(!store.activeTab.hasLoaded)
        store.retry()
        try await waitForRequests(2, loader: loader)
        await loader.succeed(1)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.hasLoaded)
        #expect(store.activeTab.items.isEmpty)
    }
}
