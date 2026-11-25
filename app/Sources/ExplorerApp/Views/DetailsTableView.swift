import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ExplorerCore

// UI-VIEW-002 / AT-UIVIEW-002, EV-0211 + paired EV-0212.
// FR-SEL-001/002/003/007/008: AppKit owns gestures and responder focus;
// the store owns selected file identities independently of keyboard focus.
struct DetailsTableView: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> ExplorerDetailsScrollView {
        let table = ExplorerTableView()
        table.style = .plain
        table.rowHeight = 26.5.pt
        table.intercellSpacing = NSSize(width: 0, height: 2.pt)
        table.backgroundColor = ExplorerTablePalette.background(for: table)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.draggingDestinationFeedbackStyle = .none
        table.setAccessibilityLabel("Files and folders")
        table.setAccessibilityIdentifier("details-table")
        table.registerForDraggedTypes(FileDragCoordinator.registeredTypes)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onBeginFileDrag = { [weak coordinator = context.coordinator] rows in
            coordinator?.beginFileDrag(rows: rows) == true
        }
        table.onFileDropExit = { [weak coordinator = context.coordinator] in coordinator?.clearFileDrop() }
        table.onFileDropUpdate = { [weak coordinator = context.coordinator] info in
            coordinator?.updateFileDrop(info) ?? []
        }

