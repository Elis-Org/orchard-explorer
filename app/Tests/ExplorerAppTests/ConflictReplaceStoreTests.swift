import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Model-only IO for NATIVE-P16: every read, write and inspection is completed
/// explicitly. Synthetic identities never reach an actual filesystem.
private actor P16Driver: DirectoryListing, FileTransferring {
    struct Call: Sendable {
        let item: FileItem
        let name: String
        let kind: TransferKind
        let replacing: ReplacementTarget?
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
        try await transfer(item, from: from, to: to, name: name, kind: kind, replacing: nil,
                           control: control, onProgress: onProgress)
    }
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, replacing target: ReplacementTarget?, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pendingWrites[calls.count] = $0
            calls.append(Call(item: item, name: name, kind: kind, replacing: target, progress: onProgress))
        }
    }
    func read(_ index: Int, _ snapshot: DirectorySnapshot) {
        pendingReads.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func complete(_ index: Int, result: FileOperationResult) {
        pendingWrites.removeValue(forKey: index)?.resume(returning: result)
    }
    func fail(_ index: Int, _ error: any Error) {
        pendingWrites.removeValue(forKey: index)?.resume(throwing: error)
    }
    func progress(_ index: Int, phase: TransferPhase) {
        calls[index].progress(TransferProgress(currentName: calls[index].name, bytesCopied: 0, phase: phase))
    }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), writes = Array(pendingWrites.values)
        pendingReads.removeAll(); pendingWrites.removeAll()
        for pending in reads { pending.resume(throwing: CancellationError()) }
        for pending in writes { pending.resume(throwing: CancellationError()) }
    }
}

private actor P16Inspector: ConflictInspecting {
    private(set) var calls: [String] = []
    private var pending: [Int: CheckedContinuation<ConflictEntry, Error>] = [:]
    private var closed = false
    func inspect(name: String, in context: FileOperationContext) async throws -> ConflictEntry {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending[calls.count] = $0
            calls.append(name)
        }
    }
    func answer(_ index: Int, _ entry: ConflictEntry) { pending.removeValue(forKey: index)?.resume(returning: entry) }
    func fail(_ index: Int, _ error: any Error) { pending.removeValue(forKey: index)?.resume(throwing: error) }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private struct P16NoCount: TransferCounting {
    func count(_ entries: [TransferEntry], destination: FileOperationContext,
               kind: TransferKind) async throws -> TransferTotals? { nil }
}

