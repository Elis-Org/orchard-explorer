import AppKit
import Combine
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

private struct InteractionDirectoryLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        [FileItem(url: url.appendingPathComponent("sample.txt"), name: "sample.txt",
                  isDirectory: false, isSymbolicLink: false, size: 28,
                  modifiedAt: Date(timeIntervalSince1970: 0), kind: "Text Document")]
    }
}

/// Deliberately does not honor cancellation: removed tabs must reject late reads themselves.
private actor InteractionControlledLoader: DirectoryListing {
    private(set) var requestedURLs: [URL] = []
    private var pending: [Int: CheckedContinuation<[FileItem], Error>] = [:]

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await withCheckedThrowingContinuation { continuation in
            let request = requestedURLs.count
            requestedURLs.append(url)
            pending[request] = continuation
        }
    }

    func complete(_ request: Int, items: [FileItem] = []) {
        pending.removeValue(forKey: request)?.resume(returning: items)
    }
}

@MainActor
final class InteractionTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-interaction-fixture", isDirectory: true)

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(predicate(), "The interaction did not reach its expected state")
    }

    private func waitForReads(_ count: Int, loader: InteractionControlledLoader) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await loader.requestedURLs.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let actual = await loader.requestedURLs.count
        try #require(actual >= count)
    }

    private func makeStore() -> ExplorerStore {
        ExplorerStore(initialURL: root, loader: InteractionDirectoryLoader(), homeURL: root)
    }

    /// FR-TAB-007 / EV-0379 / AT-TAB-007 establishes duplicated location only.
    /// Fresh history/selection and copied sort are explicit native product policy.
    @Test
    func duplicateCopiesCommittedLocationAndSortWithoutSharingHistoryOrSelection() async throws {
        let store = makeStore()
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        store.navigate(to: source)
        try await waitUntil { !store.activeTab.isLoading }
        let originalID = store.activeTabID
        let selected = try #require(store.activeTab.items.first)
        store.setSelection([selected.id], focusedID: selected.id)
        store.sort(by: .size)
        let originalHistory = store.activeTab.history
        let originalSort = store.activeTab.sort

        store.duplicateTab(originalID)
        try await waitUntil { !store.activeTab.isLoading }
        let duplicateID = store.activeTabID
        #expect(duplicateID != originalID)
        #expect(store.tabs.count == 2)
        #expect(store.activeTab.url == source)
        #expect(store.activeTab.sort == originalSort)
        #expect(store.activeTab.history.backStack.isEmpty)
        #expect(store.activeTab.history.forwardStack.isEmpty)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)

        store.navigate(to: root.appendingPathComponent("Target", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }
        store.activateTab(originalID)
        #expect(store.activeTab.url == source)
        #expect(store.activeTab.history == originalHistory)
        #expect(store.activeTab.selection.selectedIDs == [selected.id])
        #expect(store.tabs.first { $0.id == duplicateID }?.url.lastPathComponent == "Target")
    }

    /// FR-TAB-002/006 / EV-0247, EV-0290 / AT-TAB-002/006; inverse cycling is a native shortcut.
    @Test
    func inverseTabCycleWrapsAndPreservesEachLocation() async throws {
        let store = makeStore()
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        let first = store.activeTabID
        store.openTab(at: root.appendingPathComponent("Source", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }
        let second = store.activeTabID
        store.openTab(at: root.appendingPathComponent("Target", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }
        let third = store.activeTabID
        let destinations = store.tabs.map(\.url)

        store.cycleTab(backwards: true)
        #expect(store.activeTabID == second)
        store.cycleTab(backwards: true)
        #expect(store.activeTabID == first)
        store.cycleTab(backwards: true)
        #expect(store.activeTabID == third)
        store.cycleTab()
        #expect(store.activeTabID == first)
        #expect(store.tabs.map(\.url) == destinations)
    }

    /// UI-TAB-002 / EV-0373/0374 / AT-UITAB-002 covers one-tab availability.
    /// Multi-tab closure outcome is the chosen native policy, not a captured Windows transition.
    @Test
    func bulkClosureKeepsAValidActiveTabAndNeverClosesFinalWindow() async throws {
        let store = makeStore()
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        var windowCloseCount = 0
        store.onLastTabClosed = { windowCloseCount += 1 }
        let first = store.activeTabID
        store.openTab(at: root.appendingPathComponent("Source", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }
        let second = store.activeTabID
        store.openTab(at: root.appendingPathComponent("Target", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }

        store.closeTabsToRight(second)
        #expect(store.tabs.map(\.id) == [first, second])
        #expect(store.tabs.contains { $0.id == store.activeTabID })
        store.closeOtherTabs(first)
        #expect(store.tabs.map(\.id) == [first])
        #expect(store.activeTabID == first)
        store.closeOtherTabs(first)
        store.closeTabsToRight(first)
        #expect(store.tabs.map(\.id) == [first])
        #expect(windowCloseCount == 0)
    }

    /// Native stale-read safety supporting FR-TAB-003/005/006.
    @Test
    func bulkClosureRejectsPendingReadsFromEveryRemovedTab() async throws {
        let loader = InteractionControlledLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        defer { store.cancelLoads() }
        try await waitForReads(1, loader: loader)
        await loader.complete(0)
        try await waitUntil { !store.activeTab.isLoading }
        let retainedID = store.activeTabID
        store.openTab(at: root.appendingPathComponent("Source", isDirectory: true))
        try await waitForReads(2, loader: loader)
        store.openTab(at: root.appendingPathComponent("Target", isDirectory: true))
        try await waitForReads(3, loader: loader)
        store.closeOtherTabs(retainedID)

        try await confirmation("Closed tab reads cannot publish into their former window", expectedCount: 0) { change in
            let observer = store.objectWillChange.sink { change() }
            await loader.complete(1)
            await loader.complete(2)
            try await Task.sleep(nanoseconds: 50_000_000)
            withExtendedLifetime(observer) {}
        }
        #expect(store.tabs.map(\.id) == [retainedID])
        #expect(store.activeTabID == retainedID)
        #expect(store.activeTab.url == root)
        #expect(!store.activeTab.isLoading)
    }

    /// FR-TAB-008 / EV-0386 / AT-TAB-008 establishes separate windows retaining locations.
    /// History/selection transfer and cancelling pending reads are native continuity guarantees.
    @Test
    func detachTransfersCommittedStateAndRejectsOldWindowCompletion() async throws {
        let loader = InteractionControlledLoader()
        let receiverLoader = InteractionControlledLoader()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root)
        var receiver: ExplorerStore?
        defer { store.cancelLoads(); receiver?.cancelLoads() }
        try await waitForReads(1, loader: loader)
        await loader.complete(0)
        try await waitUntil { !store.activeTab.isLoading }
        let retainedID = store.activeTabID
        let source = root.appendingPathComponent("Source", isDirectory: true)
        store.openTab(at: root)
        try await waitForReads(2, loader: loader)
        await loader.complete(1)
        try await waitUntil { !store.activeTab.isLoading }
        store.navigate(to: source)
        try await waitForReads(3, loader: loader)
        let selected = FileItem(url: source.appendingPathComponent("read-only.txt"), name: "read-only.txt",
                                isDirectory: false, isSymbolicLink: false, size: 28,
                                modifiedAt: nil, kind: "Text Document")
        await loader.complete(2, items: [selected])
        try await waitUntil { !store.activeTab.isLoading }
        store.setSelection([selected.id], focusedID: selected.id)
        store.sort(by: .kind)
        let movingID = store.activeTabID
        let before = store.activeTab
        #expect(before.history.backStack == [root])
        let pending = source.appendingPathComponent("Pending", isDirectory: true)
        store.navigate(to: pending)
        try await waitForReads(4, loader: loader)
        var receivedPoint: NSPoint?
        store.onDetachTab = { tab, point in
            receivedPoint = point
            receiver = ExplorerStore(tab: tab, loader: receiverLoader, homeURL: self.root)
        }

        #expect(store.canDetachTab(movingID))
        let dropPoint = NSPoint(x: 120, y: 340)
        store.detachTab(movingID, at: dropPoint)
        let destination = try #require(receiver)
        #expect(receivedPoint == dropPoint)
        #expect(store.tabs.map(\.id) == [retainedID])
        #expect(store.activeTabID == retainedID)
        #expect(destination.activeTab.id == movingID)
        #expect(destination.activeTab.history == before.history)
        #expect(destination.activeTab.items == before.items)
        #expect(destination.activeTab.selection == before.selection)
        #expect(destination.activeTab.sort == before.sort)
        try await waitForReads(1, loader: receiverLoader)
        let receiverRequests = await receiverLoader.requestedURLs
        #expect(receiverRequests == [source], "The new window refreshes the committed location, not an unfinished navigation")
        await receiverLoader.complete(0, items: [selected])
        try await waitUntil { !destination.activeTab.isLoading }

        try await confirmation("The former window cannot apply its detached tab's late completion", expectedCount: 0) { change in
            let originalObserver = store.objectWillChange.sink { change() }
            let newObserver = destination.objectWillChange.sink { change() }
            await loader.complete(3)
            try await Task.sleep(nanoseconds: 50_000_000)
            withExtendedLifetime((originalObserver, newObserver)) {}
        }
        #expect(destination.activeTab.url == source)
        #expect(destination.activeTab.selection.selectedIDs == [selected.id])
        #expect(store.activeTab.url == root)
    }

    @Test
    func singleTabAndMissingDetachHandlerCannotLoseTab() async throws {
        let store = makeStore()
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        let onlyID = store.activeTabID
        var transfers = 0
        store.onDetachTab = { _, _ in transfers += 1 }
        #expect(!store.canDetachTab(onlyID))
        store.detachTab(onlyID)
        #expect(transfers == 0)
        #expect(store.tabs.map(\.id) == [onlyID])
        store.openTab(at: root.appendingPathComponent("Source", isDirectory: true))
        try await waitUntil { !store.activeTab.isLoading }
        store.onDetachTab = nil
        let before = store.tabs.map(\.id)
        let activeBefore = store.activeTabID
        store.detachTab(activeBefore)
        #expect(store.tabs.map(\.id) == before)
        #expect(store.activeTabID == activeBefore)
    }

    @Test
    func unknownTabCommandsDoNotChangeTabsOrActiveIdentity() async throws {
        let store = makeStore()
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        let unknown = UUID()
        let before = store.tabs.map(\.id)
        let activeBefore = store.activeTabID
        store.duplicateTab(unknown)
        store.closeOtherTabs(unknown)
        store.closeTabsToRight(unknown)
        store.detachTab(unknown)
        #expect(!store.canDetachTab(unknown))
        #expect(store.tabs.map(\.id) == before)
        #expect(store.activeTabID == activeBefore)
    }

    /// UI-SHELL-002 / EV-0372 / AT-UISHELL-002 constrains sampled outcomes only.
    /// These assertions describe explicit native breakpoints, not Windows threshold measurements.
    @Test
    func sampledWindowWidthsChooseExpectedShellRegions() {
        for width in [CGFloat(1127), CGFloat(743)] {
            let layout = ExplorerLayout(width: width)
            #expect(layout.showsSidebar)
            #expect(layout.showsAddress)
            #expect(layout.sidebarWidth == 312)
            #expect(layout.commandMode == .full)
            #expect(width - layout.sidebarWidth - 1 > 0)
        }
        let compact = ExplorerLayout(width: 377)
        #expect(compact.showsSidebar)
        #expect(compact.showsAddress)
        #expect(compact.sidebarWidth == 239)
        #expect(compact.commandMode == .compact)
        #expect(compact.width - compact.sidebarWidth - 1 > 0)

        let minimal = ExplorerLayout(width: 185)
        #expect(!minimal.showsSidebar)
        #expect(!minimal.showsAddress)
        #expect(minimal.commandMode == .minimal)
        #expect(minimal.navigationButtonWidth * 4 <= minimal.width)
    }

    /// FR-TAB-008 / EV-0386 / AT-TAB-008; cancellation/release gating is native policy.
    @Test
    func tabDragRequiresAnUncancelledObservedReleaseOutsideSourceWindow() {
        let window = NSRect(x: 100, y: 100, width: 1127, height: 635)
        let outside = NSPoint(x: 1400, y: 350)
        let inside = NSPoint(x: 500, y: 350)
        #expect(TabDetachDecision.shouldDetach(didRelease: true, cancelled: false,
                                             releasePoint: outside, sourceFrame: window))
        #expect(!TabDetachDecision.shouldDetach(didRelease: true, cancelled: false,
                                              releasePoint: inside, sourceFrame: window))
        #expect(!TabDetachDecision.shouldDetach(didRelease: true, cancelled: true,
                                              releasePoint: outside, sourceFrame: window))
        #expect(!TabDetachDecision.shouldDetach(didRelease: false, cancelled: false,
                                              releasePoint: outside, sourceFrame: window))
    }
}