        for (key, title, width) in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = title
            // Widths the user set survive view-mode switches and interface-size rebuilds.
            column.width = (store.detailsColumnWidths[key.rawValue] ?? width).pt
            column.minWidth = key == .name ? 180.pt : 80.pt
            column.headerCell = ExplorerHeaderCell(textCell: title)
            column.headerCell.font = .systemFont(ofSize: 11.pt)
            table.addTableColumn(column)
        }
        let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 680.pt, height: 28.pt))
        table.headerView = header
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClickedItem(_:))
        table.onActivate = { [weak coordinator = context.coordinator] in coordinator?.openSelectedItem() }
        table.onRename = { [weak store] in store?.beginRename() }
        table.onCopy = { [weak store] in store?.copySelection() }
        table.onCut = { [weak store] in store?.cutSelection() }
        table.onPaste = { [weak store] in store?.pasteSelection() }
        table.onTrash = { [weak store] in store?.deleteSelection() }
        table.onPermanentDeleteUnavailable = { [weak store] in store?.notePermanentDeleteUnavailable() }
        table.onUndoRename = { [weak store] in store?.undoRename() }
        table.onRedoRename = { [weak store] in store?.redoRename() }
        table.canCopySelection = { [weak store] in store?.canCopySelection == true }
        table.canCutSelection = { [weak store] in store?.canCutSelection == true }
        table.canPasteSelection = { [weak store] in store?.canPaste == true }
        table.canTrashSelection = { [weak store] in store?.canDeleteSelection == true }
        table.canUndoRename = { [weak store] in store?.canUndoRename == true }
        table.canRedoRename = { [weak store] in store?.canRedoRename == true }
        table.onSelectionIntent = { [weak coordinator = context.coordinator] in coordinator?.publishSelection() }
        table.onContextMenu = { [weak coordinator = context.coordinator] row in coordinator?.contextMenu(for: row) }
        table.onPresentContextMenu = { [weak coordinator = context.coordinator] row, point, view, keyboard in
            coordinator?.presentContextMenu(for: row, at: point, in: view, keyboard: keyboard)
        }
        table.onPointerRenameCandidate = { [weak store] id in store?.armPointerRename(itemID: id) }
        table.onPointerRenameCancel = { [weak store] in store?.cancelPointerRename() }
        header.onSortColumn = { [weak coordinator = context.coordinator] column in coordinator?.sortColumn(column) }
        table.focusCoordinator = store.focus
        table.onViewportLayout = { [weak coordinator = context.coordinator] in
            coordinator?.revealVisibility.schedule()
            coordinator?.badgeViewport.schedule()
        }
        header.focusCoordinator = store.focus
        header.setAccessibilityLabel("Details column headings")
        header.setAccessibilityIdentifier("details-headers")

        let scroll = ExplorerDetailsScrollView()
        scroll.backgroundColor = ExplorerTablePalette.background(for: table)
        scroll.documentView = table
        context.coordinator.table = table
        store.focus.register(.list, owner: table) { [weak table] in
            guard let table, let window = table.window else { return false }
            return window.makeFirstResponder(table)
        }
        store.focus.restorePendingContentFocus(owner: table)
        store.focus.register(.header, owner: header) { [weak header] in
            guard let header, let window = header.window else { return false }
            return window.makeFirstResponder(header)
        }
        updateNSView(scroll, context: context)
        return scroll
    }

    static func dismantleNSView(_ nsView: ExplorerDetailsScrollView, coordinator: Coordinator) {
        coordinator.contextMenus.dismissPresentedMenu()
        coordinator.revealVisibility.invalidate()
        coordinator.badgeViewport.invalidate()
        guard let table = coordinator.table else { return }
        table.onViewportLayout = nil
        coordinator.store.focus.unregister(.list, owner: table)
        if let header = table.headerView { coordinator.store.focus.unregister(.header, owner: header) }
        table.releaseInactiveFileDrag()
        coordinator.clearFileDrop()
        table.onBeginFileDrag = nil
        table.onFileDropExit = nil
        table.onFileDropUpdate = nil
        table.unregisterDraggedTypes()
        table.delegate = nil
        table.dataSource = nil
        table.onActivate = nil
        table.onRename = nil
        table.onCopy = nil
        table.onCut = nil
        table.onPaste = nil
        table.onTrash = nil
        table.onPermanentDeleteUnavailable = nil
        table.onUndoRename = nil
        table.onRedoRename = nil
        table.canCopySelection = nil
        table.canCutSelection = nil
        table.canPasteSelection = nil
        table.canTrashSelection = nil
        table.canUndoRename = nil
        table.canRedoRename = nil
        table.onSelectionIntent = nil
        table.onContextMenu = nil
        table.onPresentContextMenu = nil
        table.onPointerRenameCancel?()
        table.onPointerRenameCandidate = nil
        table.onPointerRenameCancel = nil
        coordinator.endNameEditing(restoreListFocus: false)
    }

    func updateNSView(_ nsView: ExplorerDetailsScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = coordinator.table else { return }
        coordinator.store = store
        coordinator.contextMenus.store = store
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        // A search session is its own presentation location (MAC-062).
        let location = "\(store.activeTabID.uuidString):\(store.activeTab.url.absoluteString)"
            + (store.activeSearch.map { ":search:\($0.id.uuidString)" } ?? "")
        let changedLocation = location != coordinator.location
        let items = store.displayedItems
        let edit = store.nameEdit
        let changedEdit = edit?.id != coordinator.editingSessionID
        if changedEdit || changedLocation { coordinator.endNameEditing(restoreListFocus: edit == nil) }
        // A draft has a stable row. Do not replace its live native field editor
        // in response to proposed-name publications or queued watcher hints.
        let retainsLiveEditor = edit != nil && edit?.id == coordinator.editingSessionID
        if (items != coordinator.items && !retainsLiveEditor) || changedLocation || changedEdit {
            coordinator.clearFileDrop()
            coordinator.items = items
            table.reloadData()
        }
        coordinator.location = location
        coordinator.synchronizeConditionalColumns(searching: store.isSearching, cloudStatus: store.showsCloudStatusColumn)
        coordinator.updateVisibleCloudStatus()
        table.itemIDs = coordinator.items.map(\.id)
        table.focusedItemID = store.currentSelection.focusedID
        table.anchorItemID = store.currentSelection.anchorID
        for (key, title, _) in Coordinator.columns {
            if let column = table.tableColumns.first(where: { $0.identifier.rawValue == key.rawValue }) {
                let arrow = store.activeTab.sort.key == key ? (store.activeTab.sort.ascending ? "  ⌃" : "  ⌄") : ""
                column.title = title + arrow
            }
        }
        let selected: IndexSet
        if let edit, let row = coordinator.items.firstIndex(where: { $0.id == edit.rowID }) {
            selected = IndexSet(integer: row)
            table.focusedItemID = edit.rowID
        } else {
            selected = IndexSet(coordinator.items.indices.filter { store.currentSelection.selectedIDs.contains(coordinator.items[$0].id) })
        }
        if selected != table.selectedRowIndexes { table.selectRowIndexes(selected, byExtendingSelection: false) }
        if changedLocation { nsView.resetForNavigation() }
        table.invalidateFocusDisplay()
        table.headerView?.needsDisplay = true
        if let edit { coordinator.synchronizeNameEditor(edit) }
        coordinator.revealVisibility.update(store: store, view: table) { [weak nsView] id in
            nsView?.revealRequestedItem(id) ?? .notReady
        }
        coordinator.updateBadgeViewport()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columns: [(SortKey, String, CGFloat)] = [
            (.name, "Name", 293), (.modifiedAt, "Date modified", 162),
            (.kind, "Type", 135), (.size, "Size", 90)
        ]
        /// NATIVE-P14: search results show each result's actual parent folder.
        static let folderColumnID = NSUserInterfaceItemIdentifier("searchFolder")
        static let cloudStatusColumnID = NSUserInterfaceItemIdentifier("cloudStatus")
        var store: ExplorerStore
        let contextMenus: FileContextMenuController
        let revealVisibility = RevealVisibilityCoordinator()
        let badgeViewport = OneDriveBadgeViewport()
        private let fileDragCoordinator: FileDragCoordinator
        var items: [FileItem] = []
        var location = ""
        var isUpdating = false
        private(set) var editingSessionID: UUID?
        private weak var nameEditor: NameEditorTextField?
        private lazy var fileDropDestination = fileDragCoordinator.makeDestination(store: store)
        weak var table: ExplorerTableView?
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()

        init(store: ExplorerStore, fileDragCoordinator: FileDragCoordinator = .shared) {
            self.store = store
            self.fileDragCoordinator = fileDragCoordinator
            contextMenus = FileContextMenuController(store: store)
        }
        // NATIVE-P13 / FR-DROP-001/002/004; EV-9001, EV-0265–0270;
        // AT-DROP-001/002/004. Hover prepares only; accept owns the write intent.
        func beginFileDrag(rows: IndexSet) -> Bool {
            guard let table else { return false }
            let itemIDs = Set(rows.compactMap {
                items.indices.contains($0) ? items[$0].id : nil
            })
            // AppKit may ask for a writer before canDragRows, or ask the latter
            // repeatedly. Never revoke a writer already issued for this batch.
            if let source = table.fileDragSource, source.isValid,
               Set(source.entries.map { $0.item.id }) == itemIDs {
                return true
            }
            guard table.fileDragSource?.hasActiveSession != true else {
                return false
            }
            table.finishFileDragSession()
            guard let entries = store.fileDragEntries(itemIDs: itemIDs) else {
                return false
            }
            table.fileDragSource = fileDragCoordinator.beginSource(entries: entries, owner: table)
            return table.fileDragSource != nil
        }

        @discardableResult
        func finishFileDrag(sequenceNumber: Int? = nil) -> Bool {
            table?.finishFileDragSession(sequenceNumber: sequenceNumber) == true
        }

        func clearFileDrop(endingSequenceNumber: Int? = nil) {
            if let endingSequenceNumber,
               let receivingSequence = fileDropDestination.draggingSequenceNumber,
               receivingSequence != endingSequenceNumber { return }
            fileDropDestination.invalidate()
            table?.setDropRow(-1, dropOperation: .above)
            table?.highlightedFileDropRow = nil
            table?.highlightsCurrentDirectoryDrop = false
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items.indices.contains(row) else { return nil }
            if table?.fileDragSource?.isValid != true {
                let selected = tableView.selectedRowIndexes
                guard beginFileDrag(rows: selected.contains(row) ? selected : IndexSet(integer: row)) else { return nil }
            }
            return table?.fileDragSource?.pasteboardWriter(itemID: items[row].id)
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            table?.startFileDragSession(sequenceNumber: session.draggingSequenceNumber)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            endFileDragSession(sequenceNumber: session.draggingSequenceNumber)
        }

        @discardableResult
        func endFileDragSession(sequenceNumber: Int) -> Bool {
            guard finishFileDrag(sequenceNumber: sequenceNumber) else { return false }
            // A later incoming drag can prepare this same table without a new
            // local mouseDown. An older source completion owns no such target.
            clearFileDrop(endingSequenceNumber: sequenceNumber)
            return true
        }

        private func fileDropTarget(at point: NSPoint) -> (row: Int, binding: FileDropBinding?) {
            guard let table else { return (-1, nil) }
            let row = table.row(at: point)
            // MAC-065: search results and their folder rows are not drop targets.
            guard !store.isSearching else { return (-1, nil) }
            if items.indices.contains(row) {
                let item = items[row]
                guard item.isDirectory else { return (row, nil) }
                let binding = store.fileDropBinding(destinationURL: item.url, expectedEntryIdentity: item.identity)
                return (row, binding)
            }
            return (-1, store.fileDropBinding(destinationURL: store.activeTab.url,
                       expectedDestinationIdentity: store.activeTab.directoryIdentity))
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            updateFileDrop(info)
        }

        func updateFileDrop(_ info: NSDraggingInfo) -> NSDragOperation {
            guard let tableView = table else { return [] }
            let target = fileDropTarget(at: tableView.convert(info.draggingLocation, from: nil))
            let operation = fileDropDestination.update(info, binding: target.binding)
            let showsTarget = !operation.isEmpty || fileDropDestination.isPreparing
            tableView.highlightedFileDropRow = showsTarget && target.row >= 0 ? target.row : nil
            tableView.highlightsCurrentDirectoryDrop = showsTarget && target.row < 0
            tableView.setDropRow(operation.isEmpty ? -1 : target.row, dropOperation: operation.isEmpty ? .above : .on)
            return operation
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let target = fileDropTarget(at: tableView.convert(info.draggingLocation, from: nil))
            defer { clearFileDrop() }
            return fileDropDestination.accept(info, binding: target.binding)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        /// Keep column focus by identity, including when both optional headings change.
        func synchronizeFolderColumn(searching: Bool) {
            synchronizeConditionalColumns(searching: searching, cloudStatus: store.showsCloudStatusColumn)
        }

        func synchronizeConditionalColumns(searching: Bool, cloudStatus: Bool) {
            guard let table else { return }
            let header = table.headerView as? ExplorerTableHeaderView
            let oldIndex = header?.focusedColumn ?? 0
            let focusedID = table.tableColumns.indices.contains(oldIndex) ? table.tableColumns[oldIndex].identifier : nil
            let oldColumns = table.tableColumns.map(\.identifier)
            synchronizeColumn(Self.cloudStatusColumnID, title: "Status", width: 70, minimum: 48,
                at: 1, visible: cloudStatus)
            synchronizeColumn(Self.folderColumnID, title: "Folder", width: 260, minimum: 120,
                at: cloudStatus ? 2 : 1, visible: searching)
            if table.tableColumns.map(\.identifier) != oldColumns { table.refreshItemPointerGeometry() }
            if let header {
                header.focusedColumn = focusedID.flatMap { id in table.tableColumns.firstIndex { $0.identifier == id } }
                    ?? max(0, min(oldIndex, table.tableColumns.count - 1))
            }
        }

        private func synchronizeColumn(_ id: NSUserInterfaceItemIdentifier, title: String,
                                       width: CGFloat, minimum: CGFloat, at position: Int, visible: Bool) {
            guard let table else { return }
            let existing = table.tableColumns.firstIndex { $0.identifier == id }
            if !visible {
                if let existing {
                    let column = table.tableColumns[existing]
                    store.detailsColumnWidths[id.rawValue] = column.width / ExplorerScale.factor
                    table.removeTableColumn(column)
                }
                return
            }
            let index: Int
            if let existing { index = existing }
            else {
                let column = NSTableColumn(identifier: id)
                column.title = title
                column.width = (store.detailsColumnWidths[id.rawValue] ?? width).pt
                column.minWidth = minimum.pt
                column.headerCell = ExplorerHeaderCell(textCell: title)
                column.headerCell.font = .systemFont(ofSize: 11.pt)
                table.addTableColumn(column)
                index = table.tableColumns.count - 1
            }
            if index != position { table.moveColumn(index, toColumn: position) }
        }

        func updateVisibleCloudStatus(changedIDs: Set<String>? = nil) {
            guard let table, let column = table.tableColumns.firstIndex(where: { $0.identifier == Self.cloudStatusColumnID }) else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.location < items.count else { return }
            for row in visible.location..<min(items.count, NSMaxRange(visible)) {
                if let changedIDs, !changedIDs.contains(items[row].id) { continue }
                let status = store.cloudStatusDisplay(for: items[row])
                (table.view(atColumn: column, row: row, makeIfNecessary: false) as? CloudStatusCellView)?
                    .configure(status.presentation, checkedAt: status.checkedAt)
            }
        }

        func visibleBadgeItems() -> [FileItem] {
            guard let table else { return [] }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.location < items.count else { return [] }
            return Array(items[visible.location..<min(items.count, NSMaxRange(visible))])
        }

        func updateBadgeViewport() {
            guard let table else { return }
            badgeViewport.update(view: table, items: { [weak self] in self?.visibleBadgeItems() ?? [] },
                report: { [weak self, weak store] owner, items in
                    store?.reportOneDriveBadgeViewport(owner, items: items) { [weak self] ids in
                        self?.updateVisibleCloudStatus(changedIDs: ids)
                    }
                }, remove: { [weak store] owner in store?.removeOneDriveBadgeViewport(owner) })
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let column = tableColumn else { return nil }
            if column.identifier == Self.cloudStatusColumnID {
                let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? CloudStatusCellView)
                    ?? CloudStatusCellView(frame: .zero)
                cell.identifier = column.identifier
                let status = store.cloudStatusDisplay(for: items[row])
                cell.configure(status.presentation, checkedAt: status.checkedAt)
                return cell
            }
            if column.identifier == Self.folderColumnID {
                let cell: ExplorerCellView
                if let reusable = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? ExplorerCellView {
                    cell = reusable
                } else {
                    cell = ExplorerCellView(showsIcon: false)
                    cell.identifier = column.identifier
                }
                let parent = store.activeSearch?.result(id: items[row].id)?.parent?.directoryURL
                    ?? items[row].url.deletingLastPathComponent()
                cell.label.stringValue = (parent.path as NSString).abbreviatingWithTildeInPath
                cell.label.lineBreakMode = .byTruncatingHead
                cell.label.alignment = .left
                cell.label.textColor = .secondaryLabelColor
                cell.toolTip = parent.path
                return cell
            }
            guard let key = SortKey(rawValue: column.identifier.rawValue) else { return nil }
            let item = items[row]
            let cell: ExplorerCellView
            if let reusable = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? ExplorerCellView {
                cell = reusable
            } else {
                cell = ExplorerCellView(showsIcon: key == .name)
                cell.identifier = column.identifier
            }
            switch key {
            case .name:
                cell.label.stringValue = item.name
                if let kind = store.nameEdit?.newItemKind, store.nameEdit?.rowID == item.id {
                    cell.icon.image = ExplorerIcons.draftIcon(kind)
                } else {
                    cell.icon.image = ExplorerIcons.icon(for: item)
                }
                cell.toolTip = item.name
            case .modifiedAt:
                cell.label.stringValue = item.modifiedAt.map(dateFormatter.string(from:)) ?? "—"
                cell.toolTip = cell.label.stringValue
            case .kind:
                cell.label.stringValue = item.kind
                cell.toolTip = item.kind
            case .size:
                // UI-SEL-001 / AT-UISEL-001: row rounds up to KB; status retains bytes.
                if let bytes = item.size {
                    let kb = bytes / 1024 + (bytes % 1024 == 0 ? 0 : 1)
                    cell.label.stringValue = "\(kb.formatted()) KB"
                } else { cell.label.stringValue = "" }
                cell.label.alignment = .right
                cell.toolTip = item.size.map { "\($0.formatted()) bytes" }
            }
            cell.label.textColor = key == .name ? .labelColor : .secondaryLabelColor
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ExplorerRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table, !table.isHandlingSelectionIntent else { return }
            // AX Select All or another native action can arrive without a key/mouse event.
            table.reconcileNativeSelectionFocus()
            publishSelection()
        }

        func publishSelection() {
            guard !isUpdating, let table else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            store.setSelection(selected, focusedID: table.focusedItemID, anchorID: table.anchorItemID)
            // Native keyboard/AX changes happen before store validation. A blocked
            // or normalized request must not leave native selection/focus ahead of
            // the authoritative state. Do not reload cells or end a live editor.
            let authoritative = store.currentSelection
            let rows = IndexSet(items.indices.filter { authoritative.selectedIDs.contains(items[$0].id) })
            if table.selectedRowIndexes != rows || table.focusedItemID != authoritative.focusedID
                || table.anchorItemID != authoritative.anchorID {
                isUpdating = true
                defer { isUpdating = false }
                table.focusedItemID = authoritative.focusedID
                table.anchorItemID = authoritative.anchorID
                if table.selectedRowIndexes != rows {
                    table.selectRowIndexes(rows, byExtendingSelection: false)
                }
            }
            table.invalidateFocusDisplay()
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let key = SortKey(rawValue: tableColumn.identifier.rawValue) else { return }
            if let table, let header = table.headerView as? ExplorerTableHeaderView,
               let column = table.tableColumns.firstIndex(of: tableColumn) { header.focusedColumn = column }
            store.sort(by: key)
        }

        func sortColumn(_ column: Int) {
            guard let table, table.tableColumns.indices.contains(column),
                  let key = SortKey(rawValue: table.tableColumns[column].identifier.rawValue) else { return }
            store.sort(by: key)
        }

        func contextMenu(for row: Int) -> NSMenu? {
            contextMenus.menu(for: items.indices.contains(row) ? items[row] : nil)
        }

        func presentContextMenu(for row: Int, at point: NSPoint, in view: NSView, keyboard: Bool) {
            contextMenus.present(for: items.indices.contains(row) ? items[row] : nil,
                                 at: point, in: view, keyboard: keyboard)
        }

        /// MAC-074: remember user-set widths in reference points.
        func tableViewColumnDidResize(_ notification: Notification) {
            table?.refreshItemPointerGeometry()
            guard !isUpdating, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            store.detailsColumnWidths[column.identifier.rawValue] = column.width / ExplorerScale.factor
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            table?.refreshItemPointerGeometry()
        }

        func synchronizeNameEditor(_ edit: NameEditSession) {
            guard let table, edit.tabID == store.activeTabID,
                  let row = items.firstIndex(where: { $0.id == edit.rowID }) else { return }
            if editingSessionID == edit.id {
                if let nameEditor {
                    Self.updateNameEditor(nameEditor, proposedName: edit.proposedName,
                                          isSubmitting: edit.isSubmitting, in: table)
                }
                return
            }
            editingSessionID = edit.id
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table, self.editingSessionID == edit.id,
                      let current = self.store.nameEdit, current.id == edit.id,
                      let currentRow = self.items.firstIndex(where: { $0.id == current.rowID }),
                      let cell = table.view(atColumn: 0, row: currentRow, makeIfNecessary: true) as? ExplorerCellView else { return }
                let field = cell.label
                self.nameEditor = field
                field.onProposalChange = { [weak self] text in
                    guard let self, self.store.nameEdit?.id == edit.id else { return }
                    self.store.updateProposedName(text, sessionID: edit.id)
                }
                field.onCommit = { [weak self] in
                    guard let self, self.store.nameEdit?.id == edit.id else { return }
                    self.store.commitNameEdit(sessionID: edit.id)
                }
                field.onCancel = { [weak self] in
                    guard let self, self.store.nameEdit?.id == edit.id else { return }
                    self.store.cancelNameEdit(sessionID: edit.id)
                }
                field.setAccessibilityLabel(current.newItemKind?.accessibilityName ?? "Rename \(current.originalName)")
                field.beginSession(id: current.id, name: current.proposedName, selection: current.initialSelection)
                Self.updateNameEditor(field, proposedName: current.proposedName,
                                      isSubmitting: current.isSubmitting, in: table)
            }
        }

        /// End-editing removes AppKit's field-editor responder during submission.
        /// Preserve file-command focus for Return → Undo without taking focus
        /// from a user who has already moved to another control.
        static func updateNameEditor(_ field: NameEditorTextField, proposedName: String,
                                     isSubmitting: Bool, in table: ExplorerTableView) {
            let returnsFocus: Bool
            if isSubmitting, !field.isSubmitting, field.window === table.window,
               let editor = field.currentEditor(), table.window?.firstResponder === editor {
                returnsFocus = true
            } else {
                returnsFocus = false
            }
            field.updateSession(proposedName: proposedName, isSubmitting: isSubmitting, focusOwner: table)
            if returnsFocus { table.window?.makeFirstResponder(table) }
        }

        func endNameEditing(restoreListFocus: Bool) {
            let hadEditorFocus = nameEditor?.currentEditor() != nil
            editingSessionID = nil
            nameEditor?.finishSession()
            nameEditor = nil
            if restoreListFocus, hadEditorFocus, let table { table.window?.makeFirstResponder(table) }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            items.indices.contains(row) ? items[row].name : nil
        }

        @objc func openClickedItem(_ sender: NSTableView) {
            guard items.indices.contains(sender.clickedRow) else { return }
            store.activate(items[sender.clickedRow])
        }

        func openSelectedItem() {
            guard let table, table.selectedRowIndexes.count == 1,
                  let row = table.selectedRowIndexes.first, items.indices.contains(row) else { return }
            store.activate(items[row])
        }
    }
}

