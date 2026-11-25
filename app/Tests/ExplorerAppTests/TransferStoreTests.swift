import AppKit
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Explicit continuations let tests retain a completed prefix while another item waits.
/// No source/destination path is ever accessed by this test double.
private actor TransferStoreDriver: DirectoryListing, FileTransferring {
    struct Call: Sendable {
        let item: FileItem
        let source: FileOperationContext
        let destination: FileOperationContext
        let name: String
        let kind: TransferKind
        let control: TransferControl
        let progress: @Sendable (TransferProgress) -> Void
    }
    private(set) var reads: [URL] = []
    private(set) var calls: [Call] = []
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingTransfers: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[reads.count] = continuation
            reads.append(url)
        }
    }
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingTransfers[calls.count] = continuation
            calls.append(Call(item: item, source: from, destination: to, name: name,
                              kind: kind, control: control, progress: onProgress))
        }
    }
    func read(_ index: Int, _ value: DirectorySnapshot) { pendingReads.removeValue(forKey: index)?.resume(returning: value) }
    func failRead(_ index: Int) { pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func complete(_ index: Int, _ item: FileItem) {
        pendingTransfers.removeValue(forKey: index)?.resume(returning: FileOperationResult(url: item.url, identity: item.identity, warning: nil))
    }
    func fail(_ index: Int, _ error: any Error = FileOperationError.staleSource) {
        pendingTransfers.removeValue(forKey: index)?.resume(throwing: error)
    }
    func progress(_ index: Int, name: String, bytes: Int64) {
        calls[index].progress(TransferProgress(currentName: name, bytesCopied: bytes))
    }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), transfers = Array(pendingTransfers.values)
        pendingReads.removeAll(); pendingTransfers.removeAll()
        for pending in reads { pending.resume(throwing: CancellationError()) }
        for pending in transfers { pending.resume(throwing: CancellationError()) }
    }
}

private actor TransferCheckpointProbe {
    private(set) var outcome: Bool?
    func finish(_ succeeded: Bool) { outcome = succeeded }
}

@MainActor
private final class TransferStoreFixture {
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerTransferStoreTests-\(UUID().uuidString)"))
    let driver = TransferStoreDriver()
    let clipboard: TransferClipboard
    let store: ExplorerStore
    init(source: URL) {
        clipboard = TransferClipboard(pasteboard: board)
        store = ExplorerStore(initialURL: source, loader: driver, homeURL: source,
                              transfers: driver, clipboard: clipboard)
    }
    func stop() {
        store.cancelTransfer()
        store.cancelLoads()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
}

/// Store coverage supporting FR-FILE-003/004 (EV-0252/0255, AT-FILE-003/004),
/// completed-prefix retention in FR-FILE-012 (EV-0417, AT-FILE-012), and explicit
/// Keep Both in FR-FILE-017 (EV-0102, AT-FILE-017). Conflict presentation, clipboard
/// ownership, suffix retries and identity reconciliation are native policies; these
/// model checks do not establish Windows dialog/graph fidelity or filesystem bytes.
@MainActor
final class TransferStoreTests {
    private let source = URL(fileURLWithPath: "/tmp/explorer-transfer-model/Source", isDirectory: true)
    private let target = URL(fileURLWithPath: "/tmp/explorer-transfer-model/Target", isDirectory: true)
    private func identity(_ inode: UInt64) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String, destination: Bool = false, inode: UInt64 = 1000,
                      directory: Bool = false, link: Bool = false) -> FileItem {
        FileItem(url: (destination ? target : source).appendingPathComponent(name, isDirectory: directory),
                 name: name, isDirectory: directory, isSymbolicLink: link,
                 size: directory ? nil : 24, modifiedAt: nil, kind: "Test item", identity: identity(inode))
    }
    private func snapshot(_ entries: [FileItem] = [], parent: UInt64 = 200) -> DirectorySnapshot {
        DirectorySnapshot(items: entries, directoryIdentity: identity(parent))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Expected transfer state was not reached within the bounded deadline")
    }
    private func requireRunning(_ control: TransferControl) async throws {
        let probe = TransferCheckpointProbe()
        let checkpoint = Task.detached {
            do { try control.checkpoint(); await probe.finish(true) }
            catch { await probe.finish(false) }
        }
        do {
            try await waitUntil { await probe.outcome != nil }
            #expect(await probe.outcome == true)
            await checkpoint.value
        } catch {
            // A regression must fail with a bounded deadline, never block the main
            // actor or leave a paused checkpoint worker alive after the test.
            control.cancel()
            checkpoint.cancel()
            await checkpoint.value
            throw error
        }
    }
    private func prepared(_ names: [String] = ["a.txt"], kind: TransferKind = .copy) async throws -> TransferStoreFixture {
        let fixture = TransferStoreFixture(source: source)
        let entries = names.enumerated().map { item($0.element, inode: UInt64(1000 + $0.offset)) }
        try await waitUntil { await fixture.driver.reads.count == 1 }
        await fixture.driver.read(0, snapshot(entries, parent: 100))
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.store.setSelection(Set(entries.map(\.id)), focusedID: entries.first?.id)
        if kind == .copy { fixture.store.copySelection() } else { fixture.store.cutSelection() }
        _ = try #require(fixture.clipboard.payload)
        fixture.store.openTab(at: target)
        try await waitUntil { await fixture.driver.reads.count == 2 }
        await fixture.driver.read(1, snapshot())
        try await waitUntil { !fixture.store.activeTab.isLoading }
        return fixture
    }
    private func verify(_ fixture: TransferStoreFixture, entries: [FileItem], readIndex: Int = 2,
                        parent: UInt64 = 200) async throws {
        try await waitUntil { await fixture.driver.reads.count == readIndex + 1 }
        await fixture.driver.read(readIndex, snapshot(entries, parent: parent))
        try await waitUntil { !fixture.store.isPerformingOperation }
    }

