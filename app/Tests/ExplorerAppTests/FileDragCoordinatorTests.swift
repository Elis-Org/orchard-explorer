import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Implements the installed SDK's required NSDraggingInfo surface without
/// starting a physical AppKit drag session or touching the general pasteboard.
@MainActor
final class FileDragInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(board: NSPasteboard, source: Any? = nil) {
        draggingPasteboard = board
        draggingSource = source
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Both fakes intentionally ignore Task cancellation; obsolete results must be
/// rejected by the controller's attempt/sequence checks, not by cooperative IO.
private actor DragHeldImporter: FileTransferImporting {
    private(set) var requests: [[String]] = []
    private var pending: [Int: CheckedContinuation<[TransferEntry], Error>] = [:]
    private var closed = false
    func capture(urlStrings: [String]) async throws -> [TransferEntry] {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requests.count] = continuation
            requests.append(urlStrings)
        }
    }
    func complete(_ index: Int, entries: [TransferEntry]) {
        pending.removeValue(forKey: index)?.resume(returning: entries)
    }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private actor DragHeldPreparer: FileDropPreparing {
    struct Call: Sendable {
        let entries: [TransferEntry]
        let destination: URL
        let kind: TransferKind
    }
    private(set) var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<PreparedFileDrop, Error>] = [:]
    private var closed = false
    func prepare(entries: [TransferEntry], destinationURL: URL,
                 expectedDestinationIdentity: LocalFileIdentity?, expectedEntryIdentity: LocalFileIdentity?,
                 kind: TransferKind) async throws -> PreparedFileDrop {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[calls.count] = continuation
            calls.append(Call(entries: entries, destination: destinationURL, kind: kind))
        }
    }
    func complete(_ index: Int, context: FileOperationContext) {
        let call = calls[index]
        pending.removeValue(forKey: index)?.resume(returning:
            PreparedFileDrop(entries: call.entries, destination: context, kind: call.kind))
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: FileOperationError.staleSource)
    }
    func shutdown() {
        closed = true
        let values = Array(pending.values)
        pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

private actor DragRecordingWriter: FileTransferring {
    private(set) var kinds: [TransferKind] = []
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        kinds.append(kind)
        return try await LocalFileTransfers().transfer(item, from: from, to: to,
            name: name, kind: kind, control: control, onProgress: onProgress)
    }
}

@MainActor
private final class DragTestFiles {
    let root: URL
    let source: URL
    let target: URL
    let file: URL
    let bytes = Data("drag payload: café 日本語\n".utf8)
    let board = NSPasteboard(name: .init("ExplorerDrag-\(UUID().uuidString)"))
    let clipboardBoard = NSPasteboard(name: .init("ExplorerDragClipboard-\(UUID().uuidString)"))
    let importer = DragHeldImporter()
    let preparer = DragHeldPreparer()
    let writer = DragRecordingWriter()
    let store: ExplorerStore
    var modifiers: NSEvent.ModifierFlags = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerDrag-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        source = root.appendingPathComponent("Source", isDirectory: true)
        target = root.appendingPathComponent("Target", isDirectory: true)
        file = source.appendingPathComponent("payload.txt")
        for folder in [source, target] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try bytes.write(to: file)
        store = ExplorerStore(initialURL: target, transfers: writer,
            clipboard: TransferClipboard(pasteboard: clipboardBoard))
    }

    func coordinator(hoverDelay: TimeInterval = 60) -> FileDragCoordinator {
        FileDragCoordinator(importer: importer, preparer: preparer,
            tabHoverDelay: hoverDelay,
            modifierFlags: { [weak self] in self?.modifiers ?? [] })
    }

    func publishExternal(on pasteboard: NSPasteboard? = nil, spelling: String? = nil) throws {
        let pasteboard = pasteboard ?? board
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        try #require(item.setString(spelling ?? file.absoluteString, forType: .fileURL))
        try #require(pasteboard.writeObjects([item]))
    }

    func cleanup() {
        store.cancelTransfer()
        store.cancelLoads()
        Task { await importer.shutdown(); await preparer.shutdown() }
        board.releaseGlobally()
        clipboardBoard.releaseGlobally()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned drag fixture: \(error)") }
    }
}

