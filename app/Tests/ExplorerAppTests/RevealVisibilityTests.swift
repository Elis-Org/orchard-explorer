import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

/// MAC-REVEAL-VIS-001 / MAC-082/083: selection and visible geometry are
/// independent assertions. These host the production representables.
@Suite(.serialized)
@MainActor
final class RevealVisibilityTests {
    @Test(arguments: FolderViewMode.allCases)
    func externalRevealInExistingFolderMakesDistantSelectionVisible(mode: FolderViewMode) async throws {
        let fixture = try await RevealVisibilityFixture.make(mode: mode)
        defer { fixture.close() }
        let target = try #require(fixture.store.sortedItems.last)
        #expect(!fixture.isVisible(target.id), "The fixture must start with the target offscreen")

        fixture.store.reveal([target.url], in: fixture.store.activeTab.url)
        try await fixture.waitUntil {
            !fixture.store.activeTab.isLoading && fixture.nativeSelectionContains(target.id)
        }
        #expect(fixture.store.currentSelection.selectedIDs == [target.id])
        #expect(fixture.store.currentSelection.focusedID == target.id)
        let becameVisible = await fixture.waitFor { fixture.isVisible(target.id) }
        #expect(becameVisible, "External reveal selected the target but left it outside the \(mode) viewport: \(fixture.geometryDescription(target.id))")
        try await fixture.waitUntil { fixture.store.pendingRevealVisibility == nil }
        let generation = fixture.store.activeTab.revealVisibilityGeneration
        fixture.scrollToBeginning()
        #expect(!fixture.isVisible(target.id))
        fixture.store.refreshAfterActivation()
        try await fixture.waitUntil { !fixture.store.activeTab.isRefreshing }
        await fixture.drainUpdates()
        #expect(!fixture.isVisible(target.id), "A consumed reveal must not replay on passive refresh/layout")
        #expect(fixture.store.activeTab.revealVisibilityGeneration == generation)

        let responder = fixture.window.firstResponder
        fixture.store.reveal([target.url], in: fixture.store.activeTab.url)
        try await fixture.waitUntil { fixture.isVisible(target.id) && fixture.store.pendingRevealVisibility == nil }
        #expect(fixture.store.activeTab.revealVisibilityGeneration != generation)
        #expect(fixture.window.firstResponder === responder, "Reveal must not move keyboard focus")
    }

    @Test(arguments: [FolderViewMode.details, .largeIcons, .list])
    func newlyLoadedTabRevealsAfterItsEmptyPresentationWasLaidOut(mode: FolderViewMode) async throws {
        let listing = RevealControlledListing()
        let fixture = try await RevealVisibilityFixture.make(mode: mode, loader: listing)
        defer { fixture.close() }
        await listing.holdReads()
        let folder = fixture.store.activeTab.url.appendingPathComponent("Other", isDirectory: true)
        let target = folder.appendingPathComponent("Item-239.txt")
        #expect(fixture.store.openTab(at: folder, revealing: [target]))
        fixture.store.setViewMode(mode)
        try await listing.waitForHeldReads(1)
        await fixture.drainUpdates()
        #expect(fixture.store.activeTab.items.isEmpty)
        await listing.releaseReads()
        try await fixture.waitUntil { fixture.nativeSelectionContains(target.absoluteString) && fixture.isVisible(target.absoluteString) }
        #expect(fixture.store.pendingRevealVisibility == nil)
    }

