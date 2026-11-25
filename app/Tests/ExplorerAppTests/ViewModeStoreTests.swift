import AppKit
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Holds reads and a synthetic mutation; no real folder or system Trash is accessed.
private actor ViewModeDriver: DirectoryListing, FileOperating, FileRecovering {
    private(set) var reads: [URL] = []
    private(set) var writes = 0
    private(set) var trashes = 0
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
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
        writes += 1
        throw FileOperationError.unsupported("Changing a view must not submit a file operation.")
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writes += 1
        throw FileOperationError.unsupported("Changing a view must not submit a file operation.")
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTrash = $0; trashes += 1 }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("This fixture does not restore files.")
    }
    func finish(_ index: Int, items: [FileItem], identity: LocalFileIdentity) {
        pendingReads.removeValue(forKey: index)?.resume(returning: DirectorySnapshot(items: items, directoryIdentity: identity))
    }
    func fail(_ index: Int) {
        pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
    func cancelTrash() {
        let call = pendingTrash; pendingTrash = nil
        call?.resume(throwing: CancellationError())
    }
    func shutdown() {
        closed = true
        let calls = Array(pendingReads.values)
        pendingReads.removeAll()
        for call in calls { call.resume(throwing: CancellationError()) }
        cancelTrash()
    }
}

