import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite(.serialized)
@MainActor
final class DetailsPointerTests {
    @Test(arguments: [false, true])
    func contextUsesOccupiedColumnsAndTreatsTrailingSpaceAsBackground(_ controlClick: Bool) throws {
        let fixture = DetailsPointerFixture()
        defer { fixture.close() }
        let table = fixture.table
        var builtRows: [Int] = []
        var presentedRows: [Int] = []
        table.onContextMenu = { row in
            builtRows.append(row)
            return NSMenu(title: row == -1 ? "Background" : "Item")
        }
        table.onPresentContextMenu = { row, _, _, _ in presentedRows.append(row) }

        let metadata = fixture.metadataPoint(row: 1)
        let gutter = try fixture.gutterPoint(row: 1)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        try fixture.contextClick(metadata, controlClick: controlClick)
        #expect(builtRows == [1] && presentedRows == [1])
        #expect(table.selectedRowIndexes == IndexSet([0, 1]))

        try fixture.contextClick(gutter, controlClick: controlClick)
        #expect(builtRows == [1, -1] && presentedRows == [1, -1])
        #expect(table.selectedRowIndexes.isEmpty && table.focusedItemID == nil && table.anchorItemID == nil)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = table.menu(for: try fixture.mouse(.rightMouseDown, at: gutter))
        #expect(menu?.title == "Background" && table.selectedRowIndexes.isEmpty)
    }

    @Test
    func primaryGutterPressClearsSelectionForEitherClickCount() throws {
        let fixture = DetailsPointerFixture()
        defer { fixture.close() }
        let table = fixture.table
        let gutter = try fixture.gutterPoint(row: 1)
        for clickCount in [1, 2] {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.focusedItemID = table.itemIDs[0]
            table.anchorItemID = table.itemIDs[0]
            // Shift uses the table's direct selection branch even on the baseline.
            // Unmodified AppKit click tracking is exercised by the desktop run.
            table.mouseDown(with: try fixture.mouse(.leftMouseDown, at: gutter, modifiers: .shift, clicks: clickCount))
            #expect(table.selectedRowIndexes.isEmpty && table.focusedItemID == nil && table.anchorItemID == nil)
        }
    }

    @Test
    func columnSpanFollowsReorderVisibilityAndHorizontalScroll() throws {
        let fixture = DetailsPointerFixture()
        defer { fixture.close() }
        let table = fixture.table
        let scroll = try #require(table.enclosingScrollView)
        let clip = scroll.contentView
        let name = table.tableColumns[0]
        let folder = table.tableColumns[1]
        name.width = 440
        folder.width = 400
        table.moveColumn(1, toColumn: 0)
        scroll.tile()
        table.layoutSubtreeIfNeeded()
        clip.scroll(to: NSPoint(x: 120, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        try #require(clip.bounds.minX > 0 && table.tableColumns[0] === folder)
        let row = table.rect(ofRow: 1)
        let first = table.rect(ofColumn: 0)
        let last = table.rect(ofColumn: 1)
        let interaction = table.itemInteractionRect(in: row)
        #expect(interaction.minX == first.minX && interaction.maxX == last.maxX)
        let point = NSPoint(x: first.midX, y: row.midY)
        try #require(table.visibleRect.contains(point))
        var presentedRow: Int?
        table.onContextMenu = { _ in NSMenu(title: "Item") }
        table.onPresentContextMenu = { row, _, _, _ in presentedRow = row }
        try fixture.contextClick(point, controlClick: false)
        #expect(presentedRow == 1 && table.selectedRowIndexes == IndexSet(integer: 1))

        folder.isHidden = true
        table.layoutSubtreeIfNeeded()
        let visibleColumn = table.rect(ofColumn: 1)
        let visibleInteraction = table.itemInteractionRect(in: table.rect(ofRow: 1))
        #expect(visibleInteraction.minX == visibleColumn.minX && visibleInteraction.maxX == visibleColumn.maxX)
        name.isHidden = true
        #expect(table.itemInteractionRect(in: row).isEmpty)
    }

    @Test(arguments: [false, true])
    func hoverClearsWhenAStationaryPointerMovesOutsideTheColumnSpan(_ removeColumn: Bool) throws {
        let fixture = DetailsPointerFixture()
        defer { fixture.close() }
        let table = fixture.table
        let row = try #require(table.rowView(atRow: 1, makeIfNecessary: true))
        let idle = try fixture.paintBackground(row)
        let metadata = fixture.metadataPoint(row: 1)
        fixture.window.pointer = table.convert(metadata, to: nil)
        row.updateTrackingAreas()
        #expect(try fixture.paintBackground(row) != idle)

        if removeColumn {
            fixture.coordinator.synchronizeConditionalColumns(searching: false, cloudStatus: false)
        } else {
            let column = table.tableColumns[1]
            column.width = 60
            fixture.coordinator.tableViewColumnDidResize(Notification(name: NSTableView.columnDidResizeNotification,
                object: table, userInfo: ["NSTableColumn": column]))
        }
        table.layoutSubtreeIfNeeded()
        try #require(table.rect(ofColumn: table.numberOfColumns - 1).maxX < metadata.x)
        #expect(try fixture.paintBackground(row) == idle)

        fixture.window.pointer = table.convert(try fixture.gutterPoint(row: 1), to: nil)
        row.updateTrackingAreas()
        #expect(try fixture.paintBackground(row) == idle, "A pointer already in the gutter must not hover the row")
    }
}

@MainActor
private final class DetailsPointerFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: DetailsPointerTestWindow
    let table: ExplorerTableView
    let coordinator: DetailsTableView.Coordinator

    override init() {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 640, height: 250)
        table = ExplorerTableView(frame: frame)
        window = DetailsPointerTestWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let root = FileManager.default.temporaryDirectory
        let store = ExplorerStore(initialURL: root, loader: DetailsPointerEmptyLoader(), homeURL: root, observer: nil)
        coordinator = DetailsTableView.Coordinator(store: store)
        super.init()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 28
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.itemIDs = ["first", "second"]
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 125
        table.addTableColumn(name)
        coordinator.table = table
        coordinator.synchronizeConditionalColumns(searching: true, cloudStatus: false)
        table.dataSource = self
        table.delegate = self
        let scroll = ExplorerDetailsScrollView(frame: frame)
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        scroll.tile()
        table.layoutSubtreeIfNeeded()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { table.itemIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTableCellView()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        coordinator.tableView(tableView, rowViewForRow: row)
    }

    func metadataPoint(row: Int) -> NSPoint {
        NSPoint(x: table.rect(ofColumn: 1).midX, y: table.rect(ofRow: row).midY)
    }

    func gutterPoint(row: Int) throws -> NSPoint {
        let edge = table.rect(ofColumn: table.numberOfColumns - 1).maxX
        try #require(edge + 20 < table.bounds.maxX)
        return NSPoint(x: edge + 20, y: table.rect(ofRow: row).midY)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = [],
               clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }

    func contextClick(_ point: NSPoint, controlClick: Bool) throws {
        if controlClick { table.mouseDown(with: try mouse(.leftMouseDown, at: point, modifiers: .control)) }
        else { table.rightMouseDown(with: try mouse(.rightMouseDown, at: point)) }
    }

    func paintBackground(_ row: NSTableRowView) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        row.bounds.fill()
        row.drawBackground(in: row.bounds)
        context.flushGraphics()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    func close() {
        coordinator.store.cancelLoads()
        window.close()
    }
}

@MainActor
private final class DetailsPointerTestWindow: NSWindow {
    var pointer = NSPoint(x: -100, y: -100)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

private struct DetailsPointerEmptyLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
}