    @Test(arguments: [FolderViewMode.details, .largeIcons])
    func detachedPresentationRetainsIntentUntilItAttachesAndCanChangeRenderer(mode: FolderViewMode) async throws {
        let fixture = try await RevealVisibilityFixture.make(mode: mode)
        defer { fixture.close() }
        fixture.window.contentView = nil
        let target = try #require(fixture.store.sortedItems.last)
        fixture.store.reveal([target.url], in: fixture.store.activeTab.url)
        try await fixture.waitUntil { !fixture.store.activeTab.isLoading && fixture.store.pendingRevealVisibility != nil }
        await fixture.drainUpdates()
        #expect(fixture.store.pendingRevealVisibility != nil, "A detached native view must not consume")
        fixture.store.setViewMode(mode == .details ? .largeIcons : .details)
        fixture.host.frame = .zero
        fixture.layout()
        #expect(fixture.store.pendingRevealVisibility != nil)
        fixture.window.contentView = fixture.host
        fixture.window.setContentSize(NSSize(width: 600, height: 260))
        try await fixture.waitUntil { fixture.isVisible(target.id) && fixture.store.pendingRevealVisibility == nil }
    }

    @Test
    func requestedVisibilityHasFreshNonceAndSelectionEchoDoesNotCancelIt() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, item = try #require(store.sortedItems.last)
        store.reveal([item.url], in: store.activeTab.url)
        try await fixture.settled()
        let first = try #require(store.pendingRevealVisibility)
        store.setSelection(store.currentSelection.selectedIDs, focusedID: store.currentSelection.focusedID,
                           anchorID: store.currentSelection.anchorID)
        #expect(store.pendingRevealVisibility == first, "Native selection echoes are not new user intent")
        store.reveal([item.url], in: store.activeTab.url)
        #expect(store.pendingRevealVisibility == nil, "A new originating reveal supersedes the previous request")
        try await fixture.settled()
        let second = try #require(store.pendingRevealVisibility)
        #expect(second.id != first.id)
        #expect(!store.acknowledgeRevealVisibility(first))
        #expect(store.pendingRevealVisibility == second)
        #expect(store.acknowledgeRevealVisibility(second))
        #expect(store.pendingRevealVisibility == nil)
        #expect(store.activeTab.revealVisibilityGeneration == second.id)
    }

    @Test
    func partialMissingAndNonexternalRevealsOnlyRequestVerifiedExternalTarget() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, root = store.activeTab.url
        let item = try #require(store.sortedItems.last)
        store.reveal([root.appendingPathComponent("gone.txt"), item.url], in: root)
        try await fixture.settled()
        #expect(store.pendingRevealVisibility?.itemID == item.id)
        #expect(store.operationNotice?.hasPrefix("Some requested items") == true)
        store.reveal([root.appendingPathComponent("gone.txt")], in: root)
        try await fixture.settled()
        #expect(store.pendingRevealVisibility == nil)
        #expect(store.currentSelection.selectedIDs.isEmpty)
        #expect(!ItemReveal.navigationChild(item.url).requestsVisibility)
        #expect(!ItemReveal.searchResult(url: item.url, identity: try #require(item.identity)).requestsVisibility)
        store.navigateBreadcrumb(to: root)
        try await fixture.settled()
        #expect(store.pendingRevealVisibility == nil)
    }

    @Test
    func selectionNavigationSearchAndRecoveryTakeoverCancelPendingRequest() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, root = store.activeTab.url
        let item = try #require(store.sortedItems.last), other = try #require(store.sortedItems.first)
        func reveal() async throws {
            store.reveal([item.url], in: root)
            try await fixture.settled()
            try #require(store.pendingRevealVisibility != nil)
        }
        try await reveal()
        store.setSelection([other.id], focusedID: other.id)
        #expect(store.pendingRevealVisibility == nil)
        try await reveal()
        store.setSelection([item.id], focusedID: other.id)
        #expect(store.pendingRevealVisibility == nil, "A focus-only change takes ownership")
        try await reveal()
        store.navigate(to: root)
        #expect(store.pendingRevealVisibility == nil)
        try await fixture.settled()
        try await reveal()
        store.submitSearch("Item")
        #expect(store.activeTab.revealVisibilityRequest == nil)
        store.closeSearch()
        try await fixture.settled()
        try await reveal()
        store.showRecovery()
        #expect(store.activeTab.revealVisibilityRequest == nil)
    }

    @Test
    func pendingBackgroundRequestSurvivesActivationAndHiddenReloadThenDropsOnDetach() async throws {
        let fixture = try await RevealStoreFixture.make(observer: RevealQuietObserver())
        defer { fixture.close() }
        let store = fixture.store, firstTab = store.activeTabID, root = store.activeTab.url
        let item = try #require(store.sortedItems.last)
        store.reveal([item.url], in: root)
        try await fixture.settled()
        let request = try #require(store.pendingRevealVisibility)
        store.openTab(at: root.appendingPathComponent("Other", isDirectory: true))
        try await fixture.settled()
        #expect(store.tabs.first(where: { $0.id == firstTab })?.revealVisibilityRequest == request)
        #expect(!store.acknowledgeRevealVisibility(request), "An inactive tab cannot be consumed")
        store.toggleHidden()
        try await fixture.allSettled()
        #expect(store.tabs.first(where: { $0.id == firstTab })?.revealVisibilityRequest == request)
        store.activateTab(firstTab)
        try await fixture.allSettled()
        #expect(store.pendingRevealVisibility == request)
        var detached: BrowserTab?
        store.onDetachTab = { tab, _ in detached = tab }
        store.detachTab(firstTab)
        #expect(detached?.revealVisibilityRequest == nil)
        #expect(!store.acknowledgeRevealVisibility(request))
    }

    @Test
    func activationRestartsAndLateSupersededLoadsKeepOnlyCurrentReveal() async throws {
        let listing = RevealControlledListing()
        let fixture = try await RevealStoreFixture.make(loader: listing, observer: RevealQuietObserver())
        defer { fixture.close() }
        let store = fixture.store, firstTab = store.activeTabID, root = store.activeTab.url
        store.openTab(at: root.appendingPathComponent("Other", isDirectory: true))
        try await fixture.settled()
        let otherTab = store.activeTabID
        store.activateTab(firstTab)
        try await fixture.allSettled()
        await listing.holdReads()
        let first = root.appendingPathComponent("Item-238.txt"), second = root.appendingPathComponent("Item-239.txt")
        store.reveal([first], in: root)
        try await listing.waitForHeldReads(1)
        #expect(store.pendingRevealVisibility == nil)
        store.activateTab(otherTab)
        store.activateTab(firstTab)
        try await listing.waitForHeldReads(3)
        store.reveal([second], in: root)
        try await listing.waitForHeldReads(4)
        await listing.releaseReads()
        try await fixture.allSettled()
        #expect(store.pendingRevealVisibility?.itemID == second.absoluteString)
        #expect(store.currentSelection.selectedIDs == [second.absoluteString])
    }

    @Test
    func passiveReloadPreservesPendingAndDoesNotReplayConsumedOrReplacedTarget() async throws {
        let listing = RevealControlledListing()
        let fixture = try await RevealStoreFixture.make(loader: listing)
        defer { fixture.close() }
        let store = fixture.store, root = store.activeTab.url, item = try #require(store.sortedItems.last)
        store.reveal([item.url], in: root)
        try await fixture.settled()
        let request = try #require(store.pendingRevealVisibility)
        store.refreshAfterActivation()
        try await fixture.settled()
        #expect(store.pendingRevealVisibility == request)
        #expect(store.acknowledgeRevealVisibility(request))
        store.refresh()
        try await fixture.settled()
        #expect(store.pendingRevealVisibility == nil)
        #expect(store.activeTab.revealVisibilityGeneration == request.id)
        store.reveal([item.url], in: root)
        try await fixture.settled()
        await listing.replaceLastItem()
        store.refreshAfterActivation()
        try await fixture.settled()
        #expect(store.activeTab.revealVisibilityRequest == nil, "The same path with another identity is not the reveal target")
        store.reveal([item.url], in: root)
        try await fixture.settled()
        await listing.removeLastItem()
        store.refreshAfterActivation()
        try await fixture.settled()
        #expect(store.activeTab.revealVisibilityRequest == nil)
    }

    @Test
    func readyAttemptConsumesEvenWhenGeometryFailsAndInvalidatedWorkDoesNotRun() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, item = try #require(store.sortedItems.last)
        store.reveal([item.url], in: store.activeTab.url)
        try await fixture.settled()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = try #require(window.contentView)
        let coordinator = RevealVisibilityCoordinator()
        var attempts = 0
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: false) }
        try await fixture.waitUntil { store.pendingRevealVisibility == nil }
        #expect(attempts == 1 && coordinator.lastAttemptWasVisible == false)
        coordinator.schedule(); coordinator.schedule()
        await fixture.drainUpdates()
        #expect(attempts == 1, "Failed diagnostic must not create an endless scroll trap")

        store.reveal([item.url], in: store.activeTab.url)
        try await fixture.settled()
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: true) }
        coordinator.invalidate()
        await fixture.drainUpdates()
        #expect(attempts == 1 && store.pendingRevealVisibility != nil)
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: true) }
        store.navigate(to: store.activeTab.url)
        await fixture.drainUpdates()
        #expect(attempts == 1, "A superseded queued view callback must do nothing")
    }

    @Test
    func queuedAttemptDefersAfterModeOrRenderedOrderChanges() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, item = try #require(store.sortedItems.last)
        let oldRestore = ViewportRestorationGuard(store: store)
        store.setViewMode(.largeIcons)
        #expect(!oldRestore.allowsRestoration(in: store), "Mode alone invalidates restoration, without a pending reveal")
        store.setViewMode(.details)
        store.reveal([item.url], in: store.activeTab.url)
        try await fixture.settled()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = try #require(window.contentView), coordinator = RevealVisibilityCoordinator()
        var attempts = 0
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: true) }
        store.setViewMode(.largeIcons)
        await fixture.drainUpdates()
        #expect(attempts == 0 && store.pendingRevealVisibility != nil)
        #expect(!oldRestore.allowsRestoration(in: store))
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: true) }
        store.setSortAscending(false)
        await fixture.drainUpdates()
        #expect(attempts == 0 && store.pendingRevealVisibility != nil)
        coordinator.update(store: store, view: view) { _ in attempts += 1; return .attempted(visible: true) }
        try await fixture.waitUntil { store.pendingRevealVisibility == nil }
        #expect(attempts == 1)
    }

    @Test
    func loadCommittingInBackgroundRetainsIntentAndFailedRevealDoesNotPublishOne() async throws {
        let listing = RevealControlledListing()
        let fixture = try await RevealStoreFixture.make(loader: listing)
        defer { fixture.close() }
        let store = fixture.store, firstTab = store.activeTabID, root = store.activeTab.url
        let target = try #require(store.sortedItems.last)
        store.openTab(at: root.appendingPathComponent("Other", isDirectory: true))
        try await fixture.settled()
        let otherTab = store.activeTabID
        store.activateTab(firstTab)
        await listing.holdReads()
        store.reveal([target.url], in: root)
        try await listing.waitForHeldReads(1)
        store.activateTab(otherTab)
        await listing.releaseReads()
        try await fixture.allSettled()
        #expect(store.pendingRevealVisibility == nil)
        let pending = try #require(store.tabs.first(where: { $0.id == firstTab })?.revealVisibilityRequest)
        #expect(pending.itemID == target.id)
        store.activateTab(firstTab)
        #expect(store.pendingRevealVisibility == pending)
        await listing.failReads()
        store.reveal([target.url], in: root)
        try await fixture.waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.errorMessage != nil)
        #expect(store.activeTab.revealVisibilityRequest == nil)
    }

    @Test
    func notReadyWaitsForLifecycleAndRestoreGuardTracksConsumedGeneration() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, item = try #require(store.sortedItems.last)
        let ordinaryRestore = ViewportRestorationGuard(store: store)
        #expect(ordinaryRestore.allowsRestoration(in: store))
        store.reveal([item.url], in: store.activeTab.url)
        try await fixture.settled()
        let pendingRestore = ViewportRestorationGuard(store: store)
        let coordinator = RevealVisibilityCoordinator()
        let view = NSView(frame: .zero)
        var attempts = 0, ready = false
        coordinator.update(store: store, view: view) { _ in
            attempts += 1
            return ready ? .attempted(visible: true) : .notReady
        }
        await fixture.drainUpdates()
        #expect(attempts == 0 && store.pendingRevealVisibility != nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.invalidate(); window.close() }
        window.contentView = view
        coordinator.schedule()
        try await fixture.waitUntil { attempts == 1 }
        await fixture.drainUpdates()
        #expect(attempts == 1 && store.pendingRevealVisibility != nil, "Not-ready does not poll")
        ready = true
        coordinator.schedule()
        try await fixture.waitUntil { store.pendingRevealVisibility == nil }
        #expect(attempts == 2)
        #expect(!pendingRestore.allowsRestoration(in: store))
        #expect(!ordinaryRestore.allowsRestoration(in: store), "A newer consumed reveal still invalidates the old anchor")
        let consumedRestore = ViewportRestorationGuard(store: store)
        #expect(consumedRestore.allowsRestoration(in: store), "Ordinary scale restoration after consumption remains allowed")
    }

    /// Actual UI crash 332c0f: SwiftUI can dismantle an outgoing collection
    /// before removing its still-attached scroll view. Its queued mode/location
    /// fallback must not use retained Swift rows after the native cache empties.
    @Test
    func dismantledCollectionDoesNotRunQueuedLocationReveal() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, target = try #require(store.sortedItems.last)
        store.setViewMode(.list)
        store.setSelection([target.id], focusedID: target.id)
        let coordinator = FileCollectionView.Coordinator(store: store)
        let scroll = coordinator.makeScrollView()
        let view = try #require(coordinator.collection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.dismantle(); window.close() }
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        window.contentView = scroll
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(view.numberOfItems(inSection: 0) == 240)
        // No await before teardown: makeScrollView's real fallback is queued.
        coordinator.dismantle()
        view.reloadData()
        view.layoutSubtreeIfNeeded()
        let nativeCount = view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : 0
        #expect(nativeCount == 0 && view.items.count == 240)
        #expect(view.window === window, "Retain the observed still-attached teardown interval")
        await fixture.drainUpdates()
        #expect(store.currentSelection.selectedIDs == [target.id])
        // The same native readiness boundary protects direct restoration and
        // explicit requests if invoked while retained Swift rows still exist.
        view.reveal(target.id)
        view.scrollItemToTop(target.id)
        switch view.revealRequestedItem(target.id) {
        case .notReady: break
        case .attempted: Issue.record("A dismantled native cache must not be treated as ready")
        }
    }

    @Test
    func ordinaryCollectionFallbackStillRevealsReadySelectedRow() async throws {
        let fixture = try await RevealStoreFixture.make()
        defer { fixture.close() }
        let store = fixture.store, target = try #require(store.sortedItems.last)
        store.setViewMode(.list)
        store.setSelection([target.id], focusedID: target.id)
        let coordinator = FileCollectionView.Coordinator(store: store)
        let scroll = coordinator.makeScrollView()
        let view = try #require(coordinator.collection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { coordinator.dismantle(); window.close() }
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        window.contentView = scroll
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        try await fixture.waitUntil {
            guard let frame = view.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 239, section: 0))?.frame else { return false }
            return view.visibleRect.insetBy(dx: -1, dy: -1).contains(frame)
        }
        #expect(store.pendingRevealVisibility == nil)
        #expect(store.currentSelection.selectedIDs == [target.id])
    }
}