@MainActor
private final class ViewModeFixture {
    let driver = ViewModeDriver()
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerViewModeTests-\(UUID())"))
    let store: ExplorerStore
    init(url: URL, tab: BrowserTab? = nil) {
        store = ExplorerStore(tab: tab ?? BrowserTab(url: url), loader: driver, homeURL: url,
            operations: driver, clipboard: TransferClipboard(pasteboard: board), recovery: driver)
    }
    func stop() {
        store.cancelLoads(); store.cancelTrash()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// FR-VIEW-001/008/010 / EV-0304–0307, EV-0316–0331, EV-0337 / corresponding
/// AT-VIEW-001/008/010 model subsets. This suite proves state retention, not keyboard
/// routing or rendered layouts. Per-tab modes and duplication/detachment continuity
/// are native policies; EV-0379/0386 establish those tab actions' locations only.
@MainActor
final class ViewModeStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-view-mode-model", isDirectory: true)
    private let modes: [FolderViewMode] = [.extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons,
                                         .list, .details, .tiles, .content]
    private func identity(_ inode: UInt64 = 100) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func items(in folder: URL) -> [FileItem] {
        ["Alpha.txt", "Beta.txt", "Gamma.txt"].enumerated().map { index, name in
            FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
                     isSymbolicLink: false, size: Int64(3 - index), modifiedAt: nil,
                     kind: "Text Document", identity: identity(UInt64(101 + index)))
        }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "View-mode state did not settle before the bounded deadline")
    }
    private func settle(_ fixture: ViewModeFixture, read index: Int, at url: URL) async throws {
        try await waitUntil { await fixture.driver.reads.count == index + 1 }
        #expect(await fixture.driver.reads[index] == url)
        await fixture.driver.finish(index, items: items(in: url), identity: identity())
        try await waitUntil { !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing }
    }
    private func ready() async throws -> ViewModeFixture {
        let fixture = ViewModeFixture(url: root)
        try await settle(fixture, read: 0, at: root)
        return fixture
    }

    @Test(arguments: [BrowserPage.home, .tag("Project"), .thisMac])
    func fixedPagesPreserveTheFolderSortAndViewMode(_ page: BrowserPage) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        store.setViewMode(.tiles)
        store.sort(by: .size)
        store.setSortAscending(false)
        let sort = store.activeTab.sort
        store.navigate(to: page.url)
        #expect(!store.canChangeViewMode && store.canToggleDetailsPane)
        store.setViewMode(.largeIcons)
        store.sort(by: .name)
        store.setSortAscending(true)
        #expect(store.activeTab.viewMode == .tiles && store.activeTab.sort == sort)
        store.back()
        try await settle(fixture, read: 1, at: root)
        #expect(store.canChangeViewMode && store.activeTab.viewMode == .tiles && store.activeTab.sort == sort)
    }

    @Test
    func numberedModesHaveTheReferenceNamesAndNewTabsDefaultToDetails() {
        let expected = ["Extra large icons", "Large icons", "Medium icons", "Small icons",
                        "List", "Details", "Tiles", "Content"]
        #expect(modes.map(\.rawValue) == Array(1...8))
        #expect(modes.map(\.title) == expected)
        #expect(BrowserTab(url: root).viewMode == .details)
    }

    @Test
    func allEightModesPreserveSelectionSortHistoryAndFailedNavigationWithoutEnumerating() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        store.navigate(to: folder)
        try await settle(fixture, read: 1, at: folder)
        let entries = items(in: folder)
        store.setSelection([entries[0].id, entries[2].id], focusedID: entries[2].id, anchorID: entries[0].id)
        store.sort(by: .size)
        store.setSortAscending(false)
        let denied = folder.appendingPathComponent("Denied", isDirectory: true)
        store.navigate(to: denied)
        try await waitUntil { await driver.reads.count == 3 }
        await driver.fail(2)
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.errorMessage != nil }
        let before = store.activeTab, sorted = store.sortedItems
        try #require(before.accessIssue != nil && before.history.backStack == [root])
        for mode in modes {
            #expect(store.canChangeViewMode)
            store.setViewMode(mode)
            let after = store.activeTab
            #expect(after.viewMode == mode && after.id == before.id && after.url == folder)
            #expect(after.selection == before.selection && after.history == before.history)
            #expect(after.sort == before.sort && after.items == before.items && store.sortedItems == sorted)
            #expect(after.errorMessage == before.errorMessage && after.accessIssue == before.accessIssue)
            #expect(after.directoryIdentity == before.directoryIdentity && !after.isUnavailable)
            #expect(await driver.reads.count == 3)
            #expect(await driver.writes == 0)
        }
        store.retry()
        try await waitUntil { await driver.reads.count == 4 }
        #expect(await driver.reads[3] == denied)
        #expect(store.activeTab.viewMode == .content)
        await driver.finish(3, items: items(in: denied), identity: identity(200))
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == denied && store.activeTab.viewMode == .content)
        #expect(store.activeTab.errorMessage == nil && store.activeTab.history.backStack == [root, folder])
    }

    @Test
    func changingModeDuringNavigationKeepsThePendingTargetAndModeSurvivesBackAndForward() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver
        let destination = root.appendingPathComponent("Child", isDirectory: true)
        store.setViewMode(.largeIcons)
        store.navigate(to: destination)
        try await waitUntil { await driver.reads.count == 2 }
        #expect(store.activeTab.isLoading && store.canChangeViewMode)
        store.setViewMode(.tiles)
        #expect(store.activeTab.isLoading && store.activeTab.url == root)
        #expect(await driver.reads.count == 2)
        await driver.finish(1, items: items(in: destination), identity: identity(200))
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == destination && store.activeTab.viewMode == .tiles)
        store.back()
        try await settle(fixture, read: 2, at: root)
        #expect(store.activeTab.viewMode == .tiles)
        store.setViewMode(.smallIcons)
        store.forward()
        try await settle(fixture, read: 3, at: destination)
        #expect(store.activeTab.viewMode == .smallIcons && store.activeTab.history.backStack == [root])
    }

    @Test
    func tabModesAreIndependentDuplicatesInheritAndNewTabsStartInDetails() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let firstID = store.activeTabID
        store.setViewMode(.largeIcons)
        store.openTab(at: root)
        #expect(store.activeTab.viewMode == .details)
        try await settle(fixture, read: 1, at: root)
        let secondID = store.activeTabID
        store.setViewMode(.tiles)
        store.activateTab(firstID)
        #expect(store.activeTab.viewMode == .largeIcons)
        store.duplicateTab(secondID)
        let duplicateID = store.activeTabID
        #expect(duplicateID != secondID && store.activeTab.viewMode == .tiles)
        try await settle(fixture, read: 2, at: root)
        store.setViewMode(.list)
        store.activateTab(secondID)
        #expect(store.activeTab.viewMode == .tiles)
        store.activateTab(duplicateID)
        #expect(store.activeTab.viewMode == .list)
        store.activateTab(firstID)
        #expect(store.activeTab.viewMode == .largeIcons)
        let destination = root.appendingPathComponent("New", isDirectory: true)
        store.openTab(at: destination)
        #expect(store.activeTab.viewMode == .details)
        try await settle(fixture, read: 3, at: destination)
        #expect(await fixture.driver.reads.count == 4)
    }

    @Test
    func detachingTransfersTheModeAndReceivingRefreshDoesNotResetIt() async throws {
        let fixture = try await ready()
        var receiver: ViewModeFixture?
        defer { fixture.stop(); receiver?.stop() }
        let store = fixture.store
        let retainedID = store.activeTabID
        store.setViewMode(.mediumIcons)
        let destination = root.appendingPathComponent("Detached", isDirectory: true)
        store.openTab(at: destination)
        try await settle(fixture, read: 1, at: destination)
        let movingID = store.activeTabID, selected = items(in: destination)[1]
        store.setSelection([selected.id], focusedID: selected.id, anchorID: selected.id)
        store.setViewMode(.content)
        let before = store.activeTab
        store.onDetachTab = { tab, _ in receiver = ViewModeFixture(url: self.root, tab: tab) }
        store.detachTab(movingID)
        let target = try #require(receiver)
        #expect(target.store.activeTab.id == movingID && target.store.activeTab.viewMode == .content)
        #expect(target.store.activeTab.selection == before.selection && target.store.activeTab.history == before.history)
        #expect(store.activeTabID == retainedID && store.activeTab.viewMode == .mediumIcons)
        try await settle(target, read: 0, at: destination)
        #expect(target.store.activeTab.viewMode == .content && target.store.activeTab.selection == before.selection)
        target.store.setViewMode(.extraLargeIcons)
        #expect(store.activeTab.viewMode == .mediumIcons)
        #expect(await fixture.driver.reads.count == 2)
        #expect(await target.driver.reads.count == 1)
    }

    @Test(arguments: ["draft", "mutation", "recovery"])
    func protectedInteractionsRejectEveryModeWithoutCancellingOrSubmittingWork(_ state: String) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, selected = items(in: root)[0]
        store.setSelection([selected.id], focusedID: selected.id)
        store.setViewMode(.largeIcons)
        var draftID: UUID?
        switch state {
        case "draft":
            store.beginRename()
            draftID = try #require(store.nameEdit).id
            store.updateProposedName("unfinished.txt", sessionID: try #require(draftID))
        case "mutation":
            store.trashSelection()
            try await waitUntil { await driver.trashes == 1 }
            #expect(store.nameEdit == nil && store.isPerformingOperation && !store.activeTab.isLoading)
        default:
            store.showRecovery()
            #expect(store.isShowingRecovery)
        }
        let before = store.activeTab
        for mode in modes {
            #expect(!store.canChangeViewMode)
            store.setViewMode(mode)
            #expect(store.activeTab.viewMode == .largeIcons)
            #expect(store.activeTab.selection == before.selection && store.activeTab.history == before.history)
            #expect(await driver.reads.count == 1)
            #expect(await driver.writes == 0)
        }
        switch state {
        case "draft":
            #expect(store.nameEdit?.id == draftID && store.nameEdit?.proposedName == "unfinished.txt")
            store.cancelNameEdit()
        case "mutation":
            #expect(store.isPerformingOperation && store.trashProgress?.isCancelling == false)
            #expect(await driver.trashes == 1)
            await driver.cancelTrash()
            try await settle(fixture, read: 1, at: root)
            try await waitUntil { !store.isPerformingOperation }
        default:
            #expect(store.isShowingRecovery)
            store.dismissRecovery()
        }
        #expect(store.canChangeViewMode)
        store.setViewMode(.content)
        #expect(store.activeTab.viewMode == .content)
    }

    @Test
    func changingUnavailableFolderPresentationDoesNotClearTheErrorOrClaimRecoveredRows() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver
        store.refresh()
        try await waitUntil { await driver.reads.count == 2 }
        await driver.fail(1)
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.isUnavailable }
        let before = store.activeTab
        for mode in modes {
            store.setViewMode(mode)
            #expect(store.activeTab.viewMode == mode && store.activeTab.isUnavailable)
            #expect(store.activeTab.errorMessage == before.errorMessage && store.activeTab.accessIssue == before.accessIssue)
            #expect(store.activeTab.items == before.items && store.activeTab.selection == before.selection)
            #expect(!store.canCreateFolder && !store.canCopySelection)
            #expect(await driver.reads.count == 2)
        }
    }
}
