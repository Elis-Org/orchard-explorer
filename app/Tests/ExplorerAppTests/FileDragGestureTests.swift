import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

private actor GestureHeldDropPreparer: FileDropPreparing {
    private(set) var requestCount = 0
    private var pending: [(PreparedFileDrop, CheckedContinuation<PreparedFileDrop, Error>)] = []

    func prepare(entries: [TransferEntry], destinationURL: URL,
                 expectedDestinationIdentity: LocalFileIdentity?, expectedEntryIdentity: LocalFileIdentity?,
                 kind: TransferKind) async throws -> PreparedFileDrop {
        let result = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destinationURL,
            expectedDestinationIdentity: expectedDestinationIdentity,
            expectedEntryIdentity: expectedEntryIdentity, kind: kind)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((result, continuation))
            requestCount += 1
        }
    }

    func releaseAll(refusing: Bool = false) {
        let held = pending
        pending.removeAll()
        for (result, continuation) in held {
            if refusing { continuation.resume(throwing: FileOperationError.unsupported("Rejected test drop")) }
            else { continuation.resume(returning: result) }
        }
    }
}

/// NATIVE-P13 / FR-DROP-001/002/004 / AT-DROP-001/002/004.
/// Native gesture-policy checks; actual pointer drags and filesystem results
/// remain separate desktop acceptance evidence.
@Suite(.serialized)
@MainActor
final class FileDragGestureTests {
    @Test(arguments: [FolderViewMode.extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons, .list, .tiles, .content])
    func collectionFolderDropCoversIconLabelAndWholeItemWithoutCompetingDescendantDestinations(_ mode: FolderViewMode) async throws {
        let dragCoordinator = FileDragCoordinator(modifierFlags: { [] })
        let fixture = try await makeFixture(includeTargetFolder: true, fileDragCoordinator: dragCoordinator)
        defer { fixture.close() }
        fixture.store.setViewMode(mode)
        fixture.coordinator.update()
        fixture.layout()
        let targetURL = fixture.root.appendingPathComponent("Target", isDirectory: true)
        let folderIndex = try #require(fixture.view.items.firstIndex(where: { $0.url == targetURL }))
        let fileIndex = try #require(fixture.view.items.firstIndex(where: { $0.name == "Alpha.txt" }))
        let folder = try #require(fixture.view.item(at: IndexPath(item: folderIndex, section: 0)) as? ExplorerCollectionItem)
        let file = try #require(fixture.view.item(at: IndexPath(item: fileIndex, section: 0)) as? ExplorerCollectionItem)
        folder.itemView.layoutSubtreeIfNeeded()
        file.itemView.layoutSubtreeIfNeeded()

        // A registered descendant competes with the collection as an AppKit
        // destination, independently of the collection's whole-item layout hit.
        var descendants = folder.itemView.subviews
        while let child = descendants.popLast() {
            #expect(child.registeredDraggedTypes.isEmpty)
            descendants.append(contentsOf: child.subviews)
        }

        let board = NSPasteboard(name: .init("explorer-icon-drop-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([fixture.root.appendingPathComponent("Alpha.txt") as NSURL]))
        let info = FileDragInfoStub(board: board)
        let folderPoints = [NSPoint(x: folder.itemView.icon.frame.midX, y: folder.itemView.icon.frame.midY),
                            NSPoint(x: folder.itemView.nameField.frame.midX, y: folder.itemView.nameField.frame.midY),
                            NSPoint(x: folder.itemView.bounds.maxX - 3, y: folder.itemView.bounds.midY)]
        for point in folderPoints {
            let collectionPoint = fixture.view.convert(point, from: folder.itemView)
            #expect(fixture.view.indexPathForItem(at: collectionPoint) == IndexPath(item: folderIndex, section: 0))
            let parentPoint = folder.itemView.convert(point, to: folder.itemView.superview)
            #expect(folder.itemView.hitTest(parentPoint) === folder.itemView)
            info.draggingLocation = folder.itemView.convert(point, to: nil)
            try await waitForGesture { fixture.view.draggingUpdated(info) == .copy }
            #expect(fixture.view.fileDropTargetID == folder.representedID)
            #expect(folder.itemView.isFileDropTarget)
            #expect(fixture.view.prepareForDragOperation(info))
        }

        // All corresponding regions of a regular file refuse, rather than
        // falling through to a copy into the parent directory.
        let filePoints = [NSPoint(x: file.itemView.icon.frame.midX, y: file.itemView.icon.frame.midY),
                          NSPoint(x: file.itemView.nameField.frame.midX, y: file.itemView.nameField.frame.midY),
                          NSPoint(x: file.itemView.bounds.maxX - 3, y: file.itemView.bounds.midY)]
        for point in filePoints {
            info.draggingLocation = file.itemView.convert(point, to: nil)
            #expect(fixture.view.draggingUpdated(info).isEmpty)
            #expect(fixture.view.fileDropTargetID == nil)
            #expect(!fixture.view.prepareForDragOperation(info))
        }

        let background = NSPoint(x: fixture.view.visibleRect.maxX - 40, y: fixture.view.visibleRect.maxY - 40)
        #expect(fixture.view.indexPathForItem(at: background) == nil)
        info.draggingLocation = fixture.view.convert(background, to: nil)
        try await waitForGesture { fixture.view.draggingUpdated(info) == .copy }
        #expect(fixture.view.fileDropTargetID == nil)
        #expect(fixture.view.prepareForDragOperation(info))
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(!fixture.store.isPerformingOperation)
        #expect(!FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("Alpha.txt").path))
    }

    @Test(arguments: ["details", "collection"])
    func holdingPreparedFolderTargetHighlightsWithoutNavigatingOrWriting(_ adapter: String) async throws {
        let preparer = GestureHeldDropPreparer()
        defer { Task { await preparer.releaseAll() } }
        let dragCoordinator = FileDragCoordinator(preparer: preparer, modifierFlags: { [] })
        let fixture = try await makeFixture(includeTargetFolder: true, fileDragCoordinator: dragCoordinator)
        defer { fixture.close() }
        let board = NSPasteboard(name: .init("explorer-folder-hover-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let sourceURL = fixture.root.appendingPathComponent("Alpha.txt")
        let targetURL = fixture.root.appendingPathComponent("Target", isDirectory: true)
        try #require(board.writeObjects([sourceURL as NSURL]))
        let info = FileDragInfoStub(board: board)
        let index = try #require(fixture.store.displayedItems.firstIndex(where: { $0.url == targetURL }))
        let targetID = fixture.store.displayedItems[index].id
        let originalTab = fixture.store.activeTabID
        let originalURL = fixture.store.activeTab.url
        let originalSelection = fixture.store.activeTab.selection
        let update: () -> NSDragOperation
        let hitTarget: () -> String?
        let visualTarget: () -> String?
        let moveToItem: (Int) -> Void
        let clear: () -> Void
        let accept: () -> Bool
        var tableCoordinator: DetailsTableView.Coordinator?
        if adapter == "details" {
            let coordinator = DetailsTableView.Coordinator(store: fixture.store, fileDragCoordinator: dragCoordinator)
            let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
            table.addTableColumn(NSTableColumn(identifier: .init("name")))
            table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
            table.dataSource = coordinator
            table.delegate = coordinator
            table.onFileDropUpdate = { coordinator.updateFileDrop($0) }
            coordinator.table = table
            coordinator.items = fixture.store.displayedItems
            let scroll = ExplorerDetailsScrollView()
            scroll.documentView = table
            fixture.window.contentView = scroll
            table.reloadData()
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            scroll.resetForNavigation()
            let row = table.rect(ofRow: index)
            info.draggingLocation = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
            tableCoordinator = coordinator
            update = { table.draggingUpdated(info) }
            hitTarget = {
                let hitRow = table.row(at: table.convert(info.draggingLocation, from: nil))
                return coordinator.items.indices.contains(hitRow) ? coordinator.items[hitRow].id : nil
            }
            visualTarget = {
                guard let row = table.highlightedFileDropRow, coordinator.items.indices.contains(row) else { return nil }
                return coordinator.items[row].id
            }
            moveToItem = { index in
                let rect = table.rect(ofRow: index)
                info.draggingLocation = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            }
            clear = { coordinator.clearFileDrop() }
            accept = { coordinator.tableView(table, acceptDrop: info, row: index, dropOperation: .on) }
            #expect(table.draggingDestinationFeedbackStyle == .none)
        } else {
            fixture.layout()
            let frame = try #require(fixture.view.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
            info.draggingLocation = fixture.view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            update = { fixture.view.draggingUpdated(info) }
            hitTarget = {
                guard let path = fixture.view.indexPathForItem(at: fixture.view.convert(info.draggingLocation, from: nil)),
                      fixture.view.items.indices.contains(path.item) else { return nil }
                return fixture.view.items[path.item].id
            }
            visualTarget = { fixture.view.fileDropTargetID }
            moveToItem = { index in
                guard let frame = fixture.view.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
                info.draggingLocation = fixture.view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            }
            clear = { fixture.view.clearFileDrop() }
            accept = { fixture.view.performDragOperation(info) }
        }
        defer { tableCoordinator?.clearFileDrop() }
        #expect(update().isEmpty)
        #expect(visualTarget() == targetID)
        for _ in 0..<3 {
            #expect(update().isEmpty)
            #expect(visualTarget() == targetID)
        }
        if adapter == "collection" { #expect(!fixture.view.prepareForDragOperation(info)) }
        try await waitForGesture { await preparer.requestCount == 1 }
        #expect(!accept())
        #expect(visualTarget() == nil)
        #expect(!fixture.store.isPerformingOperation)
        #expect(!FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("Alpha.txt").path))

        // A file row refuses immediately instead of retaining the folder outline.
        let fileIndex = try #require(fixture.store.displayedItems.firstIndex(where: { $0.url == sourceURL }))
        moveToItem(fileIndex)
        #expect(update().isEmpty)
        #expect(visualTarget() == nil)
        moveToItem(index)
        #expect(update().isEmpty)
        #expect(visualTarget() == targetID)
        try await waitForGesture { await preparer.requestCount == 2 }
        await preparer.releaseAll()
        let deadline = Date().addingTimeInterval(5)
        while update().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hitTarget() == targetID)
        #expect(update() == .copy)
        #expect(visualTarget() == targetID)
        if adapter == "collection" {
            #expect(fixture.view.fileDropTargetID == targetID)
        }
        // Hold longer than the previous 0.8-second folder navigation delay.
        let holdDeadline = Date().addingTimeInterval(1)
        while Date() < holdDeadline {
            #expect(hitTarget() == targetID)
            #expect(update() == .copy)
            #expect(visualTarget() == targetID)
            try await Task.sleep(for: .milliseconds(25))
        }
        clear()
        #expect(visualTarget() == nil)

        // Exiting or cancelling while a check is held prevents its late result
        // from restoring an outline after the destination has been cleared.
        #expect(update().isEmpty)
        #expect(visualTarget() == targetID)
        try await waitForGesture { await preparer.requestCount == 3 }
        clear()
        await preparer.releaseAll()
        try await Task.sleep(for: .milliseconds(20))
        #expect(visualTarget() == nil)

        // Refresh changes the receiving generation while preparation is held.
        #expect(update().isEmpty)
        try await waitForGesture { await preparer.requestCount == 4 }
        fixture.store.refresh()
        #expect(update().isEmpty)
        #expect(visualTarget() == nil)
        await preparer.releaseAll()
        try await waitForGesture { !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing }
        #expect(visualTarget() == nil)

        // A rejected check clears on the next normal native update.
        #expect(update().isEmpty)
        try await waitForGesture { await preparer.requestCount == 5 }
        await preparer.releaseAll(refusing: true)
        try await waitForGesture {
            _ = update()
            return visualTarget() == nil
        }
        #expect(update().isEmpty)
        #expect(visualTarget() == nil)
        #expect(fixture.store.activeTabID == originalTab)
        #expect(fixture.store.activeTab.url == originalURL)
        #expect(fixture.store.activeTab.selection == originalSelection)
        #expect(!fixture.store.isPerformingOperation)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("Alpha.txt").path))
    }

    private func waitForGesture(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }

    @Test
    func dragAutoscrollPreservesNativeHeaderOriginForShortDetailsListing() {
        let fixture = makeAutoscrollTable(rowCount: 3)
        defer { fixture.close() }
        let clip = fixture.scroll.contentView
        let initial = clip.bounds
        #expect(clip.contentInsets.top > 0)
        #expect(initial.minY < 0)
        let firstRow = fixture.table.convert(fixture.table.rect(ofRow: 0), to: clip)
        for point in [NSPoint(x: initial.midX, y: initial.midY),
                      NSPoint(x: initial.midX, y: initial.minY + 2),
                      NSPoint(x: initial.midX, y: initial.maxY - 2)] {
            updateFileDropAutoscroll(view: fixture.table, locationInWindow: clip.convert(point, to: nil))
            #expect(clip.bounds.origin == initial.origin)
            #expect(fixture.table.convert(fixture.table.rect(ofRow: 0), to: clip) == firstRow)
        }
    }

    @Test
    func dragAutoscrollDoesNotMoveShortCollectionAtEitherEdge() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let clip = try #require(fixture.view.enclosingScrollView?.contentView)
        let initial = clip.bounds
        for point in [NSPoint(x: initial.midX, y: initial.midY),
                      NSPoint(x: initial.midX, y: initial.minY + 2),
                      NSPoint(x: initial.midX, y: initial.maxY - 2)] {
            updateFileDropAutoscroll(view: fixture.view, locationInWindow: clip.convert(point, to: nil))
            #expect(clip.bounds.origin == initial.origin)
        }
    }

    @Test
    func dragAutoscrollMovesTallDetailsListingAtEdgesAndPreservesHeaderTopLimit() {
        let fixture = makeAutoscrollTable(rowCount: 80)
        defer { fixture.close() }
        let clip = fixture.scroll.contentView
        let initial = clip.bounds
        updateFileDropAutoscroll(view: fixture.table,
            locationInWindow: clip.convert(NSPoint(x: initial.midX, y: initial.midY), to: nil))
        #expect(clip.bounds.origin == initial.origin)
        updateFileDropAutoscroll(view: fixture.table,
            locationInWindow: clip.convert(NSPoint(x: initial.midX, y: initial.maxY - 2), to: nil))
        #expect(clip.bounds.minY > initial.minY)
        let scrolled = clip.bounds
        updateFileDropAutoscroll(view: fixture.table,
            locationInWindow: clip.convert(NSPoint(x: scrolled.midX, y: scrolled.minY + 2), to: nil))
        #expect(clip.bounds.origin == initial.origin)
        updateFileDropAutoscroll(view: fixture.table,
            locationInWindow: clip.convert(NSPoint(x: initial.midX, y: initial.minY + 2), to: nil))
        #expect(clip.bounds.origin == initial.origin)
    }

    @Test
    func collectionDragThresholdUsesSixPointDistance() {
        let start = NSPoint(x: 20, y: 30)
        #expect(!ExplorerFileCollectionView.crossedFileDragThreshold(from: start, to: NSPoint(x: 25.9, y: 30)))
        #expect(!ExplorerFileCollectionView.crossedFileDragThreshold(from: start, to: NSPoint(x: 23, y: 34)))
        #expect(ExplorerFileCollectionView.crossedFileDragThreshold(from: start, to: NSPoint(x: 26, y: 30)))
        #expect(ExplorerFileCollectionView.crossedFileDragThreshold(from: start, to: NSPoint(x: 20, y: 24)))
    }

    @Test
    func selectedCollectionPressPreservesMultiSelectionUntilReleaseInEveryMode() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for mode in FolderViewMode.allCases where mode != .details {
            fixture.store.setViewMode(mode)
            fixture.coordinator.update()
            fixture.layout()
            fixture.view.selectItem(at: 0, extending: false, toggling: false)
            fixture.view.selectItem(at: 1, extending: false, toggling: true)
            let selected = fixture.store.activeTab.selection.selectedIDs
            let cell = try #require(fixture.view.item(at: IndexPath(item: 0, section: 0)) as? ExplorerCollectionItem)
            cell.itemView.mouseDown(with: try fixture.event(type: .leftMouseDown, index: 0))
            #expect(fixture.store.activeTab.selection.selectedIDs == selected)
            #expect(fixture.view.selectionIndexPaths.count == 2)
            cell.itemView.mouseUp(with: try fixture.event(type: .leftMouseUp, index: 0))
            #expect(fixture.store.activeTab.selection.selectedIDs == [fixture.view.items[0].id])
        }
    }

    @Test
    func commandAndRangeClicksKeepTheirSelectionAfterRelease() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 0, extending: false, toggling: false)
        fixture.view.mouseDown(with: try fixture.event(type: .leftMouseDown, index: 2, modifiers: .shift))
        fixture.view.mouseUp(with: try fixture.event(type: .leftMouseUp, index: 2, modifiers: .shift))
        #expect(fixture.view.selectionIndexPaths.count == 3)
        fixture.view.mouseDown(with: try fixture.event(type: .leftMouseDown, index: 1, modifiers: .command))
        fixture.view.mouseUp(with: try fixture.event(type: .leftMouseUp, index: 1, modifiers: .command))
        #expect(fixture.store.activeTab.selection.selectedIDs == [fixture.view.items[0].id, fixture.view.items[2].id])
    }

