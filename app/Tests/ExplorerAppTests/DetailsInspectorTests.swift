import AppKit
import Testing
@testable import ExplorerApp
import ExplorerCore

private actor InspectorDriver: DirectoryListing, FileOperating, FileRecovering {
    private(set) var reads: [URL] = []
    private(set) var writes = 0
    private(set) var trashes = 0
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingWrite: CheckedContinuation<FileOperationResult, Error>?
    private var pendingTrash: CheckedContinuation<TrashResult, Error>?
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingReads[reads.count] = $0; reads.append(url) }
    }
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await holdWrite()
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await holdWrite()
    }
    private func holdWrite() async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingWrite = $0; writes += 1 }
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTrash = $0; trashes += 1 }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("This fixture never restores an item.")
    }
    func finish(_ index: Int, items: [FileItem], identity: LocalFileIdentity) {
        pendingReads.removeValue(forKey: index)?.resume(returning: DirectorySnapshot(items: items, directoryIdentity: identity))
    }
    func failRead(_ index: Int) { pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func failTrash() { let call = pendingTrash; pendingTrash = nil; call?.resume(throwing: CancellationError()) }
    func shutdown() {
        closed = true
        let calls = Array(pendingReads.values)
        pendingReads.removeAll()
        for call in calls { call.resume(throwing: CancellationError()) }
        let write = pendingWrite; pendingWrite = nil
        write?.resume(throwing: CancellationError())
        failTrash()
    }
}

@MainActor
private final class InspectorFixture {
    let driver = InspectorDriver()
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerDetailsInspectorTests-\(UUID())"))
    let store: ExplorerStore
    init(url: URL) {
        store = ExplorerStore(initialURL: url, loader: driver, homeURL: url, operations: driver,
            clipboard: TransferClipboard(pasteboard: board), recovery: driver)
    }
    func stop() {
        store.cancelLoads(); store.cancelTrash()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// FR-PREVIEW-003 / EV-0313–0315 / AT-PREVIEW-003 selected-item details, and
/// FR-PREVIEW-002 / EV-0277–0279 / AT-PREVIEW-002 Properties dispatch subsets.
/// Multi-selection, guards and responsive widths are explicit native policies;
/// model tests do not establish rendered pane geometry or keyboard/AX equivalence.
@MainActor
final class DetailsInspectorTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-inspector-model", isDirectory: true)
    private func identity(_ inode: UInt64 = 100) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String, inode: UInt64 = 101, under folder: URL? = nil) -> FileItem {
        FileItem(url: (folder ?? root).appendingPathComponent(name), name: name,
                 isDirectory: false, isSymbolicLink: false, size: 24,
                 modifiedAt: Date(timeIntervalSince1970: 100), kind: "Text Document", identity: identity(inode))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Inspector did not reach its expected state before the bounded deadline")
    }
    private func ready() async throws -> InspectorFixture {
        let fixture = InspectorFixture(url: root)
        try await waitUntil { await fixture.driver.reads.count == 1 }
        await fixture.driver.finish(0, items: [item("Alpha.txt"), item("Beta.txt", inode: 102)], identity: identity())
        try await waitUntil { !fixture.store.activeTab.isLoading }
        return fixture
    }

