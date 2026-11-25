import AppKit
import ExplorerCore
import SwiftUI

struct ExplorerSidebar: View {
    @ObservedObject private var store: ExplorerStore
    @ObservedObject private var pins: PinnedFolderStore
    /// Owned by the store so expansion survives an interface-size rebuild (MAC-074).
    @ObservedObject private var model: SidebarModel

    init(store: ExplorerStore) {
        self.store = store
        pins = store.pins
        model = store.sidebarModel
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarOutline(store: store, model: model)
            if let message = pins.errorMessage {
                VStack(alignment: .leading, spacing: 5.pt) {
                    Text(message).font(.system(size: 11.pt)).fixedSize(horizontal: false, vertical: true)
                    Button(scaled: "Dismiss", action: pins.dismissError).font(.system(size: 11.pt))
                }
                .padding(10.pt).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A native outline supplies keyboard disclosure, real tree accessibility, and first-responder focus.
struct SidebarOutline: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    @ObservedObject var model: SidebarModel

    func makeCoordinator() -> Coordinator { Coordinator(store: store, model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NavigationOutlineView()
        outline.headerView = nil
        outline.rowHeight = 30.pt
        outline.intercellSpacing = NSSize(width: 0, height: 2.pt)
        outline.indentationPerLevel = 14.pt
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .exterior
        outline.backgroundColor = .textBackgroundColor
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel("Navigation sidebar")
        outline.setAccessibilityIdentifier("explorer.sidebar")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        column.width = 275.pt
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = outline
        outline.action = #selector(NavigationOutlineView.activateSelectedRow(_:))
        outline.onActivateSelection = { [weak coordinator = context.coordinator] in coordinator?.activateSelection() }
        outline.onContextMenu = { [weak coordinator = context.coordinator] row, point in
            coordinator?.presentContextMenu(for: row, at: point)
        }
        outline.onContextMenuOriginRemoved = { [weak coordinator = context.coordinator] in
            coordinator?.dismissContextMenu()
        }
        outline.onFocused = { [weak store] in store?.focus.focused(.sidebar) }
        outline.registerForDraggedTypes(FileDragCoordinator.registeredTypes)
        outline.onDraggingUpdate = { [weak coordinator = context.coordinator] info in
            coordinator?.updateDrop(info) ?? []
        }
        outline.onDraggingFinished = { [weak coordinator = context.coordinator] in coordinator?.clearDrop() }
        outline.onPrepareFileDrop = { [weak coordinator = context.coordinator] in coordinator?.prepareDrop($0) == true }
        outline.onPerformFileDrop = { [weak coordinator = context.coordinator] in coordinator?.performDrop($0) == true }
        context.coordinator.outline = outline
        store.focus.register(.sidebar, owner: outline) { [weak outline] in
            guard let outline else { return false }
            return outline.window?.makeFirstResponder(outline) ?? false
        }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        context.coordinator.attachViewport(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let outline = coordinator.outline { coordinator.store.focus.unregister(.sidebar, owner: outline) }
        coordinator.dismissContextMenu()
        coordinator.clearDrop()
        coordinator.detachViewport()
        coordinator.outline?.onPrepareFileDrop = nil
        coordinator.outline?.onPerformFileDrop = nil
        // The model belongs to the store and outlives this view (interface-size rebuilds,
        // narrow layouts); the store cancels its reads when the window closes.
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let store: ExplorerStore
        let model: SidebarModel
        weak var outline: NavigationOutlineView?
        private var lastRevision = -1
        private var lastPresenceRevision = -1
        private var lastRootIDs: [ObjectIdentifier] = []
        private struct ContextTarget {
            let nodeKey: String
            let url: URL
            let expectedPinned: Bool
        }

        private var contextMenu: ContextMenuPanelController?
        private var contextTarget: ContextTarget?
        private var synchronizing = false
        private var lastLocation: String?
        private let fileDragCoordinator: FileDragCoordinator
        private lazy var fileDropDestination = fileDragCoordinator.makeDestination(store: store)
        private var dropBinding: FileDropBinding?
        private weak var dropNode: SidebarNode?
        private var isDropReady = false
        private let presenceOwner = UUID()
        private weak var scrollView: NSScrollView?
        private var viewportObservers: [NSObjectProtocol] = []
        private var windowObservers: [NSObjectProtocol] = []
        private var viewportPass: Task<Void, Never>?

        init(store: ExplorerStore, model: SidebarModel, fileDragCoordinator: FileDragCoordinator = .shared) {
            self.store = store
            self.model = model
            self.fileDragCoordinator = fileDragCoordinator
        }

        func attachViewport(_ scroll: NSScrollView) {
            scrollView = scroll
            model.attachPresenceOwner(presenceOwner)
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            viewportObservers = [
                observeViewport(NSView.boundsDidChangeNotification, object: clip),
                observeViewport(NSView.frameDidChangeNotification, object: clip),
                observeViewport(NSApplication.didBecomeActiveNotification),
                observeViewport(NSApplication.didResignActiveNotification),
                observeViewport(NSApplication.didHideNotification),
                observeViewport(NSApplication.didUnhideNotification),
            ]
            outline?.onWindowChanged = { [weak self] in self?.observeViewportWindow() }
            observeViewportWindow()
        }

        func detachViewport() {
            viewportPass?.cancel()
            viewportPass = nil
            let center = NotificationCenter.default
            for observer in viewportObservers + windowObservers { center.removeObserver(observer) }
            viewportObservers = []
            windowObservers = []
            outline?.onWindowChanged = nil
            scrollView = nil
            model.detachPresenceOwner(presenceOwner)
        }

        private func observeViewport(_ name: Notification.Name, object: AnyObject? = nil) -> NSObjectProtocol {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleViewport() }
            }
        }

        private func observeViewportWindow() {
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers = []
            if let window = outline?.window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification,
                             NSWindow.willCloseNotification] {
                    windowObservers.append(observeViewport(name, object: window))
                }
            }
            scheduleViewport()
        }

        private var viewportIsActive: Bool {
            guard let window = outline?.window, window.isVisible, !window.isMiniaturized,
                  window.occlusionState.contains(.visible) else { return false }
            return NSApp.isActive && !NSApp.isHidden
        }

        private func scheduleViewport() {
            guard scrollView != nil else { return }
            if !viewportIsActive {
                viewportPass?.cancel()
                viewportPass = nil
                model.setVisiblePresenceDemand([], owner: presenceOwner, isActive: false)
                return
            }
            guard viewportPass == nil else { return }
            viewportPass = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.viewportPass = nil
                self.updateViewport()
            }
        }