/// The shell places this scroll view below its own chrome. Disable automatic
/// titlebar insets, but honor the clip view's separate inset for the table header.
final class ExplorerDetailsScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// MAC-074: the first item at the top of the viewport, by identity.
    var topVisibleItemID: String? {
        guard let table = documentView as? ExplorerTableView else { return nil }
        let row = table.row(at: NSPoint(x: 1, y: contentView.bounds.minY + contentView.contentInsets.top + 1))
        return table.itemIDs.indices.contains(row) ? table.itemIDs[row] : nil
    }

    /// Scroll so the identified item is the first visible row again.
    func scrollItemToTop(_ id: String) {
        guard let table = documentView as? ExplorerTableView, let row = table.itemIDs.firstIndex(of: id) else { return }
        tile()
        documentView?.layoutSubtreeIfNeeded()
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX,
                                       y: table.rect(ofRow: row).minY - contentView.contentInsets.top))
        reflectScrolledClipView(contentView)
    }

    /// Call only for a changed committed tab/location. Refresh and sorting keep the viewport.
    func resetForNavigation() {
        tile()
        documentView?.layoutSubtreeIfNeeded()
        // NSClipView independently reserves the header height in contentInsets,
        // even when NSScrollView.contentInsets is zero. y=0 hides row zero under it.
        let insets = contentView.contentInsets
        contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        reflectScrolledClipView(contentView)
    }

    /// MAC-REVEAL-VIS-001: reserve the native table-header inset when revealing
    /// a row. AppKit's scrollRowToVisible alone can leave it under that header.
    func revealRequestedItem(_ id: String) -> RevealVisibilityCoordinator.Attempt {
        guard window != nil, let table = documentView as? ExplorerTableView,
              let row = table.itemIDs.firstIndex(of: id), row < table.numberOfRows else { return .notReady }
        tile()
        table.layoutSubtreeIfNeeded()
        let viewport = RevealVisibilityGeometry.viewport(in: contentView)
        let target = table.rect(ofRow: row)
        guard viewport.width > 0, viewport.height > 0, !target.isEmpty else { return .notReady }
        var origin = contentView.bounds.origin
        if target.minY < viewport.minY {
            origin.y = target.minY - contentView.contentInsets.top
        } else if target.maxY > viewport.maxY {
            origin.y = target.maxY - contentView.bounds.height + contentView.contentInsets.bottom
        }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        return .attempted(visible: RevealVisibilityGeometry.isVisible(target,
            in: RevealVisibilityGeometry.viewport(in: contentView)))
    }
}

