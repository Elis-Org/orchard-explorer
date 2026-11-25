import AppKit
import ExplorerCore
import SwiftUI

/// FR-VIEW-001/008/010, UI-VIEW-003 / EV-0306/0307, EV-0318–0329.
/// All layouts share the same snapshot, selection IDs, editor and command services.
struct FileCollectionView: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> ExplorerCollectionScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ scroll: ExplorerCollectionScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.update()
    }
    static func dismantleNSView(_ scroll: ExplorerCollectionScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var store: ExplorerStore
        private let menus: FileContextMenuController
        private let fileDragCoordinator: FileDragCoordinator
        private let revealVisibility = RevealVisibilityCoordinator()
        private let badgeViewport = OneDriveBadgeViewport()
        private(set) var items: [FileItem] = []
        weak var collection: ExplorerFileCollectionView?
        private var location = ""
        private var mode: FolderViewMode?
        private var isUpdating = false
        private(set) var editingSessionID: UUID?
        private weak var nameEditor: NameEditorTextField?
        private var announcedSelectionIDs: Set<String> = []
        private let postAccessibilityNotification: (NSView, NSAccessibility.Notification) -> Void

        init(store: ExplorerStore,
             fileDragCoordinator: FileDragCoordinator = .shared,
             postAccessibilityNotification: @escaping (NSView, NSAccessibility.Notification) -> Void = {
                 NSAccessibility.post(element: $0, notification: $1)
             }) {
            self.store = store
            self.fileDragCoordinator = fileDragCoordinator
            menus = FileContextMenuController(store: store)
            self.postAccessibilityNotification = postAccessibilityNotification
        }

        func makeScrollView() -> ExplorerCollectionScrollView {
            let view = ExplorerFileCollectionView()
            view.fileDragCoordinator = fileDragCoordinator
            view.store = store
            view.focusCoordinator = store.focus
            view.onViewportLayout = { [weak self] in
                self?.revealVisibility.schedule()
                self?.badgeViewport.schedule()
            }
            view.collectionViewLayout = ExplorerCollectionLayout()
            view.isSelectable = true
            view.allowsMultipleSelection = true
            view.allowsEmptySelection = true
            view.backgroundColors = [.textBackgroundColor]
            view.autoresizingMask = [.width]
            view.register(ExplorerCollectionItem.self, forItemWithIdentifier: ExplorerCollectionItem.reuseIdentifier)
            view.dataSource = self
            view.delegate = self
            view.setAccessibilityLabel("Files and folders")
            view.setAccessibilityIdentifier("file-collection")
            view.registerForDraggedTypes(FileDragCoordinator.registeredTypes)
            view.onSelectionIntent = { [weak self] in self?.publishSelection() }
            view.onContextMenu = { [weak self] item in self?.menus.menu(for: item) }
            view.onPresentContextMenu = { [weak self] item, point, origin, keyboard in
                self?.menus.present(for: item, at: point, in: origin, keyboard: keyboard)
            }
            let scroll = ExplorerCollectionScrollView()
            scroll.documentView = view
            collection = view
            store.focus.register(.list, owner: view) { [weak view] in
                guard let view else { return false }
                return view.window?.makeFirstResponder(view) == true
            }
            store.focus.restorePendingContentFocus(owner: view)
            update()
            return scroll
        }

        func update() {
            guard let view = collection else { return }
            isUpdating = true
            defer { isUpdating = false }
            view.store = store
            menus.store = store
            let nextLocation = "\(store.activeTabID):\(store.activeTab.url.absoluteString)"
                + (store.activeSearch.map { ":search:\($0.id.uuidString)" } ?? "")
            let changedLocation = nextLocation != location
            let changedMode = mode != store.activeTab.viewMode
            let edit = store.nameEdit
            let changedEdit = editingSessionID != edit?.id
            if changedEdit || changedLocation { endEditing(restoreFocus: edit == nil) }
            let nextItems = store.displayedItems
            let keepsEditor = edit != nil && edit?.id == editingSessionID
            let reload = changedLocation || changedMode || changedEdit || (items != nextItems && !keepsEditor)
            location = nextLocation
            mode = store.activeTab.viewMode
            if reload {
                for item in view.visibleItems() {
                    (item as? ExplorerCollectionItem)?.itemView.clearPointerHover()
                }
                view.clearFileDrop()
                view.cancelPendingFileDrag()
                items = nextItems
                view.items = items
                (view.collectionViewLayout as? ExplorerCollectionLayout)?.mode = store.activeTab.viewMode
                view.isSynchronizingSelection = true
                view.reloadData()
                view.isSynchronizingSelection = false
                view.collectionViewLayout?.invalidateLayout()
            }
            updateVisibleCloudStatus()
            reconcileSelection(showDraft: true)
            if changedLocation, let scroll = view.enclosingScrollView {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let hasExplicitReveal = store.pendingRevealVisibility != nil
            if (changedMode || changedLocation) && !hasExplicitReveal {
                let focusID = store.currentSelection.focusedID ?? store.currentSelection.selectedIDs.first
                let selection = store.currentSelection
                let restoration = ViewportRestorationGuard(store: store)
                let nextMode = mode
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, view.window != nil, self.location == nextLocation,
                          self.collection === view, view.dataSource === self,
                          self.mode == nextMode, restoration.allowsRestoration(in: self.store),
                          self.store.currentSelection == selection,
                          self.items == self.store.displayedItems else { return }
                    if let focusID { view.reveal(focusID) }
                }
            }
            if let edit { synchronizeEditor(edit) }
            revealVisibility.update(store: store, view: view) { [weak view] id in
                view?.revealRequestedItem(id) ?? .notReady
            }
            badgeViewport.update(view: view, items: { [weak self] in self?.visibleBadgeItems() ?? [] },
                report: { [weak self, weak store] owner, items in
                    store?.reportOneDriveBadgeViewport(owner, items: items) { [weak self] ids in
                        self?.updateVisibleCloudStatus(changedIDs: ids)
                    }
                }, remove: { [weak store] owner in store?.removeOneDriveBadgeViewport(owner) })
        }

        func visibleBadgeItems() -> [FileItem] {
            guard let view = collection else { return [] }
            return view.indexPathsForVisibleItems().sorted { $0.item < $1.item }.compactMap { path in
                guard path.section == 0, items.indices.contains(path.item),
                      let frame = view.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame,
                      frame.intersects(view.visibleRect) else { return nil }
                return items[path.item]
            }
        }

        func updateVisibleCloudStatus(changedIDs: Set<String>? = nil) {
            guard let view = collection else { return }
            for case let cell as ExplorerCollectionItem in view.visibleItems() {
                guard let path = view.indexPath(for: cell), path.section == 0, items.indices.contains(path.item),
                      cell.representedID == items[path.item].id else { continue }
                if let changedIDs, !changedIDs.contains(items[path.item].id) { continue }
                let status = store.cloudStatusDisplay(for: items[path.item])
                cell.itemView.updateCloudStatus(status.presentation, checkedAt: status.checkedAt)
            }
        }

        func dismantle() {
            menus.dismissPresentedMenu()
            revealVisibility.invalidate()
            badgeViewport.invalidate()
            guard let view = collection else { return }
            // SwiftUI can dismantle before removing this view from its window.
            // Retained queued callbacks must lose ownership immediately.
            collection = nil
            view.onViewportLayout = nil
            // A candidate armed by this view never outlives it (MAC-076), as in Details.
            store.cancelPointerRename()
            store.focus.unregister(.list, owner: view)
            endEditing(restoreFocus: false)
            view.releaseInactiveFileDrag()
            view.clearFileDrop()
            view.unregisterDraggedTypes()
            view.onSelectionIntent = nil
            view.onContextMenu = nil
            view.onPresentContextMenu = nil
            view.dataSource = nil
            view.delegate = nil
            view.store = nil
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: ExplorerCollectionItem.reuseIdentifier, for: indexPath)
            guard let cell = cell as? ExplorerCollectionItem, items.indices.contains(indexPath.item) else { return cell }
            let item = items[indexPath.item]
            cell.configure(item: item, mode: store.activeTab.viewMode,
                           folder: store.activeSearch?.result(id: item.id)?.parent?.directoryURL,
                           cloudStatus: store.cloudStatusDisplay(for: item))
            cell.itemView.collection = collection
            cell.onAccessibilitySelection = { [weak self] selected in
                guard let self, let view = self.collection, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                view.selectItem(at: index, extending: false, toggling: true, desiredSelection: selected)
            }
            cell.onAccessibilityFocus = { [weak self] in
                guard let self, let view = self.collection else { return }
                view.window?.makeFirstResponder(view)
                view.focusedItemID = item.id
                self.publishSelection()
                view.reveal(item.id)
            }
            cell.onActivate = { [weak self] in
                guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.collection?.selectItem(at: index, extending: false, toggling: false)
                if self.store.currentSelection.selectedIDs == [item.id] { self.store.activate(item) }
            }
            cell.onReuse = { [weak self, weak cell] in
                guard let id = cell?.itemView.nameField.sessionID else { return }
                self?.store.cancelNameEdit(sessionID: id)
            }
            cell.itemView.isFileDropTarget = collection?.fileDropTargetID == item.id
            cell.applyState(selected: collectionView.selectionIndexPaths.contains(indexPath),
                focused: collection?.focusedItemID == item.id,
                hasKeyboardFocus: collectionView.window?.firstResponder === collectionView)
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { nativeSelectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { nativeSelectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            badgeViewport.schedule()
            guard let edit = store.nameEdit, items.indices.contains(indexPath.item),
                  items[indexPath.item].id == edit.rowID else { return }
            scheduleEditorMount(id: edit.id)
        }
        private func nativeSelectionChanged() {
            guard let view = collection, !view.isSynchronizingSelection, !view.isHandlingNativeKey else { return }
            publishSelection()
        }

        func publishSelection() {
            guard !isUpdating, let view = collection, !view.isSynchronizingSelection, !view.isHandlingNativeKey else { return }
            let selected = Set(view.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            if view.focusedItemID == nil { view.focusedItemID = items.first(where: { selected.contains($0.id) })?.id }
            if view.anchorItemID == nil { view.anchorItemID = view.focusedItemID }
            store.setSelection(selected, focusedID: view.focusedItemID, anchorID: view.anchorItemID)
            // Blocked keyboard/AX changes must immediately return to store authority.
            reconcileSelection(showDraft: false)
        }

        private func reconcileSelection(showDraft: Bool) {
            guard let view = collection else { return }
            let authoritative = store.currentSelection
            var paths = Set(items.indices.filter { authoritative.selectedIDs.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
            let selectedIDs = Set(paths.map { items[$0.item].id })
            var focus = authoritative.focusedID
            if showDraft, let edit = store.nameEdit, let index = items.firstIndex(where: { $0.id == edit.rowID }) {
                paths = [IndexPath(item: index, section: 0)]
                focus = edit.rowID
            }
            view.isSynchronizingSelection = true
            view.focusedItemID = focus
            view.anchorItemID = authoritative.anchorID
            if view.selectionIndexPaths != paths { view.selectionIndexPaths = paths }
            view.isSynchronizingSelection = false
            view.updateVisibleState()
            // Announce committed selection only after native reconciliation.
            // Refused intents and the draft's temporary highlight are not changes.
            if announcedSelectionIDs != selectedIDs {
                announcedSelectionIDs = selectedIDs
                postAccessibilityNotification(view, .selectedChildrenChanged)
            }
        }

        private func synchronizeEditor(_ edit: NameEditSession) {
            guard let view = collection, items.contains(where: { $0.id == edit.rowID }) else { return }
            if editingSessionID == edit.id, let field = nameEditor, field.sessionID == edit.id {
                Self.updateEditor(field, proposedName: edit.proposedName, isSubmitting: edit.isSubmitting, in: view)
                return
            }
            editingSessionID = edit.id
            view.reveal(edit.rowID)
            // Existing visible items need one deferred mount; newly visible ones
            // are mounted by willDisplay. Neither path depends on a retry budget.
            scheduleEditorMount(id: edit.id)
        }

        private func scheduleEditorMount(id: UUID) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.collection, self.editingSessionID == id,
                      let edit = self.store.nameEdit, edit.id == id,
                      let index = self.items.firstIndex(where: { $0.id == edit.rowID }) else { return }
                view.layoutSubtreeIfNeeded()
                guard let cell = view.item(at: IndexPath(item: index, section: 0)) as? ExplorerCollectionItem,
                      cell.representedID == edit.rowID else { return }
                let field = cell.itemView.nameField
                if field.sessionID == id { return }
                self.nameEditor = field
                field.onProposalChange = { [weak self] value in self?.store.updateProposedName(value, sessionID: id) }
                field.onCommit = { [weak self] in self?.store.commitNameEdit(sessionID: id) }
                field.onCancel = { [weak self] in self?.store.cancelNameEdit(sessionID: id) }
                field.setAccessibilityLabel(edit.newItemKind?.accessibilityName ?? "Rename \(edit.originalName)")
                field.beginSession(id: id, name: edit.proposedName, selection: edit.initialSelection)
                Self.updateEditor(field, proposedName: edit.proposedName, isSubmitting: edit.isSubmitting, in: view)
            }
        }

        static func updateEditor(_ field: NameEditorTextField, proposedName: String, isSubmitting: Bool,
                                 in view: ExplorerFileCollectionView) {
            let editor = field.currentEditor()
            let restore = isSubmitting && !field.isSubmitting && editor != nil && view.window?.firstResponder === editor
            field.updateSession(proposedName: proposedName, isSubmitting: isSubmitting, focusOwner: view)
            if restore { view.window?.makeFirstResponder(view) }
        }

        private func endEditing(restoreFocus: Bool) {
            let editor = nameEditor?.currentEditor()
            let hadFocus = editor != nil && collection?.window?.firstResponder === editor
            editingSessionID = nil
            nameEditor?.finishSession()
            nameEditor = nil
            if restoreFocus, hadFocus, let view = collection { view.window?.makeFirstResponder(view) }
        }
    }
}

final class ExplorerCollectionScrollView: NSScrollView {
    private var viewport = NSSize.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        backgroundColor = .textBackgroundColor
        automaticallyAdjustsContentInsets = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if viewport != contentSize {
            viewport = contentSize
            (documentView as? NSCollectionView)?.collectionViewLayout?.invalidateLayout()
        }
    }
}

