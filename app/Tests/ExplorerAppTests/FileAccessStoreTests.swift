import AppKit
import Darwin
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Controlled failures exercise routing without changing OS permissions or touching real paths.
private actor AccessStoreDriver: DirectoryListing, FileOperating, FileRecovering, FileTransferring {
    struct Write: Sendable { let item: FileItem?; let name: String; let context: FileOperationContext }
    private(set) var reads: [URL] = []
    private(set) var writes: [Write] = []
    private(set) var restoreIDs: [UUID] = []
    private(set) var trashItems: [FileItem] = []
    private(set) var transferItems: [FileItem] = []
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingWrites: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]
    private var pendingRestore: CheckedContinuation<FileOperationResult, Error>?
    private var pendingTrash: CheckedContinuation<TrashResult, Error>?
    private var pendingTransfer: CheckedContinuation<FileOperationResult, Error>?
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pendingReads[reads.count] = $0; reads.append(url)
        }
    }
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await write(nil, name: name, context: context)
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await write(item, name: name, context: context)
    }
    private func write(_ item: FileItem?, name: String, context: FileOperationContext) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pendingWrites[writes.count] = $0; writes.append(Write(item: item, name: name, context: context))
        }
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTrash = $0; trashItems.append(item) }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingRestore = $0; restoreIDs.append(receipt.id) }
    }
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTransfer = $0; transferItems.append(item) }
    }
    func read(_ index: Int, _ value: DirectorySnapshot) { pendingReads.removeValue(forKey: index)?.resume(returning: value) }
    func failRead(_ index: Int, _ error: any Error = CocoaError(.fileReadNoPermission)) {
        pendingReads.removeValue(forKey: index)?.resume(throwing: error)
    }
    func wrote(_ index: Int, _ result: FileOperationResult) { pendingWrites.removeValue(forKey: index)?.resume(returning: result) }
    func failWrite(_ index: Int, _ error: any Error) { pendingWrites.removeValue(forKey: index)?.resume(throwing: error) }
    func failRestore(_ error: any Error) { let call = pendingRestore; pendingRestore = nil; call?.resume(throwing: error) }
    func failTrash(_ error: any Error) { let call = pendingTrash; pendingTrash = nil; call?.resume(throwing: error) }
    func failTransfer(_ error: any Error) { let call = pendingTransfer; pendingTransfer = nil; call?.resume(throwing: error) }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), writes = Array(pendingWrites.values)
        pendingReads.removeAll(); pendingWrites.removeAll()
        for call in reads { call.resume(throwing: CancellationError()) }
        for call in writes { call.resume(throwing: CancellationError()) }
        failRestore(CancellationError()); failTrash(CancellationError()); failTransfer(CancellationError())
    }
}

/// Rebinding watches is exercised, but no native notifications or permission probes occur.
private struct AccessIdleObserver: DirectoryObserving {
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor
private final class AccessStoreFixture {
    let driver = AccessStoreDriver()
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerAccessStoreTests-\(UUID())"))
    let store: ExplorerStore
    init(url: URL, observing: Bool = false) {
        store = ExplorerStore(initialURL: url, loader: driver, homeURL: url,
            observer: observing ? AccessIdleObserver() : nil, operations: driver,
            transfers: driver, clipboard: TransferClipboard(pasteboard: board), recovery: driver)
    }
    func stop() {
        store.cancelLoads(); store.cancelTrash(); store.cancelTransfer()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// FR-NAV-007 / EV-0298 / AT-NAV-007 failed navigation state, plus MAC-003 native
/// access-help policy. Error classifications do not diagnose TCC or promise FDA fixes.
@MainActor
final class FileAccessStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-access-store-model", isDirectory: true)
    private func identity(_ inode: UInt64 = 100) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String = "original.txt", under folder: URL? = nil) -> FileItem {
        FileItem(url: (folder ?? root).appendingPathComponent(name), name: name, isDirectory: false,
                 isSymbolicLink: false, size: 4, modifiedAt: nil, kind: "Text Document", identity: identity(101))
    }
    private func snapshot(_ items: [FileItem] = []) -> DirectorySnapshot {
        DirectorySnapshot(items: items, directoryIdentity: identity())
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Access state did not settle before the bounded deadline")
    }
    private func ready(observing: Bool = false) async throws -> AccessStoreFixture {
        let fixture = AccessStoreFixture(url: root, observing: observing)
        try await waitUntil { await fixture.driver.reads.count == 1 }
        await fixture.driver.read(0, snapshot([item()]))
        try await settled(fixture.store)
        return fixture
    }
    private func settled(_ store: ExplorerStore) async throws {
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
    }