    @Test
    func onlySelectedRowsSupplyDetailsAndSingleSelectionEnablesProperties() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, first = item("Alpha.txt"), second = item("Beta.txt", inode: 102)
        var requests: [FileItem] = []
        store.onShowProperties = { requests.append($0) }
        store.setSelection([], focusedID: first.id)
        #expect(store.activeTab.selection.focusedID == first.id)
        #expect(store.detailSelection.isEmpty && !store.canShowProperties)
        store.showProperties()
        #expect(requests.isEmpty)
        store.setSelection([first.id], focusedID: second.id)
        #expect(store.detailSelection == [first] && store.canShowProperties)
        store.showProperties()
        #expect(requests == [first])
        // NATIVE-P18A: several selected items open one summary panel instead.
        var groups: [[FileItem]] = []
        store.onShowMultipleProperties = { groups.append($0) }
        store.setSelection([first.id, second.id], focusedID: first.id)
        #expect(Set(store.detailSelection.map(\.id)) == [first.id, second.id])
        #expect(store.canShowProperties)
        store.showProperties()
        #expect(requests == [first])
        #expect(groups.map { Set($0.map(\.id)) } == [[first.id, second.id]])
        store.setSelection([], focusedID: second.id)
        #expect(store.detailSelection.isEmpty && !store.canShowProperties)
    }

    @Test
    func togglingAndShowingPropertiesCaptureTheItemWithoutChangingBrowsingOrReadingAgain() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        let tabID = store.activeTabID, selection = store.activeTab.selection
        let history = store.activeTab.history, rows = store.activeTab.items
        var captured: FileItem?
        store.onShowProperties = { captured = $0 }
        #expect(!store.showsDetailsPane)
        store.toggleDetailsPane()
        #expect(store.showsDetailsPane)
        store.showProperties()
        store.toggleDetailsPane()
        #expect(!store.showsDetailsPane && captured == first)
        #expect(store.activeTabID == tabID && store.activeTab.history == history)
        #expect(store.activeTab.selection == selection && store.activeTab.items == rows && store.nameEdit == nil)
        #expect(await fixture.driver.reads.count == 1)
        #expect(await fixture.driver.writes == 0)
        store.setSelection([item("Beta.txt", inode: 102).id], focusedID: nil)
        #expect(captured == first)
    }

    @Test
    func paneVisibilityBelongsToTheWindowWhileItsSelectionFollowsTheActiveTab() async throws {
        let fixture = try await ready(), otherWindow = try await ready()
        defer { fixture.stop(); otherWindow.stop() }
        let store = fixture.store, driver = fixture.driver, first = item("Alpha.txt")
        let firstTab = store.activeTabID
        store.setSelection([first.id], focusedID: first.id)
        store.toggleDetailsPane()
        let destination = root.appendingPathComponent("Second", isDirectory: true)
        let second = item("Second.txt", inode: 202, under: destination)
        store.openTab(at: destination)
        #expect(store.showsDetailsPane && store.detailSelection.isEmpty)
        try await waitUntil { await driver.reads.count == 2 }
        await driver.finish(1, items: [second], identity: identity(200))
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.detailSelection.isEmpty)
        store.setSelection([second.id], focusedID: second.id)
        #expect(store.detailSelection == [second])
        store.activateTab(firstTab)
        #expect(store.detailSelection == [first] && store.showsDetailsPane)
        #expect(!otherWindow.store.showsDetailsPane && otherWindow.store.detailSelection.isEmpty)
        #expect(await driver.reads.count == 2)
    }

    @Test
    func blockingLoadsAndUnavailableRowsCannotOpenPropertiesOrSupplyDetails() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        var requests = 0
        store.onShowProperties = { _ in requests += 1 }
        store.refresh()
        try await waitUntil { await driver.reads.count == 2 }
        #expect(store.activeTab.isLoading && store.detailSelection.isEmpty && !store.canShowProperties)
        store.showProperties()
        await driver.failRead(1)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.isUnavailable && !store.activeTab.items.isEmpty)
        #expect(store.detailSelection.isEmpty && !store.canShowProperties)
        store.setSelection([first.id], focusedID: first.id)
        store.showProperties()
        #expect(requests == 0)
    }

    @Test
    func failedNewDestinationRestoresCommittedDetailsAndRetainsItsRetryTarget() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, first = item("Alpha.txt")
        let destination = root.appendingPathComponent("Denied", isDirectory: true)
        let destinationItem = item("Destination.txt", inode: 202, under: destination)
        store.setSelection([first.id], focusedID: first.id)
        store.toggleDetailsPane()
        let history = store.activeTab.history, selection = store.activeTab.selection
        let committedItems = store.activeTab.items
        var properties: [FileItem] = []
        store.onShowProperties = { properties.append($0) }

        store.navigate(to: destination)
        try await waitUntil { await driver.reads.count == 2 }
        #expect(await driver.reads[1] == destination)
        #expect(store.detailSelection.isEmpty && !store.canShowProperties)
        #expect(store.activeTab.history == history && store.activeTab.selection == selection)
        store.showProperties()
        #expect(properties.isEmpty)
        await driver.failRead(1)
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.errorMessage != nil }

        // Failure leaves the original committed folder available. Its selection is
        // valid again; it must not be presented as belonging to the denied destination.
        #expect(store.activeTab.url == root && !store.activeTab.isUnavailable)
        #expect(store.activeTab.history == history && store.activeTab.selection == selection)
        #expect(store.activeTab.items == committedItems && store.showsDetailsPane)
        #expect(store.detailSelection == [first] && store.canShowProperties)
        #expect(store.activeTab.errorMessage?.contains(destination.path) == true)
        store.showProperties()
        #expect(properties == [first])

        store.retry()
        try await waitUntil { await driver.reads.count == 3 }
        #expect(await driver.reads[2] == destination)
        #expect(store.detailSelection.isEmpty && !store.canShowProperties)
        #expect(store.activeTab.history == history && store.activeTab.selection == selection)
        store.showProperties()
        #expect(properties == [first])
        await driver.finish(2, items: [destinationItem], identity: identity(200))
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.url == destination }
        #expect(store.activeTab.history.backStack == [root] && store.activeTab.history.forwardStack.isEmpty)
        #expect(store.activeTab.items == [destinationItem] && store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.errorMessage == nil && store.detailSelection.isEmpty && !store.canShowProperties)
        store.setSelection([destinationItem.id], focusedID: destinationItem.id)
        #expect(store.detailSelection == [destinationItem] && store.canShowProperties)
        #expect(await driver.reads.count == 3)
    }

    @Test
    func aDraftSuppressesDetailsAndPropertiesWithoutChangingItsTextOrVisibility() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        store.toggleDetailsPane()
        store.beginRename()
        let draft = try #require(store.nameEdit)
        store.updateProposedName("unfinished.txt", sessionID: draft.id)
        var shown = false
        store.onShowProperties = { _ in shown = true }
        store.toggleDetailsPane()
        store.showProperties()
        #expect(store.detailSelection.isEmpty && !store.canShowProperties && !shown)
        #expect(store.showsDetailsPane && store.nameEdit?.id == draft.id)
        #expect(store.nameEdit?.proposedName == "unfinished.txt")
        #expect(await fixture.driver.writes == 0)
        store.cancelNameEdit()
        #expect(store.detailSelection == [first] && store.canShowProperties && store.showsDetailsPane)
    }

    @Test
    func anInFlightWriteWithoutAnEditorBlocksInspectorCommandsUntilReconciled() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        store.toggleDetailsPane()
        var shown = false
        store.onShowProperties = { _ in shown = true }
        store.trashSelection()
        try await waitUntil { await driver.trashes == 1 }
        #expect(store.isPerformingOperation && store.nameEdit == nil && !store.activeTab.isLoading)
        store.toggleDetailsPane()
        store.showProperties()
        #expect(store.detailSelection.isEmpty && !store.canShowProperties && !shown)
        #expect(store.showsDetailsPane)
        await driver.failTrash()
        try await waitUntil { await driver.reads.count == 2 }
        await driver.finish(1, items: [first], identity: identity())
        try await waitUntil { !store.isPerformingOperation }
        store.setSelection([first.id], focusedID: first.id)
        #expect(store.detailSelection == [first] && store.canShowProperties)
    }

    @Test
    func recoveryPanelBlocksInspectorCommandsAndDismissRestoresSelectedDetails() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        store.toggleDetailsPane()
        store.showRecovery()
        #expect(store.isShowingRecovery)
        var shown = false
        store.onShowProperties = { _ in shown = true }
        store.toggleDetailsPane()
        store.showProperties()
        #expect(store.detailSelection.isEmpty && !store.canShowProperties && !shown && store.showsDetailsPane)
        store.dismissRecovery()
        #expect(store.detailSelection == [first] && store.canShowProperties)
        #expect(await fixture.driver.reads.count == 1)
    }

    @Test
    func aPassiveRefreshKeepsTheCommittedSelectionAvailableToTheInspector() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, first = item("Alpha.txt")
        store.setSelection([first.id], focusedID: first.id)
        var captured: FileItem?
        store.onShowProperties = { captured = $0 }
        store.refreshAfterActivation()
        try await waitUntil { await driver.reads.count == 2 }
        #expect(store.activeTab.isRefreshing && !store.activeTab.isLoading)
        #expect(store.detailSelection == [first] && store.canShowProperties)
        store.showProperties()
        #expect(captured == first)
        await driver.finish(1, items: [first], identity: identity())
        try await waitUntil { !store.activeTab.isRefreshing }
        #expect(store.detailSelection == [first])
        #expect(await driver.reads.count == 2)
    }

    @Test(arguments: [CGFloat(185), 377, 743, 899, 900, 1127, 1600])
    func responsivePaneWidthLeavesRoomForTheListOnlyAtSupportedWindowWidths(_ width: CGFloat) {
        let layout = ExplorerLayout(width: width)
        #expect(layout.detailsPaneWidth == 300)
        #expect(layout.canShowDetailsPane == (width >= 900))
        if layout.canShowDetailsPane {
            let sidebar = layout.showsSidebar ? layout.sidebarWidth + 1 : 0
            let availableListWidth = width - sidebar - layout.detailsPaneWidth - 1
            #expect(availableListWidth >= 286)
        }
    }
}