@MainActor
private final class RevealVisibilityFixture {
    let store: ExplorerStore
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let pasteboard: NSPasteboard

    private init(store: ExplorerStore, mode: FolderViewMode, pasteboard: NSPasteboard) {
        self.store = store
        self.pasteboard = pasteboard
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(RevealVisibilityContent(store: store)))
        window.contentView = host
        window.orderFront(nil)
        layout()
    }

    static func make(mode: FolderViewMode, loader: any DirectoryListing = RevealVisibilityListing()) async throws -> RevealVisibilityFixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-reveal-visibility-\(UUID().uuidString)", isDirectory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("reveal-visibility-\(UUID().uuidString)"))
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
                                  clipboard: TransferClipboard(pasteboard: pasteboard))
        let deadline = Date().addingTimeInterval(3)
        while store.activeTab.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        store.setViewMode(mode)
        let fixture = RevealVisibilityFixture(store: store, mode: mode, pasteboard: pasteboard)
        try await fixture.waitUntil {
            if let table = fixture.table { return table.numberOfRows == 240 && table.visibleRect.height > 0 }
            if let collection = fixture.collection { return collection.numberOfItems(inSection: 0) == 240 && collection.visibleRect.height > 0 }
            return false
        }
        return fixture
    }

    var table: ExplorerTableView? { descendant(in: host) }
    var collection: ExplorerFileCollectionView? { descendant(in: host) }

    func nativeSelectionContains(_ id: String) -> Bool {
        if let table, let row = table.itemIDs.firstIndex(of: id) { return table.selectedRowIndexes.contains(row) }
        if let collection, let row = collection.items.firstIndex(where: { $0.id == id }) {
            return collection.selectionIndexPaths.contains(IndexPath(item: row, section: 0))
        }
        return false
    }

    private func geometry(_ id: String) -> (target: NSRect, viewport: NSRect)? {
        if let table, let scroll = table.enclosingScrollView, let row = table.itemIDs.firstIndex(of: id) {
            let bounds = scroll.contentView.bounds
            let insets = scroll.contentView.contentInsets
            let viewport = NSRect(x: bounds.minX + insets.left, y: bounds.minY + insets.top,
                                  width: bounds.width - insets.left - insets.right,
                                  height: bounds.height - insets.top - insets.bottom)
            let rowRect = table.rect(ofRow: row)
            // A Details row spans every column; only its vertical extent must fit.
            return (NSRect(x: viewport.minX, y: rowRect.minY, width: viewport.width, height: rowRect.height), viewport)
        }
        if let collection, let row = collection.items.firstIndex(where: { $0.id == id }),
           let attributes = collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: row, section: 0)) {
            return (attributes.frame, collection.visibleRect)
        }
        return nil
    }

    func isVisible(_ id: String) -> Bool {
        guard let geometry = geometry(id), geometry.viewport.width > 0, geometry.viewport.height > 0 else { return false }
        return geometry.viewport.insetBy(dx: -1, dy: -1).contains(geometry.target)
    }

    func geometryDescription(_ id: String) -> String {
        guard let geometry = geometry(id) else { return "target/view missing" }
        return "target=\(geometry.target), viewport=\(geometry.viewport)"
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
        if let scroll = table?.enclosingScrollView ?? collection?.enclosingScrollView {
            scroll.tile()
            scroll.layoutSubtreeIfNeeded()
            scroll.documentView?.layoutSubtreeIfNeeded()
        }
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            layout()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        layout()
        return condition()
    }

    func waitUntil(_ condition: () -> Bool) async throws { try #require(await waitFor(condition)) }

    func scrollToBeginning() {
        guard let scroll = table?.enclosingScrollView ?? collection?.enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: -scroll.contentView.contentInsets.left,
                                             y: -scroll.contentView.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func drainUpdates() async {
        for _ in 0..<5 { layout(); await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
    }

    func close() {
        store.cancelLoads()
        window.contentView = nil
        window.close()
        pasteboard.releaseGlobally()
    }

    private func descendant<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match: T = descendant(in: child) { return match } }
        return nil
    }
}