/// FR-SEL-009 / AT-SEL-009 / EV-0421/0422/0424: the Mac binding uses
/// Option-Up/Down to move the row focus and Space to toggle that row's selection.
/// The selected set, focused entry and range anchor are independent identities.
final class ExplorerTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onRename: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTrash: (() -> Void)?
    /// MAC-079: Shift+Delete explains that permanent deletion is unavailable.
    var onPermanentDeleteUnavailable: (() -> Void)?
    var onUndoRename: (() -> Void)?
    var onRedoRename: (() -> Void)?
    var canCopySelection: (() -> Bool)?
    var canCutSelection: (() -> Bool)?
    var canPasteSelection: (() -> Bool)?
    var canTrashSelection: (() -> Bool)?
    var canUndoRename: (() -> Bool)?
    var canRedoRename: (() -> Bool)?
    var onSelectionIntent: (() -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var onPresentContextMenu: ((Int, NSPoint, NSView, Bool) -> Void)?
    /// MAC-076: a qualifying single click on the sole selected item's Name cell
    /// (label or blank space, never the icon or other columns); and any interruption.
    var onPointerRenameCandidate: ((String) -> Void)?
    var onPointerRenameCancel: (() -> Void)?
    var onBeginFileDrag: ((IndexSet) -> Bool)?
    var onFileDropExit: (() -> Void)?
    var onFileDropUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    var fileDragSource: FileDragSource?
    private(set) var fileDragSessionSequence: Int?
    var highlightedFileDropRow: Int? {
        didSet { if oldValue != highlightedFileDropRow { invalidateFocusDisplay() } }
    }
    var highlightsCurrentDirectoryDrop = false {
        didSet { if oldValue != highlightsCurrentDirectoryDrop { needsDisplay = true } }
    }
    weak var focusCoordinator: ExplorerFocusCoordinator?
    var onViewportLayout: (() -> Void)?
    var itemIDs: [String] = []
    var focusedItemID: String?
    var anchorItemID: String?
    private(set) var isHandlingSelectionIntent = false
    private var contrastObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        onPointerRenameCancel?()
        return onBeginFileDrag?(rowIndexes) == true
    }

    /// FR-FILE-027/028 / EV-0508: the label and blank Name-cell space are eligible;
    /// the icon and the other columns are not (only these Details samples are evidenced).
    func isPointerRenameRegion(_ point: NSPoint, row: Int) -> Bool {
        let column = column(at: point)
        guard row >= 0, column >= 0, tableColumns[column].identifier.rawValue == SortKey.name.rawValue else { return false }
        let cell = frameOfCell(atColumn: column, row: row)
        return cell.contains(point) && point.x >= cell.minX + 4.pt + 16.pt + 1
    }

    /// The candidate is decided from the state before AppKit's own click handling.
    private func pointerRenameCandidate(for event: NSEvent, row: Int, point: NSPoint) -> String? {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              window?.isKeyWindow == true, window?.firstResponder === self,
              itemIDs.indices.contains(row), selectedRowIndexes == IndexSet(integer: row),
              isPointerRenameRegion(point, row: row) else { return nil }
        return itemIDs[row]
    }
    func releaseInactiveFileDrag() {
        guard fileDragSource?.hasActiveSession != true else { return }
        finishFileDragSession()
    }
    func finishMouseDownFileDragTracking() {
        // AppKit can deliver willBegin after mouseDown's tracking call returns.
        // An issued writer bridges that gap until the native session begins;
        // the next press or teardown still clears an abandoned tentative source.
        guard fileDragSource?.hasIssuedWriter != true else { return }
        releaseInactiveFileDrag()
    }
    func beginFileDragGesture() {
        // A new physical press starts a new pointer gesture. AppKit can omit
        // the source-ended notification after an accepted local table drop;
        // that old authority must not block or supply writers for this press.
        finishFileDragSession()
    }
    func startFileDragSession(sequenceNumber: Int) {
        guard let fileDragSource, fileDragSource.isValid else { return }
        fileDragSessionSequence = sequenceNumber
        fileDragSource.startSession()
    }
    @discardableResult
    func finishFileDragSession(sequenceNumber: Int? = nil) -> Bool {
        // An old session may complete after the next press has already captured
        // a fresh source. Its completion owns only the matching session.
        if let sequenceNumber, fileDragSessionSequence != sequenceNumber { return false }
        fileDragSource?.finish()
        fileDragSource = nil
        fileDragSessionSequence = nil
        return true
    }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                  operation: NSDragOperation) {
        // The data source may have been dismantled by spring-loaded navigation.
        // The actual AppKit source retains this independent completion hook.
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        finishFileDragSession(sequenceNumber: session.draggingSequenceNumber)
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDropAutoscroll(view: self, info: sender)
        _ = super.draggingUpdated(sender)
        // Asynchronous preparation can finish without AppKit proposing a new
        // row. Recheck on each periodic update, including a resting pointer.
        return onFileDropUpdate?(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onFileDropExit?()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        // This optional AppKit destination callback has no superclass implementation.
        onFileDropExit?()
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        onFileDropExit?()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            releaseInactiveFileDrag()
            onFileDropExit?()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    // Folder targets highlight without opening while a file drag is in progress.
    @objc func springLoadingEntered(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }
    @objc func springLoadingUpdated(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }


    // FR-FILE-003/004 / EV-0252/0255 / AT-FILE-003/004: file intent only
    // when the table is the responder. A native text editor consumes these
    // selectors earlier in the responder chain, preserving text Cut/Copy/Paste.
    private var fileCommands: FileCommandEligibility {
        FileCommandEligibility(ownsFileFocus: window?.firstResponder === self,
            copy: canCopySelection?() == true, cut: canCutSelection?() == true,
            paste: canPasteSelection?() == true, delete: canTrashSelection?() == true,
            undo: canUndoRename?() == true, redo: canRedoRename?() == true)
    }

    @objc func copy(_ sender: Any?) {
        guard fileCommands.allows(.copy) else { return }
        onCopy?()
    }

    @objc func cut(_ sender: Any?) {
        guard fileCommands.allows(.cut) else { return }
        onCut?()
    }

    @objc func paste(_ sender: Any?) {
        guard fileCommands.allows(.paste) else { return }
        onPaste?()
    }

    // FR-FILE-005/011 / EV-0444–0448, EV-0236–0240 / AT-FILE-005/011.
    // Native menu selectors reach file actions only when the table is the
    // responder; an active text editor keeps its own editing/undo behavior.
    @objc func moveToTrash(_ sender: Any?) {
        guard fileCommands.allows(.delete),
              !FileListDeleteKey.isAutoRepeat(triggeringEvent()) else { return }
        onTrash?()
    }
    /// Test seam for the event that triggered an action (MAC-079 repeat guard).
    var triggeringEvent: () -> NSEvent? = { NSApp.currentEvent }

    @objc func undo(_ sender: Any?) {
        if let editor = activeTextEditor { editor.undoManager?.undo(); return }
        guard fileCommands.allows(.undo) else { return }
        onUndoRename?()
    }

    @objc func redo(_ sender: Any?) {
        if let editor = activeTextEditor { editor.undoManager?.redo(); return }
        guard fileCommands.allows(.redo) else { return }
        onRedoRename?()
    }

    private var activeTextEditor: NSTextView? { window?.firstResponder as? NSTextView }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return fileCommands.allows(.copy)
        case #selector(cut(_:)): return fileCommands.allows(.cut)
        case #selector(paste(_:)): return fileCommands.allows(.paste)
        case #selector(moveToTrash(_:)): return fileCommands.allows(.delete)
        case #selector(undo(_:)):
            if let editor = activeTextEditor {
                (item as? NSMenuItem)?.title = editor.undoManager?.undoMenuItemTitle ?? "Undo"
                return editor.undoManager?.canUndo == true
            }
            (item as? NSMenuItem)?.title = "Undo Rename"
            return fileCommands.allows(.undo)
        case #selector(redo(_:)):
            if let editor = activeTextEditor {
                (item as? NSMenuItem)?.title = editor.undoManager?.redoMenuItemTitle ?? "Redo"
                return editor.undoManager?.canRedo == true
            }
            (item as? NSMenuItem)?.title = "Redo Rename"
            return fileCommands.allows(.redo)
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusCoordinator?.focused(.list); invalidateFocusDisplay() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onPointerRenameCancel?(); invalidateFocusDisplay() }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        draggingDestinationFeedbackStyle = .none
        focusCoordinator?.restorePendingContentFocus(owner: self)
        if window != nil, contrastObserver == nil {
            contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updatePalette() }
            }
        } else if window == nil, let observer = contrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            contrastObserver = nil
        }
        updatePalette()
        onViewportLayout?()
    }

    override func layout() {
        super.layout()
        // An empty/loading replacement can attach before it has usable bounds.
        // Retry after layout; the coordinator consumes the request only once.
        focusCoordinator?.restorePendingContentFocus(owner: self)
        onViewportLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePalette()
    }

    private func updatePalette() {
        backgroundColor = ExplorerTablePalette.background(for: self)
        enclosingScrollView?.backgroundColor = backgroundColor
        headerView?.needsDisplay = true
        invalidateFocusDisplay()
    }

    func invalidateFocusDisplay() {
        needsDisplay = true
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }

    func refreshItemPointerGeometry() {
        enumerateAvailableRowViews { row, _ in
            row.updateTrackingAreas()
            row.needsDisplay = true
        }
    }

    /// The space past the rendered columns is background even at an item's y-coordinate.
    func itemInteractionRect(in rowFrame: NSRect) -> NSRect {
        let columns = tableColumns
        guard let first = columns.firstIndex(where: { !$0.isHidden }),
              let last = columns.lastIndex(where: { !$0.isHidden }) else { return .zero }
        let left = rect(ofColumn: first).minX
        let right = rect(ofColumn: last).maxX
        guard right > left else { return .zero }
        let columnSpan = NSRect(x: left, y: rowFrame.minY, width: right - left, height: rowFrame.height)
        return rowFrame.intersection(columnSpan)
    }

    private func pointerRow(at point: NSPoint) -> Int {
        let row = row(at: point)
        guard itemIDs.indices.contains(row), itemInteractionRect(in: rect(ofRow: row)).contains(point) else { return -1 }
        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlightsCurrentDirectoryDrop {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: visibleRect.insetBy(dx: 2, dy: 2))
            border.lineWidth = 3
            border.stroke()
        }
    }

    /// Used only for native actions lacking an explicit keyboard/pointer focus intent.
    func reconcileNativeSelectionFocus() {
        if let focusedItemID, itemIDs.contains(focusedItemID) { return }
        focusedItemID = selectedRowIndexes.first.flatMap { itemIDs.indices.contains($0) ? itemIDs[$0] : nil }
        if anchorItemID == nil { anchorItemID = focusedItemID }
    }

    override func keyDown(with event: NSEvent) {
        onPointerRenameCancel?()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let deleteKey = FileListDeleteKey(event) {
            switch deleteKey {
            case .trash: moveToTrash(nil)
            case .permanentUnavailable: if window?.firstResponder === self { onPermanentDeleteUnavailable?() }
            case .ignoredRepeat: break
            }
            return
        }
        if modifiers.isEmpty, event.keyCode == 120 { onRename?(); return }
        if modifiers == [.shift], event.keyCode == 109 { showKeyboardContextMenu(); return }
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 { onActivate?(); return }
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            if modifiers == [.option] {
                moveFocusedRow(by: event.keyCode == 125 ? 1 : -1, preservingSelection: true, extending: false)
                return
            }
            if modifiers.isEmpty || modifiers == [.shift] {
                moveFocusedRow(by: event.keyCode == 125 ? 1 : -1,
                               preservingSelection: false, extending: modifiers.contains(.shift))
                return
            }
        }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == " " {
            toggleFocusedRow()
            return
        }
        isHandlingSelectionIntent = true
        super.keyDown(with: event)
        isHandlingSelectionIntent = false
        // Native type-to-select selects one row. Preserve a separate focus for
        // additive gestures, but track a single resulting type-search match.
        if selectedRowIndexes.count == 1, let row = selectedRowIndexes.first, itemIDs.indices.contains(row) {
            focusedItemID = itemIDs[row]
            anchorItemID = focusedItemID
        }
        onSelectionIntent?()
    }

    override func selectAll(_ sender: Any?) {
        isHandlingSelectionIntent = true
        super.selectAll(sender)
        isHandlingSelectionIntent = false
        if focusedItemID == nil { focusedItemID = itemIDs.first }
        if anchorItemID == nil { anchorItemID = focusedItemID }
        onSelectionIntent?()
    }

    func moveFocusedRow(by delta: Int, preservingSelection: Bool, extending: Bool) {
        guard !itemIDs.isEmpty else { return }
        let previous = focusedItemID.flatMap { itemIDs.firstIndex(of: $0) }
        let row = previous.map { min(max($0 + delta, 0), itemIDs.count - 1) }
            ?? (delta < 0 ? itemIDs.count - 1 : 0)
        if !preservingSelection {
            let selected: IndexSet
            if extending {
                let anchor = anchorItemID.flatMap { itemIDs.firstIndex(of: $0) } ?? previous ?? row
                anchorItemID = itemIDs[anchor]
                selected = IndexSet(integersIn: min(anchor, row)..<(max(anchor, row) + 1))
            } else {
                anchorItemID = itemIDs[row]
                selected = IndexSet(integer: row)
            }
            isHandlingSelectionIntent = true
            selectRowIndexes(selected, byExtendingSelection: false)
            isHandlingSelectionIntent = false
        }
        focusedItemID = itemIDs[row]
        scrollRowToVisible(row)
        onSelectionIntent?()
        invalidateFocusDisplay()
    }

    func toggleFocusedRow() {
        guard let row = focusedItemID.flatMap({ itemIDs.firstIndex(of: $0) }) else { return }
        var selected = selectedRowIndexes
        if selected.contains(row) { selected.remove(row) } else { selected.insert(row) }
        isHandlingSelectionIntent = true
        selectRowIndexes(selected, byExtendingSelection: false)
        isHandlingSelectionIntent = false
        if anchorItemID == nil { anchorItemID = focusedItemID }
        onSelectionIntent?()
        invalidateFocusDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showPointerContextMenu(with: event)
            return
        }
        // Every new press ends an earlier candidate (including a double-click's second press).
        onPointerRenameCancel?()
        beginFileDragGesture()
        defer { finishMouseDownFileDragTracking() }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = pointerRow(at: point)
        var renameCandidate: String?
        isHandlingSelectionIntent = true
        if !itemIDs.indices.contains(clicked) {
            window?.makeFirstResponder(self)
            focusedItemID = nil
            anchorItemID = nil
            deselectAll(nil)
        } else if event.modifierFlags.contains(.shift) {
            // AppKit's private range anchor can be different after a programmatic
            // keyboard range update. Share the explicit identity anchor instead.
            let anchor = anchorItemID.flatMap { itemIDs.firstIndex(of: $0) }
                ?? focusedItemID.flatMap { itemIDs.firstIndex(of: $0) } ?? clicked
            anchorItemID = itemIDs[anchor]
            focusedItemID = itemIDs[clicked]
            window?.makeFirstResponder(self)
            let range = IndexSet(integersIn: min(anchor, clicked)..<(max(anchor, clicked) + 1))
            selectRowIndexes(range, byExtendingSelection: event.modifierFlags.contains(.command))
        } else {
            renameCandidate = pointerRenameCandidate(for: event, row: clicked, point: point)
            focusedItemID = itemIDs[clicked]
            anchorItemID = focusedItemID
            // Native tracking returns after mouse-up; it owns selection, drag and double-click.
            super.mouseDown(with: event)
        }
        isHandlingSelectionIntent = false
        onSelectionIntent?()
        invalidateFocusDisplay()
        // Arm only for an undragged single click released over the same, still sole-selected row.
        if let renameCandidate, fileDragSource?.hasActiveSession != true, fileDragSource?.hasIssuedWriter != true,
           selectedRowIndexes == IndexSet(integer: clicked), itemIDs.indices.contains(clicked),
           itemIDs[clicked] == renameCandidate,
           let release = NSApp.currentEvent, release.type == .leftMouseUp,
           pointerRow(at: convert(release.locationInWindow, from: nil)) == clicked,
           window?.isKeyWindow == true, window?.firstResponder === self {
            onPointerRenameCandidate?(renameCandidate)
        }
    }

    override func rightMouseDown(with event: NSEvent) { showPointerContextMenu(with: event) }

    func showPointerContextMenu(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, contextMenu) = preparePointerContextMenu(at: point)
        guard let menu = contextMenu else { return }
        if let menuPresenter { menuPresenter(menu, point, self) }
        else if let onPresentContextMenu { onPresentContextMenu(row, point, self, false) }
        else { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        preparePointerContextMenu(at: convert(event.locationInWindow, from: nil)).menu
    }

    private func preparePointerContextMenu(at point: NSPoint) -> (row: Int, menu: NSMenu?) {
        onPointerRenameCancel?()
        onFileDropExit?()
        let clicked = pointerRow(at: point)
        window?.makeFirstResponder(self)
        if itemIDs.indices.contains(clicked) {
            // FR-MENU-007/008: an unselected target replaces the selection; a target
            // inside the selection keeps it.
            focusedItemID = itemIDs[clicked]
            if !selectedRowIndexes.contains(clicked) {
                anchorItemID = focusedItemID
                isHandlingSelectionIntent = true
                selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                isHandlingSelectionIntent = false
            }
            onSelectionIntent?()
        } else {
            // FR-MENU-009 / EV-0541: empty background clears the selection.
            isHandlingSelectionIntent = true
            focusedItemID = nil
            anchorItemID = nil
            deselectAll(nil)
            isHandlingSelectionIntent = false
            onSelectionIntent?()
        }
        // Menu availability must use the selection established by this click.
        return (clicked, onContextMenu?(clicked))
    }

    /// FR-MENU-003 / UI-MENU-006: Shift-F10 (and the accessibility Show Menu action)
    /// opens the menu for the current selection, or the background menu without one.
    /// The selection is not changed.
    @discardableResult
    func showKeyboardContextMenu() -> Bool {
        onPointerRenameCancel?()
        let focusedRow = focusedItemID.flatMap { itemIDs.firstIndex(of: $0) }
        let row = focusedRow.flatMap { selectedRowIndexes.contains($0) ? $0 : nil } ?? selectedRowIndexes.first ?? -1
        guard let menu = onContextMenu?(row) else { return false }
        let point: NSPoint
        if row >= 0 {
            scrollRowToVisible(row)
            let rect = rect(ofRow: row)
            point = NSPoint(x: rect.minX + 24.pt, y: rect.maxY)
        } else {
            point = NSPoint(x: visibleRect.minX + 24.pt, y: visibleRect.minY + 24.pt)
        }
        if let menuPresenter { menuPresenter(menu, point, self) }
        else if let onPresentContextMenu { onPresentContextMenu(row, point, self, true) }
        else { menu.popUp(positioning: nil, at: point, in: self) }
        return true
    }

    /// Test seam: `NSMenu.popUp` runs a modal tracking loop. Production leaves it nil.
    var menuPresenter: ((NSMenu, NSPoint, NSView) -> Void)?

    override func accessibilityPerformShowMenu() -> Bool { showKeyboardContextMenu() }
}

