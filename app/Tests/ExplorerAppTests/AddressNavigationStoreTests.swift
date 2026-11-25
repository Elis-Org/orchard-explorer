import AppKit
import Darwin
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Synthetic reads intentionally survive cancellation; no fixture path is read
/// or mutated on disk and no system pasteboard or Trash is used.
private actor AddressStoreDriver: DirectoryListing, FileOperating, FileRecovering {
    private(set) var reads: [URL] = []
    private(set) var trashes = 0
    private(set) var writes = 0
    private var pending: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingTrash: CheckedContinuation<TrashResult, Error>?
    private var stopped = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !stopped else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pending[reads.count] = $0; reads.append(url) }
    }
    func finish(_ index: Int, items: [FileItem], identity: LocalFileIdentity) {
        pending.removeValue(forKey: index)?.resume(returning: DirectorySnapshot(items: items, directoryIdentity: identity))
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writes += 1
        throw FileOperationError.unsupported("Address actions must not create folders.")
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writes += 1
        throw FileOperationError.unsupported("Address actions must not rename files.")
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !stopped else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTrash = $0; trashes += 1 }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("This fixture does not restore files.")
    }
    func cancelTrash() {
        let call = pendingTrash; pendingTrash = nil
        call?.resume(throwing: CancellationError())
    }
    func shutdown() {
        stopped = true
        let calls = Array(pending.values)
        pending.removeAll()
        for call in calls { call.resume(throwing: CancellationError()) }
        cancelTrash()
    }
}

@MainActor
private final class AddressStoreFixture {
    let driver = AddressStoreDriver()
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerAddressTests-\(UUID())"))
    let store: ExplorerStore
    init(url: URL, detachedTab: BrowserTab? = nil,
         validateSearchResult: @escaping @Sendable (FilenameSearchResult) async throws -> Bool
            = FilenameSearchValidation.isCurrent, recentAddressHistory: RecentAddressHistory? = nil) {
        let clipboard = TransferClipboard(pasteboard: board)
        if let detachedTab {
            store = ExplorerStore(tab: detachedTab, loader: driver, homeURL: url,
                operations: driver, clipboard: clipboard, recovery: driver,
                validateSearchResult: validateSearchResult, recentAddressHistory: recentAddressHistory)
        } else {
            store = ExplorerStore(initialURL: url, loader: driver, homeURL: url,
                operations: driver, clipboard: clipboard, recovery: driver,
                validateSearchResult: validateSearchResult, recentAddressHistory: recentAddressHistory)
        }
    }
    func stop() {
        store.address.cancel(); store.cancelLoads(); store.cancelTrash()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// Ignores cancellation to exercise the final publication boundary.
private actor TypedAddressDriver {
    private(set) var requests: [URL] = []
    private(set) var cancellationAtReturn: [Int: Bool] = [:]
    private var replies: [Int: CheckedContinuation<FileActivationTarget, Never>] = [:]
    private var stopped = false

    func resolve(_ url: URL) async -> FileActivationTarget {
        guard !stopped else { return .unsupported }
        let index = requests.count
        let response: FileActivationTarget = await withCheckedContinuation {
            replies[index] = $0
            requests.append(url)
        }
        cancellationAtReturn[index] = Task.isCancelled
        return response
    }

    func complete(_ index: Int) {
        replies.removeValue(forKey: index)?.resume(returning: .ordinaryFile(requests[index]))
    }

    func shutdown() {
        stopped = true
        for reply in replies.values { reply.resume(returning: .unsupported) }
        replies.removeAll()
    }
}

private actor AddressActivationGate {
    private(set) var isWaiting = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var verdict: Bool?

    func validate() async -> Bool {
        if let verdict { return verdict }
        return await withCheckedContinuation {
            isWaiting = true
            waiters.append($0)
        }
    }

    func release(_ verdict: Bool) {
        self.verdict = verdict
        let pending = waiters
        waiters.removeAll()
        for reply in pending { reply.resume(returning: verdict) }
    }
}

/// NATIVE-P11 / MAC-052–055; FR-NAV-002/003/005 / AT-NAV-002/003/005
/// model subsets. UI-NAV-002 / EV-0404–0406 establishes address menu presence.
/// Success-only recents, clipboard formats and protected-operation guards are
/// native policies; these tests do not establish actual UI or Windows fidelity.
@MainActor
final class AddressNavigationStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/Explorer Address Store", isDirectory: true)
    private func identity(_ inode: UInt64 = 100) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func items(in url: URL) -> [FileItem] {
        ["Alpha.txt", "Beta.txt"].enumerated().map { index, name in
            FileItem(url: url.appendingPathComponent(name), name: name, isDirectory: false,
                isSymbolicLink: false, size: 10, modifiedAt: nil, kind: "Text Document",
                identity: identity(UInt64(101 + index)))
        }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Address store did not settle before the bounded deadline")
    }
    private func settle(_ fixture: AddressStoreFixture, read: Int, at url: URL) async throws {
        try await waitUntil { await fixture.driver.reads.count == read + 1 }
        #expect(await fixture.driver.reads[read] == url)
        await fixture.driver.finish(read, items: items(in: url), identity: identity())
        try await waitUntil { !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing }
    }
    private func ready(detachedTab: BrowserTab? = nil,
                       validateSearchResult: @escaping @Sendable (FilenameSearchResult) async throws -> Bool
                        = FilenameSearchValidation.isCurrent,
                       recentAddressHistory: RecentAddressHistory? = nil) async throws -> AddressStoreFixture {
        let fixture = AddressStoreFixture(url: root, detachedTab: detachedTab,
            validateSearchResult: validateSearchResult, recentAddressHistory: recentAddressHistory)
        do { try await settle(fixture, read: 0, at: root); return fixture }
        catch { fixture.stop(); throw error }
    }

    @Test
    func virtualPagesCommitWithoutReadingAndSupersedeAStaleDirectoryLoad() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let home = try #require(URL(string: "maxplorer-page://home"))
        let drives = try #require(URL(string: "maxplorer-page://this-mac"))
        let tag = try #require(URL(string: "maxplorer-page://home/tag/VMOpYW0gLyDDiXR1ZGU"))
        let folder = root.appendingPathComponent("Nested", isDirectory: true)
        let firstTab = store.activeTabID
        store.navigate(to: folder)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        store.navigate(to: home)
        #expect(store.activeTab.url == home)
        #expect(store.activeTab.title == "Home")
        #expect(store.activeTab.homeSection == .recent)
        #expect(store.activeTab.history.parent == nil)
        #expect(store.currentOperationContext == nil)
        #expect(!store.canPaste && !store.canCreateFolder)
        #expect(store.fileDropBinding(destinationURL: home) == nil)
        let stale = items(in: root)[0]
        let router = P18Router()
        store.applications = router
        store.setSelection([stale.id], focusedID: stale.id)
        #expect(!store.canDeleteSelection && !store.canCutSelection && !store.canRenameSelection)
        #expect(store.fileDragEntries(itemIDs: [stale.id]) == nil)
        store.beginRename()
        store.deleteSelection()
        store.activate(stale)
        #expect(store.nameEdit == nil && router.defaults.isEmpty)
        #expect(await fixture.driver.writes == 0)
        #expect(await fixture.driver.trashes == 0)
        await fixture.driver.finish(1, items: items(in: folder), identity: identity())
        let homeHistory = store.activeTab.history
        store.navigate(to: tag)
        #expect(store.activeTab.title == "Home" && store.activeTab.homeTag == "Téam / Étude")
        #expect(store.activeTab.history == homeHistory)
        store.navigate(to: folder)
        try await settle(fixture, read: 2, at: folder)
        store.back()
        #expect(store.activeTab.url == home && store.activeTab.homeSection == .tags)
        #expect(store.activeTab.homeTag == "Téam / Étude" && store.activeTab.history.parent == nil)
        store.openTab(at: drives)
        #expect(store.activeTab.history.parent == nil)
        #expect(store.canSearch)
        store.submitSearch("Music")
        #expect(store.activeSearch == nil)
        #expect(store.activeTab.folderTitle == "This Mac")
        #expect(store.matchesPageFilter("Music Drive") && !store.matchesPageFilter("Startup"))
        let drivesTab = store.activeTabID
        let activeGeneration = try #require(store.contextMenuLoadGeneration)
        store.refreshAfterActivation()
        #expect(store.contextMenuLoadGeneration == activeGeneration)
        store.refresh()
        #expect(store.contextMenuLoadGeneration != activeGeneration)
        #expect(store.activeTab.pageFilter == "Music")
        store.activateTab(firstTab)
        #expect(store.activeTab.url == home)
        #expect(store.activeTab.homeSection == .tags && store.activeTab.pageFilter.isEmpty)
        store.activateTab(drivesTab)
        #expect(store.activeTab.pageFilter == "Music")
        store.closeSearch()
        #expect(store.matchesPageFilter("Startup"))
        #expect(await fixture.driver.reads == [root, folder, folder])
        #expect(store.activeTab.items.isEmpty && store.activeTab.directoryIdentity == nil)
        #expect(store.tabShowing(root, alternatePaths: [""]) == nil)
    }