@MainActor
private final class P16Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerP16-\(UUID())", isDirectory: true)
    var source: URL { root.appendingPathComponent("Source", isDirectory: true) }
    var target: URL { root.appendingPathComponent("Target", isDirectory: true) }
    let board = NSPasteboard(name: .init("ExplorerP16Clipboard-\(UUID())"))
    let driver = P16Driver()
    let inspector = P16Inspector()
    let history = RecoveryHistory()
    let store: ExplorerStore
    init() {
        store = ExplorerStore(initialURL: root.appendingPathComponent("Target", isDirectory: true),
            loader: driver, homeURL: root, transfers: driver,
            clipboard: TransferClipboard(pasteboard: board), recoveryHistory: history,
            transferCounter: P16NoCount(), conflictInspector: inspector)
    }
    func identity(_ inode: UInt64, device: UInt64 = 2) -> LocalFileIdentity {
        LocalFileIdentity(device: device, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    var destination: FileOperationContext {
        FileOperationContext(directoryURL: target, directoryIdentity: identity(200))
    }
    var sourceContext: FileOperationContext {
        FileOperationContext(directoryURL: source, directoryIdentity: identity(100))
    }
    func entry(_ name: String = "a.txt", inode: UInt64 = 1000, folder: Bool = false) -> TransferEntry {
        TransferEntry(source: sourceContext, item: FileItem(url: source.appendingPathComponent(name, isDirectory: folder),
            name: name, isDirectory: folder, isSymbolicLink: false, size: folder ? nil : 120,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), kind: folder ? "Folder" : "Plain Text",
            identity: identity(inode)))
    }
    func existing(_ name: String = "a.txt", inode: UInt64 = 3000, kind: ConflictEntryKind = .file,
                  size: Int64 = 80) -> ConflictEntry {
        let type: UInt16 = switch kind {
        case .file: UInt16(S_IFREG)
        case .folder: UInt16(S_IFDIR)
        case .symbolicLink: UInt16(S_IFLNK)
        case .other: UInt16(S_IFIFO)
        }
        let target = ReplacementTarget(name: name, identity: identity(inode), fileType: type, size: size,
                                       modifiedSeconds: 1_700_000_000, modifiedNanoseconds: 0)
        return ConflictEntry(target: target, kind: kind, kindDescription: kind == .folder ? "Folder" : "Plain Text",
                             size: kind == .file ? size : nil, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    func receipt(_ name: String = "a.txt", inode: UInt64 = 3000) -> TrashReceipt {
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let original = FileItem(url: target.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 80, modifiedAt: nil, kind: "Plain Text", identity: identity(inode))
        let trashed = FileItem(url: trash.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 80, modifiedAt: nil, kind: "Plain Text", identity: identity(inode))
        return TrashReceipt(original: original, originalContext: destination, trashed: trashed,
            trashContext: FileOperationContext(directoryURL: trash, directoryIdentity: identity(300)))
    }
    func result(_ name: String = "a.txt", receipt: TrashReceipt? = nil) -> FileOperationResult {
        FileOperationResult(url: target.appendingPathComponent(name), identity: identity(4000), warning: nil,
                            replacedReceipt: receipt)
    }
    func stop() {
        store.cancelTransfer()
        store.cancelLoads()
        Task { await driver.shutdown(); await inspector.shutdown() }
        board.releaseGlobally()
    }
}

/// NATIVE-P16 / MAC-070–073 store/model coverage for FR-FILE-009,
/// UI-FILE-002/003; EV-0256–0262; AT-FILE-009, AT-UIFILE-002/003 native subset.
/// Synthetic identities establish policy only — not actual Trash IO, AppKit
/// rendering, visual comparison or full Windows acceptance.
@MainActor
final class ConflictReplaceStoreTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let reached = await condition()
        try #require(reached, "Phase 16 model state did not settle before the bounded deadline")
    }
    private func ready() async throws -> P16Fixture {
        let f = P16Fixture()
        do {
            try await waitUntil { await f.driver.reads.count == 1 }
            await f.driver.read(0, DirectorySnapshot(items: [], directoryIdentity: f.destination.directoryIdentity))
            try await waitUntil { f.store.activeTab.hasLoaded && !f.store.activeTab.isLoading }
            return f
        } catch { f.stop(); throw error }
    }
    private func start(_ f: P16Fixture, _ entries: [TransferEntry], kind: TransferKind = .copy) async throws {
        let binding = try #require(f.store.fileDropBinding(destinationURL: f.target))
        try #require(f.store.acceptPreparedFileDrop(PreparedFileDrop(entries: entries,
            destination: f.destination, kind: kind), binding: binding))
        try await waitUntil { await f.driver.calls.count == 1 }
    }
    /// Collision on write `index`, then the inspector answers inspection `inspection`.
    private func collide(_ f: P16Fixture, write index: Int, inspection: Int, _ existing: ConflictEntry?,
                         name: String = "a.txt") async throws {
        await f.driver.fail(index, FileOperationError.collision(name))
        try await waitUntil { await f.inspector.calls.count == inspection + 1 }
        #expect(f.store.transfer?.conflictName == nil, "No choice is offered before the existing item is read")
        if let existing { await f.inspector.answer(inspection, existing) }
        else { await f.inspector.fail(inspection, FileOperationError.unsupported("Unreadable")) }
        try await waitUntil { f.store.transfer?.conflictName == name }
    }
    private func finish(_ f: P16Fixture, results: [FileItem]) async throws {
        let reads = await f.driver.reads.count
        try await waitUntil { await f.driver.reads.count == reads + 1 }
        await f.driver.read(reads, DirectorySnapshot(items: results, directoryIdentity: f.destination.directoryIdentity))
        try await waitUntil { !f.store.isPerformingOperation && !f.store.activeTab.isLoading }
    }
    private func resultItem(_ f: P16Fixture, _ name: String = "a.txt") -> FileItem {
        FileItem(url: f.target.appendingPathComponent(name), name: name, isDirectory: false, isSymbolicLink: false,
                 size: 120, modifiedAt: nil, kind: "Plain Text", identity: f.identity(4000))
    }

    /// MAC-070/071: both versions are presented; Replace retries the same name
    /// with the compared target and its receipt joins Recently Trashed.
    @Test
    func replaceRetriesTheSameNameWithTheComparedTargetAndRecordsTheReceipt() async throws {
        let f = try await ready()
        defer { f.stop() }
        let entry = f.entry()
        try await start(f, [entry])
        let existing = f.existing()
        try await collide(f, write: 0, inspection: 0, existing)
        let info = try #require(f.store.transfer?.conflict)
        #expect(info.incoming == entry.item && info.incomingLocation == f.source)
        #expect(info.destinationLocation == f.target && info.existing?.target == existing.target)
        #expect(info.canReplace && info.replaceUnavailableReason == nil && !info.changedSinceCompared)
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        let call = await f.driver.calls[1]
        #expect(call.name == "a.txt" && call.replacing == existing.target)
        #expect(await f.driver.calls[0].replacing == nil, "The first attempt never replaces")
        #expect(f.store.transfer?.conflictName == nil && f.store.transfer?.conflict == nil)
        let receipt = f.receipt()
        await f.driver.complete(1, result: f.result(receipt: receipt))
        try await finish(f, results: [resultItem(f)])
        #expect(f.history.entries.map(\.id) == [receipt.id])
        let notice = try #require(f.store.operationNotice)
        #expect(notice.hasPrefix("Copied 1 of 1 selected items."))
        #expect(notice.contains("Replaced 1 existing item; the previous version is in the Trash (File ▸ Recently Trashed…)."))
    }

    /// MAC-071: folders and type mismatches never offer Replace; a programmatic
    /// Replace is ignored and the conflict keeps waiting for a valid choice.
    @Test(arguments: ["existing-folder", "incoming-folder", "same-item", "unreadable"])
    func replaceIsUnavailableWithReasonAndIgnored(_ scenario: String) async throws {
        let f = try await ready()
        defer { f.stop() }
        let entry = scenario == "incoming-folder" ? f.entry("a.txt", folder: true) : f.entry()
        try await start(f, [entry])
        let existing: ConflictEntry? = switch scenario {
        case "existing-folder": f.existing(kind: .folder)
        case "same-item": f.existing(inode: 1000)
        case "unreadable": nil
        default: f.existing()
        }
        try await collide(f, write: 0, inspection: 0, existing)
        let info = try #require(f.store.transfer?.conflict)
        #expect(!info.canReplace)
        let reason = switch scenario {
        case "same-item": "This is the same item."
        case "unreadable": "The existing item couldn't be read, so it can't be replaced."
        default: "Folders can't be replaced or merged."
        }
        #expect(info.replaceUnavailableReason == reason)
        if scenario == "unreadable" { #expect(info.existing == nil && info.inspectionError != nil) }
        f.store.resolveTransferConflict(.replace)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.store.transfer?.conflictName == "a.txt", "Replace is not accepted for these versions")
        #expect(await f.driver.calls.count == 1)
        f.store.resolveTransferConflict(.keepBoth)
        try await waitUntil { await f.driver.calls.count == 2 }
        let call = await f.driver.calls[1]
        // Folders retain their whole stem; only inspected same-item copies keep Copy style.
        let expectedName = scenario == "same-item" ? "a - Copy.txt"
            : scenario == "incoming-folder" ? "a.txt (2)" : "a (2).txt"
        #expect(call.name == expectedName)
        #expect(call.replacing == nil)
    }

    /// MAC-073: a destination changed after comparison is presented again with
    /// fresh details; the next Replace uses the newly compared target.
    @Test
    func changedDestinationIsComparedAgainBeforeAnotherReplace() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()], kind: .move)
        let first = f.existing(size: 80)
        try await collide(f, write: 0, inspection: 0, first)
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, TransferReplacementError.destinationChanged("a.txt"))
        try await waitUntil { await f.inspector.calls.count == 2 }
        #expect(f.store.transfer?.conflictName == nil)
        let second = f.existing(size: 95)
        await f.inspector.answer(1, second)
        try await waitUntil { f.store.transfer?.conflictName == "a.txt" }
        let info = try #require(f.store.transfer?.conflict)
        #expect(info.changedSinceCompared && info.existing?.size == 95 && info.canReplace)
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 3 }
        #expect(await f.driver.calls[2].replacing == second.target)
        #expect(await f.driver.calls[2].kind == .move)
        await f.driver.complete(2, result: f.result(receipt: f.receipt()))
        try await finish(f, results: [resultItem(f)])
        #expect(f.history.entries.count == 1)
        #expect(f.store.operationNotice?.hasPrefix("Moved 1 of 1 selected items.") == true)
    }

    /// MAC-071: a type found non-replaceable by the writer keeps Replace off.
    @Test
    func writerRefusalKeepsReplaceDisabledOnThePromptAgain() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, TransferReplacementError.notReplaceable("a.txt"))
        try await waitUntil { await f.inspector.calls.count == 2 }
        await f.inspector.answer(1, f.existing())
        try await waitUntil { f.store.transfer?.conflictName == "a.txt" }
        let info = try #require(f.store.transfer?.conflict)
        #expect(info.replaceRefused && !info.canReplace && !info.changedSinceCompared)
        f.store.resolveTransferConflict(.skip)
        try await finish(f, results: [])
        #expect(await f.driver.calls.count == 2)
        #expect(f.store.operationNotice?.contains("Skipped 1.") == true)
        #expect(f.history.entries.isEmpty)
    }

    /// MAC-072: when the replaced item could not be put back, its receipt is
    /// kept in Recently Trashed and the batch stops with the Trash location.
    @Test
    func failedRestoreKeepsTheReceiptAndStops() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry(), f.entry("b.txt", inode: 1001)])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        let receipt = f.receipt()
        await f.driver.fail(1, ReplacementRecoveryError(receipt: receipt, cause: "Publication failed.",
                                                        accessFailure: .permissionDenied))
        try await finish(f, results: [])
        #expect(f.history.entries.map(\.id) == [receipt.id])
        #expect(f.store.operationAccessIssue?.action == "Restore replaced item")
        #expect(f.store.operationAccessIssue?.locations == [f.target, receipt.trashContext.directoryURL])
        #expect(await f.driver.calls.count == 2, "The batch stops; b.txt is not attempted")
        let notice = try #require(f.store.operationNotice)
        #expect(notice.contains("Stopped.") && notice.contains(receipt.trashed.url.path))
        #expect(!notice.contains("Replaced 1"))
    }

    /// MAC-070: Cancel while the existing item is still being read starts no
    /// further write and offers no choice.
    @Test
    func cancelDuringInspectionEndsWithoutAnotherWrite() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()])
        await f.driver.fail(0, FileOperationError.collision("a.txt"))
        try await waitUntil { await f.inspector.calls.count == 1 }
        // Review d0a87c9e #5: the inspection never answers; Cancel still ends the batch.
        f.store.cancelTransfer()
        try await finish(f, results: [])
        #expect(await f.driver.calls.count == 1)
        #expect(f.store.transfer == nil)
        #expect(f.store.operationNotice?.contains("Cancelled") == true)
        // A late answer is discarded.
        await f.inspector.answer(0, f.existing())
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.store.transfer == nil)
        #expect(await f.driver.calls.count == 1)
    }

    /// MAC-070: Cancel on the comparison leaves the destination untouched.
    @Test
    func cancelOnTheComparisonStopsWithoutReplacing() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.cancel)
        try await finish(f, results: [])
        #expect(await f.driver.calls.count == 1)
        #expect(f.history.entries.isEmpty)
        #expect(f.store.operationNotice == "Copied 0 of 1 selected items. Cancelled; completed items were retained.")
    }

    /// Review d0a87c9e #1: a Replace stopped without a verified Trash receipt
    /// records nothing in Recently Trashed and never claims a replacement.
    @Test
    func unverifiedTrashStopsWithoutClaimingRecentlyTrashed() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry(), f.entry("b.txt", inode: 1001)])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        let location = f.root.appendingPathComponent(".Trash/a.txt")
        await f.driver.fail(1, ReplacementTrashError.unverified(name: "a.txt", trashLocation: location, detail: ""))
        try await finish(f, results: [])
        #expect(f.history.entries.isEmpty)
        #expect(await f.driver.calls.count == 2)
        let notice = try #require(f.store.operationNotice)
        #expect(notice.contains("Stopped.") && notice.contains(location.path))
        #expect(notice.contains("not listed in Recently Trashed") && !notice.contains("Replaced 1"))
    }

    /// Follow-up 55b3f24a #8: a Replace attempt that announced its committed
    /// phase and was rolled back leaves Cancel available while the next
    /// conflict inspection stalls.
    @Test
    func rolledBackReplaceKeepsCancelAvailableForTheNextInspection() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.progress(1, phase: .finalizing)
        try await waitUntil { f.store.transfer?.phase == .finalizing }
        #expect(f.store.transfer?.canCancel == false)
        // Publication met an occupant; the existing item was restored and the collision rethrown.
        await f.driver.fail(1, FileOperationError.collision("a.txt"))
        try await waitUntil { await f.inspector.calls.count == 2 }
        #expect(f.store.transfer?.phase == .copying && f.store.transfer?.canCancel == true)
        f.store.cancelTransfer()
        try await finish(f, results: [])
        #expect(await f.driver.calls.count == 2)
        #expect(f.store.operationNotice?.contains("Cancelled") == true)
    }

    /// Follow-up 55b3f24a #9: retirement failures keep their Access Help classification.
    @Test
    func replacementTrashFailureKeepsAccessHelp() async throws {
        let f = try await ready()
        defer { f.stop() }
        try await start(f, [f.entry()])
        try await collide(f, write: 0, inspection: 0, f.existing())
        f.store.resolveTransferConflict(.replace)
        try await waitUntil { await f.driver.calls.count == 2 }
        await f.driver.fail(1, ReplacementTrashError.uncertain(name: "a.txt", detail: "Denied.", accessFailure: .permissionDenied))
        try await finish(f, results: [])
        #expect(f.store.operationAccessIssue?.failure == .permissionDenied)
        #expect(f.store.operationNotice?.contains("Stopped.") == true)
        #expect(f.history.entries.isEmpty)
    }
}
