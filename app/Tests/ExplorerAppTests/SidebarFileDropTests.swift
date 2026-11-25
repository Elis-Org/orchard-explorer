import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@MainActor
private final class SidebarDragInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = NSImage(size: NSSize(width: 32, height: 32))
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingSequenceNumber = 7_000
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(board: NSPasteboard, window: NSWindow?, source: Any?) {
        draggingPasteboard = board
        draggingDestinationWindow = window
        draggingSource = source
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        for (index, boardItem) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            let writer: NSPasteboardWriting
            if classArray.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(NSURL.self) }),
               let spelling = boardItem.string(forType: .fileURL), let url = NSURL(string: spelling) {
                writer = url
            } else { writer = boardItem }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let origin = view?.convert(draggingLocation, from: nil)
                ?? draggingDestinationWindow?.convertToScreen(NSRect(origin: draggingLocation, size: .zero)).origin ?? .zero
            item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 32, height: 32)), contents: draggedImage)
            var stop = ObjCBool(false)
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}

private actor SidebarHeldDropPreparer: FileDropPreparing {
    private(set) var requestCount = 0
    private var pending: [(PreparedFileDrop, CheckedContinuation<PreparedFileDrop, Error>)] = []

    func prepare(entries: [TransferEntry], destinationURL: URL,
                 expectedDestinationIdentity: LocalFileIdentity?, expectedEntryIdentity: LocalFileIdentity?,
                 kind: TransferKind) async throws -> PreparedFileDrop {
        let prepared = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destinationURL,
            expectedDestinationIdentity: expectedDestinationIdentity,
            expectedEntryIdentity: expectedEntryIdentity, kind: kind)
        return try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            pending.append((prepared, continuation))
        }
    }

    func release() {
        let held = pending
        pending.removeAll()
        for (prepared, continuation) in held { continuation.resume(returning: prepared) }
    }
}

@MainActor
private final class SidebarDropModifiers {
    var flags: NSEvent.ModifierFlags = []
}