private struct RevealVisibilityContent: View {
    @ObservedObject var store: ExplorerStore
    var body: some View {
        Group {
            if store.activeTab.viewMode == .details { DetailsTableView(store: store) }
            else { FileCollectionView(store: store) }
        }
    }
}

private struct RevealVisibilityListing: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        (0..<240).map { index in
            let name = String(format: "Item-%03d.txt", index)
            return FileItem(url: url.appendingPathComponent(name), name: name, isDirectory: false,
                            isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text Document",
                            identity: LocalFileIdentity(device: 1, inode: UInt64(index + 100), birthSeconds: 1, birthNanoseconds: 0))
        }
    }
}

@MainActor
private final class RevealStoreFixture {
    let store: ExplorerStore
    private let pasteboard: NSPasteboard

    private init(loader: any DirectoryListing, observer: (any DirectoryObserving)?) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-reveal-store-\(UUID().uuidString)", isDirectory: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("reveal-store-\(UUID().uuidString)"))
        store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer,
                              clipboard: TransferClipboard(pasteboard: pasteboard))
    }

    static func make(loader: any DirectoryListing = RevealVisibilityListing(),
                     observer: (any DirectoryObserving)? = nil) async throws -> RevealStoreFixture {
        let fixture = RevealStoreFixture(loader: loader, observer: observer)
        try await fixture.settled()
        return fixture
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    func settled() async throws {
        try await waitUntil { self.store.activeTab.hasLoaded && !self.store.activeTab.isLoading && !self.store.activeTab.isRefreshing }
    }

    func allSettled() async throws {
        try await waitUntil { self.store.tabs.allSatisfy { $0.hasLoaded && !$0.isLoading && !$0.isRefreshing } }
    }

    func drainUpdates() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
    }

    func close() { store.cancelLoads(); pasteboard.releaseGlobally() }
}