    @Test
    func cancelledPendingPressCannotCollapseSelectionLater() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 0, extending: false, toggling: false)
        fixture.view.selectItem(at: 1, extending: false, toggling: true)
        let selected = fixture.store.activeTab.selection.selectedIDs
        fixture.view.mouseDown(with: try fixture.event(type: .leftMouseDown, index: 0))
        fixture.view.cancelPendingFileDrag()
        fixture.view.mouseUp(with: try fixture.event(type: .leftMouseUp, index: 0))
        #expect(fixture.store.activeTab.selection.selectedIDs == selected)
    }

    @Test
    func escapeCancelsPendingCollectionClickThroughResponderAction() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 0, extending: false, toggling: false)
        fixture.view.selectItem(at: 1, extending: false, toggling: true)
        let selected = fixture.store.activeTab.selection.selectedIDs
        fixture.view.mouseDown(with: try fixture.event(type: .leftMouseDown, index: 0))
        #expect(NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: fixture.view, from: nil))
        fixture.view.mouseUp(with: try fixture.event(type: .leftMouseUp, index: 0))
        #expect(fixture.store.activeTab.selection.selectedIDs == selected)
    }

    @Test
    func detailsSourceWritesEntireRequestedSelectionAndEndsAuthority() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let coordinator = DetailsTableView.Coordinator(store: fixture.store)
        let table = ExplorerTableView()
        coordinator.table = table
        coordinator.items = fixture.store.displayedItems
        // Exercise source transport directly. NSTableView.mouseDown enters its
        // native event-tracking loop, which is not a synthetic gesture test.
        #expect(coordinator.beginFileDrag(rows: IndexSet([0, 1])))
        #expect(coordinator.tableView(table, pasteboardWriterForRow: 0) != nil)
        #expect(coordinator.tableView(table, pasteboardWriterForRow: 1) != nil)
        #expect(coordinator.tableView(table, pasteboardWriterForRow: 2) == nil)
        coordinator.finishFileDrag()
        #expect(table.fileDragSource == nil)
    }

    @Test
    func consecutiveDistinctDetailsMovesRetireMissingCompletionAndIgnoreLateOldSessionEnd() async throws {
        let dragCoordinator = FileDragCoordinator(modifierFlags: { [] })
        let fixture = try await makeFixture(includeTargetFolder: true, fileDragCoordinator: dragCoordinator)
        defer { fixture.close() }
        let coordinator = DetailsTableView.Coordinator(store: fixture.store, fileDragCoordinator: dragCoordinator)
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        let scroll = ExplorerDetailsScrollView()
        scroll.documentView = table
        fixture.window.contentView = scroll
        defer { coordinator.finishFileDrag(); coordinator.clearFileDrop() }
        let board = NSPasteboard(name: .init("explorer-repeat-drag-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let targetURL = fixture.root.appendingPathComponent("Target", isDirectory: true)
        var previousSource: FileDragSource?
        var previousSequence: Int?

        for (offset, name) in ["Alpha.txt", "Bravo.txt"].enumerated() {
            coordinator.items = fixture.store.displayedItems
            table.itemIDs = coordinator.items.map(\.id)
            table.reloadData()
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            scroll.resetForNavigation()
            // The reported second drag starts from an unselected distinct row.
            table.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            fixture.store.setSelection([], focusedID: nil, anchorID: nil)
            let sourceURL = fixture.root.appendingPathComponent(name)
            let expectedBytes = try Data(contentsOf: sourceURL)
            let row = try #require(coordinator.items.firstIndex(where: { $0.url == sourceURL }))

            if offset > 0 {
                // Also model a cancelled/outgoing drag for which no receiving
                // accept or native end arrives. It still needs fresh-press recovery.
                #expect(coordinator.beginFileDrag(rows: IndexSet(integer: row)))
                let orphan = try #require(table.fileDragSource)
                let orphanSequence = 900 + offset
                table.startFileDragSession(sequenceNumber: orphanSequence)
                #expect(orphan.hasActiveSession)
                previousSource = orphan
                previousSequence = orphanSequence
            }

            // Invoke the exact fresh-press boundary without entering AppKit's
            // mouseDown tracking loop. Omit the previous session's end callback.
            table.beginFileDragGesture()
            if let previousSource {
                #expect(!previousSource.isValid)
                #expect(!previousSource.hasActiveSession)
            }
            #expect(coordinator.beginFileDrag(rows: IndexSet(integer: row)))
            let source = try #require(table.fileDragSource)
            #expect(source !== previousSource)
            if let previousSequence {
                #expect(!coordinator.finishFileDrag(sequenceNumber: previousSequence))
                #expect(table.fileDragSource === source)
                #expect(source.isValid)
            }
            let sequence = 400 + offset
            table.startFileDragSession(sequenceNumber: sequence)
            if let previousSequence {
                #expect(!coordinator.finishFileDrag(sequenceNumber: previousSequence))
                #expect(table.fileDragSource === source)
                #expect(source.hasActiveSession)
            }
            let writer = try #require(coordinator.tableView(table, pasteboardWriterForRow: row))
            board.clearContents()
            try #require(board.writeObjects([writer]))
            let info = FileDragInfoStub(board: board, source: table)
            info.draggingSequenceNumber = sequence
            let targetRow = try #require(coordinator.items.firstIndex(where: { $0.url == targetURL }))
            let targetFrame = table.rect(ofRow: targetRow)
            info.draggingLocation = table.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
            try await waitForGesture { coordinator.updateFileDrop(info) == .move }
            if let previousSequence {
                #expect(!coordinator.finishFileDrag(sequenceNumber: previousSequence))
                #expect(table.highlightedFileDropRow == targetRow)
                #expect(source.isValid)
            }
            #expect(coordinator.tableView(table, acceptDrop: info, row: targetRow, dropOperation: .on))
            try await waitForGesture {
                !fixture.store.isPerformingOperation && !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing
            }
            #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
            #expect(try Data(contentsOf: targetURL.appendingPathComponent(name)) == expectedBytes)
            #expect(fixture.store.activeTab.url == fixture.root)
            #expect(fixture.store.activeTab.selection.selectedIDs.isEmpty)
            // A successful receiver retires the authority even without an end callback.
            #expect(!source.hasActiveSession)
            #expect(!source.isValid)
            previousSource = source
            previousSequence = sequence
        }
        let finalSequence = try #require(previousSequence)
        // A newer incoming external drag has no local press to reset the old
        // source sequence. Its prepared target must survive that source's late end.
        coordinator.items = fixture.store.displayedItems
        table.itemIDs = coordinator.items.map(\.id)
        table.reloadData()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        scroll.resetForNavigation()
        let incomingURL = fixture.root.appendingPathComponent("Charlie.txt")
        board.clearContents()
        try #require(board.writeObjects([incomingURL as NSURL]))
        let incoming = FileDragInfoStub(board: board)
        incoming.draggingSequenceNumber = 800
        let targetRow = try #require(coordinator.items.firstIndex(where: { $0.url == targetURL }))
        let targetFrame = table.rect(ofRow: targetRow)
        incoming.draggingLocation = table.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        try await waitForGesture { coordinator.updateFileDrop(incoming) == .copy }
        #expect(table.highlightedFileDropRow == targetRow)
        #expect(coordinator.endFileDragSession(sequenceNumber: finalSequence))
        #expect(table.highlightedFileDropRow == targetRow)
        #expect(coordinator.updateFileDrop(incoming) == .copy)
        #expect(!coordinator.endFileDragSession(sequenceNumber: finalSequence))
        #expect(coordinator.updateFileDrop(incoming) == .copy)
        #expect(!fixture.store.isPerformingOperation)
        #expect(FileManager.default.fileExists(atPath: incomingURL.path))
        #expect(!FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("Charlie.txt").path))
        #expect(previousSource?.isValid == false)
    }

    @Test
    func detailsWriterBeforeCanDragCreatesOneStableBatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let coordinator = DetailsTableView.Coordinator(store: fixture.store)
        let table = ExplorerTableView()
        coordinator.table = table
        coordinator.items = fixture.store.displayedItems
        table.dataSource = coordinator
        table.reloadData()
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let first = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let source = try #require(table.fileDragSource)
        #expect(coordinator.beginFileDrag(rows: IndexSet([0, 1])))
        #expect(table.fileDragSource === source)
        let second = try #require(coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        let tokenType = NSPasteboard.PasteboardType("com.native-explorer.file-drag-token")
        #expect(first.string(forType: tokenType) == second.string(forType: tokenType))
        // The real SDK delivers willBegin asynchronously after mouseDown
        // returns. End-of-tracking cleanup must preserve issued writer tokens.
        table.finishMouseDownFileDragTracking()
        #expect(source.isValid)
        table.startFileDragSession(sequenceNumber: 11)
        #expect(source.hasActiveSession)
        table.releaseInactiveFileDrag()
        #expect(source.isValid)
        table.finishFileDragSession()
        #expect(source.pasteboardWriter(itemID: coordinator.items[0].id) == nil)
    }

    @Test
    func detailsEndOfTrackingReleasesSourceWhenNoWriterWasIssued() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let coordinator = DetailsTableView.Coordinator(store: fixture.store)
        let table = ExplorerTableView()
        coordinator.table = table
        coordinator.items = fixture.store.displayedItems
        #expect(coordinator.beginFileDrag(rows: IndexSet(integer: 0)))
        let source = try #require(table.fileDragSource)
        #expect(!source.hasIssuedWriter)
        table.finishMouseDownFileDragTracking()
        #expect(table.fileDragSource == nil)
        #expect(!source.isValid)
    }

    @Test
    func detailsActiveSourceSurvivesDismantleAndReleasesItsDetachedOwnerOnEnd() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        weak var originalTable: ExplorerTableView?
        try autoreleasepool {
            var coordinator: DetailsTableView.Coordinator? = DetailsTableView.Coordinator(store: fixture.store)
            var table: ExplorerTableView? = ExplorerTableView()
            originalTable = table
            coordinator?.table = table
            coordinator?.items = fixture.store.displayedItems
            #expect(coordinator?.beginFileDrag(rows: IndexSet(integer: 0)) == true)
            let source = try #require(table?.fileDragSource)
            let itemID = try #require(coordinator?.items.first?.id)
            table?.startFileDragSession(sequenceNumber: 77)
            DetailsTableView.dismantleNSView(ExplorerDetailsScrollView(), coordinator: try #require(coordinator))
            coordinator = nil
            table = nil
            #expect(originalTable != nil)
            #expect(source.pasteboardWriter(itemID: itemID) != nil)
            // Same cleanup method as the table's independent native ended hook.
            #expect(originalTable?.finishFileDragSession(sequenceNumber: 77) == true)
            #expect(!source.hasActiveSession)
            #expect(source.pasteboardWriter(itemID: itemID) == nil)
        }
        #expect(originalTable == nil)
    }

    private func makeAutoscrollTable(rowCount: Int) -> TableAutoscrollFixture {
        _ = NSApplication.shared
        let source = AutoscrollRows(count: rowCount)
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 640, height: CGFloat(rowCount) * 26))
        table.rowHeight = 26
        table.intercellSpacing = .zero
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 300
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 28))
        table.dataSource = source
        let scroll = ExplorerDetailsScrollView()
        scroll.documentView = table
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.resetForNavigation()
        return TableAutoscrollFixture(window: window, scroll: scroll, table: table, source: source)
    }

    @MainActor
    private final class AutoscrollRows: NSObject, NSTableViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func numberOfRows(in tableView: NSTableView) -> Int { count }
    }

    @MainActor
    private struct TableAutoscrollFixture {
        let window: NSWindow
        let scroll: ExplorerDetailsScrollView
        let table: ExplorerTableView
        let source: AutoscrollRows
        func close() {
            withExtendedLifetime(source) { window.close() }
        }
    }

    private func makeFixture(includeTargetFolder: Bool = false,
                             fileDragCoordinator: FileDragCoordinator = .shared) async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-file-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for name in ["Alpha.txt", "Bravo.txt", "Charlie.txt"] {
                try Data(name.utf8).write(to: root.appendingPathComponent(name))
            }
            if includeTargetFolder {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Target", isDirectory: true), withIntermediateDirectories: false)
            }
            let store = ExplorerStore(initialURL: root, homeURL: root)
            let deadline = Date().addingTimeInterval(5)
            while store.activeTab.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!store.activeTab.isLoading)
            store.setViewMode(.largeIcons)
            let coordinator = FileCollectionView.Coordinator(store: store, fileDragCoordinator: fileDragCoordinator)
            let scroll = coordinator.makeScrollView()
            let view = try #require(coordinator.collection)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.orderFront(nil)
            let fixture = Fixture(root: root, store: store, coordinator: coordinator, view: view, window: window)
            fixture.layout()
            #expect(view.items.count == (includeTargetFolder ? 4 : 3))
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let store: ExplorerStore
        let coordinator: FileCollectionView.Coordinator
        let view: ExplorerFileCollectionView
        let window: NSWindow

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            view.collectionViewLayout?.invalidateLayout()
            view.layoutSubtreeIfNeeded()
        }
        func event(type: NSEvent.EventType, index: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let frame = try #require(view.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
            let point = view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func close() {
            coordinator.dismantle()
            store.cancelLoads()
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