/// NATIVE-P13 / FR-DROP-001/002/004 / AT-DROP-001/002/004.
/// Native destination release routing with disposable files; no pointer tracking.
@Suite(.serialized)
@MainActor
final class SidebarFileDropTests {
    @Test(arguments: [false, true])
    func nativeDraggingEndedRunsDestinationCleanup(isSidebar: Bool) {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("explorer-drag-end-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let info = SidebarDragInfoStub(board: board, window: nil, source: nil)
        var cleanupCount = 0
        let endDrag: (any NSDraggingInfo) -> Void
        if isSidebar {
            let outline = NavigationOutlineView()
            outline.onDraggingFinished = { cleanupCount += 1 }
            endDrag = outline.draggingEnded
        } else {
            let table = ExplorerTableView()
            table.onFileDropExit = { cleanupCount += 1 }
            endDrag = table.draggingEnded
        }

        endDrag(info)
        #expect(cleanupCount == 1)
        info.draggingSequenceNumber += 1
        endDrag(info)
        #expect(cleanupCount == 2)
    }

    @Test(arguments: [false, true])
    func nativeSidebarReleaseRoutesReadyMoveAfterPendingOrPrewarmedEntry(preparedBeforeEntry: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let originalURL = fixture.store.activeTab.url
        let originalSelection = fixture.store.activeTab.selection
        let sidebarSelection = fixture.outline.selectedRow
        if preparedBeforeEntry {
            #expect(fixture.coordinator.updateDrop(fixture.info).isEmpty)
            try await waitUntil { await fixture.preparer.requestCount == 1 }
            await fixture.preparer.release()
            try await waitUntil { fixture.coordinator.updateDrop(fixture.info) == .move }
            #expect(fixture.outline.draggingEntered(fixture.info) == .move)
        } else {
            #expect(fixture.outline.draggingEntered(fixture.info).isEmpty)
            #expect(fixture.outline.draggingUpdated(fixture.info).isEmpty)
            try await waitUntil { await fixture.preparer.requestCount == 1 }
            await fixture.preparer.release()
        }
        try await waitUntil { fixture.outline.draggingUpdated(fixture.info) == .move }
        #expect(fixture.outline.highlightedDropRow == fixture.targetRow)
        #expect(fixture.store.activeTab.url == originalURL)
        #expect(fixture.store.activeTab.selection == originalSelection)
        #expect(fixture.outline.selectedRow == sidebarSelection)
        #expect(!fixture.store.isPerformingOperation)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))

        let targetCell = try #require(fixture.outline.view(atColumn: 0, row: fixture.targetRow, makeIfNecessary: true) as? NSTableCellView)
        #expect(targetCell.imageView?.registeredDraggedTypes.isEmpty == true)
        // Exercise the actual native release entry points, not coordinator.acceptDrop.
        let prepares = fixture.outline.prepareForDragOperation(fixture.info)
        #expect(prepares)
        guard prepares else { return }
        #expect(fixture.outline.performDragOperation(fixture.info))
        #expect(!fixture.outline.performDragOperation(fixture.info))
        try await waitUntil {
            !fixture.store.isPerformingOperation && !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        #expect(try Data(contentsOf: fixture.targetURL.appendingPathComponent("payload.txt")) == fixture.bytes)
        #expect(fixture.store.activeTab.url == originalURL)
        #expect(fixture.outline.selectedRow == sidebarSelection)
        #expect(fixture.outline.highlightedDropRow == -1)
        #expect(fixture.outline.toolTip == nil)
    }

    @Test
    func pendingSidebarReleaseRefusesAndClearsWithoutWriting() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        #expect(fixture.outline.draggingEntered(fixture.info).isEmpty)
        try await waitUntil { await fixture.preparer.requestCount == 1 }
        #expect(fixture.outline.draggingUpdated(fixture.info).isEmpty)
        #expect(fixture.outline.highlightedDropRow == fixture.targetRow)
        #expect(!fixture.outline.prepareForDragOperation(fixture.info))
        #expect(!fixture.outline.performDragOperation(fixture.info))
        await fixture.preparer.release()
        #expect(fixture.outline.highlightedDropRow == -1)
        #expect(fixture.outline.toolTip == nil)
        #expect(!fixture.store.isPerformingOperation)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.appendingPathComponent("payload.txt").path))
    }

    @Test(arguments: ["pointer", "outside", "background", "binding", "node", "modifier", "sequence", "pasteboard", "source"])
    func changedSidebarReleaseStateCannotSubmitPreparedMove(_ change: String) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let originalURL = fixture.store.activeTab.url
        let originalSelection = fixture.store.activeTab.selection
        let originalSidebarSelection = fixture.outline.selectedRow
        #expect(fixture.outline.draggingEntered(fixture.info).isEmpty)
        try await waitUntil { await fixture.preparer.requestCount == 1 }
        await fixture.preparer.release()
        try await waitUntil { fixture.outline.draggingUpdated(fixture.info) == .move }
        switch change {
        case "pointer":
            let group = fixture.outline.rect(ofRow: 0)
            fixture.info.draggingLocation = fixture.outline.convert(NSPoint(x: group.midX, y: group.midY), to: nil)
        case "outside":
            let row = fixture.outline.rect(ofRow: fixture.targetRow)
            fixture.info.draggingLocation = fixture.outline.convert(NSPoint(x: fixture.outline.visibleRect.maxX + 20, y: row.midY), to: nil)
        case "background":
            let last = fixture.outline.rect(ofRow: fixture.outline.numberOfRows - 1)
            fixture.info.draggingLocation = fixture.outline.convert(NSPoint(x: last.midX, y: last.maxY + 6), to: nil)
        case "binding": fixture.store.refresh()
        case "node":
            fixture.store.pins.unpin(fixture.targetURL)
            try #require(fixture.store.pins.pin(fixture.targetURL))
            fixture.coordinator.update()
        case "modifier": fixture.modifiers.flags = .option
        case "sequence": fixture.info.draggingSequenceNumber += 1
        case "pasteboard":
            fixture.board.clearContents()
            try #require(fixture.board.writeObjects([fixture.sourceURL as NSURL]))
        default: fixture.source.finish()
        }
        if ["pointer", "outside", "background", "binding", "node"].contains(change) {
            #expect(!fixture.outline.prepareForDragOperation(fixture.info))
        }
        #expect(!fixture.outline.performDragOperation(fixture.info))
        #expect(fixture.outline.highlightedDropRow == -1)
        #expect(fixture.outline.toolTip == nil)
        #expect(!fixture.store.isPerformingOperation)
        #expect(fixture.store.activeTab.url == originalURL)
        #expect(fixture.store.activeTab.selection == originalSelection)
        #expect(fixture.outline.selectedRow == originalSidebarSelection)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.appendingPathComponent("payload.txt").path))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let reached = await condition()
        try #require(reached)
    }

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-sidebar-drop-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let targetURL = root.appendingPathComponent("DropSidebarTarget", isDirectory: true)
        let sourceURL = sourceFolder.appendingPathComponent("payload.txt")
        let bytes = Data("sidebar native release fixture".utf8)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
        try bytes.write(to: sourceURL)
        let pins = PinnedFolderStore(homeURL: root)
        try #require(pins.pin(targetURL))
        let store = ExplorerStore(initialURL: sourceFolder, homeURL: root, pins: pins)
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        let model = SidebarModel(homeURL: root, pins: pins)
        let preparer = SidebarHeldDropPreparer()
        let modifiers = SidebarDropModifiers()
        let dragCoordinator = FileDragCoordinator(preparer: preparer, modifierFlags: { modifiers.flags })
        let coordinator = SidebarOutline.Coordinator(store: store, model: model, fileDragCoordinator: dragCoordinator)
        let outline = NavigationOutlineView()
        outline.headerView = nil
        outline.rowHeight = 30
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: .init("destination"))
        column.width = 300
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.registerForDraggedTypes(FileDragCoordinator.registeredTypes)
        outline.onDraggingUpdate = { coordinator.updateDrop($0) }
        outline.onDraggingFinished = { coordinator.clearDrop() }
        outline.onPrepareFileDrop = { coordinator.prepareDrop($0) }
        outline.onPerformFileDrop = { coordinator.performDrop($0) }
        coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        coordinator.update()
        window.contentView?.layoutSubtreeIfNeeded()
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let targetRow = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.url == targetURL
        })
        let item = try #require(store.displayedItems.first(where: { $0.url == sourceURL }))
        store.setSelection([item.id], focusedID: item.id, anchorID: item.id)
        let entries = try #require(store.fileDragEntries(itemIDs: [item.id]))
        let owner = NSObject()
        let source = try #require(dragCoordinator.beginSource(entries: entries, owner: owner))
        source.startSession()
        let writer = try #require(source.pasteboardWriter(itemID: item.id))
        let board = NSPasteboard(name: .init("explorer-sidebar-drag-\(UUID().uuidString)"))
        try #require(board.writeObjects([writer]))
        let info = SidebarDragInfoStub(board: board, window: window, source: source)
        info.draggingSequenceNumber = 7_000
        let row = outline.rect(ofRow: targetRow)
        info.draggingLocation = outline.convert(NSPoint(x: row.maxX - 40, y: row.midY), to: nil)
        return Fixture(root: root, sourceURL: sourceURL, targetURL: targetURL, bytes: bytes,
            store: store, model: model, coordinator: coordinator, outline: outline,
            preparer: preparer, modifiers: modifiers, source: source, board: board, info: info, window: window, targetRow: targetRow)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let sourceURL: URL
        let targetURL: URL
        let bytes: Data
        let store: ExplorerStore
        let model: SidebarModel
        let coordinator: SidebarOutline.Coordinator
        let outline: NavigationOutlineView
        let preparer: SidebarHeldDropPreparer
        let modifiers: SidebarDropModifiers
        let source: FileDragSource
        let board: NSPasteboard
        let info: SidebarDragInfoStub
        let window: NSWindow
        let targetRow: Int

        func close() {
            coordinator.clearDrop()
            source.finish()
            store.cancelLoads()
            model.cancelLoads()
            window.close()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
            Task { await preparer.release() }
        }
    }
}