/// UI-VIEW-001 / AT-UIVIEW-001 and FR-SEL-005: a real keyboard responder,
/// independent of the table's selected rows. Left/Right changes the focused heading.
final class ExplorerTableHeaderView: NSTableHeaderView {
    private lazy var pointerHover = PointerHoverTracker(view: self)
    var hoveredColumn: Int { pointerHover.point.map { column(at: $0) } ?? -1 }
    override func updateTrackingAreas() { super.updateTrackingAreas(); pointerHover.update() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); pointerHover.movedToWindow() }
    override func mouseEntered(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseEntered(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseExited(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseMoved(with: event) }
    }
    weak var focusCoordinator: ExplorerFocusCoordinator?
    var onSortColumn: ((Int) -> Void)?
    var focusedColumn = 0 {
        didSet { needsDisplay = true; updateAccessibilityValue() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusCoordinator?.focused(.header); needsDisplay = true; updateAccessibilityValue() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard let tableView, !tableView.tableColumns.isEmpty else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 123 || event.keyCode == 124 {
            focusedColumn = min(max(focusedColumn + (event.keyCode == 124 ? 1 : -1), 0), tableView.tableColumns.count - 1)
            scrollToVisible(headerRect(ofColumn: focusedColumn))
            return
        }
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 || event.charactersIgnoringModifiers == " " {
            onSortColumn?(focusedColumn)
            updateAccessibilityValue()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let column = column(at: convert(event.locationInWindow, from: nil))
        if column >= 0 { focusedColumn = column; window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self, let tableView,
              tableView.tableColumns.indices.contains(focusedColumn) else { return }
        let rect = headerRect(ofColumn: focusedColumn).insetBy(dx: 2, dy: 2)
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 3 : 2
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessibilityValue() {
        guard let tableView, tableView.tableColumns.indices.contains(focusedColumn) else { return }
        setAccessibilityValue(tableView.tableColumns[focusedColumn].title)
    }
}

private final class ExplorerCellView: NSTableCellView {
    let label = NameEditorTextField()
    let icon = NSImageView()

    init(showsIcon: Bool) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12.pt)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        if showsIcon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4.pt),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16.pt), icon.heightAnchor.constraint(equalToConstant: 16.pt),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5.pt)
            ])
        } else { label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7.pt).isActive = true }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7.pt),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private enum ExplorerTablePalette {
    static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static func background(for view: NSView) -> NSColor {
        isDark(view) ? .controlBackgroundColor : .white
    }
    static func selection(for view: NSView) -> NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            return isDark(view) ? .selectedContentBackgroundColor : NSColor(srgbRed: 0.65, green: 0.83, blue: 0.98, alpha: 1)
        }
        return isDark(view) ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55)
            : NSColor(srgbRed: 0.8, green: 0.91, blue: 0.996, alpha: 1)
    }
}

