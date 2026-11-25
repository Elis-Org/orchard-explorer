import AppKit
import Testing
@testable import ExplorerApp

@MainActor
private final class FocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class FocusTableData: NSObject, NSTableViewDataSource {
    let rows: Int
    init(rows: Int) { self.rows = rows }
    func numberOfRows(in tableView: NSTableView) -> Int { rows }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        "Item \(row)"
    }
}

/// Native AppKit responder tests, not VoiceOver or Windows AX-equivalence claims.
@Suite(.serialized)
@MainActor
final class FocusTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }

    private func view(in window: NSWindow, x: CGFloat = 0) -> FocusTestView {
        let result = FocusTestView(frame: NSRect(x: x, y: 20, width: 100, height: 40))
        window.contentView?.addSubview(result)
        return result
    }

    private func register(_ region: ExplorerFocusRegion, view: NSView, coordinator: ExplorerFocusCoordinator) {
        coordinator.register(region, owner: view) { [weak view] in
            guard let view, let window = view.window else { return false }
            return window.makeFirstResponder(view)
        }
    }

    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                     window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: code))
    }

    /// FR-SEL-005 / EV-0428–0437, EV-0440 / AT-SEL-005: observed visible-region order;
    /// the optional Details region is a native extension after the sidebar.
    @Test
    func cycleFollowsObservedOrderAndReverse() throws {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        var views: [ExplorerFocusRegion: NSView] = [:]
        for (index, region) in ExplorerFocusRegion.allCases.enumerated() {
            let owner = view(in: window, x: CGFloat(index) * 110)
            views[region] = owner
            register(region, view: owner, coordinator: coordinator)
        }
        let list = try #require(views[.list])
        #expect(window.makeFirstResponder(list))
        for region in [ExplorerFocusRegion.header, .status, .tabs, .sidebar, .details, .list] {
            #expect(coordinator.cycle())
            #expect(coordinator.currentRegion == region)
            #expect(window.firstResponder === views[region])
        }
        for region in [ExplorerFocusRegion.details, .sidebar, .tabs, .status, .header, .list] {
            #expect(coordinator.cycle(backwards: true))
            #expect(coordinator.currentRegion == region)
            #expect(window.firstResponder === views[region])
        }
    }

    @Test
    func cycleSkipsHiddenDetachedTransparentAndRefusedRegions() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let list = view(in: window)
        let hiddenParent = NSView(frame: NSRect(x: 0, y: 80, width: 100, height: 80))
        window.contentView?.addSubview(hiddenParent)
        let header = FocusTestView(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        hiddenParent.addSubview(header)
        hiddenParent.isHidden = true
        let detached = FocusTestView(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        let transparent = view(in: window, x: 220)
        transparent.alphaValue = 0
        let sidebar = view(in: window, x: 330)
        register(.list, view: list, coordinator: coordinator)
        register(.header, view: header, coordinator: coordinator)
        register(.status, view: detached, coordinator: coordinator)
        register(.tabs, view: transparent, coordinator: coordinator)
        register(.sidebar, view: sidebar, coordinator: coordinator)
        #expect(window.makeFirstResponder(list))
        #expect(coordinator.cycle())
        #expect(window.firstResponder === sidebar)

        coordinator.unregister(.list, owner: list)
        coordinator.unregister(.sidebar, owner: sidebar)
        hiddenParent.isHidden = false
        coordinator.register(.header, owner: header) { false }
        #expect(!coordinator.cycle())
    }

    @Test
    func replacementSurvivesOldUnregisterAndRegistryDoesNotRetainViews() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        weak var weakReplacement: FocusTestView?
        autoreleasepool {
            var replacement: FocusTestView? = view(in: window, x: 110)
            weakReplacement = replacement
            register(.list, view: old, coordinator: coordinator)
            register(.list, view: replacement!, coordinator: coordinator)
            coordinator.unregister(.list, owner: old)
            #expect(coordinator.cycle())
            // Capture only a Bool in Testing's expression diagnostics, not the
            // native responder whose lifetime this test is about to assert.
            let focusedReplacement = window.firstResponder === replacement
            #expect(focusedReplacement)
            window.makeFirstResponder(nil)
            replacement?.removeFromSuperview()
            replacement = nil
        }
        // Native AppKit calls may autorelease a removed responder. Check after
        // draining that ownership, with the coordinator still strongly alive.
        #expect(weakReplacement == nil)
        #expect(!coordinator.cycle())
    }

    @Test
    func actualResponderAndClosestAncestorOverrideRememberedRegion() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let list = view(in: window)
        let header = FocusTestView(frame: NSRect(x: 5, y: 5, width: 80, height: 20))
        list.addSubview(header)
        let status = view(in: window, x: 220)
        register(.list, view: list, coordinator: coordinator)
        register(.header, view: header, coordinator: coordinator)
        register(.status, view: status, coordinator: coordinator)
        coordinator.focused(.sidebar)
        #expect(window.makeFirstResponder(header))
        #expect(coordinator.cycle())
        #expect(window.firstResponder === status)
    }

    /// FR-SEL-009 / EV-0421/0422/0424 / AT-SEL-009: adapted Option-Down + Space.
    @Test
    func nonadjacentKeyboardSelectionKeepsFocusAndAnchorIndependent() throws {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let data = FocusTableData(rows: 5)
        table.dataSource = data
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.itemIDs = ["Alpha 2", "Alpha 10", "Alpha.csv", "Beta", "Gamma"]
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.focusedItemID = "Alpha 2"
        table.anchorItemID = "Alpha 2"
        #expect(window.makeFirstResponder(table))

        table.keyDown(with: try key(125, modifiers: [.option], window: window))
        table.keyDown(with: try key(125, modifiers: [.option], window: window))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(table.focusedItemID == "Alpha.csv")
        #expect(table.anchorItemID == "Alpha 2")
        table.keyDown(with: try key(49, characters: " ", window: window))
        #expect(table.selectedRowIndexes == IndexSet([0, 2]))
        #expect(table.focusedItemID == "Alpha.csv")
        #expect(table.anchorItemID == "Alpha 2")
        table.keyDown(with: try key(49, characters: " ", window: window))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(table.focusedItemID == "Alpha.csv", "Toggling off must not return focus to the first selected row")
    }

    /// FR-SEL-001 / EV-0218 / AT-SEL-001: range extension and contraction.
    @Test
    func shiftArrowsExtendAndContractFromTheOriginalAnchor() throws {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let data = FocusTableData(rows: 5)
        table.dataSource = data
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.itemIDs = ["0", "1", "2", "3", "4"]
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.focusedItemID = "1"
        table.anchorItemID = "1"
        table.keyDown(with: try key(125, modifiers: [.shift], window: window))
        table.keyDown(with: try key(125, modifiers: [.shift], window: window))
        #expect(table.selectedRowIndexes == IndexSet([1, 2, 3]))
        #expect(table.focusedItemID == "3")
        #expect(table.anchorItemID == "1")
        table.keyDown(with: try key(126, modifiers: [.shift], window: window))
        #expect(table.selectedRowIndexes == IndexSet([1, 2]))
        #expect(table.focusedItemID == "2")
        #expect(table.anchorItemID == "1")
    }

    @Test
    func shiftClickAfterUpwardKeyboardRangeKeepsTheOriginalAnchor() throws {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let data = FocusTableData(rows: 5)
        table.dataSource = data
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.itemIDs = ["0", "1", "2", "3", "4"]
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        table.focusedItemID = "3"
        table.anchorItemID = "3"
        table.keyDown(with: try key(126, modifiers: [.shift], window: window))
        table.keyDown(with: try key(126, modifiers: [.shift], window: window))
        #expect(table.selectedRowIndexes == IndexSet([1, 2, 3]))
        let rect = table.rect(ofRow: 4)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                   modifierFlags: [.shift], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
        #expect(table.selectedRowIndexes == IndexSet([3, 4]))
        #expect(table.focusedItemID == "4")
        #expect(table.anchorItemID == "3")
    }

    /// UI-SHELL-001/UI-VIEW-002: committed navigation must not hide the first row
    /// beneath a floating header after scrolling a previous long directory.
    @Test
    func navigationResetShowsFirstRowBelowTheHeaderAndDoesNotClearSelection() {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 1800))
        let data = FocusTableData(rows: 80)
        table.dataSource = data
        table.rowHeight = 26.5
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.headerView = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let scroll = ExplorerDetailsScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        table.reloadData()
        scroll.tile()
        table.selectRowIndexes(IndexSet(integer: 30), byExtendingSelection: false)
        table.scrollRowToVisible(30)
        #expect(scroll.documentVisibleRect.minY > 0)
        scroll.resetForNavigation()
        #expect(!scroll.automaticallyAdjustsContentInsets)
        #expect(scroll.contentInsets.top == 0)
        #expect(scroll.documentVisibleRect.minY == -scroll.contentView.contentInsets.top)
        #expect(scroll.documentVisibleRect.intersection(table.rect(ofRow: 0)).height == table.rect(ofRow: 0).height)
        #expect(table.selectedRowIndexes == IndexSet(integer: 30))
        if let header = table.headerView {
            let headerInScroll = scroll.convert(header.bounds, from: header)
            let firstRowInScroll = scroll.convert(table.rect(ofRow: 0), from: table)
            #expect(headerInScroll.intersection(firstRowInScroll).isEmpty,
                    "The initial row must remain below the header at the inset-aware top scroll position")
        } else {
            Issue.record("The viewport regression fixture requires a real table header")
        }
    }

    /// UI-VIEW-001 / EV-0428/0429, EV-0440 / AT-UIVIEW-001: native focusable header.
    @Test
    func headerKeysChooseAndSortColumnsWithoutChangingSelectedRows() throws {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let data = FocusTableData(rows: 3)
        table.dataSource = data
        table.allowsMultipleSelection = true
        for title in ["Name", "Date modified", "Type", "Size"] {
            let column = NSTableColumn(identifier: .init(title))
            column.title = title
            table.addTableColumn(column)
        }
        let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        table.headerView = header
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        table.reloadData()
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let coordinator = ExplorerFocusCoordinator()
        table.focusCoordinator = coordinator
        header.focusCoordinator = coordinator
        register(.list, view: table, coordinator: coordinator)
        register(.header, view: header, coordinator: coordinator)
        #expect(window.makeFirstResponder(table))
        #expect(coordinator.cycle())
        #expect(window.firstResponder === header)
        var sorted: [Int] = []
        header.onSortColumn = { sorted.append($0) }
        header.keyDown(with: try key(124, window: window))
        header.keyDown(with: try key(36, characters: "\r", window: window))
        header.keyDown(with: try key(123, window: window))
        header.keyDown(with: try key(49, characters: " ", window: window))
        #expect(sorted == [1, 0])
        #expect(table.selectedRowIndexes == IndexSet([0, 2]))
        #expect(coordinator.cycle(backwards: true))
        #expect(window.firstResponder === table)
        #expect(table.selectedRowIndexes == IndexSet([0, 2]))
    }
}