    @Test
    func copyCapturesTheSourceAcrossTabsAndRunsOneSequentialBatch() async throws {
        let f = try await prepared(["b.txt", "a.txt"])
        defer { f.stop() }
        let payload = try #require(f.clipboard.payload)
        let originalItems = f.store.tabs[0].items
        #expect(payload.items.map(\.name) == ["a.txt", "b.txt"])
        #expect(await f.driver.calls.isEmpty)
        f.store.pasteSelection()
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let first = try #require(await f.driver.calls.first)
        #expect(first.source == FileOperationContext(directoryURL: source, directoryIdentity: identity(100)))
        #expect(first.destination == FileOperationContext(directoryURL: target, directoryIdentity: identity(200)))
        #expect(first.item == payload.items[0] && first.kind == .copy && first.name == "a.txt")
        #expect(f.store.transfer?.totalItems == 2 && !f.store.canPaste)
        let a = item("a.txt", destination: true, inode: 2000), b = item("b.txt", destination: true, inode: 2001)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.transfer?.completedItems == 1)
        #expect(await f.driver.calls[1].name == "b.txt")
        await f.driver.complete(1, b)
        try await waitUntil { await f.driver.reads.count == 3 }
        #expect(f.store.isPerformingOperation && f.store.transfer == nil)
        #expect(f.store.activeTab.items.isEmpty && f.store.activeTab.selection.selectedIDs.isEmpty)
        try await verify(f, entries: [a, b])
        #expect(f.store.activeTab.selection.selectedIDs == [a.id, b.id])
        #expect(f.store.tabs[0].items == originalItems)
        #expect(f.clipboard.payload?.id == payload.id && f.store.canPaste)
        #expect(f.store.operationNotice?.contains("Copied 2 of 2") == true)
    }

    @Test(arguments: ["cut", "move-here"])
    func moveIntentIsConsumedBeforeStartingEvenWhenTheBatchFails(_ command: String) async throws {
        let f = try await prepared(kind: command == "cut" ? .move : .copy)
        defer { f.stop() }
        if command == "cut" { f.store.pasteSelection() } else { f.store.moveHere() }
        #expect(f.clipboard.payload == nil)
        try await waitUntil { await f.driver.calls.count == 1 }
        #expect(await f.driver.calls[0].kind == .move)
        await f.driver.fail(0)
        try await verify(f, entries: [])
        #expect(f.store.operationNotice?.contains("Moved 0 of 1") == true)
        #expect(f.store.operationNotice?.contains("Stopped") == true)
        #expect(!f.store.canPaste)
        f.store.pasteSelection()
        #expect(await f.driver.calls.count == 1)
    }

    @Test
    func externalClipboardReplacementCannotStartAFileTransfer() async throws {
        let f = try await prepared()
        defer { f.stop() }
        f.board.clearContents()
        try #require(f.board.setString("external content", forType: .string))
        #expect(!f.store.canPaste)
        f.store.pasteSelection()
        f.store.moveHere()
        #expect(f.store.transfer == nil && !f.store.isPerformingOperation)
        #expect(await f.driver.calls.isEmpty)
        #expect(f.board.string(forType: .string) == "external content")
    }

    @Test
    func failureStopsAtTheCurrentItemAndRetainsTheCompletedPrefix() async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1)
        try await verify(f, entries: [a])
        #expect(await f.driver.calls.count == 2)
        #expect(f.store.activeTab.selection.selectedIDs == [a.id])
        #expect(f.store.operationNotice?.contains("Copied 1 of 3") == true)
        #expect(f.store.operationNotice?.contains("Stopped") == true)
        #expect(f.clipboard.payload?.kind == .copy)
    }

    @Test
    func skippingAConflictContinuesTheBatchWithoutSelectingTheSkippedItem() async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000), c = item("c.txt", destination: true, inode: 2002)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, FileOperationError.collision("b.txt"))
        try await waitUntil { f.store.transfer?.conflictName == "b.txt" }
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == false)
        f.store.resolveTransferConflict(.skip)
        try await waitUntil { await f.driver.calls.count == 3 }
        #expect(f.store.transfer?.skippedItems == 1)
        await f.driver.complete(2, c)
        let existing = item("b.txt", destination: true, inode: 9000)
        try await verify(f, entries: [a, existing, c])
        #expect(f.store.activeTab.selection.selectedIDs == [a.id, c.id])
        #expect(f.store.operationNotice?.contains("Copied 2 of 3") == true)
        #expect(f.store.operationNotice?.contains("Skipped 1") == true)
    }

    @Test
    func serviceCancellationKeepsCompletedPrefixAndCancellationNotice() async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, CancellationError())
        try await verify(f, entries: [a])
        #expect(await f.driver.calls.count == 2)
        #expect(f.store.activeTab.selection.selectedIDs == [a.id])
        #expect(f.store.operationNotice?.contains("Copied 1 of 3") == true)
        #expect(f.store.operationNotice?.contains("Cancelled; completed items were retained") == true)
        #expect(f.store.operationNotice?.contains("Stopped") == false)
    }

    @Test
    func conflictReplyIsConsumedOnceBeforeTheNextItem() async throws {
        let f = try await prepared(["a.txt", "b.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        await f.driver.fail(0, FileOperationError.collision("a.txt"))
        try await waitUntil { f.store.transfer?.conflictName == "a.txt" }
        f.store.resolveTransferConflict(.skip)
        f.store.resolveTransferConflict(.cancel)
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.transfer?.isCancelling == false)
        let b = item("b.txt", destination: true, inode: 2001)
        await f.driver.complete(1, b)
        try await verify(f, entries: [b])
        #expect(f.store.operationNotice?.contains("Skipped 1") == true)
        #expect(f.store.operationNotice?.contains("Cancelled") == false)
    }

    @Test(arguments: ["conflict-choice", "cancel-command"])
    func cancellingAConflictRetainsCompletedItemsAndStartsNoLaterItem(_ cancellation: String) async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, FileOperationError.collision("b.txt"))
        try await waitUntil { f.store.transfer?.conflictName != nil }
        if cancellation == "conflict-choice" { f.store.resolveTransferConflict(.cancel) }
        else { f.store.cancelTransfer() }
        try await verify(f, entries: [a])
        #expect(await f.driver.calls.count == 2)
        #expect(f.store.activeTab.selection.selectedIDs == [a.id])
        #expect(f.store.operationNotice?.contains("Cancelled; completed items were retained") == true)
    }

    @Test
    func pauseResumeAndCancelReachTheCurrentServiceControl() async throws {
        let f = try await prepared(["a.txt", "b.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.progress(1, name: "b.txt", bytes: 12)
        try await waitUntil { f.store.transfer?.bytesCopied == 12 }
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == true)
        f.store.resumeTransfer()
        #expect(f.store.transfer?.isPaused == false)
        let control = await f.driver.calls[1].control
        try control.checkpoint()
        f.store.pauseTransfer()
        f.store.cancelTransfer()
        #expect(f.store.transfer?.isCancelling == true && f.store.transfer?.isPaused == false)
        #expect(throws: CancellationError.self) { try control.checkpoint() }
        await f.driver.fail(1, CancellationError())
        try await verify(f, entries: [a])
        #expect(f.store.activeTab.selection.selectedIDs == [a.id])
        #expect(f.store.operationNotice?.contains("Copied 1 of 2") == true)
    }

    @Test
    func pausingAMoveLeavesItsServiceGateRunningAndCancellationStillRetainsCompletedItems() async throws {
        let f = try await prepared(["a.txt", "b.txt", "c.txt"], kind: .move)
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let first = await f.driver.calls[0]
        #expect(first.kind == .move)
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == false)
        try await requireRunning(first.control)
        let a = item("a.txt", destination: true, inode: 1000)
        let b = item("b.txt", destination: true, inode: 1001)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        let second = await f.driver.calls[1]
        #expect(second.kind == .move && second.name == "b.txt")
        #expect(f.store.transfer?.completedItems == 1)
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == false)
        try await requireRunning(second.control)
        await f.driver.complete(1, b)
        try await waitUntil { await f.driver.calls.count == 3 }
        #expect(f.store.transfer?.completedItems == 2)
        f.store.cancelTransfer()
        #expect(f.store.transfer?.isCancelling == true && f.store.transfer?.isPaused == false)
        let thirdControl = await f.driver.calls[2].control
        #expect(throws: CancellationError.self) { try thirdControl.checkpoint() }
        await f.driver.fail(2, CancellationError())
        try await verify(f, entries: [a, b])
        #expect(f.store.activeTab.selection.selectedIDs == [a.id, b.id])
        #expect(f.store.operationNotice?.contains("Moved 2 of 3") == true)
        #expect(f.store.operationNotice?.contains("Cancelled; completed items were retained") == true)
        #expect(f.clipboard.payload == nil)
    }

    @Test
    func keepBothRetriesAnExclusiveCandidateCollisionWithoutAnotherImplicitDecision() async throws {
        let f = try await prepared(["report.tar.gz"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        await f.driver.fail(0, FileOperationError.collision("report.tar.gz"))
        try await waitUntil { f.store.transfer?.conflictName == "report.tar.gz" }
        #expect(await f.driver.calls.count == 1)
        f.store.resolveTransferConflict(.keepBoth)
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(await f.driver.calls[1].name == "report.tar (2).gz")
        await f.driver.fail(1, FileOperationError.collision("report.tar (2).gz"))
        try await waitUntil { await f.driver.calls.count == 3 }
        #expect(f.store.transfer?.conflictName == nil)
        #expect(await f.driver.calls[2].name == "report.tar (3).gz")
        let copied = item("report.tar (3).gz", destination: true, inode: 2000)
        await f.driver.complete(2, copied)
        try await verify(f, entries: [copied])
        #expect(f.store.activeTab.selection.selectedIDs == [copied.id])
    }

    @Test
    func keepBothNamingSeparatesOnlyARegularVisibleFilesFinalExtension() {
        #expect(transferCopyName(for: item("a.txt"), attempt: 1) == "a - Copy.txt")
        #expect(transferCopyName(for: item("archive.tar.gz"), attempt: 2) == "archive.tar - Copy (2).gz")
        #expect(transferCopyName(for: item(".hidden.txt"), attempt: 1) == ".hidden.txt - Copy")
        #expect(transferCopyName(for: item("folder.ext", directory: true), attempt: 1) == "folder.ext - Copy")
        #expect(transferCopyName(for: item("shortcut.txt", link: true), attempt: 1) == "shortcut.txt - Copy")
    }

    @Test
    func staleProgressCannotOverwriteANewerItemOrANewerBatch() async throws {
        let f = try await prepared(["a.txt", "b.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000), b = item("b.txt", destination: true, inode: 2001)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.progress(1, name: "current-item", bytes: 8)
        try await waitUntil { f.store.transfer?.currentName == "current-item" }
        await f.driver.progress(0, name: "obsolete-item", bytes: 999)
        await f.driver.progress(1, name: "late-current-item", bytes: 7)
        // Bounded negative window for the progress callback's hop to the main actor.
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.store.transfer?.currentName == "current-item" && f.store.transfer?.bytesCopied == 8)
        await f.driver.complete(1, b)
        try await verify(f, entries: [a, b])
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 3 }
        await f.driver.progress(2, name: "new-batch", bytes: 4)
        try await waitUntil { f.store.transfer?.currentName == "new-batch" }
        await f.driver.progress(1, name: "obsolete-batch", bytes: 1000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.store.transfer?.currentName == "new-batch" && f.store.transfer?.bytesCopied == 4)
        f.store.cancelTransfer()
        await f.driver.fail(2, CancellationError())
        try await verify(f, entries: [a, b], readIndex: 3)
    }

    @Test
    func verificationSelectsOnlyResultsWhoseFreshIdentityMatches() async throws {
        let f = try await prepared(["a.txt", "b.txt"])
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let a = item("a.txt", destination: true, inode: 2000), b = item("b.txt", destination: true, inode: 2001)
        await f.driver.complete(0, a)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.complete(1, b)
        let replacement = item("b.txt", destination: true, inode: 9000)
        try await verify(f, entries: [a, replacement])
        #expect(f.store.activeTab.selection.selectedIDs == [a.id])
        #expect(f.store.activeTab.selection.focusedID == a.id)
        #expect(f.store.operationNotice?.contains("Copied 2 of 2") == true)
        #expect(f.store.operationNotice?.contains("could not be verified") == true)
    }

    @Test
    func committedTransferWithFailedReloadPreservesItsSummaryAndRetryOnlyReads() async throws {
        let f = try await prepared()
        defer { f.stop() }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let copied = item("a.txt", destination: true, inode: 2000)
        await f.driver.complete(0, copied)
        try await waitUntil { await f.driver.reads.count == 3 }
        await f.driver.failRead(2)
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.store.activeTab.isUnavailable && f.store.transfer == nil)
        #expect(f.store.operationNotice?.contains("Copied 1 of 1") == true)
        #expect(f.store.operationNotice?.contains("Retry only reloads") == true)
        f.store.retry()
        try await waitUntil { await f.driver.reads.count == 4 }
        #expect(await f.driver.calls.count == 1)
        await f.driver.read(3, snapshot([copied]))
        try await waitUntil { !f.store.activeTab.isLoading }
        #expect(!f.store.activeTab.isUnavailable && f.store.activeTab.items == [copied])
        #expect(await f.driver.calls.count == 1)
    }

    @Test
    func transferAndVerificationPreventNavigationClosingAndAnotherMutation() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let ids = f.store.tabs.map(\.id), active = f.store.activeTabID
        let intent = try #require(f.clipboard.payload)
        var detached = false
        f.store.onDetachTab = { _, _ in detached = true }
        f.store.pasteSelection()
        try await waitUntil { await f.driver.calls.count == 1 }
        let copied = item("a.txt", destination: true, inode: 2000)
        for verifying in [false, true] {
            if verifying {
                await f.driver.complete(0, copied)
                try await waitUntil { await f.driver.reads.count == 3 }
            }
            f.store.navigate(to: source); f.store.up(); f.store.back(); f.store.refresh()
            f.store.activateTab(ids[0]); f.store.addTab(); f.store.closeTab(active)
            f.store.closeOtherTabs(ids[0]); f.store.closeTabsToRight(ids[0]); f.store.detachTab(active)
            f.store.beginCreateFolder(); f.store.beginRename(); f.store.copySelection(); f.store.cutSelection()
            f.store.pasteSelection(); f.store.moveHere(); f.store.toggleHidden()
            #expect(f.store.tabs.map(\.id) == ids && f.store.activeTabID == active)
            #expect(f.store.activeTab.url == target && f.store.nameEdit == nil && !f.store.showHidden)
            #expect(!f.store.canDetachTab(active) && !detached)
            #expect(f.clipboard.payload?.id == intent.id)
            #expect(await f.driver.calls.count == 1)
            #expect(await f.driver.reads.count == (verifying ? 3 : 2))
        }
        try await verify(f, entries: [copied])
        f.store.closeTab(active)
        #expect(f.store.tabs.count == 1 && f.store.activeTabID == ids[0])
    }

    @Test
    func aSharedClipboardCarriesTheCapturedSelectionToAnotherWindow() async throws {
        let f = try await prepared()
        defer { f.stop() }
        let secondDriver = TransferStoreDriver()
        let second = ExplorerStore(initialURL: target, loader: secondDriver,
                                   transfers: secondDriver, clipboard: f.clipboard)
        defer {
            second.cancelTransfer(); second.cancelLoads()
            Task { await secondDriver.shutdown() }
        }
        try await waitUntil { await secondDriver.reads.count == 1 }
        await secondDriver.read(0, snapshot())
        try await waitUntil { !second.activeTab.isLoading }
        #expect(second.canPaste)
        second.pasteSelection()
        try await waitUntil { await secondDriver.calls.count == 1 }
        #expect(await secondDriver.calls[0].source.directoryURL == source)
        #expect(await f.driver.calls.isEmpty)
        let copied = item("a.txt", destination: true, inode: 2000)
        await secondDriver.complete(0, copied)
        try await waitUntil { await secondDriver.reads.count == 2 }
        await secondDriver.read(1, snapshot([copied]))
        try await waitUntil { !second.isPerformingOperation }
        #expect(second.activeTab.selection.selectedIDs == [copied.id])
        #expect(f.clipboard.payload?.kind == .copy)
    }
}