    @Test(arguments: ["activation", "tab return", "visibility"])
    func deniedNavigationKeepsItsRequestedLocationThroughPassiveReadsAndExplicitRetry(_ trigger: String) async throws {
        let fixture = try await ready(observing: true), denied = root.appendingPathComponent("Denied", isDirectory: true)
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, firstID = store.activeTabID
        store.navigate(to: denied)
        try await waitUntil { await driver.reads.count == 2 }
        await driver.failRead(1)
        // Failed navigation reattaches observation and reads the committed folder.
        try await waitUntil { await driver.reads.count == 3 }
        await driver.read(2, snapshot([item()]))
        try await settled(store)
        let issue = try #require(store.activeTab.accessIssue)
        #expect(issue.failure == .permissionDenied && issue.locations == [denied])
        #expect(store.activeTab.url == root)
        var passive = 3
        switch trigger {
        case "activation": store.refreshAfterActivation()
        case "visibility": store.toggleHidden()
        default:
            store.openTab(at: root.appendingPathComponent("Other", isDirectory: true))
            try await waitUntil { await driver.reads.count == 4 }
            await driver.read(3, snapshot())
            try await settled(store)
            store.activateTab(firstID)
            passive = 4
        }
        try await waitUntil { await driver.reads.count == passive + 1 }
        #expect(await driver.reads[passive] == root)
        await driver.read(passive, snapshot([item()]))
        try await settled(store)
        #expect(store.activeTab.accessIssue == issue)
        store.retry()
        try await waitUntil { await driver.reads.count == passive + 2 }
        #expect(store.activeTab.accessIssue == nil)
        #expect(await driver.reads[passive + 1] == denied)
        await driver.read(passive + 1, snapshot())
        try await settled(store)
        #expect(store.activeTab.url == denied && store.activeTab.accessIssue == nil)
        #expect(store.activeTab.errorMessage == nil && store.activeTab.history.backStack == [root])
    }

    @Test
    func deniedCurrentFolderDisablesActionsAndDismissingHelpOrErrorDoesNotClaimRecovery() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, original = item()
        store.setSelection([original.id], focusedID: original.id)
        store.refresh()
        try await waitUntil { await driver.reads.count == 2 }
        await driver.failRead(1)
        try await settled(store)
        let issue = try #require(store.activeTab.accessIssue)
        #expect(issue.locations == [root] && issue.failure == .permissionDenied)
        #expect(store.activeTab.isUnavailable && store.activeTab.items == [original])
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(!store.canCreateFolder && !store.canRenameSelection && !store.canCopySelection && !store.canTrashSelection)
        var shown: [FileAccessContext?] = []
        store.onShowAccessHelp = { shown.append($0) }
        store.showAccessHelp(issue)
        #expect(shown.count == 1 && shown[0] == issue)
        #expect(store.activeTab.isUnavailable && store.activeTab.accessIssue == issue)
        #expect(await driver.reads.count == 2)
        store.dismissError()
        #expect(store.activeTab.accessIssue == nil && store.activeTab.isUnavailable)
        store.retry()
        try await waitUntil { await driver.reads.count == 3 }
        await driver.read(2, snapshot([original]))
        try await settled(store)
        #expect(!store.activeTab.isUnavailable && store.canCreateFolder)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
    }