/// Selection/focus remain separate lexical IDs, even in spatial icon layouts.
final class ExplorerFileCollectionView: NSCollectionView, NSUserInterfaceValidations {
    weak var store: ExplorerStore?
    var fileDragCoordinator: FileDragCoordinator = .shared
    weak var focusCoordinator: ExplorerFocusCoordinator?
    var onViewportLayout: (() -> Void)?
    var items: [FileItem] = []
    var focusedItemID: String?
    var anchorItemID: String?
    var isSynchronizingSelection = false
    private(set) var isHandlingNativeKey = false
    var onSelectionIntent: (() -> Void)?
    var onContextMenu: ((FileItem?) -> NSMenu?)?
    var onPresentContextMenu: ((FileItem?, NSPoint, NSView, Bool) -> Void)?
    private var typePrefix = ""
    private var lastTypeTime = TimeInterval.zero
    private struct PendingFileDrag {
        let itemID: String
        let location: NSPoint
        let entries: [TransferEntry]?
        let collapsesSelectionOnRelease: Bool
        let activatesOnRelease: Bool
        /// MAC-076: set when the press may become a second-click rename.
        var renameCandidate = false
        /// The store's interruption count when pressed; any key, press or menu
        /// tracking before release invalidates the candidate.
        var renameInterruptions = 0
    }
    private var pendingFileDrag: PendingFileDrag?
    private var fileDragSource: FileDragSource?
    private var fileDropDestination: FileDragDestination?
    private(set) var fileDropTargetID: String?
    private var isFileDropReady = false
    private var highlightsCurrentDirectoryDrop = false