private struct RevealQuietObserver: DirectoryObserving {
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> { AsyncThrowingStream { _ in } }
}

private actor RevealControlledListing: DirectoryListing {
    private var holdsReads = false
    private var heldReads: [(DirectorySnapshot, CheckedContinuation<DirectorySnapshot, Never>)] = []
    private var replacesLast = false
    private var removesLast = false
    private var failsReads = false

    func holdReads() { holdsReads = true }
    func replaceLastItem() { replacesLast = true }
    func removeLastItem() { removesLast = true }
    func failReads() { failsReads = true }
    func releaseReads() {
        holdsReads = false
        let pending = heldReads
        heldReads = []
        for (snapshot, continuation) in pending { continuation.resume(returning: snapshot) }
    }
    func waitForHeldReads(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while heldReads.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(heldReads.count >= count)
    }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        if failsReads { throw CocoaError(.fileReadNoSuchFile) }
        var items = try await RevealVisibilityListing().contents(of: url, showHidden: showHidden)
        if removesLast { items.removeLast() }
        else if replacesLast, let last = items.popLast() {
            items.append(FileItem(url: last.url, name: last.name, isDirectory: false, isSymbolicLink: false,
                                  size: 1, modifiedAt: nil, kind: last.kind,
                                  identity: LocalFileIdentity(device: 1, inode: 9000, birthSeconds: 1, birthNanoseconds: 0)))
        }
        let snapshot = DirectorySnapshot(items: items,
            directoryIdentity: LocalFileIdentity(device: 1, inode: 99, birthSeconds: 1, birthNanoseconds: 0))
        if holdsReads { return await withCheckedContinuation { heldReads.append((snapshot, $0)) } }
        return snapshot
    }
}