private final class ExplorerRowView: PointerHoverRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    private var owningTable: ExplorerTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? ExplorerTableView { return table }
            ancestor = view.superview
        }
        return nil
    }

    override var pointerInteractionRect: NSRect {
        guard let table = owningTable else { return .zero }
        let rect = table.itemInteractionRect(in: convert(bounds, to: table))
        return rect.isNull ? .zero : convert(rect, from: table)
    }

    override var pointerHoverRect: NSRect { itemRect }

    private var itemRect: NSRect {
        let rect = pointerInteractionRect
        return rect.isEmpty ? .zero : rect.insetBy(dx: 1, dy: 1)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        ExplorerTablePalette.selection(for: self).setFill()
        itemRect.fill()
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let border: NSColor = contrast ? .labelColor : (ExplorerTablePalette.isDark(self) ? .separatorColor
            : NSColor(srgbRed: 0.35, green: 0.5, blue: 0.6, alpha: 1))
        border.setStroke()
        let path = NSBezierPath(rect: itemRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = contrast ? 2 : 1
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let table = owningTable else { return }
        let row = table.row(for: self)
        if table.highlightedFileDropRow == row {
            NSColor.controlAccentColor.setStroke()
            let target = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            target.lineWidth = 3
            target.stroke()
        }
        guard table.window?.firstResponder === table else { return }
        guard table.itemIDs.indices.contains(row), table.focusedItemID == table.itemIDs[row] else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(rect: itemRect.insetBy(dx: 1, dy: 1))
        path.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 3 : 2
        path.stroke()
    }
}