/// NATIVE-P13; FR-DROP-001/002/004, EV-9001/0265–0270, AT-DROP-001/002/004.
/// These controller/byte tests never enter physical pointer tracking. Escape uses
/// the adapter's invalidate contract; no Windows FR-DROP-003 fidelity claim.
@MainActor
final class FileDragCoordinatorTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let reached = await condition()
        try #require(reached, "Drag controller did not reach the expected state before the bounded deadline")
    }

    private func ready(_ files: DragTestFiles) async throws -> (FileDropBinding, FileOperationContext) {
        try await waitUntil { files.store.activeTab.hasLoaded && !files.store.activeTab.isLoading }
        let binding = try #require(files.store.fileDropBinding(destinationURL: files.target))
        let identity = try #require(files.store.activeTab.directoryIdentity)
        return (binding, FileOperationContext(directoryURL: files.target, directoryIdentity: identity))
    }

    private func entries(_ files: DragTestFiles) async throws -> [TransferEntry] {
        try await LocalFileTransferImporter().capture(urlStrings: [files.file.absoluteString])
    }

    private func prepareExternal(_ files: DragTestFiles, destination: FileDragDestination,
                                 info: FileDragInfoStub, binding: FileDropBinding,
                                 context: FileOperationContext) async throws {
        #expect(destination.update(info, binding: binding) == [])
        #expect(destination.isPreparing)
        try await waitUntil { await files.importer.requests.count == 1 }
        #expect(await files.importer.requests[0] == [files.file.absoluteString])
        await files.importer.complete(0, entries: try await entries(files))
        try await waitUntil { await files.preparer.calls.count == 1 }
        #expect(await files.writer.kinds.isEmpty)
        await files.preparer.complete(0, context: context)
        try await waitUntil { !destination.isPreparing }
    }

    @Test
    func externalCandidatePreparesWithoutWritesAndOneReadyDropCopiesOnceAcrossControllers() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        let second = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate(); second.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        let generalCount = NSPasteboard.general.changeCount
        let clipboardCount = files.clipboardBoard.changeCount
        let dragCount = files.board.changeCount
        try await prepareExternal(files, destination: destination, info: info, binding: binding, context: context)
        #expect(destination.update(info, binding: binding) == .copy)
        #expect(await files.preparer.calls[0].kind == .copy)
        #expect(await files.writer.kinds.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.target.appendingPathComponent("payload.txt").path))
        #expect(destination.accept(info, binding: binding))
        #expect(!destination.accept(info, binding: binding))
        try await waitUntil { !files.store.isPerformingOperation && !files.store.activeTab.isLoading }
        #expect(second.update(info, binding: binding) == [])
        #expect(!second.accept(info, binding: binding))
        #expect(await files.writer.kinds == [.copy])
        #expect(try Data(contentsOf: files.target.appendingPathComponent("payload.txt")) == files.bytes)
        #expect(try Data(contentsOf: files.file) == files.bytes)
        #expect(NSPasteboard.general.changeCount == generalCount)
        #expect(files.clipboardBoard.changeCount == clipboardCount)
        #expect(files.board.changeCount == dragCount)
    }

    @Test
    func releaseBeforePreparationFinishesRejectsLateCapture() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, _) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        #expect(destination.update(info, binding: binding) == [])
        try await waitUntil { await files.importer.requests.count == 1 }
        #expect(!destination.accept(info, binding: binding))
        await files.importer.complete(0, entries: try await entries(files))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await files.preparer.calls.isEmpty)
        #expect(await files.writer.kinds.isEmpty)
        #expect(!destination.isPreparing)
    }

    @Test(arguments: ["exit", "escape"])
    func invalidationCancelsHoverAndLatePreparationWithoutSubmitting(_ reason: String) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator(hoverDelay: 0.005)
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        var hoverCount = 0
        let hover = FileDropHover(id: reason, action: { hoverCount += 1 })
        #expect(destination.update(info, binding: binding, hover: hover) == [])
        try await waitUntil { await files.importer.requests.count == 1 }
        await files.importer.complete(0, entries: try await entries(files))
        try await waitUntil { await files.preparer.calls.count == 1 }
        destination.invalidate()
        await files.preparer.complete(0, context: context)
        try await Task.sleep(for: .milliseconds(30))
        #expect(hoverCount == 0)
        #expect(!destination.accept(info, binding: binding))
        #expect(await files.writer.kinds.isEmpty)
        #expect(!destination.isPreparing)
    }

    @Test
    func completedTabHoverInvokesOnlyActivationAndNeverSubmitsAFileOperation() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator(hoverDelay: 0.005)
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        var hoverCount = 0
        #expect(destination.update(info, binding: binding,
            hover: FileDropHover(id: "tab",
                action: { hoverCount += 1 })) == [])
        try await waitUntil { await files.importer.requests.count == 1 }
        await files.importer.complete(0, entries: try await entries(files))
        try await waitUntil { await files.preparer.calls.count == 1 }
        await files.preparer.complete(0, context: context)
        try await waitUntil { hoverCount == 1 }
        #expect(await files.writer.kinds.isEmpty)
        #expect(!destination.accept(info, binding: binding))
        #expect(!FileManager.default.fileExists(atPath: files.target.appendingPathComponent("payload.txt").path))
    }

    @Test(arguments: ["generation", "sequence", "board-content", "board-object", "modifier", "source-mask"])
    func changedDropInputCannotUseAReadyPreparation(_ change: String) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        try await prepareExternal(files, destination: destination, info: info, binding: binding, context: context)
        let replacement = NSPasteboard(name: .init("ExplorerDragReplacement-\(UUID().uuidString)"))
        defer { replacement.releaseGlobally() }
        switch change {
        case "generation": files.store.cancelLoads()
        case "sequence": info.draggingSequenceNumber += 1
        case "board-content": try files.publishExternal(spelling: files.source.appendingPathComponent("replacement.txt").absoluteString)
        case "board-object": try files.publishExternal(on: replacement); info.draggingPasteboard = replacement
        case "modifier": files.modifiers = .option
        default: info.draggingSourceOperationMask = .move
        }
        #expect(!destination.accept(info, binding: binding))
        #expect(await files.writer.kinds.isEmpty)
        #expect(!files.store.isPerformingOperation)
        #expect(!FileManager.default.fileExists(atPath: files.target.appendingPathComponent("payload.txt").path))
    }

    @Test
    func activeSessionRetainsItsOwnerAcrossPresentationReplacementAndReleasesOnFinish() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let coordinator = files.coordinator()
        var owner: NSObject? = NSObject()
        weak var detachedOwner = owner
        let captured = try await entries(files)
        var candidate: FileDragSource?
        if let owner { candidate = coordinator.beginSource(entries: captured, owner: owner) }
        let source = try #require(candidate)
        source.startSession()
        owner = nil
        source.finishIfInactive()
        #expect(detachedOwner != nil)
        #expect(source.hasActiveSession)
        #expect(source.pasteboardWriter(itemID: captured[0].item.id) != nil)
        source.finish()
        #expect(detachedOwner == nil)
        #expect(!source.hasActiveSession)
        #expect(source.pasteboardWriter(itemID: captured[0].item.id) == nil)
    }

    @Test
    func acceptedInternalDropReleasesSessionOwnerAndCannotReplayWithoutNativeEnd() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        let secondDestination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate(); secondDestination.invalidate() }
        var owner: NSObject? = NSObject()
        weak var detachedOwner = owner
        let captured = try await entries(files)
        var candidate: FileDragSource?
        if let owner { candidate = coordinator.beginSource(entries: captured, owner: owner) }
        let source = try #require(candidate)
        defer { source.finish() }
        source.startSession()
        let writer = try #require(source.pasteboardWriter(itemID: captured[0].item.id))
        files.board.clearContents()
        try #require(files.board.writeObjects([writer]))
        let info = FileDragInfoStub(board: files.board, source: source)
        owner = nil
        #expect(detachedOwner != nil)
        #expect(destination.update(info, binding: binding).isEmpty)
        try await waitUntil { await files.preparer.calls.count == 1 }
        #expect(source.hasActiveSession)
        #expect(detachedOwner != nil)
        await files.preparer.complete(0, context: context)
        try await waitUntil { !destination.isPreparing }
        #expect(destination.update(info, binding: binding) == .move)
        #expect(destination.accept(info, binding: binding))
        // Do not deliver a native end callback. Acceptance must break registry
        // retention of the old owner immediately and revoke all issued writers.
        #expect(detachedOwner == nil)
        #expect(!source.hasActiveSession)
        #expect(!source.isValid)
        #expect(source.pasteboardWriter(itemID: captured[0].item.id) == nil)
        #expect(!destination.accept(info, binding: binding))
        #expect(secondDestination.update(info, binding: binding).isEmpty)
        #expect(!secondDestination.accept(info, binding: binding))
        try await waitUntil {
            !files.store.isPerformingOperation && !files.store.activeTab.isLoading && !files.store.activeTab.isRefreshing
        }
        #expect(await files.writer.kinds == [.move])
        #expect(!FileManager.default.fileExists(atPath: files.file.path))
        #expect(try Data(contentsOf: files.target.appendingPathComponent("payload.txt")) == files.bytes)
    }

    @Test(arguments: ["copy", "move", "cancel", "changed-mask", "changed-modifier"])
    func ambiguousHomeDropFreezesTheAcceptedOfferAndWaitsForTheChosenDirectory(_ mode: String) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let home = ExplorerStore(initialURL: BrowserPage.home.url, transfers: files.writer,
                                 clipboard: TransferClipboard(pasteboard: files.clipboardBoard))
        defer { home.cancelLoads(); home.cancelTransfer() }
        let target = try #require(home.homeFileDropTarget(row: nil))
        guard case .choose = target else { Issue.record("Expected directory chooser"); return }
        var choose: ((URL?) -> Void)?
        home.onChooseHomeFolder = { choose = $0 }
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: home)
        defer { destination.invalidate() }
        let captured = try await entries(files)
        let source = try #require(coordinator.beginSource(entries: captured, owner: files))
        defer { source.finish() }
        source.startSession()
        let writer = try #require(source.pasteboardWriter(itemID: captured[0].item.id))
        try #require(files.board.writeObjects([writer]))
        let info = FileDragInfoStub(board: files.board, source: source)
        files.modifiers = mode == "move" ? .command : []
        #expect(destination.update(info, target: target).isEmpty)
        try await waitUntil { !destination.isPreparing }
        let proposed: NSDragOperation = mode == "move" ? .move : .copy
        #expect(destination.update(info, target: target) == proposed)
        #expect(choose == nil)
        if mode == "changed-mask" { info.draggingSourceOperationMask = .move }
        if mode == "changed-modifier" { files.modifiers = .command }
        if mode.hasPrefix("changed") {
            #expect(!destination.accept(info, target: target))
            #expect(choose == nil)
            #expect(await files.writer.kinds.isEmpty)
            return
        }
        #expect(destination.accept(info, target: target))
        #expect(!source.isValid)
        #expect(!destination.accept(info, target: target))
        #expect(await files.preparer.calls.isEmpty)
        #expect(await files.writer.kinds.isEmpty)
        let finish = try #require(choose)
        files.board.clearContents()
        files.modifiers = .option
        if mode == "cancel" {
            finish(nil)
            #expect(await files.preparer.calls.isEmpty)
            #expect(try Data(contentsOf: files.file) == files.bytes)
            return
        }
        finish(files.target)
        try await waitUntil { await files.preparer.calls.count == 1 }
        let call = await files.preparer.calls[0]
        let expected: TransferKind = mode == "move" ? .move : .copy
        #expect(call.kind == expected)
        #expect(call.destination.standardizedFileURL.path == files.target.path)
        let verified = try await FileOperationContext.verifiedDirectory(at: files.target)
        await files.preparer.complete(0, context: verified)
        let output = files.target.appendingPathComponent("payload.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: output.path) && !home.isPerformingOperation }
        #expect(await files.writer.kinds == [expected])
        #expect(try Data(contentsOf: output) == files.bytes)
        #expect(FileManager.default.fileExists(atPath: files.file.path) == (mode == "copy"))
    }

    @Test
    func externalHomeOfferRejectsPromisesAndOnlyCopiesCapturedFileURLsAfterChoice() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let home = ExplorerStore(initialURL: BrowserPage.home.url, transfers: files.writer,
                                 clipboard: TransferClipboard(pasteboard: files.clipboardBoard))
        defer { home.cancelLoads(); home.cancelTransfer() }
        var choose: ((URL?) -> Void)?
        home.onChooseHomeFolder = { choose = $0 }
        let target = try #require(home.homeFileDropTarget(row: nil))
        let destination = files.coordinator().makeDestination(store: home)
        defer { destination.invalidate() }
        let item = NSPasteboardItem()
        try #require(item.setString(files.file.absoluteString, forType: .fileURL))
        let promise = try #require(NSFilePromiseReceiver.readableDraggedTypes.first)
        try #require(item.setString("promise", forType: .init(promise)))
        try #require(files.board.writeObjects([item]))
        let info = FileDragInfoStub(board: files.board)
        #expect(destination.update(info, target: target).isEmpty)
        #expect(!destination.accept(info, target: target))
        #expect(choose == nil)
        files.modifiers = .command
        try files.publishExternal()
        #expect(destination.update(info, target: target).isEmpty)
        try await waitUntil { await files.importer.requests.count == 1 }
        await files.importer.complete(0, entries: try await entries(files))
        try await waitUntil { !destination.isPreparing }
        #expect(destination.update(info, target: target) == .copy)
        #expect(destination.accept(info, target: target))
        let finish = try #require(choose)
        files.board.clearContents()
        finish(files.target)
        try await waitUntil { await files.preparer.calls.count == 1 }
        #expect(await files.preparer.calls[0].kind == .copy)
        let verified = try await FileOperationContext.verifiedDirectory(at: files.target)
        await files.preparer.complete(0, context: verified)
        let output = files.target.appendingPathComponent("payload.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: output.path) && !home.isPerformingOperation }
        #expect(try Data(contentsOf: files.file) == files.bytes)
        #expect(try Data(contentsOf: output) == files.bytes)
    }

    @Test(arguments: ["folder-and-child", "replaced-child", "link-parent"])
    func backgroundDropRechecksTheSelectionThatContributedItsDestination(_ mode: String) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let witness = files.target.appendingPathComponent("witness.txt")
        if mode == "link-parent" {
            try FileManager.default.createSymbolicLink(at: witness, withDestinationURL: files.source)
        } else {
            try Data("witness".utf8).write(to: witness)
        }
        let shortcuts = FinderTagShortcuts()
        shortcuts.setShowsAllTagged(true)
        let home = ExplorerStore(initialURL: BrowserPage.home.url, transfers: files.writer,
                                 clipboard: TransferClipboard(pasteboard: files.clipboardBoard), tagShortcuts: shortcuts)
        defer { home.cancelLoads(); home.cancelTransfer() }
        home.selectHomeSection(.tags)
        let scope = try #require(home.homeResultScope)
        let dir = try #require(FinderTagItem(indexedURL: files.target, tags: ["Group"], contentTypes: ["public.directory"]))
        let item = try #require(FinderTagItem(indexedURL: witness, tags: ["Group"], contentTypes: ["public.text"]))
        home.replaceHomeTagSnapshot(FinderTagsSnapshot(names: [], items: [dir, item]), in: scope)
        let directoryRow = HomeResultRow(item: dir, group: "Group")
        let itemRow = HomeResultRow(item: item, group: "Group")
        home.selectHomeResult(directoryRow, in: scope)
        home.selectHomeResult(itemRow, in: scope, toggling: true)
        try await waitUntil { home.homeFileDropTarget(row: nil) != nil }
        let target = try #require(home.homeFileDropTarget(row: nil))
        guard case .folder(let binding) = target else { Issue.record("Expected one physical destination"); return }
        #expect(binding.destinationURL.standardizedFileURL.path == files.target.path)
        if mode == "replaced-child" {
            try FileManager.default.moveItem(at: witness, to: files.root.appendingPathComponent("previous"))
            try Data("replacement".utf8).write(to: witness)
        }
        let destination = FileDragCoordinator(modifierFlags: { [] }).makeDestination(store: home)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        #expect(destination.update(info, target: target).isEmpty)
        try await waitUntil { !destination.isPreparing }
        if mode == "replaced-child" {
            #expect(!destination.accept(info, target: target))
            #expect(await files.writer.kinds.isEmpty)
            return
        }
        #expect(destination.update(info, target: target) == .copy)
        #expect(destination.accept(info, target: target))
        let output = files.target.appendingPathComponent("payload.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: output.path) && !home.isPerformingOperation }
        #expect(try Data(contentsOf: output) == files.bytes)
        #expect(try Data(contentsOf: files.file) == files.bytes)
    }

    @Test
    func unusedSourceAuthorityIsReleasedWhenItsPresentationLeaves() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let coordinator = files.coordinator()
        let owner = NSObject()
        let captured = try await entries(files)
        var source: FileDragSource? = try #require(coordinator.beginSource(entries: captured, owner: owner))
        weak var releasedSource = source
        source?.finishIfInactive()
        source = nil
        #expect(releasedSource == nil)
    }

    @Test(arguments: [false, true])
    func internalMoveSwitchesToOptionCopyAndRejectsTheOlderPreparation(actualOwnerIsSource: Bool) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, context) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        let owner = NSObject()
        let captured = try await entries(files)
        let source = try #require(coordinator.beginSource(entries: captured, owner: owner))
        defer { source.finish() }
        let writer = try #require(source.pasteboardWriter(itemID: captured[0].item.id))
        files.board.clearContents()
        try #require(files.board.writeObjects([writer]))
        let info = FileDragInfoStub(board: files.board, source: actualOwnerIsSource ? owner : source)
        #expect(destination.update(info, binding: binding) == [])
        try await waitUntil { await files.preparer.calls.count == 1 }
        #expect(await files.preparer.calls[0].kind == .move)
        #expect(await files.importer.requests.isEmpty)
        files.modifiers = .option
        #expect(destination.update(info, binding: binding) == [])
        try await waitUntil { await files.preparer.calls.count == 2 }
        #expect(await files.preparer.calls[1].kind == .copy)
        await files.preparer.complete(0, context: context)
        try await Task.sleep(for: .milliseconds(20))
        #expect(destination.isPreparing)
        #expect(await files.writer.kinds.isEmpty)
        await files.preparer.complete(1, context: context)
        try await waitUntil { !destination.isPreparing }
        #expect(destination.update(info, binding: binding) == .copy)
        #expect(destination.accept(info, binding: binding))
        try await waitUntil { !files.store.isPerformingOperation && !files.store.activeTab.isLoading }
        #expect(await files.writer.kinds == [.copy])
        #expect(try Data(contentsOf: files.file) == files.bytes)
    }

    @Test(arguments: ["foreign-source", "finished-source", "unregistered-token"])
    func tokenBytesNeverSupplyMoveAuthorityWithoutTheRegisteredActualSource(_ forgery: String) async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, _) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        let owner = NSObject()
        let captured = try await entries(files)
        let source = try #require(coordinator.beginSource(entries: captured, owner: owner))
        defer { source.finish() }
        let writer = try #require(source.pasteboardWriter(itemID: captured[0].item.id))
        files.board.clearContents()
        try #require(files.board.writeObjects([writer]))
        let info = FileDragInfoStub(board: files.board, source: source)
        switch forgery {
        case "foreign-source": info.draggingSource = NSObject()
        case "finished-source": source.finish()
        default:
            let item = NSPasteboardItem()
            try #require(item.setString(files.file.absoluteString, forType: .fileURL))
            try #require(item.setString(UUID().uuidString,
                forType: .init("com.native-explorer.file-drag-token")))
            files.board.clearContents()
            try #require(files.board.writeObjects([item]))
        }
        #expect(destination.update(info, binding: binding) == [])
        #expect(destination.refusalReason != nil)
        #expect(!destination.accept(info, binding: binding))
        #expect(await files.importer.requests.isEmpty)
        #expect(await files.preparer.calls.isEmpty)
        #expect(await files.writer.kinds.isEmpty)
    }

    @Test
    func preparationFailureRefusesDropAndNeverCallsWriter() async throws {
        let files = try DragTestFiles()
        defer { files.cleanup() }
        let (binding, _) = try await ready(files)
        let coordinator = files.coordinator()
        let destination = coordinator.makeDestination(store: files.store)
        defer { destination.invalidate() }
        try files.publishExternal()
        let info = FileDragInfoStub(board: files.board)
        #expect(destination.update(info, binding: binding) == [])
        try await waitUntil { await files.importer.requests.count == 1 }
        await files.importer.complete(0, entries: try await entries(files))
        try await waitUntil { await files.preparer.calls.count == 1 }
        await files.preparer.fail(0)
        try await waitUntil { !destination.isPreparing }
        #expect(destination.refusalReason != nil)
        #expect(!destination.accept(info, binding: binding))
        #expect(await files.writer.kinds.isEmpty)
    }
}