        private func updateViewport() {
            guard viewportIsActive, let outline else {
                model.setVisiblePresenceDemand([], owner: presenceOwner, isActive: false)
                return
            }
            model.setVisiblePresenceDemand(Self.visibleFolderRows(in: outline), owner: presenceOwner, isActive: true)
        }

        static func visibleFolderRows(in outline: NSOutlineView) -> [SidebarNode] {
            let rect = outline.visibleRect
            let rows = outline.rows(in: rect)
            guard rows.location != NSNotFound, rows.length > 0, !rect.isEmpty else { return [] }
            return (rows.location..<min(NSMaxRange(rows), outline.numberOfRows)).compactMap { row in
                guard outline.rect(ofRow: row).intersects(rect),
                      let node = outline.item(atRow: row) as? SidebarNode, node.kind == .folder else { return nil }
                return node
            }
        }

        func update() {
            guard let outline else { return }
            if let dropBinding, !store.isCurrentFileDropBinding(dropBinding) { clearDrop() }
            let rootIDs = model.roots.map(ObjectIdentifier.init)
            if lastRevision != model.revision || rootIDs != lastRootIDs {
                let selectedNode = outline.item(atRow: outline.selectedRow) as? SidebarNode
                let scrollOrigin = scrollView?.contentView.bounds.origin
                synchronizing = true
                for row in (0..<outline.numberOfRows).reversed() {
                    if let node = outline.item(atRow: row) as? SidebarNode, !node.isExpandable {
                        collapseLeaf(node, in: outline)
                    }
                }
                outline.reloadData()
                for root in model.roots where root.expanded && root.isExpandable {
                    outline.expandItem(root)
                    restoreExpansion(root)
                }
                synchronizing = false
                lastRevision = model.revision
                lastRootIDs = rootIDs
                dismissInvalidContextMenu()
                // A removed/replaced presentation must never retain a highlighted target.
                if let dropNode {
                    let row = outline.row(forItem: dropNode)
                    if row < 0 { clearDrop() }
                    else if outline.highlightedDropRow >= 0 { outline.highlightedDropRow = row }
                }
                if let selectedNode {
                    let sameItem = outline.row(forItem: selectedNode)
                    let samePath = (0..<outline.numberOfRows).first {
                        guard let path = selectedNode.url?.path else { return false }
                        return (outline.item(atRow: $0) as? SidebarNode)?.url?.path == path
                    }
                    if let row = sameItem >= 0 ? sameItem : samePath {
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    } else { outline.deselectAll(nil) }
                }
                if let scrollView, let scrollOrigin {
                    let clip = scrollView.contentView
                    var bounds = clip.bounds
                    bounds.origin = scrollOrigin
                    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                    scrollView.reflectScrolledClipView(clip)
                }
            }
            if lastPresenceRevision != model.presenceRevision {
                let dirty = model.takeDirtyPresenceNodes(owner: presenceOwner)
                synchronizing = true
                for row in (0..<outline.numberOfRows).reversed() {
                    guard let node = outline.item(atRow: row) as? SidebarNode,
                          dirty.contains(ObjectIdentifier(node)) else { continue }
                    collapseLeaf(node, in: outline)
                    outline.reloadItem(node, reloadChildren: false)
                }
                synchronizing = false
                lastPresenceRevision = model.presenceRevision
            }
            // A breadcrumb update selects an already-visible tree row without expanding
            // or reading unrelated folders. This never dispatches another navigation.
            let favoriteKey = store.selectedSidebarFavoriteKey
            let location = store.activeTabID.uuidString + store.activeTab.url.absoluteString + (favoriteKey ?? "")
            if location != lastLocation || outline.selectedRow < 0 {
                if let row = (0..<outline.numberOfRows).first(where: {
                    guard let node = outline.item(atRow: $0) as? SidebarNode else { return false }
                    if let page = BrowserPage(url: store.activeTab.url) {
                        return node.url == (page.parent ?? page).url
                    }
                    guard store.physicalFolderURL != nil else { return false }
                    if let favoriteKey { return node.key == favoriteKey }
                    return node.url?.path == store.activeTab.url.path
                }) {
                    if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                } else { outline.deselectAll(nil) }
                lastLocation = location
            }
            scheduleViewport()
        }