    override var acceptsFirstResponder: Bool { true }
    override var selectionIndexPaths: Set<IndexPath> {
        didSet { if !isSynchronizingSelection, !isHandlingNativeKey, oldValue != selectionIndexPaths { onSelectionIntent?() } }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusCoordinator?.focused(.list); updateVisibleState() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            // A held press must not arm a rename after focus moved away (MAC-076).
            pendingFileDrag?.renameCandidate = false
            store?.cancelPointerRename(); updateVisibleState(hasKeyboardFocus: false)
        }
        return accepted
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusCoordinator?.restorePendingContentFocus(owner: self)
        onViewportLayout?()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            releaseInactiveFileDrag()
            clearFileDrop()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func layout() {
        super.layout()
        focusCoordinator?.restorePendingContentFocus(owner: self)
        onViewportLayout?()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColors = [.textBackgroundColor]
        enclosingScrollView?.backgroundColor = .textBackgroundColor
        updateVisibleState()
    }

    func updateVisibleState(hasKeyboardFocus: Bool? = nil) {
        for item in visibleItems() {
            guard let cell = item as? ExplorerCollectionItem, let id = cell.representedID,
                  let path = indexPath(for: item), path.section == 0,
                  items.indices.contains(path.item), items[path.item].id == id else { continue }
            cell.itemView.isFileDropTarget = fileDropTargetID == id
            cell.applyState(selected: selectionIndexPaths.contains(path),
                            focused: focusedItemID == id,
                            hasKeyboardFocus: hasKeyboardFocus ?? (window?.firstResponder === self))
        }
    }