    @Test
    func inlineTagFiltersStayOnHomeAndSurviveFolderHistoryAndTabSwitches() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let home = BrowserPage.home.url
        store.navigate(to: home)
        let firstTab = store.activeTabID
        let history = store.activeTab.history
        let generation = store.activeTab.homeTagGeneration
        store.selectHomeSection(.tags)
        #expect(store.activeTab.homeTag == nil)
        #expect(store.activeTab.homeTagGeneration != generation)
        store.tagShortcuts.setVisible("Work / \"Q2\" *", visible: true)
        store.selectHomeTag("Work / \"Q2\" *")
        let selectedGeneration = store.activeTab.homeTagGeneration
        #expect(store.activeTab.url == home && store.activeTab.history == history)
        store.selectHomeTag("Work / \"Q2\" *")
        #expect(store.activeTab.homeTagGeneration != selectedGeneration && store.activeTab.homeTag == nil)
        store.selectHomeTag("Work / \"Q2\" *")
        let folder = root.appendingPathComponent("Tagged folder", isDirectory: true)
        store.navigate(to: folder)
        try await settle(fixture, read: 1, at: folder)
        store.back()
        #expect(store.activeTab.url == home && store.activeTab.homeTag == "Work / \"Q2\" *")
        store.duplicateTab(firstTab)
        #expect(store.activeTab.homeTag == "Work / \"Q2\" *")
        store.selectHomeTag(nil)
        #expect(store.activeTab.homeTag == nil)
        store.activateTab(firstTab)
        #expect(store.activeTab.homeTag == "Work / \"Q2\" *")
        store.selectHomeSection(.recent)
        store.selectHomeSection(.tags)
        #expect(store.activeTab.homeTag == nil)
        #expect(store.activeTab.homeTagGeneration != selectedGeneration)
        #expect(await fixture.driver.reads == [root, folder])
    }

    @Test func uncheckingShortcutClearsOnlyMatchingFiltersAcrossTabsAndWindowsSynchronously() {
        let shortcuts = FinderTagShortcuts()
        let first = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: shortcuts)
        let second = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: shortcuts)
        defer { first.cancelLoads(); second.cancelLoads() }
        let legacy = BrowserPage.tag("Résumé").url
        first.navigate(to: legacy)
        let original = first.activeTabID, originalGeneration = first.activeTab.homeTagGeneration
        #expect(shortcuts.names.isEmpty && first.activeTab.homeTag == "Résumé")
        shortcuts.setVisible("Unrelated", visible: true)
        shortcuts.setVisible("Résumé", visible: false) // Never selected as a shortcut.
        #expect(first.activeTab.homeTagGeneration == originalGeneration)
        first.duplicateTab(original)
        let copy = first.activeTabID
        second.navigate(to: legacy)
        let otherGeneration = second.activeTab.homeTagGeneration
        shortcuts.setVisible("Re\u{301}sume\u{301}", visible: true)
        shortcuts.setVisible("Unrelated", visible: false)
        #expect(first.activeTab.homeTag == "Résumé" && second.activeTab.homeTagGeneration == otherGeneration)
        let history = first.activeTab.history
        shortcuts.setVisible("Résumé", visible: false)
        #expect(first.tabs.allSatisfy { $0.homeTag == nil })
        #expect(first.tabs.first { $0.id == original }?.homeTagGeneration != originalGeneration)
        #expect(first.activeTabID == copy && first.activeTab.history == history)
        #expect(second.activeTab.homeTag == nil && second.activeTab.homeTagGeneration != otherGeneration)
        #expect(first.activeTab.homeSection == .tags && second.activeTab.homeSection == .tags)
        let cleared = second.activeTab.homeTagGeneration
        shortcuts.setVisible("Résumé", visible: false)
        #expect(second.activeTab.homeTagGeneration == cleared)
        second.selectHomeTag("Résumé")
        #expect(second.activeTab.homeTag == nil)
        second.navigate(to: legacy)
        #expect(second.activeTab.homeTag == "Résumé" && shortcuts.names.isEmpty)
    }

    @Test func defaultScopeChangesRefreshEveryDependentTabAndPreserveNamedDrillDown() {
        let choices = FinderTagShortcuts()
        let first = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: choices)
        let second = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: choices)
        defer { first.cancelLoads(); second.cancelLoads() }
        first.selectHomeSection(.tags)
        second.selectHomeSection(.tags)
        choices.setVisible("A", visible: true)
        let background = first.activeTabID, backgroundGeneration = first.activeTab.homeTagGeneration
        first.duplicateTab(background)
        first.selectHomeTag("A")
        let drilled = first.activeTab.homeTagGeneration
        let other = second.activeTab.homeTagGeneration
        choices.setVisible("B", visible: true)
        #expect(first.tabs.first { $0.id == background }?.homeTagGeneration != backgroundGeneration)
        #expect(first.activeTab.homeTagGeneration == drilled && first.activeTab.homeTag == "A")
        #expect(second.activeTab.homeTagGeneration != other && choices.scope(for: second.activeTab.homeTag) == .selected(["A", "B"]))
        choices.setShowsAllTagged(true)
        let all = second.activeTab.homeTagGeneration
        choices.setVisible("B", visible: false)
        #expect(second.activeTab.homeTagGeneration == all)
        #expect(first.activeTab.homeTagGeneration == drilled)
        choices.setVisible("A", visible: false)
        #expect(first.activeTab.homeTagGeneration != drilled && first.activeTab.homeTag == nil)
        #expect(choices.scope(for: first.activeTab.homeTag) == .allTagged && second.activeTab.homeTagGeneration == all)
        second.selectHomeSection(.recent)
        let recent = second.activeTab.homeTagGeneration
        choices.setShowsAllTagged(false)
        #expect(second.activeTab.homeTagGeneration == recent)
    }

    @Test(arguments: [true, false])
    func uncheckingInAnotherWindowInvalidatesAnOpenTagEditor(drilledDown: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-origin-" + UUID().uuidString)
        try Data().write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = try await FinderTagFile.identity(at: url)
        let shortcuts = FinderTagShortcuts()
        let store = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: shortcuts)
        let other = ExplorerStore(initialURL: BrowserPage.home.url, tagShortcuts: shortcuts)
        defer { store.cancelLoads(); other.cancelLoads() }
        shortcuts.setVisible("Chosen", visible: true)
        store.selectHomeSection(.tags)
        if drilledDown { store.selectHomeTag("Chosen") }
        store.performPageAction(.editTags, url: url, folder: false, representedIdentity: identity)
        let editor = try #require(store.finderTagEditor)
        try await waitUntil { !editor.isLoading }
        editor.toggle("Synthetic pending assignment")
        #expect(editor.canApply)
        other.tagShortcuts.setVisible("Chosen", visible: false)
        store.applyFinderTagEdits()
        #expect(editor.originChanged && !editor.submitted && store.activeTab.homeTag == nil)
        let assignments = try await FinderTagFile.read(at: url, expecting: identity)
        #expect(assignments.names.isEmpty)
    }

    @Test
    func typedPageURLsAreExcludedFromPhysicalResolutionAndAddressHistory() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, home = try #require(URL(string: "maxplorer-page://home"))
        let history = RecentAddressHistory()
        history.record(home)
        #expect(history.entries.isEmpty)
        store.submitTypedAddress(home)
        #expect(store.activeTab.url == root)
        #expect(OpenRequestPlan.make([home], isFolder: { _ in true }).targets.isEmpty)
        store.navigate(to: home)
        store.requestAddressEditing()
        #expect(store.address.text == "Home")
        store.address.updateText(root.path, showHidden: false)
        #expect(store.address.submissionURL(relativeTo: home)?.path == root.path)
    }

    @Test
    func submittingTheCurrentFolderRecordsItOnlyAfterAReadWithoutAddingNavigationHistory() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let isolated = try await ready()
        defer { isolated.stop() }
        let store = fixture.store, before = store.activeTab.history
        store.submitAddress(root)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        #expect(store.address.recentAddresses.isEmpty && store.activeTab.history == before)
        await fixture.driver.finish(1, items: items(in: root), identity: identity())
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.history == before && store.address.recentAddresses == [root])
        #expect(isolated.store.address.recentAddresses.isEmpty)
    }

    @Test
    func addressSubmissionCommitsHistoryAndRecentOnlyAfterSuccessIncludingTheCurrentFolder() async throws {
        let shared = RecentAddressHistory()
        let fixture = try await ready(recentAddressHistory: shared)
        defer { fixture.stop() }
        let receiver = try await ready(detachedTab: BrowserTab(url: root), recentAddressHistory: shared)
        defer { receiver.stop() }
        let store = fixture.store, child = root.appendingPathComponent("Child", isDirectory: true)
        let selected = items(in: root)[0]
        store.setSelection([selected.id], focusedID: selected.id)
        let before = store.activeTab
        store.submitAddress(child)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        #expect(store.activeTab.history == before.history && store.activeTab.selection == before.selection)
        #expect(store.address.recentAddresses.isEmpty && receiver.store.address.recentAddresses.isEmpty)
        await fixture.driver.finish(1, items: items(in: child), identity: identity())
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == child && store.activeTab.history.backStack == [root])
        #expect(store.activeTab.selection.selectedIDs.isEmpty && store.address.recentAddresses == [child])
        #expect(receiver.store.address.recentAddresses == [child])
        let history = store.activeTab.history
        store.submitAddress(child)
        #expect(store.address.recentAddresses == [child])
        try await settle(fixture, read: 2, at: child)
        #expect(store.activeTab.history == history && store.address.recentAddresses == [child])
        store.navigate(to: root)
        try await settle(fixture, read: 3, at: root)
        #expect(receiver.store.address.recentAddresses == [child])

        store.submitAddress(root)
        try await settle(fixture, read: 4, at: root)
        let address = receiver.store.address
        address.showHistory()
        let chosen = try #require(address.suggestion(at: 1, requestID: address.requestID))
        try #require(chosen == child && address.suggestions == [root, child])
        receiver.store.submitAddress(chosen)
        try await waitUntil { await receiver.driver.reads.count == 2 }
        #expect(store.address.recentAddresses == [root, child])
        try await settle(receiver, read: 1, at: child)
        #expect(store.address.recentAddresses == [child, root] && address.recentAddresses == [child, root])
    }

    @Test
    func failedSubmissionRetainsRetryTargetAcrossPassiveRefreshButRetryIsNotAnAddressRecent() async throws {
        let shared = RecentAddressHistory()
        let reader = AddressNavigationModel(recentHistory: shared)
        let fixture = try await ready(recentAddressHistory: shared)
        defer { fixture.stop() }
        let store = fixture.store, denied = root.appendingPathComponent("Denied", isDirectory: true)
        let selected = items(in: root)[1]
        store.setSelection([selected.id], focusedID: selected.id)
        let before = store.activeTab
        store.submitAddress(denied)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        await fixture.driver.fail(1)
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.errorMessage != nil }
        #expect(store.activeTab.history == before.history && store.activeTab.selection == before.selection)
        #expect(reader.recentAddresses.isEmpty)
        store.refreshAfterActivation()
        try await settle(fixture, read: 2, at: root)
        #expect(store.activeTab.errorMessage != nil && store.address.recentAddresses.isEmpty)
        store.retry()
        try await settle(fixture, read: 3, at: denied)
        #expect(store.activeTab.url == denied && store.activeTab.history.backStack == [root])
        #expect(store.activeTab.errorMessage == nil && reader.recentAddresses.isEmpty)
    }

    @Test
    func supersededSuccessCannotChangeLocationHistoryOrRecents() async throws {
        let shared = RecentAddressHistory()
        let reader = AddressNavigationModel(recentHistory: shared)
        let fixture = try await ready(recentAddressHistory: shared)
        defer { fixture.stop() }
        let store = fixture.store
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        store.submitAddress(first)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        store.submitAddress(second)
        try await settle(fixture, read: 2, at: second)
        await fixture.driver.finish(1, items: items(in: first), identity: identity(200))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.activeTab.url == second && store.activeTab.history.backStack == [root])
        #expect(store.address.recentAddresses == [second] && reader.recentAddresses == [second])
    }

    @Test
    func closingTheSubmittingTabRejectsItsLateSuccess() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, retained = store.activeTabID
        store.openTab(at: root)
        try await settle(fixture, read: 1, at: root)
        let closing = store.activeTabID, target = root.appendingPathComponent("Closed", isDirectory: true)
        store.submitAddress(target)
        try await waitUntil { await fixture.driver.reads.count == 3 }
        store.closeTab(closing)
        await fixture.driver.finish(2, items: items(in: target), identity: identity())
        for _ in 0..<10 { await Task.yield() }
        #expect(store.tabs.count == 1 && store.activeTabID == retained && store.activeTab.url == root)
        #expect(store.activeTab.history.backStack.isEmpty && store.address.recentAddresses.isEmpty)
    }

    @Test(arguments: ["refresh", "hidden"])
    func restartedPendingAddressReadsPreserveTheSuccessfulSubmissionIntent(_ restart: String) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, target = root.appendingPathComponent("Pending", isDirectory: true)
        store.submitAddress(target)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        store.refreshAfterActivation()
        #expect(await fixture.driver.reads.count == 2)
        if restart == "refresh" { store.refresh() } else { store.toggleHidden() }
        try await settle(fixture, read: 2, at: target)
        await fixture.driver.finish(1, items: items(in: root), identity: identity(200))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.activeTab.url == target && store.activeTab.history.backStack == [root])
        #expect(store.address.recentAddresses == [target])
    }

    @Test
    func committingANewLocationInvalidatesAnEditorOpenedDuringTheReadButPassiveRefreshKeepsItsDraft() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerAddressContext-\(UUID())", isDirectory: true)
        let child = temporary.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let fixture = AddressStoreFixture(url: temporary)
        defer { fixture.stop(); try? FileManager.default.removeItem(at: temporary) }
        try await settle(fixture, read: 0, at: temporary)
        let store = fixture.store
        store.submitAddress(child)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        store.requestAddressEditing()
        store.address.updateText(temporary.path + "/Ch", showHidden: false)
        try await waitUntil { !store.address.isLoading && !store.address.suggestions.isEmpty }
        store.address.highlight(0)
        let oldRequest = store.address.requestID
        #expect(store.address.isEditing && store.address.highlightedIndex == 0)
        await fixture.driver.finish(1, items: items(in: child), identity: identity())
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == child && store.address.recentAddresses == [child])
        #expect(!store.address.isEditing && store.address.presentation == nil && store.address.highlightedIndex == nil)
        #expect(store.address.suggestion(at: 0, requestID: oldRequest) == nil)

        store.requestAddressEditing()
        store.address.updateText("unfinished relative path", showHidden: false)
        store.refreshAfterActivation()
        try await settle(fixture, read: 2, at: child)
        #expect(store.address.isEditing && store.address.text == "unfinished relative path")
        #expect(store.address.recentAddresses == [child] && store.activeTab.history.backStack == [temporary])
    }

    @Test
    func addressMenusHighlightingAndClearingHistoryPreserveEveryTabsNavigationAndSelection() async throws {
        let shared = RecentAddressHistory()
        let fixture = try await ready(recentAddressHistory: shared)
        defer { fixture.stop() }
        let peer = try await ready(recentAddressHistory: shared)
        defer { peer.stop() }
        let store = fixture.store, child = root.appendingPathComponent("Child", isDirectory: true)
        let grandchild = child.appendingPathComponent("Grandchild", isDirectory: true)
        store.submitAddress(child)
        try await settle(fixture, read: 1, at: child)
        store.back()
        try await settle(fixture, read: 2, at: root)
        let firstID = store.activeTabID, selected = items(in: root)[0]
        store.setSelection([selected.id], focusedID: selected.id, anchorID: selected.id)
        store.openTab(at: root)
        try await settle(fixture, read: 3, at: root)
        store.activateTab(firstID)
        let before = store.tabs

        peer.store.navigate(to: child)
        try await settle(peer, read: 1, at: child)
        peer.store.navigate(to: grandchild)
        try await settle(peer, read: 2, at: grandchild)
        peer.store.back()
        try await settle(peer, read: 3, at: child)
        let peerSelection = items(in: child)[1]
        peer.store.setSelection([peerSelection.id], focusedID: peerSelection.id, anchorID: peerSelection.id)
        let peerBefore = peer.store.activeTab
        try #require(peerBefore.history.backStack == [root] && peerBefore.history.forwardStack == [grandchild])
        try #require(peerBefore.selection.selectedIDs == [peerSelection.id])
        peer.store.address.showHistory()
        let peerRequest = peer.store.address.requestID
        try #require(peer.store.address.suggestion(at: 0, requestID: peerRequest) == child)

        store.address.showHistory()
        store.address.moveHighlight(by: 1)
        #expect(store.address.highlightedIndex == 0)
        store.requestAddressEditing()
        store.address.cancel()
        store.address.showHistory()
        store.clearAddressHistory()
        #expect(store.address.recentAddresses.isEmpty && store.address.presentation == nil)
        #expect(peer.store.address.recentAddresses.isEmpty && peer.store.address.presentation == nil)
        #expect(peer.store.address.requestID != peerRequest
                && peer.store.address.suggestion(at: 0, requestID: peerRequest) == nil)
        #expect(store.tabs.count == before.count && store.activeTabID == firstID)
        for (old, current) in zip(before, store.tabs) {
            #expect(old.id == current.id && old.history == current.history && old.selection == current.selection)
            #expect(old.items == current.items && old.url == current.url)
        }
        #expect(peer.store.activeTabID == peerBefore.id && peer.store.activeTab.url == peerBefore.url)
        #expect(peer.store.activeTab.history == peerBefore.history && peer.store.currentSelection == peerBefore.selection)
        #expect(store.activeTab.history.forwardStack == [child])
        #expect(await fixture.driver.reads.count == 4)
        #expect(await peer.driver.reads.count == 4)
        #expect(await fixture.driver.writes == 0)
        #expect(await peer.driver.writes == 0)
    }

    @Test
    func copyAddressExportsLocalURLAndTextWithoutReconstructingTransferIntent() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, board = fixture.board, selected = items(in: root)[0]
        store.setSelection([selected.id], focusedID: selected.id)
        store.copySelection()
        try #require(store.clipboard.payload != nil)
        let before = store.activeTab
        store.copyAddress(asText: false, to: board)
        let exported = try #require(board.string(forType: .fileURL))
        #expect(URL(string: exported)?.path == root.path)
        #expect(board.string(forType: .string) == root.path && store.clipboard.payload == nil)
        #expect(!(board.types ?? []).contains { $0.rawValue == "com.native-explorer.internal-transfer-token" })
        store.copyAddress(asText: true, to: board)
        #expect(board.string(forType: .string) == root.path && board.string(forType: .fileURL) == nil)
        #expect(store.clipboard.payload == nil && store.activeTab.selection == before.selection)
        #expect(store.activeTab.history == before.history && fixture.store.address.recentAddresses.isEmpty)
        #expect(await fixture.driver.reads.count == 1)
        #expect(await fixture.driver.writes == 0)
    }

    @Test(arguments: ["https://example.com/folder", "file://remote/tmp/folder", "file:///tmp/folder?query", "file:///tmp/folder#fragment", "file:///tmp/bad%00name"])
    func invalidURLValuesCannotStartAnAddressLoad(_ text: String) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, before = store.activeTab
        store.submitAddress(try #require(URL(string: text)))
        for _ in 0..<10 { await Task.yield() }
        #expect(await fixture.driver.reads.count == 1)
        #expect(store.activeTab.history == before.history && store.address.recentAddresses.isEmpty)
    }

    // ND-ADDR-01–03. Use a real benign document and a recording router;
    // the synthetic browsing provider exposes any unintended folder load.
    @Test(arguments: [false, true])
    func typedDocumentAndLaunchFailureRetainFolderSelectionAndHistory(_ launchFails: Bool) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let router = P18Router()
        router.failsDefaults = launchFails
        store.applications = router
        let document = FileManager.default.temporaryDirectory
            .appendingPathComponent("typed-document-\(UUID()).txt")
        try Data("Benign test document".utf8).write(to: document, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: document) }
        let folder = root.appendingPathComponent("Child", isDirectory: true)
        store.submitAddress(folder)
        try await settle(fixture, read: 1, at: folder)
        let rows = items(in: folder)
        store.setSelection(Set(rows.map(\.id)), focusedID: rows[0].id, anchorID: rows[1].id)
        let before = store.activeTab
        let recents = store.address.recentAddresses
        store.requestAddressEditing()
        store.address.updateText(document.absoluteString, showHidden: false)
        store.submitTypedAddress(try #require(store.address.submissionURL(relativeTo: before.url)))
        try await waitUntil { router.defaults.count == 1 }
        #expect(router.defaults.map(\.path) == [document.path])
        #expect(!store.address.isEditing && store.activeTab.errorMessage == nil)
        #expect((store.operationNotice != nil) == launchFails)
        #expect(store.activeTab.history == before.history && store.activeTab.selection == before.selection)
        #expect(store.address.recentAddresses == recents)
        #expect(await fixture.driver.reads.count == 2)
    }

    @Test
    func typedMissingPathAndStaleFolderSuggestionCannotOpenAnApplication() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let router = P18Router()
        store.applications = router
        let missing = root.appendingPathComponent("Missing-\(UUID()).txt")
        store.submitTypedAddress(missing)
        try await waitUntil { store.operationNotice != nil }
        #expect(store.activeTab.errorMessage == nil && store.activeTab.url == root)
        #expect(await fixture.driver.reads.count == 1)

        let stale = FileManager.default.temporaryDirectory.appendingPathComponent("stale-folder-\(UUID())")
        try Data().write(to: stale, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: stale) }
        store.submitAddress(stale)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        await fixture.driver.fail(1)
        try await waitUntil { store.activeTab.errorMessage != nil }
        #expect(router.defaults.isEmpty)
        #expect(store.activeTab.url == root && store.address.recentAddresses.isEmpty)
    }

    enum Supersession: CaseIterable { case newerAddress, tabRoundTrip, teardown }

    @Test(arguments: Supersession.allCases)
    func lateTypedResultCannotLaunchAfterLosingItsOwner(_ supersession: Supersession) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let router = ZIPAppRouter()
        store.applications = router
        let resolver = TypedAddressDriver()
        defer { Task { await resolver.shutdown() } }
        store.resolvePhysicalAddress = { await resolver.resolve($0) }
        let origin = store.activeTabID
        if supersession == .tabRoundTrip {
            let other = root.appendingPathComponent("Other", isDirectory: true)
            store.openTab(at: other)
            try await settle(fixture, read: 1, at: other)
            store.activateTab(origin)
        }
        let first = root.appendingPathComponent("First.txt")
        let second = root.appendingPathComponent("Second.txt")
        store.submitTypedAddress(first)
        try await waitUntil { await resolver.requests.count == 1 }
        switch supersession {
        case .newerAddress:
            store.submitTypedAddress(second)
            try await waitUntil { await resolver.requests.count == 2 }
            await resolver.complete(1)
            try await waitUntil { router.opened == [second] }
        case .tabRoundTrip:
            store.activateTab(try #require(store.tabs.first { $0.id != origin }).id)
            store.activateTab(origin)
        case .teardown:
            store.cancelLoads()
        }
        await resolver.complete(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(router.opened == (supersession == .newerAddress ? [second] : []))
        #expect(store.activeTab.url == root && store.address.recentAddresses.isEmpty)
    }

    enum HomeOpenOrder: CaseIterable { case typedThenPage, pageThenTyped, pageThenPage }

    @Test(arguments: HomeOpenOrder.allCases)
    func latestHomeOrAddressOpenOwnsTheApplicationHandoff(_ order: HomeOpenOrder) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        store.navigate(to: BrowserPage.home.url)
        let router = ZIPAppRouter()
        store.applications = router
        let resolver = TypedAddressDriver()
        defer { Task { await resolver.shutdown() } }
        store.resolvePhysicalAddress = { await resolver.resolve($0) }
        let first = root.appendingPathComponent("Earlier.txt")
        let second = root.appendingPathComponent("Later.txt")
        if order == .typedThenPage { store.submitTypedAddress(first) }
        else { store.performPageAction(.open, url: first, folder: false) }
        try await waitUntil { await resolver.requests == [first] }
        if order == .pageThenTyped { store.submitTypedAddress(second) }
        else { store.performPageAction(.open, url: second, folder: false) }
        try await waitUntil { await resolver.requests == [first, second] }

        await resolver.complete(0)
        try await waitUntil { await resolver.cancellationAtReturn[0] != nil }
        #expect(await resolver.cancellationAtReturn[0] == true)
        await resolver.complete(1)
        try await waitUntil { !router.opened.isEmpty }
        #expect(router.opened == [second])
        #expect(store.activePage == .home)
    }

    enum NewerActivation: CaseIterable { case row, selection, search, openWith }

    @Test(arguments: NewerActivation.allCases)
    func newerApplicationActivationCancelsPendingTypedAddress(_ activation: NewerActivation) async throws {
        let gate = AddressActivationGate()
        let fixture = try await ready(validateSearchResult: { _ in await gate.validate() })
        defer { fixture.stop(); Task { await gate.release(false) } }
        let store = fixture.store
        let router = ZIPAppRouter()
        store.applications = router
        store.validateRoutingTarget = { _ in await gate.validate() }
        let resolver = TypedAddressDriver()
        defer { Task { await resolver.shutdown() } }
        store.resolvePhysicalAddress = { await resolver.resolve($0) }
        let rows = items(in: root)
        let row = rows[0]
        if activation == .search {
            let query = try #require(FilenameSearchQuery(text: "Alpha"))
            var search = SearchSession(query: query, rootURL: root, rootTitle: "Address fixture")
            let parent = FileOperationContext(directoryURL: root, directoryIdentity: identity())
            search.append([FilenameSearchResult(item: row, parent: parent)], sort: FileSort())
            store.tabs[0].search = search
        } else {
            store.setSelection(activation == .selection ? Set(rows.map(\.id)) : [row.id],
                               focusedID: row.id)
        }
        let typed = root.appendingPathComponent("Earlier typed document.txt")
        store.submitTypedAddress(typed)
        try await waitUntil { await resolver.requests == [typed] }

        switch activation {
        case .row, .search: store.activate(row)
        case .selection: store.openSelection()
        case .openWith:
            store.open(row, withApplicationAt: URL(fileURLWithPath: "/tmp/Synthetic Editor.app"))
        }
        if activation != .row {
            try await waitUntil { await gate.isWaiting }
            #expect(router.opened.isEmpty)
        }
        await resolver.complete(0)
        try await waitUntil { await resolver.cancellationAtReturn[0] != nil }
        #expect(await resolver.cancellationAtReturn[0] == true)
        await gate.release(true)
        let expected = activation == .selection ? rows.map(\.url) : [row.url]
        try await waitUntil { Set(router.opened).isSuperset(of: expected) }
        #expect(router.opened.count == expected.count && !router.opened.contains(typed))
        #expect(store.activeTab.url == root)
    }

    @Test(arguments: [false, true])
    func invalidActivationKeepsPendingTypedAddress(_ unsupportedSearch: Bool) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let router = ZIPAppRouter()
        store.applications = router
        let resolver = TypedAddressDriver()
        defer { Task { await resolver.shutdown() } }
        store.resolvePhysicalAddress = { await resolver.resolve($0) }
        let row = items(in: root)[0]
        if unsupportedSearch {
            let query = try #require(FilenameSearchQuery(text: "Alpha"))
            var search = SearchSession(query: query, rootURL: root, rootTitle: "Address fixture")
            search.append([FilenameSearchResult(item: row, parent: nil)], sort: FileSort())
            store.tabs[0].search = search
        }
        let typed = root.appendingPathComponent("Earlier typed document.txt")
        store.submitTypedAddress(typed)
        try await waitUntil { await resolver.requests == [typed] }
        if unsupportedSearch {
            store.activate(row)
        } else {
            // Open With was captured for a selection that no longer exists.
            store.open(row, withApplicationAt: URL(fileURLWithPath: "/tmp/Synthetic Editor.app"))
        }
        #expect(store.operationNotice != nil)
        await resolver.complete(0)
        try await waitUntil { router.opened == [typed] }
        #expect(await resolver.cancellationAtReturn[0] == false)
    }

    @Test
    func typedDocumentRevokesOlderNavigationEvenWhenPreviewBlocksMaintenanceRead() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store
        let router = ZIPAppRouter()
        store.applications = router
        store.resolvePhysicalAddress = { .ordinaryFile($0) }
        let document = root.appendingPathComponent("Document.txt")
        let query = try #require(FilenameSearchQuery(text: "Alpha"))
        store.tabs[0].search = SearchSession(query: query, rootURL: root, rootTitle: "Address fixture")
        let generation = store.activeSearch?.generation
        let before = store.activeTab.history
        let older = root.appendingPathComponent("Older folder intent", isDirectory: true)
        store.submitAddress(older)
        try await waitUntil { await fixture.driver.reads.count == 2 }

        // Establish the same synchronous blocker a cloud preview request sets.
        // There is no provider wait between this setup and the newer intent.
        let online = FileItem(url: document, name: document.lastPathComponent, isDirectory: false,
            isSymbolicLink: false, size: 0, modifiedAt: nil, kind: "Text Document",
            identity: identity(200), availability: .onlineOnly)
        let context = FileOperationContext(directoryURL: root, directoryIdentity: identity())
        store.preview.show(PreviewRequest(tabID: store.activeTabID, generation: store.contextMenuLoadGeneration,
            searchGeneration: generation, items: [online],
            entry: ItemOperationEntry(item: online, context: .filesystem(context))))
        try #require(store.preview.blocksAutomaticRefresh(tabID: store.activeTabID))
        store.submitTypedAddress(document)
        try await waitUntil { router.opened == [document] }
        await fixture.driver.finish(1, items: items(in: older), identity: identity(201))
        try await settle(fixture, read: 2, at: root)
        #expect(store.activeTab.history == before && store.activeTab.url == root)
        #expect(store.activeSearch?.generation == generation && store.address.recentAddresses.isEmpty)
    }

    @Test
    func physicalClassificationDistinguishesFoldersPackagesZIPLinksAndSpecialFiles() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("typed-classification-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Folder.zip", isDirectory: true)
        let package = directory.appendingPathComponent("Benign.rtfd", isDirectory: true)
        let archive = directory.appendingPathComponent("Empty.zip")
        let document = directory.appendingPathComponent("Document.txt")
        let folderLink = directory.appendingPathComponent("Folder link")
        let documentLink = directory.appendingPathComponent("Document link")
        let broken = directory.appendingPathComponent("Broken link")
        let cyclic = directory.appendingPathComponent("Cyclic link")
        let fifo = directory.appendingPathComponent("FIFO")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try manager.createDirectory(at: package, withIntermediateDirectories: false)
        try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: archive)
        try Data("Benign test document".utf8).write(to: document)
        try manager.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        try manager.createSymbolicLink(at: documentLink, withDestinationURL: document)
        try manager.createSymbolicLink(at: broken, withDestinationURL: directory.appendingPathComponent("Absent"))
        try manager.createSymbolicLink(at: cyclic, withDestinationURL: cyclic)
        try #require(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)

        let folderTarget = try await FileActivationTarget.resolvePhysicalAddress(folder)
        let folderLinkTarget = try await FileActivationTarget.resolvePhysicalAddress(folderLink)
        #expect(folderTarget.browsingURL?.path == folder.path)
        #expect(folderLinkTarget.browsingURL?.path == folderLink.path)
        let archiveTarget = try await FileActivationTarget.resolvePhysicalAddress(archive)
        #expect(archiveTarget.browsingURL.flatMap(ArchiveLocation.init(url:))?.archiveURL.path == archive.path)
        for file in [document, documentLink, package] {
            let target = try await FileActivationTarget.resolvePhysicalAddress(file)
            guard case .ordinaryFile(let url) = target else {
                Issue.record("Expected ordinary activation for \(file.lastPathComponent)")
                continue
            }
            #expect(url.path == file.path)
        }
        let slash = try LocalPathInput.resolve(document.path + "/")
        let dot = try LocalPathInput.resolve(document.path + "/.")
        for invalid in [broken, cyclic, fifo, slash, dot] {
            await #expect(throws: (any Error).self) { try await FileActivationTarget.resolvePhysicalAddress(invalid) }
        }
    }

    @Test(arguments: ["draft", "mutation", "recovery"])
    func protectedInteractionsRejectSubmissionAndCopyWithoutCancellingProtectedWork(_ state: String) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, selected = items(in: root)[0]
        store.setSelection([selected.id], focusedID: selected.id)
        var draftID: UUID?
        switch state {
        case "draft":
            store.beginRename()
            draftID = try #require(store.nameEdit).id
            store.updateProposedName("unfinished.txt", sessionID: try #require(draftID))
        case "mutation":
            store.trashSelection()
            try await waitUntil { await fixture.driver.trashes == 1 }
        default:
            store.showRecovery()
        }
        fixture.board.clearContents()
        fixture.board.setString("Retained clipboard", forType: .string)
        let before = store.activeTab
        #expect(!store.canUseAddress)
        store.submitAddress(root.appendingPathComponent("Rejected", isDirectory: true))
        store.copyAddress(asText: false, to: fixture.board)
        #expect(store.activeTab.history == before.history && store.activeTab.selection == before.selection)
        #expect(fixture.board.string(forType: .string) == "Retained clipboard")
        #expect(await fixture.driver.reads.count == 1)
        #expect(await fixture.driver.writes == 0)
        #expect(store.address.recentAddresses.isEmpty)
        switch state {
        case "draft":
            #expect(store.nameEdit?.id == draftID && store.nameEdit?.proposedName == "unfinished.txt")
            let previousRequest = store.addressFocusRequest
            store.requestAddressEditing()
            #expect(store.nameEdit == nil && store.address.isEditing)
            #expect(store.addressFocusRequest == previousRequest + 1 && store.address.text == root.path)
        case "mutation":
            store.requestAddressEditing()
            #expect(store.isPerformingOperation && !store.address.isEditing)
            #expect(store.trashProgress?.isCancelling == false)
            await fixture.driver.cancelTrash()
            try await settle(fixture, read: 1, at: root)
            try await waitUntil { !store.isPerformingOperation }
        default:
            store.requestAddressEditing()
            #expect(store.isShowingRecovery && !store.address.isEditing)
        }
    }
}
