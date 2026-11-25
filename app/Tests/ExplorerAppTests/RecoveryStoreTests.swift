import AppKit
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Controlled calls access no paths and intentionally allow a committed Trash result
/// to arrive after cancellation. Closing the fixture also rejects future reads.
private actor RecoveryStoreDriver: DirectoryListing, FileRecovering, FileOperating {
    struct TrashCall: Sendable { let item: FileItem; let context: FileOperationContext }
    struct RestoreCall: Sendable { let receipt: TrashReceipt; let name: String }
    struct WriteCall: Sendable { let item: FileItem?; let name: String; let context: FileOperationContext }
    private(set) var reads: [URL] = []
    private(set) var trashCalls: [TrashCall] = []
    private(set) var restoreCalls: [RestoreCall] = []
    private(set) var writes: [WriteCall] = []
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingTrash: [Int: CheckedContinuation<TrashResult, Error>] = [:]
    private var pendingRestore: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]
    private var pendingWrites: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[reads.count] = continuation; reads.append(url)
        }
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingTrash[trashCalls.count] = continuation; trashCalls.append(TrashCall(item: item, context: context))
        }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRestore[restoreCalls.count] = continuation; restoreCalls.append(RestoreCall(receipt: receipt, name: name))
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
        return try await withCheckedThrowingContinuation { continuation in
            pendingWrites[writes.count] = continuation; writes.append(WriteCall(item: item, name: name, context: context))
        }
    }
    func read(_ index: Int, _ snapshot: DirectorySnapshot) { pendingReads.removeValue(forKey: index)?.resume(returning: snapshot) }
    func failRead(_ index: Int) { pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func trashed(_ index: Int, receipt: TrashReceipt?, warning: String? = nil) {
        pendingTrash.removeValue(forKey: index)?.resume(returning: TrashResult(receipt: receipt, warning: warning))
    }
    func failTrash(_ index: Int, _ error: any Error = FileOperationError.staleSource) {
        pendingTrash.removeValue(forKey: index)?.resume(throwing: error)
    }
    func restored(_ index: Int, _ result: FileOperationResult) { pendingRestore.removeValue(forKey: index)?.resume(returning: result) }
    func failRestore(_ index: Int, _ error: any Error = FileOperationError.collision("a.txt")) {
        pendingRestore.removeValue(forKey: index)?.resume(throwing: error)
    }
    func wrote(_ index: Int, _ result: FileOperationResult) { pendingWrites.removeValue(forKey: index)?.resume(returning: result) }
    func failWrite(_ index: Int, _ error: any Error = FileOperationError.staleSource) {
        pendingWrites.removeValue(forKey: index)?.resume(throwing: error)
    }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), trash = Array(pendingTrash.values)
        let restore = Array(pendingRestore.values), writes = Array(pendingWrites.values)
        pendingReads.removeAll(); pendingTrash.removeAll(); pendingRestore.removeAll(); pendingWrites.removeAll()
        for call in reads { call.resume(throwing: CancellationError()) }
        for call in trash { call.resume(throwing: CancellationError()) }
        for call in restore + writes { call.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class RecoveryStoreFixture {
    let driver = RecoveryStoreDriver()
    let history: RecoveryHistory
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerRecoveryStoreTests-\(UUID().uuidString)"))
    let store: ExplorerStore
    init(url: URL, history: RecoveryHistory? = nil) {
        self.history = history ?? RecoveryHistory()
        store = ExplorerStore(initialURL: url, loader: driver, homeURL: url, operations: driver,
                              clipboard: TransferClipboard(pasteboard: board), recovery: driver,
                              recoveryHistory: self.history)
    }
    func stop() {
        store.cancelTrash(); store.cancelLoads()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// Model subsets of FR-FILE-005/007/011, EV-0448/0453/0240, AT-FILE-005/007/011.
/// Receipt scope/claims, partial batches and exclusive restore retry are explicit native
/// policies. These checks do not claim system Trash bytes, GUI routing or Windows parity.
@MainActor
final class RecoveryStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-recovery-model/Source", isDirectory: true)
    private let trash = URL(fileURLWithPath: "/tmp/explorer-recovery-model/Trash", isDirectory: true)
    private func identity(_ inode: UInt64) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private var context: FileOperationContext { FileOperationContext(directoryURL: root, directoryIdentity: identity(100)) }
    private func item(_ name: String = "a.txt", inode: UInt64 = 1000, in directory: URL? = nil) -> FileItem {
        FileItem(url: (directory ?? root).appendingPathComponent(name), name: name, isDirectory: false,
                 isSymbolicLink: false, size: 26, modifiedAt: nil, kind: "Text Document", identity: identity(inode))
    }
    private func renamed(_ original: FileItem, _ name: String) -> FileItem {
        FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: original.isDirectory,
                 isSymbolicLink: original.isSymbolicLink, size: original.size, modifiedAt: original.modifiedAt,
                 kind: original.kind, identity: original.identity)
    }
    private func receipt(_ original: FileItem) -> TrashReceipt {
        TrashReceipt(original: original, originalContext: context,
                     trashed: FileItem(url: trash.appendingPathComponent(original.name), name: original.name,
                                       isDirectory: original.isDirectory, isSymbolicLink: original.isSymbolicLink,
                                       size: original.size, modifiedAt: original.modifiedAt, kind: original.kind, identity: original.identity),
                     trashContext: FileOperationContext(directoryURL: trash, directoryIdentity: identity(200)))
    }
    private func result(_ entry: FileItem) -> FileOperationResult {
        FileOperationResult(url: entry.url, identity: entry.identity, warning: nil)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Recovery state did not settle within the bounded deadline")
    }
    private func read(_ f: RecoveryStoreFixture, _ index: Int, _ entries: [FileItem], parent: UInt64 = 100) async throws {
        try await waitUntil { await f.driver.reads.count == index + 1 }
        await f.driver.read(index, DirectorySnapshot(items: entries, directoryIdentity: identity(parent)))
        try await waitUntil { !f.store.activeTab.isLoading && !f.store.isPerformingOperation }
    }
    private func prepared(_ names: [String] = ["a.txt"], history: RecoveryHistory? = nil) async throws -> RecoveryStoreFixture {
        let f = RecoveryStoreFixture(url: root, history: history)
        let entries = names.enumerated().map { item($0.element, inode: UInt64(1000 + $0.offset)) }
        try await read(f, 0, entries)
        f.store.setSelection(Set(entries.map(\.id)), focusedID: entries.first?.id)
        return f
    }
    private func commitRename(_ f: RecoveryStoreFixture, original: FileItem, to name: String = "renamed.txt") async throws -> FileItem {
        let writeIndex = await f.driver.writes.count, readIndex = await f.driver.reads.count
        f.store.setSelection([original.id], focusedID: original.id)
        f.store.beginRename()
        let edit = try #require(f.store.nameEdit)
        f.store.updateProposedName(name, sessionID: edit.id)
        f.store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await f.driver.writes.count == writeIndex + 1 }
        let updated = renamed(original, name)
        await f.driver.wrote(writeIndex, result(updated))
        try await read(f, readIndex, [updated])
        return updated
    }

    @Test
    func trashCapturesSelectionAndContextAndRetainsReceiptsWhenALaterItemFails() async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        let originals = f.store.sortedItems, firstReceipt = receipt(f.store.sortedItems[0])
        var closed = false
        f.store.onLastTabClosed = { closed = true }
        f.store.trashSelection()
        f.store.trashSelection()
        try await waitUntil { await f.driver.trashCalls.count == 1 }
        f.store.navigate(to: trash); f.store.closeTab(f.store.activeTabID); f.store.addTab()
        f.store.setSelection([originals[2].id], focusedID: originals[2].id)
        #expect(f.store.activeTab.url == root && f.store.tabs.count == 1 && !closed)
        let first = try #require(await f.driver.trashCalls.first)
        #expect(first.item == originals[0] && first.context == context)
        await f.driver.trashed(0, receipt: firstReceipt)
        try await waitUntil { await f.driver.trashCalls.count == 2 }
        #expect(f.history.entries.map(\.id) == [firstReceipt.id])
        #expect(f.store.trashProgress?.completedItems == 1 && f.store.trashProgress?.totalItems == 3)
        #expect(await f.driver.trashCalls[1].item == originals[1])
        #expect(await f.driver.trashCalls[1].context == context)
        await f.driver.failTrash(1)
        try await read(f, 1, Array(originals.dropFirst()))
        #expect(await f.driver.trashCalls.count == 2)
        #expect(f.history.entries.map(\.id) == [firstReceipt.id])
        #expect(f.store.activeTab.selection.selectedIDs.isEmpty && f.store.trashProgress == nil)
        #expect(f.store.operationNotice?.hasPrefix("Moved 1 of 3 selected items to Trash.") == true)
        #expect(f.store.operationNotice?.contains("Stopped") == true)
    }

    @Test(arguments: [false, true])
    func uncertainTrashReportsOnlyConfirmedCompletionsAndRetainsTheirReceipts(_ hasConfirmedPrefix: Bool) async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        let originals = f.store.sortedItems, confirmed = hasConfirmedPrefix ? 1 : 0
        let entry = receipt(originals[0])
        f.store.trashSelection()
        try await waitUntil { await f.driver.trashCalls.count == 1 }
        if hasConfirmedPrefix {
            await f.driver.trashed(0, receipt: entry)
            try await waitUntil { await f.driver.trashCalls.count == 2 }
        }
        await f.driver.failTrash(confirmed, FileRecoveryError.outcomeUncertain("The original entry was not found after the system error."))
        // The fresh snapshot can show that the uncertain call also removed an entry;
        // that is not proof of a verified Trash result or authority to invent a receipt.
        try await read(f, 1, Array(originals.dropFirst(confirmed + 1)))
        #expect(await f.driver.trashCalls.count == confirmed + 1)
        #expect(f.history.entries.map(\.id) == (hasConfirmedPrefix ? [entry.id] : []))
        #expect(f.store.operationNotice?.hasPrefix("Confirmed \(confirmed) of 3 selected items moved to Trash.") == true)
        #expect(f.store.operationNotice?.contains("outcome is uncertain") == true)
        #expect(f.store.activeTab.selection.selectedIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelTrashRetainsACommittedResultButNeverStartsTheNextItem(_ committed: Bool) async throws {
        let f = try await prepared(["a.txt", "b.txt"])
        defer { f.stop() }
        let originals = f.store.sortedItems, entry = receipt(f.store.sortedItems[0])
        f.store.trashSelection()
        try await waitUntil { await f.driver.trashCalls.count == 1 }
        f.store.cancelTrash()
        #expect(f.store.trashProgress?.isCancelling == true)
        if committed { await f.driver.trashed(0, receipt: entry) }
        else { await f.driver.failTrash(0, CancellationError()) }
        try await read(f, 1, committed ? Array(originals.dropFirst()) : originals)
        #expect(await f.driver.trashCalls.count == 1)
        #expect(f.history.entries.map(\.id) == (committed ? [entry.id] : []))
        #expect(f.store.operationNotice?.contains("Cancelled") == true)
        #expect(f.store.activeTab.selection.selectedIDs.isEmpty)
    }

    @Test
    func committedTrashWithoutAVerifiedReceiptIsReportedWithoutInventingRecovery() async throws {
        let f = try await prepared()
        defer { f.stop() }
        f.store.trashSelection()
        try await waitUntil { await f.driver.trashCalls.count == 1 }
        let warning = "The item was sent to Trash, but no verified recovery receipt is available."
        await f.driver.trashed(0, receipt: nil, warning: warning)
        try await read(f, 1, [])
        #expect(f.history.entries.isEmpty && f.history.claimedIDs.isEmpty)
        #expect(f.store.operationNotice?.contains(warning) == true)
        #expect(f.store.activeTab.items.isEmpty && f.store.activeTab.selection.selectedIDs.isEmpty)
    }

    @Test
    func trashReloadFailureRetainsItsReceiptAndRetryDoesNotTrashAgain() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let entry = receipt(f.store.activeTab.items[0])
        f.store.trashSelection()
        try await waitUntil { await f.driver.trashCalls.count == 1 }
        await f.driver.trashed(0, receipt: entry)
        try await waitUntil { await f.driver.reads.count == 2 }
        await f.driver.failRead(1)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.history.entries.map(\.id) == [entry.id] && f.store.activeTab.isUnavailable)
        #expect(f.store.operationNotice?.contains("Retry only reloads") == true)
        f.store.retry()
        try await read(f, 2, [])
        #expect(await f.driver.trashCalls.count == 1)
        #expect(f.history.entries.map(\.id) == [entry.id])
    }

    @Test
    func sharedReceiptClaimsExcludeAnotherWindowUntilFailureReleasesTheClaim() async throws {
        let history = RecoveryHistory(), entry = receipt(item())
        history.record(entry)
        let first = try await prepared([], history: history), second = try await prepared([], history: history)
        defer { first.stop(); second.stop() }
        first.store.showRecovery(); second.store.showRecovery()
        #expect(first.store.canRestore(entry.id) && second.store.canRestore(entry.id))
        first.store.restore(entry.id, as: entry.original.name)
        #expect(history.claimedIDs == [entry.id])
        #expect(!second.store.canRestore(entry.id))
        second.store.restore(entry.id, as: entry.original.name)
        try await waitUntil { await first.driver.restoreCalls.count == 1 }
        #expect(await second.driver.restoreCalls.isEmpty)
        await first.driver.failRestore(0)
        try await waitUntil { !first.store.isPerformingOperation }
        #expect(history.claimedIDs.isEmpty && history.entries.map(\.id) == [entry.id])
        #expect(first.store.isShowingRecovery && first.store.recoveryError != nil)
        second.store.restore(entry.id, as: entry.original.name)
        try await waitUntil { await second.driver.restoreCalls.count == 1 }
        await second.driver.restored(0, result(entry.original))
        try await waitUntil { await second.driver.reads.count == 2 }
        #expect(history.entries.isEmpty && history.claimedIDs.isEmpty)
        #expect(!second.store.isShowingRecovery)
        try await read(second, 1, [entry.original])
        #expect(second.store.activeTab.selection.selectedIDs == [entry.original.id])
    }

    @Test
    func restoreCollisionKeepsTheReceiptAndAnExplicitCorrectedNameUsesTheSameContext() async throws {
        let f = try await prepared([])
        defer { f.stop() }
        let entry = receipt(item()), restored = item("restored-safe.txt")
        f.history.record(entry)
        f.store.showRecovery()
        f.store.restore(entry.id, as: entry.original.name)
        try await waitUntil { await f.driver.restoreCalls.count == 1 }
        await f.driver.failRestore(0)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.store.isShowingRecovery && f.store.recoveryError != nil)
        #expect(f.history.entries.map(\.id) == [entry.id] && f.history.claimedIDs.isEmpty)
        #expect(await f.driver.reads.count == 1)
        f.store.restore(entry.id, as: restored.name)
        try await waitUntil { await f.driver.restoreCalls.count == 2 }
        let call = await f.driver.restoreCalls[1]
        #expect(call.name == restored.name && call.receipt.id == entry.id)
        #expect(call.receipt.originalContext == entry.originalContext && call.receipt.trashed == entry.trashed)
        await f.driver.restored(1, result(restored))
        try await read(f, 1, [restored])
        #expect(f.history.entries.isEmpty && !f.store.isShowingRecovery && f.store.recoveryError == nil)
        #expect(f.store.activeTab.selection.selectedIDs == [restored.id])
    }

    @Test
    func committedRestoreRetiresTheReceiptBeforeItsCapturedParentCanBeReloaded() async throws {
        let f = try await prepared([])
        defer { f.stop() }
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("Elsewhere", isDirectory: true)
        f.store.navigate(to: elsewhere)
        try await read(f, 1, [], parent: 300)
        let entry = receipt(item())
        f.history.record(entry)
        f.store.showRecovery()
        f.store.restore(entry.id, as: entry.original.name)
        try await waitUntil { await f.driver.restoreCalls.count == 1 }
        await f.driver.restored(0, result(entry.original))
        try await waitUntil { await f.driver.reads.count == 3 }
        #expect(f.history.entries.isEmpty && !f.store.isShowingRecovery)
        #expect(f.store.activeTab.url == elsewhere)
        #expect(await f.driver.reads.last == root)
        await f.driver.failRead(2)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.store.operationNotice?.contains("Retry only reloads") == true)
        f.store.retry()
        try await read(f, 3, [entry.original])
        #expect(await f.driver.restoreCalls.count == 1)
        #expect(f.store.activeTab.url == root && f.history.entries.isEmpty)
    }

    @Test
    func restoreRefusesAnInFlightRefreshWithoutClaimingOrReplacingTheRead() async throws {
        let f = try await prepared([])
        defer { f.stop() }
        let entry = receipt(item())
        f.history.record(entry)
        f.store.showRecovery()
        #expect(f.store.canRestore(entry.id))
        f.store.refresh()
        try await waitUntil { await f.driver.reads.count == 2 }
        #expect(f.store.isShowingRecovery && f.store.activeTab.isLoading)
        #expect(!f.store.canRestore(entry.id))
        f.store.restore(entry.id, as: entry.original.name)
        #expect(f.history.claimedIDs.isEmpty && !f.store.isPerformingOperation)
        #expect(await f.driver.restoreCalls.isEmpty)
        #expect(await f.driver.reads.count == 2)
        let external = item("external.txt", inode: 3000)
        try await read(f, 1, [external])
        #expect(f.store.activeTab.items == [external] && f.store.isShowingRecovery)
        #expect(f.store.canRestore(entry.id))
        f.store.restore(entry.id, as: entry.original.name)
        try await waitUntil { await f.driver.restoreCalls.count == 1 }
        #expect(f.history.claimedIDs == [entry.id])
        await f.driver.failRestore(0)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.history.claimedIDs.isEmpty && f.history.entries.map(\.id) == [entry.id])
    }

    @Test(arguments: [false, true])
    func recoveryCommandsCannotPreemptPendingNavigationWithRenameHistory(_ redo: Bool) async throws {
        let f = try await prepared()
        defer { f.stop() }
        let original = f.store.activeTab.items[0]
        _ = try await commitRename(f, original: original)
        if redo {
            f.store.undoRename()
            try await waitUntil { await f.driver.writes.count == 2 }
            await f.driver.wrote(1, result(original))
            try await read(f, 2, [original])
        }
        #expect(redo ? f.store.canRedoRename : f.store.canUndoRename)
        let writesBefore = await f.driver.writes.count, nextRead = await f.driver.reads.count
        let entry = receipt(item("recoverable.txt", inode: 4000))
        f.history.record(entry)
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("Pending", isDirectory: true)
        f.store.navigate(to: elsewhere)
        try await waitUntil { await f.driver.reads.count == nextRead + 1 }
        #expect(f.store.activeTab.isLoading && f.store.activeTab.url == root)
        #expect(!f.store.canUndoRename && !f.store.canRedoRename && !f.store.canShowRecovery)
        if redo { f.store.redoRename() } else { f.store.undoRename() }
        f.store.showRecovery()
        f.store.restore(entry.id, as: entry.original.name)
        #expect(!f.store.isPerformingOperation && !f.store.isShowingRecovery)
        #expect(f.history.claimedIDs.isEmpty)
        #expect(await f.driver.writes.count == writesBefore)
        #expect(await f.driver.restoreCalls.isEmpty)
        #expect(await f.driver.reads.count == nextRead + 1)
        let destinationEntry = item("destination.txt", inode: 3000, in: elsewhere)
        try await read(f, nextRead, [destinationEntry], parent: 300)
        #expect(f.store.activeTab.url == elsewhere && f.store.activeTab.items == [destinationEntry])
        #expect(f.store.activeTab.history.backStack.last == root)
        #expect(redo ? f.store.canRedoRename : f.store.canUndoRename)
        #expect(f.store.canShowRecovery && f.history.entries.map(\.id) == [entry.id])
    }

    @Test
    func renameUndoRedoUsesItsCapturedParentDespiteLaterNavigation() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let original = f.store.activeTab.items[0], after = try await commitRename(f, original: f.store.activeTab.items[0])
        #expect(f.store.canUndoRename && !f.store.canRedoRename)
        f.store.beginCreateFolder()
        #expect(!f.store.canUndoRename)
        f.store.cancelNameEdit()
        #expect(f.store.canUndoRename)
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("Elsewhere", isDirectory: true)
        f.store.navigate(to: elsewhere)
        try await read(f, 2, [], parent: 300)
        #expect(f.store.canUndoRename)
        f.store.undoRename()
        f.store.undoRename()
        try await waitUntil { await f.driver.writes.count == 2 }
        let undo = await f.driver.writes[1]
        #expect(undo.context == context && undo.item == after && undo.name == original.name)
        await f.driver.wrote(1, result(original))
        try await read(f, 3, [original])
        #expect(f.store.activeTab.url == root && !f.store.canUndoRename && f.store.canRedoRename)
        f.store.redoRename()
        try await waitUntil { await f.driver.writes.count == 3 }
        let redo = await f.driver.writes[2]
        #expect(redo.context == context && redo.item == original && redo.name == after.name)
        await f.driver.wrote(2, result(after))
        try await read(f, 4, [after])
        #expect(f.store.canUndoRename && !f.store.canRedoRename)
        #expect(f.store.activeTab.selection.selectedIDs == [after.id])
    }

    @Test
    func staleUndoPassesTheCapturedIdentityAndNeverSubstitutesTheReplacementRow() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let after = try await commitRename(f, original: f.store.activeTab.items[0])
        let replacement = item(after.name, inode: 9000)
        f.store.refresh()
        try await read(f, 2, [replacement])
        f.store.undoRename()
        try await waitUntil { await f.driver.writes.count == 2 }
        #expect(await f.driver.writes[1].item?.identity == after.identity)
        #expect(await f.driver.writes[1].item?.identity != replacement.identity)
        await f.driver.failWrite(1, FileOperationError.staleSource)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.store.activeTab.items == [replacement] && f.store.canUndoRename)
        #expect(f.store.operationNotice?.contains(FileOperationError.staleSource.localizedDescription) == true)
        #expect(await f.driver.reads.count == 3)
        f.store.undoRename()
        try await waitUntil { await f.driver.writes.count == 3 }
        #expect(await f.driver.writes[2].item?.identity == after.identity)
        await f.driver.failWrite(2, FileOperationError.staleSource)
        try await waitUntil { !f.store.isPerformingOperation }
    }

    @Test
    func undoDirectionCommitsBeforeReloadAndRetryDoesNotRepeatTheRename() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let original = f.store.activeTab.items[0]
        _ = try await commitRename(f, original: original)
        f.store.undoRename()
        try await waitUntil { await f.driver.writes.count == 2 }
        await f.driver.wrote(1, result(original))
        try await waitUntil { await f.driver.reads.count == 3 }
        await f.driver.failRead(2)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(!f.store.canUndoRename && f.store.canRedoRename)
        #expect(f.store.operationNotice?.contains("Retry only reloads") == true)
        f.store.retry()
        try await read(f, 3, [original])
        #expect(await f.driver.writes.count == 2)
        #expect(!f.store.canUndoRename && f.store.canRedoRename)
    }

    @Test(arguments: ["create", "rename", "trash"])
    func aNewSubmittedMutationInvalidatesRenameHistoryEvenWhenItFails(_ kind: String) async throws {
        let f = try await prepared()
        defer { f.stop() }
        let after = try await commitRename(f, original: f.store.activeTab.items[0])
        #expect(f.store.canUndoRename)
        if kind == "trash" {
            f.store.trashSelection()
            try await waitUntil { await f.driver.trashCalls.count == 1 }
            await f.driver.failTrash(0)
            try await read(f, 2, [after])
        } else {
            if kind == "create" { f.store.beginCreateFolder() } else { f.store.beginRename() }
            let edit = try #require(f.store.nameEdit)
            f.store.updateProposedName("will-fail", sessionID: edit.id)
            f.store.commitNameEdit(sessionID: edit.id)
            try await waitUntil { await f.driver.writes.count == 2 }
            await f.driver.failWrite(1)
            try await waitUntil { !f.store.isPerformingOperation }
            f.store.cancelNameEdit()
        }
        #expect(!f.store.canUndoRename && !f.store.canRedoRename)
    }

    @Test(arguments: ["no-op", "unknown identity", "different identity"])
    func onlyAVerifiedNonNoopRenameCreatesUndoHistory(_ state: String) async throws {
        let f = try await prepared()
        defer { f.stop() }
        let original = f.store.activeTab.items[0]
        let name = state == "no-op" ? original.name : "after.txt"
        f.store.beginRename()
        let edit = try #require(f.store.nameEdit)
        f.store.updateProposedName(name, sessionID: edit.id)
        f.store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await f.driver.writes.count == 1 }
        let after = renamed(original, name)
        let returnedIdentity = state == "unknown identity" ? nil
            : state == "different identity" ? identity(9000) : original.identity
        await f.driver.wrote(0, FileOperationResult(url: after.url, identity: returnedIdentity, warning: nil))
        try await read(f, 1, [after])
        #expect(!f.store.canUndoRename && !f.store.canRedoRename)
    }

    @Test
    func renameHistoryBelongsToItsWindowAndRecoveryPanelDisablesItsCommands() async throws {
        let history = RecoveryHistory()
        let first = try await prepared(history: history), second = try await prepared(history: history)
        defer { first.stop(); second.stop() }
        _ = try await commitRename(first, original: first.store.activeTab.items[0])
        #expect(first.store.canUndoRename && !second.store.canUndoRename && !second.store.canRedoRename)
        history.record(receipt(item("other.txt", inode: 2000)))
        first.store.showRecovery()
        #expect(first.store.isShowingRecovery && !first.store.canUndoRename)
        first.store.undoRename()
        #expect(await first.driver.writes.count == 1)
        first.store.dismissRecovery()
        #expect(first.store.canUndoRename)
    }
}