    /// MAC-074: the first visible item, by identity.
    var topVisibleItemID: String? {
        let first = indexPathsForVisibleItems().filter { $0.section == 0 }.map(\.item).min()
        return first.flatMap { items.indices.contains($0) ? items[$0].id : nil }
    }

    func scrollItemToTop(_ id: String) {
        guard let target = preparedScrollTarget(id) else { return }
        scrollToItems(at: [target.path], scrollPosition: .top)
    }

    func reveal(_ id: String) {
        guard let target = preparedScrollTarget(id) else { return }
        scrollToItems(at: [target.path], scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
    }

    func revealRequestedItem(_ id: String) -> RevealVisibilityCoordinator.Attempt {
        guard let target = preparedScrollTarget(id), let scroll = enclosingScrollView else { return .notReady }
        scrollToItems(at: [target.path], scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
        return .attempted(visible: RevealVisibilityGeometry.isVisible(target.frame,
            in: RevealVisibilityGeometry.viewport(in: scroll.contentView)))
    }

    /// Swift rows can outlive NSCollectionView's native cache during teardown
    /// or reload. Reveal and restoration validate the native state after layout,
    /// not just the retained Swift array's index.
    private func preparedScrollTarget(_ id: String) -> (path: IndexPath, frame: NSRect)? {
        guard window != nil, dataSource != nil, let scroll = enclosingScrollView,
              let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        scroll.tile()
        layoutSubtreeIfNeeded()
        let viewport = RevealVisibilityGeometry.viewport(in: scroll.contentView)
        guard viewport.width > 0, viewport.height > 0, numberOfSections > 0,
              numberOfItems(inSection: 0) == items.count else { return nil }
        let path = IndexPath(item: index, section: 0)
        guard let frame = collectionViewLayout?.layoutAttributesForItem(at: path)?.frame,
              !frame.isEmpty else { return nil }
        return (path, frame)
    }

    func selectItem(at index: Int, extending: Bool, toggling: Bool, desiredSelection: Bool? = nil) {
        guard items.indices.contains(index) else { return }
        var state = SelectionState()
        state.selectedIDs = Set(selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
        state.focusedID = focusedItemID
        state.anchorID = anchorItemID
        if let desiredSelection {
            if desiredSelection { state.selectedIDs.insert(items[index].id) }
            else { state.selectedIDs.remove(items[index].id) }
            if state.focusedID == nil { state.focusedID = items[index].id }
            if state.anchorID == nil { state.anchorID = state.focusedID }
        } else {
            state.select(items[index].id, orderedIDs: items.map(\.id), extending: extending, toggling: toggling)
        }
        applyIntent(state)
    }

    private func applyIntent(_ state: SelectionState) {
        isSynchronizingSelection = true
        focusedItemID = state.focusedID
        anchorItemID = state.anchorID
        selectionIndexPaths = Set(items.indices.filter { state.selectedIDs.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
        isSynchronizingSelection = false
        onSelectionIntent?()
        updateVisibleState()
    }

    /// Test seam: replaces the active-window/first-responder precondition (unit-test
    /// windows never become key). Production leaves it nil.
    var pointerRenameFocusCheck: (() -> Bool)?

    /// FR-FILE-031 / EV-0561: in icon layouts only the name label is evidenced as a
    /// rename region (the picture is not); other layouts use their name label too (MAC-076).
    func isPointerRenameRegion(_ point: NSPoint, at path: IndexPath) -> Bool {
        guard let cell = item(at: path) as? ExplorerCollectionItem else { return false }
        let label = cell.itemView.nameField
        return label.convert(label.bounds, to: self).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        // Every press ends an earlier candidate (including a double-click's second press).
        store?.cancelPointerRename()
        let wasFocused = pointerRenameFocusCheck?() ?? (window?.isKeyWindow == true && window?.firstResponder === self)
        cancelPendingFileDrag()
        if event.modifierFlags.contains(.control) {
            showPointerContextMenu(with: event)
            return
        }
        window?.makeFirstResponder(self)
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), items.indices.contains(path.item) else {
            applyIntent(SelectionState()); return
        }
        let item = items[path.item]
        let wasSoleSelection = selectionIndexPaths == [path]
        let extends = event.modifierFlags.contains(.shift)
        let toggles = event.modifierFlags.contains(.command)
        // A press on a selected item retains the complete drag selection. A
        // plain click collapses it only after the pointer is released.
        let preservesSelection = !extends && !toggles && selectionIndexPaths.contains(path)
        if preservesSelection {
            focusedItemID = item.id
            onSelectionIntent?()
            updateVisibleState()
        } else {
            selectItem(at: path.item, extending: extends, toggling: toggles)
        }
        let selectedIDs = Set(selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
        pendingFileDrag = PendingFileDrag(itemID: item.id, location: event.locationInWindow,
            entries: selectedIDs.contains(item.id) ? store?.fileDragEntries(itemIDs: selectedIDs) : nil,
            collapsesSelectionOnRelease: preservesSelection,
            activatesOnRelease: event.clickCount == 2 && !extends && !toggles)
        pendingFileDrag?.renameInterruptions = store?.pointerInterruptions ?? 0
        pendingFileDrag?.renameCandidate = wasSoleSelection && wasFocused && event.clickCount == 1
            && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            && isPointerRenameRegion(convert(event.locationInWindow, from: nil), at: path)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pending = pendingFileDrag,
              Self.crossedFileDragThreshold(from: pending.location, to: event.locationInWindow) else { return }
        // Threshold crossing consumes click activation even if the source has
        // become unavailable; a drag gesture must never open the pressed item.
        pendingFileDrag = nil
        finishFileDrag()
        guard let entries = pending.entries,
              let source = fileDragCoordinator.beginSource(entries: entries, owner: self) else { return }
        let draggingItems = entries.compactMap { entry -> NSDraggingItem? in
            guard let writer = source.pasteboardWriter(itemID: entry.item.id) else { return nil }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let frame = items.firstIndex(where: { $0.id == entry.item.id }).flatMap {
                collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
            } ?? NSRect(origin: convert(pending.location, from: nil), size: NSSize(width: 32, height: 32))
            draggingItem.setDraggingFrame(frame, contents: ItemMetadataFormatting.genericIcon(for: entry.item))
            return draggingItem
        }
        guard draggingItems.count == entries.count else { source.finish(); return }
        fileDragSource = source
        source.startSession()
        let session = beginDraggingSession(with: draggingItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let pending = pendingFileDrag else { return }
        pendingFileDrag = nil
        guard let index = items.firstIndex(where: { $0.id == pending.itemID }) else { return }
        if pending.collapsesSelectionOnRelease { selectItem(at: index, extending: false, toggling: false) }
        if pending.activatesOnRelease, store?.currentSelection.selectedIDs == [pending.itemID] { store?.activate(items[index]) }
        else if pending.renameCandidate, selectionIndexPaths == [IndexPath(item: index, section: 0)],
                indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item == index,
                store?.pointerInterruptions == pending.renameInterruptions,
                pointerRenameFocusCheck?() ?? (window?.isKeyWindow == true && window?.firstResponder === self) {
            store?.armPointerRename(itemID: pending.itemID)
        }
    }

    static func crossedFileDragThreshold(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= 6
    }

    func cancelPendingFileDrag() { pendingFileDrag = nil }
    func finishFileDrag() {
        cancelPendingFileDrag()
        fileDragSource?.finish()
        fileDragSource = nil
    }

    func releaseInactiveFileDrag() {
        cancelPendingFileDrag()
        fileDragSource?.finishIfInactive()
        // An active source is retained by its registry until AppKit completion.
        // The disappearing view need not retain an extra reference to it.
        fileDragSource = nil
    }

    override func cancelOperation(_ sender: Any?) {
        cancelPendingFileDrag()
        clearFileDrop()
    }

    private func destination() -> FileDragDestination? {
        guard let store else { return nil }
        if fileDropDestination == nil { fileDropDestination = fileDragCoordinator.makeDestination(store: store) }
        return fileDropDestination
    }

    private func fileDropTarget(info: NSDraggingInfo) -> (id: String?, binding: FileDropBinding?) {
        // MAC-065: search results and their folder rows are not drop targets.
        guard let store, !store.isSearching else { return (nil, nil) }
        if let path = indexPathForItem(at: convert(info.draggingLocation, from: nil)), items.indices.contains(path.item) {
            let item = items[path.item]
            guard item.isDirectory else { return (nil, nil) }
            let binding = store.fileDropBinding(destinationURL: item.url, expectedEntryIdentity: item.identity)
            return (item.id, binding)
        }
        return (nil, store.fileDropBinding(destinationURL: store.activeTab.url,
                    expectedDestinationIdentity: store.activeTab.directoryIdentity))
    }

    func clearFileDrop() {
        fileDropDestination?.invalidate()
        fileDropTargetID = nil
        isFileDropReady = false
        highlightsCurrentDirectoryDrop = false
        updateVisibleState()
        needsDisplay = true
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDropAutoscroll(view: self, info: sender)
        let target = fileDropTarget(info: sender)
        let operation = destination()?.update(sender, binding: target.binding) ?? []
        isFileDropReady = !operation.isEmpty
        let showsTarget = isFileDropReady || fileDropDestination?.isPreparing == true
        fileDropTargetID = showsTarget ? target.id : nil
        highlightsCurrentDirectoryDrop = showsTarget && target.id == nil
        updateVisibleState()
        needsDisplay = true
        return operation
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearFileDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearFileDrop() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Readiness remains tied to the last update. Acceptance rechecks the
        // binding and never starts a fresh asynchronous preparation on release.
        isFileDropReady
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = fileDropTarget(info: sender)
        defer { clearFileDrop() }
        return destination()?.accept(sender, binding: target.binding) == true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearFileDrop() }
    @objc func springLoadingEntered(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }
    @objc func springLoadingUpdated(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlightsCurrentDirectoryDrop {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: visibleRect.insetBy(dx: 2, dy: 2))
            border.lineWidth = 3
            border.stroke()
        }
    }

    override func rightMouseDown(with event: NSEvent) { showPointerContextMenu(with: event) }

    func showPointerContextMenu(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let item = indexPathForItem(at: point).flatMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        if let menuPresenter { menuPresenter(menu, point, self) }
        else if let onPresentContextMenu { onPresentContextMenu(item, point, self, false) }
        else { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        store?.cancelPointerRename()
        cancelPendingFileDrag()
        clearFileDrop()
        window?.makeFirstResponder(self)
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        let item = path.flatMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        if let path, let item {
            // FR-MENU-007/008: replace with an unselected target; keep a selection containing it.
            if !selectionIndexPaths.contains(path) { selectItem(at: path.item, extending: false, toggling: false) }
            else { focusedItemID = item.id; onSelectionIntent?() }
        } else {
            // FR-MENU-009: empty background clears the selection.
            applyIntent(SelectionState())
        }
        return onContextMenu?(item)
    }

    /// FR-MENU-003 / UI-MENU-006: Shift-F10 / accessibility Show Menu, without changing the selection.
    /// Item-level AX invocation follows context-click targeting, while the
    /// container's keyboard invocation continues to use the current selection.
    @discardableResult
    func showItemContextMenu(itemID: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        store?.cancelPointerRename()
        cancelPendingFileDrag()
        clearFileDrop()
        window?.makeFirstResponder(self)
        if !selectionIndexPaths.contains(IndexPath(item: index, section: 0)) {
            selectItem(at: index, extending: false, toggling: false)
        } else {
            focusedItemID = itemID
            onSelectionIntent?()
        }
        return showKeyboardContextMenu()
    }

    /// Container-level Shift-F10 and AX Show Menu preserve the current selection.
    @discardableResult
    func showKeyboardContextMenu() -> Bool {
        store?.cancelPointerRename()
        let selected = selectionIndexPaths.map(\.item).filter { items.indices.contains($0) }.sorted()
        let focused = focusedItemID.flatMap { id in items.firstIndex { $0.id == id } }
        let index = focused.flatMap { selected.contains($0) ? $0 : nil } ?? selected.first
        let item = index.map { items[$0] }
        guard let menu = onContextMenu?(item) else { return false }
        var point = NSPoint(x: visibleRect.minX + 24.pt, y: visibleRect.minY + 24.pt)
        if let index, let frame = collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
            point = NSPoint(x: frame.midX, y: frame.maxY)
        }
        if let menuPresenter { menuPresenter(menu, point, self) }
        else if let onPresentContextMenu { onPresentContextMenu(item, point, self, true) }
        else { menu.popUp(positioning: nil, at: point, in: self) }
        return true
    }

    /// Test seam: `NSMenu.popUp` runs a modal tracking loop. Production leaves it nil.
    var menuPresenter: ((NSMenu, NSPoint, NSView) -> Void)?

    override func accessibilityPerformShowMenu() -> Bool { showKeyboardContextMenu() }

    override func selectAll(_ sender: Any?) {
        var state = SelectionState()
        state.selectedIDs = Set(items.map(\.id))
        state.focusedID = focusedItemID ?? items.first?.id
        state.anchorID = anchorItemID ?? state.focusedID
        applyIntent(state)
    }
    override func deselectAll(_ sender: Any?) { applyIntent(SelectionState()) }

    override func keyDown(with event: NSEvent) {
        store?.cancelPointerRename()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let deleteKey = FileListDeleteKey(event) {
            switch deleteKey {
            case .trash: moveToTrash(nil)
            case .permanentUnavailable: if ownsFileFocus { store?.notePermanentDeleteUnavailable() }
            case .ignoredRepeat: break
            }
            return
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return }
        if modifiers.isEmpty, event.keyCode == 120 { if ownsFileFocus { store?.beginRename() }; return }
        if modifiers == .shift, event.keyCode == 109 { if ownsFileFocus { showKeyboardContextMenu() }; return }
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 { if ownsFileFocus { activateSelection() }; return }
        if event.keyCode == 115 || event.keyCode == 119,
           modifiers.isEmpty || modifiers == .shift || modifiers == .option {
            moveToEdge(last: event.keyCode == 119, preservingSelection: modifiers == .option,
                       extending: modifiers == .shift)
            return
        }
        if modifiers.isEmpty, event.keyCode == 116 || event.keyCode == 121 {
            scrollPage(down: event.keyCode == 121)
            return
        }
        if [UInt16(123), 124, 125, 126].contains(event.keyCode), modifiers.isEmpty || modifiers == .shift || modifiers == .option {
            moveFocus(keyCode: event.keyCode, preservingSelection: modifiers == .option, extending: modifiers == .shift)
            return
        }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == " ", let index = items.firstIndex(where: { $0.id == focusedItemID }) {
            selectItem(at: index, extending: false, toggling: true,
                       desiredSelection: !selectionIndexPaths.contains(IndexPath(item: index, section: 0)))
            return
        }
        if modifiers.isEmpty || modifiers == .shift, let text = event.characters, !text.isEmpty,
           !event.modifierFlags.contains(.function),
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
               && !(0xF700...0xF8FF).contains($0.value) }) {
            typeSelect(text, at: event.timestamp); return
        }
        // AppKit bindings such as Command-arrow may change native selection.
        // Publish their final result once, including its endpoint, rather than
        // accepting intermediate callbacks with the old keyboard focus.
        let previous = selectionIndexPaths
        isHandlingNativeKey = true
        super.keyDown(with: event)
        isHandlingNativeKey = false
        if previous != selectionIndexPaths {
            let validPaths = Set(selectionIndexPaths.filter { $0.section == 0 && items.indices.contains($0.item) })
            let added = validPaths.subtracting(previous)
            let candidates = (added.isEmpty ? validPaths : added).sorted { $0.item < $1.item }
            let towardStart = [UInt16(123), 126, 115, 116].contains(event.keyCode)
            let endpoint = towardStart ? candidates.first : candidates.last
            focusedItemID = endpoint.map { items[$0.item].id }
            if !modifiers.contains(.shift) || anchorItemID == nil { anchorItemID = focusedItemID }
        }
        onSelectionIntent?()
        updateVisibleState()
    }

    private func scrollPage(down: Bool) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let viewport = clip.bounds
        // verticalPageScroll is the overlap retained between pages, not the
        // distance to advance. NSScrollView has no scrollPageDown: implementation.
        let distance = max(1, viewport.height - max(0, scroll.verticalPageScroll))
        let direction: CGFloat = (down == isFlipped) ? 1 : -1
        let maximumY = max(bounds.minY, bounds.maxY - viewport.height)
        let targetY = min(maximumY, max(bounds.minY, viewport.minY + direction * distance))
        clip.scroll(to: NSPoint(x: viewport.minX, y: targetY))
        scroll.reflectScrolledClipView(clip)
    }

    private func moveToEdge(last: Bool, preservingSelection: Bool, extending: Bool) {
        guard !items.isEmpty else { return }
        let index = last ? items.count - 1 : 0
        if preservingSelection { focusedItemID = items[index].id; onSelectionIntent?(); updateVisibleState() }
        else { selectItem(at: index, extending: extending, toggling: false) }
        if let focusedItemID { reveal(focusedItemID) }
    }

    func moveFocus(keyCode: UInt16, preservingSelection: Bool, extending: Bool) {
        guard !items.isEmpty, let layout = collectionViewLayout as? ExplorerCollectionLayout else { return }
        layout.prepare()
        let previous = items.firstIndex { $0.id == focusedItemID }
        let target = previous.flatMap { layout.geometry.neighbor(of: $0, keyCode: keyCode) }
            ?? (previous == nil ? 0 : previous!)
        if preservingSelection { focusedItemID = items[target].id; onSelectionIntent?(); updateVisibleState() }
        else { selectItem(at: target, extending: extending, toggling: false) }
        if let focusedItemID { reveal(focusedItemID) }
    }

    func typeSelect(_ text: String, at timestamp: TimeInterval) {
        let startsNew = timestamp - lastTypeTime > 1 || timestamp < lastTypeTime
        typePrefix = startsNew ? text : typePrefix + text
        lastTypeTime = timestamp
        let focused = items.firstIndex { $0.id == focusedItemID } ?? -1
        let order = Array(items.indices.filter { $0 > focused }) + Array(items.indices.filter { $0 <= focused })
        func match(_ prefix: String) -> Int? { order.first { items[$0].name.lowercased().hasPrefix(prefix.lowercased()) } }
        let retainsCurrent = !startsNew && items.indices.contains(focused)
            && items[focused].name.lowercased().hasPrefix(typePrefix.lowercased())
        if let index = retainsCurrent ? focused : (match(typePrefix) ?? match(text)) {
            if match(typePrefix) == nil { typePrefix = text }
            selectItem(at: index, extending: false, toggling: false)
            if let focusedItemID { reveal(focusedItemID) }
        }
    }

    private func activateSelection() {
        guard let store, store.currentSelection.selectedIDs.count == 1,
              let item = items.first(where: { store.currentSelection.selectedIDs.contains($0.id) }) else { return }
        store.activate(item)
    }

    private var ownsFileFocus: Bool { window?.firstResponder === self }
    private var textEditor: NSTextView? { window?.firstResponder as? NSTextView }
    private var fileCommands: FileCommandEligibility {
        FileCommandEligibility(ownsFileFocus: ownsFileFocus,
            copy: store?.canCopySelection == true, cut: store?.canCutSelection == true,
            paste: store?.canPaste == true, delete: store?.canDeleteSelection == true,
            undo: store?.canUndoRename == true, redo: store?.canRedoRename == true)
    }
    @objc func copy(_ sender: Any?) { if fileCommands.allows(.copy) { store?.copySelection() } }
    @objc func cut(_ sender: Any?) { if fileCommands.allows(.cut) { store?.cutSelection() } }
    @objc func paste(_ sender: Any?) { if fileCommands.allows(.paste) { store?.pasteSelection() } }
    @objc func moveToTrash(_ sender: Any?) {
        guard fileCommands.allows(.delete), !FileListDeleteKey.isAutoRepeat(triggeringEvent()) else { return }
        store?.deleteSelection()
    }
    /// Test seam for the event that triggered an action (MAC-079 repeat guard).
    var triggeringEvent: () -> NSEvent? = { NSApp.currentEvent }
    @objc func undo(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.undo(); return }
        if fileCommands.allows(.undo) { store?.undoRename() }
    }
    @objc func redo(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.redo(); return }
        if fileCommands.allows(.redo) { store?.redoRename() }
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return fileCommands.allows(.copy)
        case #selector(cut(_:)): return fileCommands.allows(.cut)
        case #selector(paste(_:)): return fileCommands.allows(.paste)
        case #selector(moveToTrash(_:)): return fileCommands.allows(.delete)
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = textEditor?.undoManager?.undoMenuItemTitle ?? (textEditor == nil ? "Undo Rename" : "Undo")
            return textEditor.map { $0.undoManager?.canUndo == true } ?? fileCommands.allows(.undo)
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = textEditor?.undoManager?.redoMenuItemTitle ?? (textEditor == nil ? "Redo Rename" : "Redo")
            return textEditor.map { $0.undoManager?.canRedo == true } ?? fileCommands.allows(.redo)
        case #selector(selectAll(_:)): return !items.isEmpty
        default: return false
        }
    }
}