private final class ExplorerHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        ExplorerTablePalette.background(for: controlView).setFill()
        cellFrame.fill()
        if let header = controlView as? ExplorerTableHeaderView,
           header.column(at: NSPoint(x: cellFrame.midX, y: cellFrame.midY)) == header.hoveredColumn {
            ExplorerHoverPalette.drawControl(in: cellFrame.insetBy(dx: 1, dy: 1))
        }
        if let header = controlView as? ExplorerTableHeaderView, header.window?.firstResponder === header,
           header.column(at: NSPoint(x: cellFrame.midX, y: cellFrame.midY)) == header.focusedColumn {
            ExplorerTablePalette.selection(for: controlView).setFill()
            cellFrame.fill()
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (contrast ? NSColor.labelColor : NSColor.separatorColor).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: cellFrame.height - 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.pt),
            .foregroundColor: contrast ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let text = NSAttributedString(string: stringValue, attributes: attributes)
        text.draw(at: NSPoint(x: cellFrame.minX + 7.pt, y: cellFrame.midY - text.size().height / 2))
    }
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

/// Keep scrolling and target hit-testing in the same periodic drag update.
@MainActor
func updateFileDropAutoscroll(view: NSView, info: NSDraggingInfo) {
    updateFileDropAutoscroll(view: view, locationInWindow: info.draggingLocation)
}

@MainActor
func updateFileDropAutoscroll(view: NSView, locationInWindow: NSPoint) {
    guard let scroll = view.enclosingScrollView else { return }
    let clip = scroll.contentView
    let point = clip.convert(locationInWindow, from: nil)
    let viewport = clip.bounds
    let inset: CGFloat = 28
    let step: CGFloat = 12
    var origin = viewport.origin
    if point.y < viewport.minY + inset { origin.y -= step }
    else if point.y > viewport.maxY - inset { origin.y += step }
    if point.x < viewport.minX + inset { origin.x -= step }
    else if point.x > viewport.maxX - inset { origin.x += step }
    guard origin != viewport.origin else { return }
    // AppKit reserves table headers in clip.contentInsets. A valid top origin
    // can therefore be negative; clamping to document bounds hides row zero.
    // Native constraints also prevent edge motion in a short document.
    let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: viewport.size))
    if constrained.origin != viewport.origin {
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }
}