        private func collapseLeaf(_ node: SidebarNode, in outline: NSOutlineView) {
            if !node.isExpandable, outline.isItemExpanded(node) {
                outline.collapseItem(node, collapseChildren: true)
            }
        }

        private func restoreExpansion(_ node: SidebarNode) {
            guard let outline else { return }
            for child in node.children {
                collapseLeaf(child, in: outline)
                if child.isExpandable, child.expanded {
                    outline.expandItem(child)
                    restoreExpansion(child)
                }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarNode)?.children.count ?? model.roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? SidebarNode)?.children[index] ?? model.roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.isExpandable == true
        }
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.isExpandable
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.kind != .message || node.retryParent != nil
        }

        // NATIVE-P13: native drop-on-folder transport. Hover only prepares a
        // read-only proposal; the shared destination owns all transfer authority.
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            updateDrop(info)
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard index == NSOutlineViewDropOnItemIndex,
                  let node = item as? SidebarNode, node === dropNode else {
                clearDrop()
                return false
            }
            return performDrop(info)
        }

        private func currentDropBinding(_ info: any NSDraggingInfo) -> FileDropBinding? {
            guard let outline else { return nil }
            let point = outline.convert(info.draggingLocation, from: nil)
            let row = outline.row(at: point)
            guard outline.visibleRect.contains(point), row >= 0, row < outline.numberOfRows,
                  let node = outline.item(atRow: row) as? SidebarNode,
                  node === dropNode, node.kind == .folder, node.retryParent == nil,
                  let url = node.url, let dropBinding,
                  store.fileDropBinding(destinationURL: url, expectedEntryIdentity: node.fileIdentity) == dropBinding else { return nil }
            return dropBinding
        }

        func prepareDrop(_ info: any NSDraggingInfo) -> Bool {
            guard isDropReady, currentDropBinding(info) != nil else {
                clearDrop()
                return false
            }
            return true
        }

        func performDrop(_ info: any NSDraggingInfo) -> Bool {
            defer { clearDrop() }
            guard isDropReady, let binding = currentDropBinding(info) else { return false }
            return fileDropDestination.accept(info, binding: binding)
        }

        func updateDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
            guard let outline else { return [] }
            let point = outline.convert(info.draggingLocation, from: nil)
            let row = outline.row(at: point)
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode,
                  node.kind == .folder, node.retryParent == nil, let url = node.url,
                  let binding = store.fileDropBinding(destinationURL: url,
                                                      expectedEntryIdentity: node.fileIdentity) else {
                clearDrop()
                return []
            }
            if dropBinding != binding || dropNode !== node { clearDrop() }
            dropBinding = binding
            dropNode = node
            outline.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let operation = fileDropDestination.update(info, binding: binding)
            isDropReady = !operation.isEmpty
            outline.highlightedDropRow = operation.isEmpty && !fileDropDestination.isPreparing ? -1 : row
            outline.toolTip = fileDropDestination.refusalReason
                ?? (fileDropDestination.isPreparing ? "Checking drop destination…" : "Drop into \(node.title)")
            return operation
        }

        func clearDrop() {
            fileDropDestination.invalidate()
            dropBinding = nil
            dropNode = nil
            isDropReady = false
            outline?.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            outline?.highlightedDropRow = -1
            outline?.toolTip = nil
        }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            (item as? SidebarNode)?.isExpandable == true
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? SidebarNode)?.separatorBefore == true ? 35.pt : 30.pt
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !synchronizing, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            model.expand(node)
            scheduleViewport()
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !synchronizing, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            model.collapse(node)
            scheduleViewport()
            dismissInvalidContextMenu()
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let node = item as? SidebarNode, node.kind != .message || node.retryParent != nil else { return nil }
            let row = NavigationSidebarRowView()
            row.separatorBefore = node.separatorBefore
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: node.title)
            label.font = .systemFont(ofSize: 12.pt)
            label.textColor = node.kind == .message ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            var inset: CGFloat = 4.pt
            if node.kind != .message {
                // MAC-075: ordinary folders use Explorer's drawn yellow folder; special
                // locations keep their system symbols, sized with the interface.
                let image: NSImageView
                if node.symbol == "folder.fill" {
                    image = NSImageView(image: ExplorerIcons.folder)
                    image.imageScaling = .scaleProportionallyUpOrDown
                } else {
                    image = NSImageView(image: NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil) ?? NSImage())
                    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.pt, weight: .regular)
                    image.contentTintColor = .systemBlue
                }
                image.unregisterDraggedTypes()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4.pt),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16.pt), image.heightAnchor.constraint(equalToConstant: 16.pt)
                ])
                inset = 26.pt
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6.pt),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.toolTip = node.retryParent?.failure ?? node.url?.path
            return cell
        }

        func activateSelection() {
            guard let outline, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
            if let retry = node.retryParent { model.retry(retry) }
            else if let url = node.url { store.activateSidebarItem(key: node.key, url: url) }
        }

        func menu(for row: Int) -> NSMenu? {
            guard let outline, let node = outline.item(atRow: row) as? SidebarNode, let url = node.url else { return nil }
            let target = ContextTarget(nodeKey: node.key, url: url, expectedPinned: store.pins.contains(url))
            let menu = NSMenu()
            menu.autoenablesItems = false
            let open = NSMenuItem(title: "Open in New Tab", action: #selector(openInTab(_:)), keyEquivalent: "")
            open.identifier = .init("context-sidebar-open-in-new-tab")
            open.target = self
            open.representedObject = target
            open.image = MenuIcons.Glyph.newTab.image
            menu.addItem(open)

            guard node.kind == .folder else { return menu }
            let pinned = target.expectedPinned
            let pin = NSMenuItem(title: pinned ? "Unpin from Quick access" : "Pin to Quick access",
                                 action: pinned ? #selector(unpin(_:)) : #selector(pin(_:)), keyEquivalent: "")
            pin.identifier = .init(pinned ? "context-sidebar-unpin" : "context-sidebar-pin")
            pin.target = self
            pin.representedObject = target
            pin.image = (pinned ? MenuIcons.Glyph.unpin : .pin).image
            menu.addItem(pin)
            return menu
        }

        func presentContextMenu(for row: Int, at point: NSPoint) {
            dismissContextMenu()
            guard let outline, let menu = menu(for: row),
                  let target = menu.items.first?.representedObject as? ContextTarget else { return }
            store.cancelPointerRename()
            let presentation = ContextMenuPanelController(
                menu: menu, title: "Sidebar actions", accessibilityIdentifier: "explorer-sidebar-context-menu",
                origin: outline, point: point, keyboard: false,
                isCurrent: { [weak self] in self?.isContextTargetCurrent(target) == true },
                onDismiss: { [weak self] _ in
                    self?.contextMenu = nil
                    self?.contextTarget = nil
                })
            contextTarget = target
            contextMenu = presentation
            presentation.show()
        }

        func dismissContextMenu() {
            let presentation = contextMenu
            contextMenu = nil
            contextTarget = nil
            presentation?.dismiss(reason: .replacement)
        }

        private func dismissInvalidContextMenu() {
            if let contextTarget, !isContextTargetCurrent(contextTarget) { dismissContextMenu() }
        }

        private func isContextTargetCurrent(_ target: ContextTarget) -> Bool {
            guard outline != nil, store.pins.contains(target.url) == target.expectedPinned else { return false }
            func containsTarget(_ node: SidebarNode) -> Bool {
                (node.key == target.nodeKey && node.url == target.url) || node.children.contains(where: containsTarget)
            }
            return model.roots.contains(where: containsTarget)
        }

        @objc private func openInTab(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? ContextTarget, isContextTargetCurrent(target) else { return }
            store.activateSidebarItem(key: target.nodeKey, url: target.url, newTab: true)
        }

        @objc private func pin(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? ContextTarget, !target.expectedPinned,
                  isContextTargetCurrent(target) else { return }
            store.pins.pin(target.url)
        }

        @objc private func unpin(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? ContextTarget, target.expectedPinned,
                  isContextTargetCurrent(target) else { return }
            store.pins.unpin(target.url)
        }
    }
}