    @Test(arguments: [Int32(EACCES), Int32(EROFS)])
    func deniedRenameRetainsItsProposalAndHelpNeverReplaysTheMutation(_ code: Int32) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, original = item()
        store.setSelection([original.id], focusedID: original.id)
        store.beginRename()
        let draft = try #require(store.nameEdit)
        store.updateProposedName("proposed.txt", sessionID: draft.id)
        var shown: [FileAccessContext?] = []
        store.onShowAccessHelp = { shown.append($0) }
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        store.showAccessHelp()
        #expect(shown.isEmpty)
        await driver.failWrite(0, FileOperationError.systemFailure(operation: "Rename", code: code))
        try await waitUntil { !store.isPerformingOperation }
        let issue = try #require(store.nameEdit?.accessIssue)
        #expect(issue.failure == (code == EROFS ? .readOnlyVolume : .permissionDenied))
        #expect(issue.locations == [root])
        store.showAccessHelp(issue)
        #expect(shown.count == 1 && shown[0] == issue)
        #expect(store.nameEdit?.id == draft.id && store.nameEdit?.proposedName == "proposed.txt")
        #expect(store.nameEdit?.errorMessage != nil && store.nameEdit?.accessIssue == issue)
        #expect(await driver.writes.count == 1)
        #expect(await driver.reads.count == 1)
        store.updateProposedName("retry.txt", sessionID: draft.id)
        #expect(store.nameEdit?.accessIssue == nil)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 2 }
        let request = await driver.writes[1]
        #expect(request.name == "retry.txt" && ItemOperationContext.filesystem(request.context) == draft.context && request.item == original)
        let renamed = item("retry.txt")
        await driver.wrote(1, FileOperationResult(url: renamed.url, identity: renamed.identity, warning: nil))
        try await waitUntil { await driver.reads.count == 2 }
        await driver.read(1, snapshot([renamed]))
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.nameEdit == nil && store.operationAccessIssue == nil)
    }

    @Test
    func helpDuringPendingNavigationDoesNotCancelOrReplaceTheRequestedLoad() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, destination = root.appendingPathComponent("Pending", isDirectory: true)
        var shown = 0
        store.onShowAccessHelp = { context in #expect(context == nil); shown += 1 }
        store.navigate(to: destination)
        try await waitUntil { await driver.reads.count == 2 }
        store.showAccessHelp()
        #expect(shown == 1 && store.activeTab.isLoading && store.activeTab.url == root)
        await driver.read(1, snapshot())
        try await settled(store)
        #expect(store.activeTab.url == destination && store.activeTab.history.backStack == [root])
        #expect(await driver.reads.count == 2)
    }

    @Test
    func aCommittedRenameAccessWarningOffersHelpWithoutRestoringARetryableDraft() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, original = item(), renamed = item("done.txt")
        store.setSelection([original.id], focusedID: original.id)
        store.beginRename()
        let draft = try #require(store.nameEdit)
        store.updateProposedName(renamed.name, sessionID: draft.id)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        await driver.wrote(0, FileOperationResult(url: renamed.url, identity: nil,
            warning: "The rename completed, but its result could not be inspected.", accessFailure: .permissionDenied))
        try await waitUntil { await driver.reads.count == 2 }
        await driver.read(1, snapshot([renamed]))
        try await waitUntil { !store.isPerformingOperation }
        let issue = try #require(store.operationAccessIssue)
        #expect(issue.failure == .permissionDenied && issue.locations == [root])
        #expect(store.nameEdit == nil && store.activeTab.items == [renamed])
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        var shown = 0
        store.onShowAccessHelp = { #expect($0 == issue); shown += 1 }
        store.showAccessHelp(issue)
        store.refresh()
        try await waitUntil { await driver.reads.count == 3 }
        await driver.read(2, snapshot([renamed]))
        try await settled(store)
        #expect(shown == 1 && store.nameEdit == nil)
        #expect(await driver.writes.count == 1)
    }

    @Test
    func ordinaryMissingFileAndCollisionErrorsDoNotAcquirePermissionGuidance() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver
        store.refresh()
        try await waitUntil { await driver.reads.count == 2 }
        await driver.failRead(1, CocoaError(.fileReadNoSuchFile))
        try await settled(store)
        #expect(store.activeTab.errorMessage != nil && store.activeTab.accessIssue == nil)
        store.retry()
        try await waitUntil { await driver.reads.count == 3 }
        await driver.read(2, snapshot([item()]))
        try await settled(store)
        store.beginCreateFolder()
        let draft = try #require(store.nameEdit)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        await driver.failWrite(0, FileOperationError.collision(draft.proposedName))
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.nameEdit?.errorMessage != nil && store.nameEdit?.accessIssue == nil)
    }

    @Test(arguments: ["Trash", "Copy"])
    func batchAccessFailureRetainsAffectedLocationsUntilItsNoticeIsDismissed(_ action: String) async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver, original = item()
        store.setSelection([original.id], focusedID: original.id)
        var destination = root
        var nextRead = 1
        if action == "Copy" {
            store.copySelection()
            destination = root.appendingPathComponent("Destination", isDirectory: true)
            store.navigate(to: destination)
            try await waitUntil { await driver.reads.count == 2 }
            await driver.read(1, snapshot())
            try await settled(store)
            store.pasteSelection()
            try await waitUntil { await driver.transferItems.count == 1 }
            await driver.failTransfer(FileOperationError.systemFailure(operation: "Copy", code: EACCES))
            nextRead = 2
        } else {
            store.trashSelection()
            try await waitUntil { await driver.trashItems.count == 1 }
            await driver.failTrash(CocoaError(.fileWriteNoPermission))
        }
        try await waitUntil { await driver.reads.count == nextRead + 1 }
        await driver.read(nextRead, snapshot(action == "Trash" ? [original] : []))
        try await waitUntil { !store.isPerformingOperation }
        let issue = try #require(store.operationAccessIssue)
        #expect(issue.failure == .permissionDenied)
        #expect(issue.locations == (action == "Copy" ? [root, destination] : [root]))
        var shown = 0
        store.onShowAccessHelp = { #expect($0 == issue); shown += 1 }
        store.showAccessHelp(issue)
        #expect(shown == 1 && store.operationNotice != nil && store.operationAccessIssue == issue)
        #expect(await driver.trashItems.count == (action == "Trash" ? 1 : 0))
        #expect(await driver.transferItems.count == (action == "Copy" ? 1 : 0))
        store.dismissOperationNotice()
        #expect(store.operationNotice == nil && store.operationAccessIssue == nil)
    }

    @Test
    func deniedRestoreKeepsTheReceiptAndPanelWhenAccessHelpIsOpened() async throws {
        let fixture = try await ready()
        defer { fixture.stop() }
        let store = fixture.store, driver = fixture.driver
        let trash = root.appendingPathComponent("Synthetic Trash", isDirectory: true)
        let receipt = TrashReceipt(original: item(),
            originalContext: FileOperationContext(directoryURL: root, directoryIdentity: identity()),
            trashed: item(under: trash),
            trashContext: FileOperationContext(directoryURL: trash, directoryIdentity: identity(200)))
        store.recoveryHistory.record(receipt)
        store.showRecovery()
        store.restore(receipt.id, as: "restored.txt")
        try await waitUntil { await driver.restoreIDs.count == 1 }
        await driver.failRestore(CocoaError(.fileWriteNoPermission))
        try await waitUntil { !store.isPerformingOperation }
        let issue = try #require(store.recoveryAccessIssue)
        #expect(issue.failure == .permissionDenied && issue.locations == [receipt.originalContext.directoryURL])
        // Receipt access authorizes recovery of this item, not listing its Trash parent.
        #expect(!issue.locations.contains(trash))
        var shown = 0
        store.onShowAccessHelp = { #expect($0 == issue); shown += 1 }
        store.showAccessHelp(issue)
        #expect(shown == 1 && store.isShowingRecovery && store.recoveryError != nil)
        #expect(store.recoveryHistory.entries.map(\.id) == [receipt.id])
        #expect(store.recoveryHistory.claimedIDs.isEmpty && store.canRestore(receipt.id))
        #expect(await driver.restoreIDs.count == 1)
        #expect(await driver.reads.count == 1)
        store.dismissRecovery()
        #expect(store.recoveryAccessIssue == nil && store.recoveryError == nil)
    }
}
