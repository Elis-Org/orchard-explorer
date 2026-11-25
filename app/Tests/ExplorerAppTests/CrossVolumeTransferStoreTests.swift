import AppKit
import Combine
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Model-only IO: every read and write must be completed explicitly. Synthetic
/// device identities never reach LocalFileTransfers or an actual filesystem.
private actor P15TransferDriver: DirectoryListing, FileTransferring {
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
    private var pendingWrites: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pendingReads[reads.count] = $0
            reads.append(url)
        }
    }
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pendingWrites[calls.count] = $0
            calls.append(Call(item: item, source: from, destination: to, name: name,
                              kind: kind, control: control, progress: onProgress))
        }
    }
    func read(_ index: Int, _ snapshot: DirectorySnapshot) {
        pendingReads.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func complete(_ index: Int, _ item: FileItem, sourceRetention: String? = nil) {
        pendingWrites.removeValue(forKey: index)?.resume(returning:
            FileOperationResult(url: item.url, identity: item.identity, warning: nil,
                                sourceRetention: sourceRetention))
    }
    func fail(_ index: Int, _ error: any Error) {
        pendingWrites.removeValue(forKey: index)?.resume(throwing: error)
    }
    func complete(_ index: Int, result: FileOperationResult) {
        pendingWrites.removeValue(forKey: index)?.resume(returning: result)
    }
    func progress(_ index: Int, bytes: Int64, entries: Int, phase: TransferPhase = .copying) {
        calls[index].progress(TransferProgress(currentName: calls[index].name,
            bytesCopied: bytes, itemsCompleted: entries, phase: phase))
    }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), writes = Array(pendingWrites.values)
        pendingReads.removeAll(); pendingWrites.removeAll()
        for pending in reads { pending.resume(throwing: CancellationError()) }
        for pending in writes { pending.resume(throwing: CancellationError()) }
    }
}

/// Deliberately ignores cancellation until released, exercising late-result
/// rejection as well as allowing held, known, unknown and refused counts.
private actor P15HeldCounter: TransferCounting {
    struct Call: Sendable {
        let entries: [TransferEntry]
        let destination: FileOperationContext
        let kind: TransferKind
    }
    private(set) var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<TransferTotals?, Error>] = [:]
    private var closed = false
    func count(_ entries: [TransferEntry], destination: FileOperationContext,
               kind: TransferKind) async throws -> TransferTotals? {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending[calls.count] = $0
            calls.append(Call(entries: entries, destination: destination, kind: kind))
        }
    }
    func complete(_ index: Int = 0, totals: TransferTotals?) {
        pending.removeValue(forKey: index)?.resume(returning: totals)
    }
    func fail(_ error: any Error, at index: Int = 0) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private actor P15HeldImporter: FileTransferImporting {
    private(set) var calls: [[String]] = []
    private var pending: [Int: CheckedContinuation<[TransferEntry], Error>] = [:]
    private var closed = false
    func capture(urlStrings: [String]) async throws -> [TransferEntry] {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending[calls.count] = $0
            calls.append(urlStrings)
        }
    }
    func complete(_ index: Int = 0, entries: [TransferEntry]) {
        pending.removeValue(forKey: index)?.resume(returning: entries)
    }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private actor P15HeldPreparer: FileDropPreparing {
    struct Call: Sendable {
        let entries: [TransferEntry]
        let destinationURL: URL
        let expectedDestination: LocalFileIdentity?
        let expectedEntry: LocalFileIdentity?
        let kind: TransferKind
    }
    private(set) var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<PreparedFileDrop, Error>] = [:]
    private var closed = false
    func prepare(entries: [TransferEntry], destinationURL: URL,
                 expectedDestinationIdentity: LocalFileIdentity?, expectedEntryIdentity: LocalFileIdentity?,
                 kind: TransferKind) async throws -> PreparedFileDrop {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending[calls.count] = $0
            calls.append(Call(entries: entries, destinationURL: destinationURL,
                expectedDestination: expectedDestinationIdentity, expectedEntry: expectedEntryIdentity, kind: kind))
        }
    }
    func complete(_ index: Int = 0, destination: FileOperationContext, entries: [TransferEntry]? = nil) {
        let call = calls[index]
        pending.removeValue(forKey: index)?.resume(returning:
            PreparedFileDrop(entries: entries ?? call.entries, destination: destination, kind: call.kind))
    }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private actor P15CheckpointProbe {
    private(set) var started = false
    private(set) var succeeded: Bool?
    func start() { started = true }
    func finish(_ succeeded: Bool) { self.succeeded = succeeded }
}