@MainActor
private final class NavigationSidebarRowView: PointerHoverRowView {
    var separatorBefore = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard separatorBefore else { return }
        NSColor.separatorColor.setFill()
        let y = isFlipped ? bounds.minY + 1.pt : bounds.maxY - 2.pt
        NSRect(x: bounds.minX + 7.pt, y: y, width: max(0, bounds.width - 14.pt), height: 1.pt).fill()
    }
}

@MainActor
final class NavigationOutlineView: NSOutlineView {
    var onActivateSelection: (() -> Void)?
    var onContextMenu: ((Int, NSPoint) -> Void)?
    var onContextMenuOriginRemoved: (() -> Void)?
    var onFocused: (() -> Void)?
    var onWindowChanged: (() -> Void)?
    private var activationSuppressed = false
    var onDraggingUpdate: ((any NSDraggingInfo) -> NSDragOperation)?
    var onDraggingFinished: (() -> Void)?
    var onPrepareFileDrop: ((any NSDraggingInfo) -> Bool)?
    var onPerformFileDrop: ((any NSDraggingInfo) -> Bool)?
    var highlightedDropRow = -1 { didSet { if oldValue != highlightedDropRow { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlightedDropRow >= 0, highlightedDropRow < numberOfRows else { return }
        let rect = rect(ofRow: highlightedDropRow).insetBy(dx: 2, dy: 1)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        border.stroke()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onPrepareFileDrop?(sender) == true
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Native outline proposal caching can retain the initial pending refusal.
        // The receiving controller revalidates and accepts its prepared target.
        onPerformFileDrop?(sender) == true
    }
    @objc func springLoadingEntered(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }
    @objc func springLoadingUpdated(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { [] }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Native autoscroll continues while the pointer rests near an edge.
        if let window, let event = NSEvent.mouseEvent(with: .leftMouseDragged,
            location: sender.draggingLocation, modifierFlags: NSEvent.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            _ = autoscroll(with: event)
        }
        // Preserve outline drag lifecycle, then recheck asynchronous preparation
        // even when AppKit's proposed row has not changed.
        _ = super.draggingUpdated(sender)
        return onDraggingUpdate?(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDraggingFinished?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // This optional AppKit destination callback has no superclass implementation.
        onDraggingFinished?()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        onDraggingFinished?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { onContextMenuOriginRemoved?() }
        if newWindow == nil { onDraggingFinished?() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = .textBackgroundColor
        enclosingScrollView?.backgroundColor = .textBackgroundColor
        needsDisplay = true
    }

    @objc func activateSelectedRow(_ sender: Any?) {
        if !activationSuppressed { onActivateSelection?() }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocused?() }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let isDisclosure = row >= 0 && frameOfOutlineCell(atRow: row).contains(point)
        activationSuppressed = isDisclosure
        super.mouseDown(with: event)
        activationSuppressed = false
    }

    override func keyDown(with event: NSEvent) {
        // Left/right retain AppKit's tree expansion semantics and never navigate.
        if event.keyCode == 36 || event.keyCode == 76 { onActivateSelection?(); return }
        activationSuppressed = true
        super.keyDown(with: event)
        activationSuppressed = false
        if event.keyCode == 125 || event.keyCode == 126 { onActivateSelection?() }
    }

    override func rightMouseDown(with event: NSEvent) { showContextMenu(with: event) }

    private func showContextMenu(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onContextMenu?(row(at: point), point)
    }
}