@MainActor
private final class P15Fixture {
    // Unique disposable URL namespace; the IO doubles do not create/access it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerP15-\(UUID())", isDirectory: true)
    var source: URL { root.appendingPathComponent("Source", isDirectory: true) }
    var target: URL { root.appendingPathComponent("Target", isDirectory: true) }
    let board = NSPasteboard(name: .init("ExplorerP15Clipboard-\(UUID())"))
    let dragBoard = NSPasteboard(name: .init("ExplorerP15Drag-\(UUID())"))
    let driver = P15TransferDriver()
    let counter = P15HeldCounter()
    let importer = P15HeldImporter()
    let preparer = P15HeldPreparer()
    let clipboard: TransferClipboard
    let store: ExplorerStore
    var modifiers: NSEvent.ModifierFlags = []
    init() {
        clipboard = TransferClipboard(pasteboard: board)
        store = ExplorerStore(initialURL: root.appendingPathComponent("Target", isDirectory: true),
            loader: driver, homeURL: root, transfers: driver, transferImporter: importer,
            clipboard: clipboard, transferCounter: counter)
    }
    func identity(_ inode: UInt64, device: UInt64 = 2) -> LocalFileIdentity {
        LocalFileIdentity(device: device, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    var destination: FileOperationContext {
        FileOperationContext(directoryURL: target, directoryIdentity: identity(200))
    }
    func entries(_ devices: [(item: UInt64, parent: UInt64)] = [(1, 1)]) -> [TransferEntry] {
        devices.enumerated().map { index, devices in
            let parent = source.appendingPathComponent("Parent\(index)", isDirectory: true)
            let name = "\(index).txt"
            let item = FileItem(url: parent.appendingPathComponent(name), name: name,
                isDirectory: false, isSymbolicLink: false, size: 100, modifiedAt: nil, kind: "Model fixture",
                identity: identity(UInt64(1000 + index), device: devices.item))
            return TransferEntry(source: FileOperationContext(directoryURL: parent,
                directoryIdentity: identity(UInt64(100 + index), device: devices.parent)), item: item)
        }
    }
    func result(_ index: Int) -> FileItem {
        FileItem(url: target.appendingPathComponent("\(index).txt"), name: "\(index).txt",
            isDirectory: false, isSymbolicLink: false, size: 100, modifiedAt: nil, kind: "Model result",
            identity: identity(UInt64(2000 + index)))
    }
    func coordinator() -> FileDragCoordinator {
        FileDragCoordinator(importer: importer, preparer: preparer, tabHoverDelay: 60,
                            modifierFlags: { [weak self] in self?.modifiers ?? [] })
    }
    func stop() {
        store.cancelTransfer()
        store.cancelLoads()
        Task {
            await driver.shutdown(); await counter.shutdown()
            await importer.shutdown(); await preparer.shutdown()
        }
        board.releaseGlobally()
        dragBoard.releaseGlobally()
    }
}

/// NATIVE-P15 / MAC-066–069 store/model coverage for FR-FILE-015/020,
/// UI-FILE-004; EV-0102, EV-0407–0417; AT-FILE-015/020, AT-UIFILE-004.
/// Synthetic identities establish policy, not actual cross-volume IO, AppKit UI,
/// visual comparisons, source-removal safety or full Windows acceptance.
/// Evidence is the named filtered tests in this file; no milestone approval is
/// implied (the lead records the GPT-6 Astra milestone review separately).
@MainActor
final class CrossVolumeTransferStoreTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let reached = await condition()
        try #require(reached, "Phase 15 model state did not settle before the bounded deadline")
    }
    private func ready() async throws -> P15Fixture {
        let f = P15Fixture()
        do {
            try await waitUntil { await f.driver.reads.count == 1 }
            await f.driver.read(0, DirectorySnapshot(items: [], directoryIdentity: f.destination.directoryIdentity))
            try await waitUntil { f.store.activeTab.hasLoaded && !f.store.activeTab.isLoading }
            return f
        } catch { f.stop(); throw error }
    }
    private func prepared(_ f: P15Fixture, entries: [TransferEntry]? = nil, kind: TransferKind = .copy) throws {
        let binding = try #require(f.store.fileDropBinding(destinationURL: f.target))
        try #require(f.store.acceptPreparedFileDrop(PreparedFileDrop(entries: entries ?? f.entries(),
            destination: f.destination, kind: kind), binding: binding))
    }
    private func startWriter(_ f: P15Fixture, totals: TransferTotals? = nil) async throws {
        try await waitUntil { await f.counter.calls.count == 1 }
        await f.counter.complete(totals: totals)
        try await waitUntil { await f.driver.calls.count == 1 }
    }
    private func verify(_ f: P15Fixture, results: [FileItem]) async throws {
        try await waitUntil { await f.driver.reads.count == 2 }
        await f.driver.read(1, DirectorySnapshot(items: results, directoryIdentity: f.destination.directoryIdentity))
        try await waitUntil { !f.store.isPerformingOperation && !f.store.activeTab.isLoading }
    }
    private func running(_ control: TransferControl) async throws {
        let probe = P15CheckpointProbe()
        let worker = Task.detached {
            do { try control.checkpoint(); await probe.finish(true) }
            catch { await probe.finish(false) }
        }
        do {
            try await waitUntil { await probe.succeeded != nil }
            #expect(await probe.succeeded == true)
            await worker.value
        } catch {
            control.cancel(); worker.cancel(); await worker.value
            throw error
        }
    }

    /// MAC-066/068/069: counting locks out writes and Cancel rejects a late count.
    /// The asserted title-driving state maps to "Counting items…" in the private
    /// TransferProgressView.title; this test does not inspect a rendered title.
    @Test
    func countingPrecedesWritesAndCancelRejectsLateTotals() async throws {
        let f = try await ready()
        defer { f.stop() }
        let entries = f.entries()
        try prepared(f, entries: entries, kind: .move)
        try await waitUntil { await f.counter.calls.count == 1 }
        let session = try #require(f.store.transfer)
        #expect(session.isCounting && !session.isPreparing && !session.isCancelling)
        #expect(session.currentName.isEmpty && session.totals == nil && session.fraction == nil)
        #expect(!session.canPause && session.canCancel && f.store.isPerformingOperation)
        #expect(await f.driver.calls.isEmpty)
        let call = await f.counter.calls[0]
        #expect(call.entries.map(\.item) == entries.map(\.item))
        #expect(call.entries.map(\.source) == entries.map(\.source))
        #expect(call.destination == f.destination && call.kind == .move)
        f.store.cancelTransfer()
        #expect(f.store.transfer == nil && !f.store.isPerformingOperation)
        #expect(f.store.operationNotice == "Transfer cancelled before any files were changed.")
        await f.counter.complete(totals: TransferTotals(entries: [.init(items: 1, bytes: 100)]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await f.driver.calls.isEmpty)
        #expect(f.store.operationNotice == "Transfer cancelled before any files were changed.")
    }

    /// MAC-066/069: predictable refusal propagates verbatim, before any writer.
    @Test
    func counterRefusalEndsPreparedMoveWithoutWrites() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, kind: .move)
        try await waitUntil { await f.counter.calls.count == 1 }
        let message = "The source volume is read-only. Use Copy instead. No files were changed."
        await f.counter.fail(FileOperationError.unsupported(message))
        try await waitUntil { f.store.transfer == nil && !f.store.isPerformingOperation }
        #expect(f.store.operationNotice == message)
        #expect(await f.driver.calls.isEmpty)
    }

    /// MAC-066: the existing internal Cut/Paste consume happens synchronously
    /// before counting; a refusal does not restore that single-use move payload.
    @Test
    func counterRefusalDoesNotRestoreConsumedCutPasteIntent() async throws {
        let f = try await ready()
        defer { f.stop() }
        f.clipboard.capture(entries: f.entries(), kind: .move)
        _ = try #require(f.clipboard.payload, "Isolated pasteboard must retain the Cut payload")
        f.store.pasteSelection()
        #expect(f.clipboard.payload == nil && !f.store.canPaste)
        try await waitUntil { await f.counter.calls.count == 1 }
        #expect(await f.counter.calls[0].kind == .move)
        let message = "Read-only source cannot be moved. No files were changed."
        await f.counter.fail(FileOperationError.unsupported(message))
        try await waitUntil { !f.store.isPerformingOperation }
        #expect(f.store.operationNotice == message)
        #expect(f.clipboard.payload == nil && !f.store.canPaste)
        f.store.pasteSelection()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await f.counter.calls.count == 1)
        #expect(await f.driver.calls.isEmpty)
    }

    /// MAC-069: current callbacks, counted completion and conflict Skip contribute
    /// once each. Published terminal snapshots expose accounting before teardown.
    @Test
    func countedProgressCompletionAndSkipReachOneHundredPercent() async throws {
        let f = try await ready()
        defer { f.stop() }
        let totals = TransferTotals(entries: [.init(items: 3, bytes: 100),
            .init(items: 2, bytes: 200), .init(items: 4, bytes: 300)])
        var states: [TransferSession] = []
        let subscription = f.store.$transfer.sink { if let value = $0 { states.append(value) } }
        defer { subscription.cancel() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1), (1, 1)]))
        try await startWriter(f, totals: totals)
        #expect(f.store.transfer?.fraction == 0 && f.store.transfer?.remainingBytes == 600)
        #expect(f.store.transfer?.remainingEntries == 9)
        await f.driver.progress(0, bytes: 40, entries: 1)
        try await waitUntil { f.store.transfer?.doneBytes == 40 && f.store.transfer?.doneEntries == 1 }
        #expect(f.store.transfer?.remainingBytes == 560 && f.store.transfer?.remainingEntries == 8)
        #expect(f.store.transfer?.fraction == Double(40) / 600)
        await f.driver.complete(0, f.result(0))
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.transfer?.processedBytes == 100 && f.store.transfer?.processedEntries == 3)
        #expect(f.store.transfer?.bytesCopied == 0 && f.store.transfer?.currentEntries == 0)
        await f.driver.fail(1, FileOperationError.collision("1.txt"))
        try await waitUntil { f.store.transfer?.conflictName != nil }
        f.store.resolveTransferConflict(.skip)
        try await waitUntil { await f.driver.calls.count == 3 }
        #expect(f.store.transfer?.skippedItems == 1 && f.store.transfer?.completedItems == 1)
        #expect(f.store.transfer?.doneBytes == 300 && f.store.transfer?.doneEntries == 5)
        #expect(f.store.transfer?.fraction == 0.5)
        #expect(f.store.transfer?.remainingBytes == 300 && f.store.transfer?.remainingEntries == 4)
        await f.driver.progress(2, bytes: 90, entries: 2)
        try await waitUntil { f.store.transfer?.doneBytes == 390 && f.store.transfer?.doneEntries == 7 }
        #expect(f.store.transfer?.remainingBytes == 210 && f.store.transfer?.remainingEntries == 2)
        await f.driver.complete(2, f.result(2))
        try await verify(f, results: [f.result(0), f.result(1), f.result(2)])
        let terminal = try #require(states.last)
        #expect(terminal.processedBytes == 600 && terminal.processedEntries == 9)
        #expect(terminal.doneBytes == 600 && terminal.doneEntries == 9 && terminal.fraction == 1)
        #expect(terminal.remainingBytes == 0 && terminal.remainingEntries == 0)
        #expect(terminal.completedItems == 2 && terminal.skippedItems == 1)
        #expect(f.store.activeTab.selection.selectedIDs == [f.result(0).id, f.result(2).id])
    }

    /// MAC-069: nil and mismatched per-entry totals remain honestly unknown,
    /// including after real progress callbacks and completion of a prefix.
    @Test(arguments: [false, true])
    func unknownOrMismatchedTotalsKeepFractionAndRemainingUnknown(mismatched: Bool) async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]))
        let totals = mismatched ? TransferTotals(entries: [.init(items: 10, bytes: 999)]) : nil
        try await startWriter(f, totals: totals)
        await f.driver.progress(0, bytes: 40, entries: 2)
        try await waitUntil { f.store.transfer?.doneBytes == 40 }
        #expect(f.store.transfer?.totals == nil && f.store.transfer?.fraction == nil)
        #expect(f.store.transfer?.remainingBytes == nil && f.store.transfer?.remainingEntries == nil)
        await f.driver.complete(0, f.result(0))
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.transfer?.processedBytes == 40 && f.store.transfer?.processedEntries == 2)
        #expect(f.store.transfer?.fraction == nil && f.store.transfer?.secondsRemaining(at: ProcessInfo.processInfo.systemUptime) == nil)
        #expect(f.store.transfer?.remainingBytes == nil && f.store.transfer?.remainingEntries == nil)
        await f.driver.complete(1, f.result(1))
        try await verify(f, results: [f.result(0), f.result(1)])
    }

    /// MAC-066/067: a published copy with retained originals is selected, but
    /// never reported as a successful move in the completed batch notice.
    @Test
    func retainedSourceProducesHonestMoveSummaryAndSelectsBothDestinations() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]), kind: .move)
        try await startWriter(f)
        await f.driver.complete(0, f.result(0))
        try await waitUntil { await f.driver.calls.count == 2 }
        let retained = "The original remains at \(f.entries([(1, 1), (1, 1)])[1].item.url.path)."
        await f.driver.complete(1, f.result(1), sourceRetention: retained)
        try await verify(f, results: [f.result(0), f.result(1)])
        #expect(f.store.operationNotice?.hasPrefix("Moved 1 of 2 selected items.") == true)
        #expect(f.store.operationNotice?.contains("1 item was copied but not moved") == true)
        #expect(f.store.operationNotice?.contains(retained) == true)
        #expect(f.store.activeTab.selection.selectedIDs == [f.result(0).id, f.result(1).id])
        #expect(await f.driver.calls.map(\.kind) == [.move, .move])
    }

    /// MAC-066/068 + Phase 7: same-device rename is never paused in the lane.
    @Test
    func sameVolumeMoveCannotPauseItsWriterGate() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(2, 2)]), kind: .move)
        try await startWriter(f, totals: TransferTotals(entries: [.init(items: 1, bytes: 0)]))
        #expect(f.store.transfer?.canPause == false && f.store.transfer?.currentItemPausable == false)
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == false)
        try await running(await f.driver.calls[0].control)
        await f.driver.complete(0, f.result(0))
        try await verify(f, results: [f.result(0)])
    }

    /// MAC-066/068: either item OR parent device mismatch makes Move pausable;
    /// Copy remains pausable even on the destination's own device.
    @Test(arguments: ["copy", "item-device", "parent-device"])
    func copiesAndCrossVolumeMovesPauseAndResumeTheWriterGate(_ scenario: String) async throws {
        let f = try await ready()
        defer { f.stop() }
        let devices: [(item: UInt64, parent: UInt64)] = scenario == "item-device" ? [(1, 2)]
            : scenario == "parent-device" ? [(2, 1)] : [(2, 2)]
        try prepared(f, entries: f.entries(devices), kind: scenario == "copy" ? .copy : .move)
        try await startWriter(f)
        #expect(f.store.transfer?.canPause == true && f.store.transfer?.currentItemPausable == true)
        let control = await f.driver.calls[0].control
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == true)
        let probe = P15CheckpointProbe()
        let worker = Task.detached {
            await probe.start()
            do { try control.checkpoint(); await probe.finish(true) }
            catch { await probe.finish(false) }
        }
        defer { control.cancel(); worker.cancel() }
        try await waitUntil { await probe.started }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.succeeded == nil)
        f.store.resumeTransfer()
        #expect(f.store.transfer?.isPaused == false)
        try await waitUntil { await probe.succeeded != nil }
        #expect(await probe.succeeded == true)
        await worker.value
        await f.driver.complete(0, f.result(0))
        try await verify(f, results: [f.result(0)])
    }

    /// MAC-066/068 + Phase 7: pause carries across a completed cross-device item,
    /// but the following rename waits outside its writer until Resume or Cancel.
    @Test(arguments: [false, true])
    func pausedCrossVolumePrefixGatesFollowingRename(cancel: Bool) async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (2, 2)]), kind: .move)
        try await startWriter(f)
        f.store.pauseTransfer()
        await f.driver.complete(0, f.result(0))
        try await waitUntil { f.store.transfer?.completedItems == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.store.transfer?.isPaused == true)
        #expect(await f.driver.calls.count == 1)
        if cancel {
            f.store.cancelTransfer()
            try await verify(f, results: [f.result(0)])
            #expect(await f.driver.calls.count == 1)
            #expect(f.store.operationNotice?.hasPrefix("Moved 1 of 2 selected items.") == true)
            #expect(f.store.operationNotice?.contains("Cancelled; completed items were retained.") == true)
            #expect(f.store.activeTab.selection.selectedIDs == [f.result(0).id])
        } else {
            f.store.resumeTransfer()
            try await waitUntil { await f.driver.calls.count == 2 }
            #expect(f.store.transfer?.isPaused == false && f.store.transfer?.canPause == false)
            let call = await f.driver.calls[1]
            #expect(call.kind == .move && call.item == f.entries([(1, 1), (2, 2)])[1].item)
            try await running(call.control)
            await f.driver.complete(1, f.result(1))
            try await verify(f, results: [f.result(0), f.result(1)])
        }
    }

    /// MAC-067/068: removal after publication cannot pause/cancel; returning
    /// from that item resets phase and restores cancellation for the next copy.
    @Test
    func removingOriginalsDisablesPauseAndCancelUntilTheItemReturns() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]), kind: .move)
        try await startWriter(f)
        await f.driver.progress(0, bytes: 100, entries: 1, phase: .removingOriginals)
        try await waitUntil { f.store.transfer?.phase == .removingOriginals }
        #expect(f.store.transfer?.canCancel == false && f.store.transfer?.canPause == false)
        f.store.pauseTransfer()
        f.store.cancelTransfer()
        #expect(f.store.transfer?.isPaused == false && f.store.transfer?.isCancelling == false)
        #expect(f.store.transfer != nil && f.store.isPerformingOperation)
        try await running(await f.driver.calls[0].control)
        // A late copying callback must not regress the removal phase.
        await f.driver.progress(0, bytes: 100, entries: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.store.transfer?.phase == .removingOriginals)
        await f.driver.complete(0, f.result(0))
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.transfer?.phase == .copying)
        #expect(f.store.transfer?.canCancel == true && f.store.transfer?.canPause == true)
        f.store.cancelTransfer()
        let control = await f.driver.calls[1].control
        #expect(throws: CancellationError.self) { try control.checkpoint() }
        await f.driver.fail(1, CancellationError())
        try await verify(f, results: [f.result(0)])
        #expect(f.store.activeTab.selection.selectedIDs == [f.result(0).id])
    }

    /// MAC-069: deterministic clock samples, two-second minimum and five-second
    /// window discard an older faster prefix; zero-byte totals use entry percent.
    @Test
    func estimatorRequiresTwoSecondsAndMeasuresTheRecentWindow() {
        var rate = TransferRateEstimator()
        #expect(rate.bytesPerSecond(at: 0) == nil)
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 100, at: 1)
        rate.record(bytes: 199, at: 1.99)
        #expect(rate.bytesPerSecond(at: 1.99) == nil)
        rate.record(bytes: 200, at: 2)
        #expect(rate.bytesPerSecond(at: 2) == 100)
        rate.record(bytes: 220, at: 4)
        rate.record(bytes: 240, at: 6)
        rate.record(bytes: 250, at: 7)
        #expect(rate.bytesPerSecond(at: 7) == 10)
        var session = modelSession()
        session.totals = TransferTotals(entries: [.init(items: 3, bytes: 0)])
        session.processedEntries = 1
        session.currentEntries = 2
        #expect(session.fraction == 1 && session.remainingEntries == 0 && session.remainingBytes == 0)
    }

    /// MAC-069: paused time and callbacks made during it never contribute;
    /// backwards byte counts reset the sample history for a fresh measurement.
    @Test
    func estimatorExcludesPausedTimeAndResetsForBackwardsBytes() {
        var rate = TransferRateEstimator()
        rate.record(bytes: 0, at: 10)
        rate.record(bytes: 200, at: 12)
        #expect(rate.bytesPerSecond(at: 12) == 100)
        rate.pause(at: 12)
        rate.pause(at: 13)
        rate.record(bytes: 9999, at: 18)
        #expect(rate.bytesPerSecond(at: 18) == nil)
        rate.resume(at: 22)
        rate.record(bytes: 400, at: 24)
        #expect(rate.bytesPerSecond(at: 24) == 100)
        rate.record(bytes: 10, at: 25)
        #expect(rate.bytesPerSecond(at: 25) == nil)
        rate.record(bytes: 110, at: 26)
        #expect(rate.bytesPerSecond(at: 26) == nil)
        rate.record(bytes: 210, at: 27)
        #expect(rate.bytesPerSecond(at: 27) == 100)
    }

    /// MAC-069: samples outside the five-second window cannot establish speed
    /// after a long callback gap; two fresh seconds are required again.
    @Test
    func estimatorDoesNotUseSamplesOlderThanItsFiveSecondWindow() {
        var rate = TransferRateEstimator()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 100, at: 1)
        rate.record(bytes: 1000, at: 10)
        #expect(rate.bytesPerSecond(at: 10) == nil)
        rate.record(bytes: 1100, at: 11)
        #expect(rate.bytesPerSecond(at: 11) == nil)
        rate.record(bytes: 1200, at: 12)
        #expect(rate.bytesPerSecond(at: 12) == 100)
    }

    /// MAC-069 / FR-FILE-020 / UI-FILE-004: ETA needs known bytes and speed,
    /// disappears while paused/removing and after the remaining work reaches zero.
    @Test
    func secondsRemainingNeedsKnownTotalsSpeedAndActiveCopying() {
        var session = modelSession()
        session.totals = TransferTotals(entries: [.init(items: 3, bytes: 1000)])
        #expect(session.secondsRemaining(at: 0) == nil)
        session.rate.record(bytes: 0, at: 0)
        session.rate.record(bytes: 200, at: 2)
        session.bytesCopied = 200
        #expect(session.secondsRemaining(at: 2) == 8)
        session.isPaused = true
        #expect(session.secondsRemaining(at: 2) == nil)
        session.isPaused = false
        session.totals = nil
        #expect(session.secondsRemaining(at: 2) == nil)
        session.totals = TransferTotals(entries: [.init(items: 3, bytes: 1000)])
        session.phase = .removingOriginals
        #expect(session.secondsRemaining(at: 2) == nil)
        session.phase = .copying
        session.bytesCopied = 1000
        #expect(session.secondsRemaining(at: 2) == nil)
        // Follow-up finding 8: a speed older than the window is stale, not shown.
        session.bytesCopied = 200
        #expect(session.secondsRemaining(at: 2) == 8)
        #expect(session.rate.bytesPerSecond(at: 7.5) == nil)
        #expect(session.secondsRemaining(at: 7.5) == nil)
    }
    /// Review 8f1afb6d findings 5/6 (live): completion uses the writer's
    /// authoritative work; a rename with unknown totals still counts.
    @Test
    func authoritativeResultsCountRenamesWithUnknownTotals() async throws {
        let g = try await ready()
        defer { g.stop() }
        try prepared(g, entries: g.entries([(2, 2), (1, 1)]), kind: .move)
        try await startWriter(g, totals: nil)
        await g.driver.complete(0, result: FileOperationResult(url: g.result(0).url, identity: g.result(0).identity,
            warning: nil, transferredBytes: 0, transferredEntries: 1))
        try await waitUntil { await g.driver.calls.count == 2 }
        #expect(g.store.transfer?.processedEntries == 1, "A rename counts as processed even without totals or progress")
        #expect(g.store.transfer?.fraction == nil)
    }

    /// Review finding 7: a skipped item advances percent but never measured speed.
    @Test
    func skippedBytesNeverFeedMeasuredSpeed() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1), (1, 1)]), kind: .copy)
        try await startWriter(f, totals: TransferTotals(entries: [.init(items: 1, bytes: 10),
            .init(items: 1, bytes: 100_000_000_000), .init(items: 1, bytes: 10)]))
        await f.driver.complete(0, result: FileOperationResult(url: f.result(0).url, identity: f.result(0).identity,
            warning: nil, transferredBytes: 10, transferredEntries: 1))
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, FileOperationError.collision("1.txt"))
        try await waitUntil { f.store.transfer?.conflictName != nil }
        f.store.resolveTransferConflict(.skip)
        try await waitUntil { await f.driver.calls.count == 3 }
        await f.driver.progress(2, bytes: 5, entries: 0)
        try await waitUntil { f.store.transfer?.bytesCopied == 5 }
        let session = try #require(f.store.transfer)
        #expect(session.measuredDoneBytes == 15)
        #expect(session.doneBytes == 100_000_000_015)
    }

    /// Review finding 4: a pause that meets the committed phase is presented as
    /// pending for the next item, and Pause cannot start during that phase.
    @Test
    func pauseMeetingTheCommittedPhaseIsPendingForTheNextItem() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]), kind: .move)
        try await startWriter(f, totals: nil)
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == true)
        await f.driver.progress(0, bytes: 10, entries: 1, phase: .finalizing)
        try await waitUntil { f.store.transfer?.phase == .finalizing }
        let session = try #require(f.store.transfer)
        #expect(session.isFinishingItem && !session.canPause && !session.canCancel)
        f.store.resumeTransfer()
        #expect(f.store.transfer?.isPaused == false)
        f.store.pauseTransfer()
        #expect(f.store.transfer?.isPaused == false, "Pause cannot start during the committed phase")
    }

    /// Review findings 10/11 and follow-up 3c27ebcf findings 3/4: Access Help
    /// points where the failure happened, and every kept original is named by
    /// its original name (not a Keep Both destination name).
    @Test
    func retainedOriginalsAreNamedAndAccessHelpPointsWhereTheFailureHappened() async throws {
        let f = try await ready()
        defer { f.stop() }
        let entries = f.entries([(1, 1), (1, 1)])
        try prepared(f, entries: entries, kind: .move)
        try await startWriter(f, totals: nil)
        let renamed = f.target.appendingPathComponent("0 - Copy.txt")
        await f.driver.complete(0, result: FileOperationResult(url: renamed, identity: f.result(0).identity,
            warning: nil, accessFailure: .permissionDenied, sourceRetention: "Kept in first.",
            retainedOriginalLocation: entries[0].source.directoryURL, sourceRetentionCause: .originalNotRemovable,
            accessFailureLocation: entries[0].source.directoryURL))
        try await waitUntil { await f.driver.calls.count == 2 }
        #expect(f.store.operationAccessIssue?.locations == [entries[0].source.directoryURL])
        #expect(f.store.operationAccessIssue?.action == "Remove original after move")
        await f.driver.complete(1, result: FileOperationResult(url: f.result(1).url, identity: f.result(1).identity,
            warning: nil, accessFailure: .permissionDenied, sourceRetention: "Kept in second.",
            retainedOriginalLocation: entries[1].source.directoryURL, sourceRetentionCause: .metadataNotPreserved,
            accessFailureLocation: f.target))
        try await verify(f, results: [f.result(1)])
        let notice = try #require(f.store.operationNotice)
        #expect(notice.hasPrefix("Moved 0 of 2 selected items. 2 items were copied but not moved:"))
        #expect(notice.contains("“0.txt”: Kept in first.") && notice.contains("“1.txt”: Kept in second."))
        #expect(!notice.contains("0 - Copy.txt"))
        // A destination-side failure points at the destination, not the original.
        #expect(f.store.operationAccessIssue?.locations == [f.target])
        #expect(f.store.operationAccessIssue?.action == "Verify completed transfer")
    }

    /// Review f7716cbf (deferred Low, closed in NATIVE-P16): a destination-side
    /// access failure combined with a kept original is not labelled as removal.
    @Test
    func combinedDestinationFailureAndKeptOriginalPointsAtTheDestination() async throws {
        let f = try await ready()
        defer { f.stop() }
        let entries = f.entries([(1, 1)])
        try prepared(f, entries: entries, kind: .move)
        try await startWriter(f, totals: nil)
        await f.driver.complete(0, result: FileOperationResult(url: f.result(0).url, identity: f.result(0).identity,
            warning: nil, accessFailure: .permissionDenied, sourceRetention: "Kept.",
            retainedOriginalLocation: entries[0].source.directoryURL, sourceRetentionCause: .originalNotRemovable,
            accessFailureLocation: f.target))
        try await verify(f, results: [f.result(0)])
        #expect(f.store.operationAccessIssue?.locations == [f.target])
        #expect(f.store.operationAccessIssue?.action == "Verify completed transfer")
    }

    /// Follow-up finding 2: an item larger than counted makes totals unknown at
    /// once (indeterminate), so the bar never reads 100% early or moves back.
    @Test
    func itemLargerThanCountedMakesTotalsUnknownImmediately() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]), kind: .copy)
        try await startWriter(f, totals: TransferTotals(entries: [.init(items: 1, bytes: 100), .init(items: 1, bytes: 100)]))
        await f.driver.progress(0, bytes: 150, entries: 0)
        try await waitUntil { f.store.transfer?.bytesCopied == 150 }
        let session = try #require(f.store.transfer)
        #expect(session.totals == nil && session.totalsChanged && session.fraction == nil)
    }

    /// Follow-up finding 2: a smaller-than-counted item shrinks the basis live
    /// (observed while the next item is still pending).
    @Test
    func smallerThanCountedItemShrinksTheBasisWhileTheBatchContinues() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 1), (1, 1)]), kind: .copy)
        try await startWriter(f, totals: TransferTotals(entries: [.init(items: 2, bytes: 100), .init(items: 1, bytes: 100)]))
        await f.driver.complete(0, result: FileOperationResult(url: f.result(0).url, identity: f.result(0).identity,
            warning: nil, transferredBytes: 60, transferredEntries: 1))
        try await waitUntil { await f.driver.calls.count == 2 }
        let session = try #require(f.store.transfer)
        #expect(session.totals == TransferTotals(entries: [.init(items: 1, bytes: 60), .init(items: 1, bytes: 100)]))
        #expect(session.doneBytes == 60 && session.fraction == 60.0 / 160.0)
    }

    /// Follow-up finding 5: a late earlier-phase callback cannot regress the phase.
    @Test
    func phasesOnlyAdvanceWithinAnItem() async throws {
        let f = try await ready()
        defer { f.stop() }
        try prepared(f, entries: f.entries([(1, 2)]), kind: .move)
        try await startWriter(f, totals: nil)
        await f.driver.progress(0, bytes: 10, entries: 1, phase: .removingOriginals)
        try await waitUntil { f.store.transfer?.phase == .removingOriginals }
        await f.driver.progress(0, bytes: 10, entries: 1, phase: .finalizing)
        await f.driver.progress(0, bytes: 10, entries: 1, phase: .copying)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.store.transfer?.phase == .removingOriginals)
    }

    private func modelSession() -> TransferSession {
        TransferSession(id: UUID(), kind: .copy, sourceURLs: [],
            destinationURL: FileManager.default.temporaryDirectory, totalItems: 1)
    }

    /// MAC-068 / FR-FILE-015: controller seams exercise same-volume Move,
    /// either device mismatch -> Copy, Option -> Copy, Command -> Move, and
    /// external Copy regardless of modifiers. No physical dragging session.
    @Test(arguments: ["same", "item-device", "parent-device", "option-same", "option-cross",
                      "command-cross", "external", "external-option", "external-command"])
    func dragDefaultsAndModifiersReachTheAcceptedTransfer(_ scenario: String) async throws {
        let f = try await ready()
        defer { f.stop() }
        let external = scenario.hasPrefix("external")
        let cross = scenario.contains("cross") || scenario == "item-device" || scenario == "parent-device"
        let devices: [(item: UInt64, parent: UInt64)] = scenario == "parent-device" ? [(2, 1)]
            : cross ? [(1, 2)] : [(2, 2)]
        let entries = f.entries(devices)
        f.modifiers = scenario.contains("option") ? .option : scenario.contains("command") ? .command : []
        let expected: TransferKind = external || f.modifiers.contains(.option) ? .copy
            : !cross || f.modifiers.contains(.command) ? .move : .copy
        let coordinator = f.coordinator()
        let destination = coordinator.makeDestination(store: f.store)
        defer { destination.invalidate() }
        let owner = NSObject()
        let source: FileDragSource?
        if external { source = nil }
        else {
            let capturedSource = try #require(coordinator.beginSource(entries: entries, owner: owner))
            source = capturedSource
        }
        defer { source?.finish() }
        f.dragBoard.clearContents()
        if let source {
            let writer = try #require(source.pasteboardWriter(itemID: entries[0].item.id))
            try #require(f.dragBoard.writeObjects([writer]))
        } else {
            let item = NSPasteboardItem()
            try #require(item.setString(entries[0].item.url.absoluteString, forType: .fileURL))
            try #require(f.dragBoard.writeObjects([item]))
        }
        let info = FileDragInfoStub(board: f.dragBoard, source: source)
        let binding = try #require(f.store.fileDropBinding(destinationURL: f.target))
        #expect(destination.update(info, binding: binding).isEmpty)
        if external {
            try await waitUntil { await f.importer.calls.count == 1 }
            #expect(await f.importer.calls[0] == entries.map { $0.item.url.absoluteString })
            await f.importer.complete(entries: entries)
        }
        try await waitUntil { await f.preparer.calls.count == 1 }
        #expect(await f.preparer.calls[0].kind == expected)
        #expect(await f.driver.calls.isEmpty)
        #expect(await f.counter.calls.isEmpty)
        await f.preparer.complete(destination: f.destination)
        try await waitUntil { !destination.isPreparing }
        #expect(destination.refusalReason == nil)
        #expect(destination.update(info, binding: binding) == (expected == .copy ? .copy : .move))
        #expect(destination.accept(info, binding: binding))
        try await startWriter(f)
        #expect(await f.counter.calls[0].kind == expected)
        let call = await f.driver.calls[0]
        #expect(call.kind == expected && call.source == entries[0].source && call.destination == f.destination)
        if !external { #expect(await f.importer.calls.isEmpty) }
        await f.driver.complete(0, f.result(0))
        try await verify(f, results: [f.result(0)])
    }

    /// MAC-068: target-entry prediction can differ from the prepared directory
    /// device (e.g. a folder link); default Move then refuses before acceptance.
    @Test
    func mispredictedCrossVolumeDefaultMoveIsRefusedAfterPreparation() async throws {
        let f = try await ready()
        defer { f.stop() }
        let entries = f.entries([(2, 2)])
        let coordinator = f.coordinator()
        let destination = coordinator.makeDestination(store: f.store)
        defer { destination.invalidate() }
        let owner = NSObject()
        let source = try #require(coordinator.beginSource(entries: entries, owner: owner))
        defer { source.finish() }
        let writer = try #require(source.pasteboardWriter(itemID: entries[0].item.id))
        f.dragBoard.clearContents()
        try #require(f.dragBoard.writeObjects([writer]))
        let folder = f.target.appendingPathComponent("OtherVolume", isDirectory: true)
        let binding = try #require(f.store.fileDropBinding(destinationURL: folder,
            expectedEntryIdentity: f.identity(500)))
        let info = FileDragInfoStub(board: f.dragBoard, source: source)
        #expect(destination.update(info, binding: binding).isEmpty)
        try await waitUntil { await f.preparer.calls.count == 1 }
        #expect(await f.preparer.calls[0].kind == .move)
        let actual = FileOperationContext(directoryURL: folder, directoryIdentity: f.identity(501, device: 3))
        await f.preparer.complete(destination: actual)
        try await waitUntil { !destination.isPreparing }
        #expect(destination.refusalReason?.contains("another volume") == true)
        #expect(!destination.accept(info, binding: binding))
        #expect(await f.driver.calls.isEmpty)
        #expect(await f.counter.calls.isEmpty)
        #expect(await f.importer.calls.isEmpty)
        #expect(f.store.transfer == nil && !f.store.isPerformingOperation)
    }
}
