import AppKit
import SwiftUI

private enum TabStripPalette {
    static let background = NSColor(name: "ExplorerTabStrip") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 0.851, green: 0.855, blue: 0.875, alpha: 1)
    }
    static let active = NSColor(name: "ExplorerActiveTab") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .controlBackgroundColor
            : NSColor(srgbRed: 0.953, green: 0.957, blue: 0.965, alpha: 1)
    }
}

// UI-TAB-001/002, FR-TAB-001/003/007/008; AT-UITAB-001/002,
// AT-TAB-001/003/007/008. EV-0373 + paired EV-0374 establish the menu states;
// EV-0379 and EV-0386 establish duplication and detached-window outcomes.
struct ExplorerTabStrip: View {
    @ObservedObject var store: ExplorerStore
    let width: CGFloat

    private var compact: Bool { width < 300.pt }
    private var stripWidth: CGFloat {
        min(CGFloat(store.tabs.count) * 223.pt, max(0, width - 126.pt))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Room for the native window buttons, which do not scale (MAC-074).
            Color.clear.frame(width: 80)
            if !compact {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3.pt) {
                            ForEach(store.tabs) { tab in
                                HStack(spacing: 0) {
                                    TabDragHandle(store: store, tab: tab)
                                    Button { store.closeTab(tab.id) } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9.pt))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 27.pt, height: 28.pt)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ChromeButtonStyle())
                                    .accessibilityLabel("Close tab \(tab.title)")
                                    .help("Close tab (⌘W)")
                                }
                                .padding(.trailing, 4.pt)
                                .frame(width: 220.pt, height: 31.pt)
                                .background(tab.id == store.activeTabID ? Color(nsColor: TabStripPalette.active) : Color.clear)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7.pt, topTrailingRadius: 7.pt))
                                .id(tab.id)
                            }
                        }
                        .padding(.top, 7.pt)
                    }
                    .onChange(of: store.activeTabID) { _, id in proxy.scrollTo(id, anchor: .center) }
                    .onChange(of: width) { _, _ in proxy.scrollTo(store.activeTabID, anchor: .center) }
                }
                .frame(width: stripWidth, height: 38.pt)
            }
            Button(action: store.addTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12.pt))
                    .frame(width: 34.pt, height: 32.pt)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChromeButtonStyle())
            .accessibilityLabel("New tab")
            .help("New tab (⌘T)")
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .frame(height: 38.pt)
        .background(Color(nsColor: TabStripPalette.background))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("tab-strip")
    }
}

/// A release outside the source window tears off a tab on macOS. The Windows
/// trace does not establish a drag threshold, a reorder policy, or cancellation.
/// Requiring an observed mouse-up prevents Escape or a lost gesture from
/// being mistaken for a successful tear-off.
enum TabDetachDecision {
    static func shouldDetach(didRelease: Bool, cancelled: Bool, releasePoint: NSPoint, sourceFrame: NSRect) -> Bool {
        didRelease && !cancelled && !sourceFrame.contains(releasePoint)
    }
}

@MainActor
private struct TabDragHandle: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    let tab: BrowserTab

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> TabDragButton {
        let button = TabDragButton()
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 12.pt)
        button.registerForDraggedTypes(FileDragCoordinator.registeredTypes)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: TabDragButton, context: Context) {
        button.tabID = tab.id
        button.title = tab.title
        button.isActiveTab = tab.id == store.activeTabID
        button.toolTip = "\(BrowsingPresentation.path(tab.url))\nDrag outside this window to move the tab to a new window."
        button.configureFileDrop(store: store, tab: tab)
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilityLabel("Tab, \(tab.title)")
        button.setAccessibilityIdentifier("tab-\(tab.id.uuidString)")
        button.setAccessibilitySelected(button.isActiveTab)
        button.setAccessibilityValue(button.isActiveTab ? 1 : 0)
        if button.isActiveTab {
            store.focus.register(.tabs, owner: button) { [weak button] in
                guard let button, let window = button.window else { return false }
                return window.makeFirstResponder(button)
            }
        } else {
            store.focus.unregister(.tabs, owner: button)
        }
        button.needsDisplay = true
    }

    static func dismantleNSView(_ button: TabDragButton, coordinator: Coordinator) {
        coordinator.store?.focus.unregister(.tabs, owner: button)
        button.endEventMonitoring()
    }

    final class Coordinator {
        weak var store: ExplorerStore?
        init(store: ExplorerStore) { self.store = store }
    }
}

/// Owns only input transport. Navigation, tab lifetime and window ownership stay
/// in ExplorerStore/ExplorerApplication. AppKit delivers a captured pointer
/// gesture to its initial view. File-drop reception has a separate shared
/// destination, so receiving a file never enters the tab-detachment gesture.
@MainActor
final class TabDragButton: PointerHoverButton {
    weak var store: ExplorerStore? {
        didSet { if oldValue !== store { dismissContextMenu() } }
    }
    var tabID = UUID() {
        didSet { if oldValue != tabID { dismissContextMenu() } }
    }
    private var contextMenu: ContextMenuPanelController?
    var isActiveTab = false
    private var mouseDownPoint: NSPoint?
    private var dragInProgress = false
    private var dragCancelled = false
    private var sourceWindowFrame: NSRect?
    private var eventMonitor: Any?
    private var hasPushedDragCursor = false
    private var fileDropDestination: FileDragDestination?
    private var fileDropBinding: FileDropBinding?
    private var isFileDropHighlighted = false
    private var ordinaryToolTip: String?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configureFileDrop(store: ExplorerStore, tab: BrowserTab) {
        let updatedToolTip = toolTip
        if self.store !== store {
            clearFileDrop()
            self.store = store
            fileDropDestination = FileDragCoordinator.shared.makeDestination(store: store)
        }
        let binding = store.fileDropBinding(destinationURL: tab.url,
                                             expectedDestinationIdentity: tab.directoryIdentity,
                                             tabID: tab.id)
        if binding != fileDropBinding {
            clearFileDrop()
            fileDropBinding = binding
        }
        ordinaryToolTip = updatedToolTip
        toolTip = updatedToolTip
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { updateFileDrop(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updateFileDrop(sender) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !updateFileDrop(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearFileDrop() }
        guard let binding = currentFileDropBinding() else { return false }
        return fileDropDestination?.accept(sender, binding: binding) ?? false
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearFileDrop() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { clearFileDrop() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clearFileDrop() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissContextMenu() }
        if newWindow == nil { clearFileDrop() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateFileDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let store, let binding = currentFileDropBinding(), let fileDropDestination else {
            clearFileDrop()
            return []
        }
        // Hover activation changes receiverActiveTabID. Derive the next binding
        // directly from the live store rather than waiting for a SwiftUI update.
        if binding != fileDropBinding {
            clearFileDrop()
            fileDropBinding = binding
        }
        let id = binding.tabID
        let hover: FileDropHover? = store.activeTabID == id ? nil
            : FileDropHover(id: "tab:" + id.uuidString) { [weak store] in
                store?.activateTab(id)
            }
        let operation = fileDropDestination.update(info, binding: binding, hover: hover)
        isFileDropHighlighted = !operation.isEmpty || fileDropDestination.isPreparing
        toolTip = fileDropDestination.refusalReason
            ?? (fileDropDestination.isPreparing ? "Checking drop destination…" : "Drop into \(title)")
        needsDisplay = true
        return operation
    }

    private func currentFileDropBinding() -> FileDropBinding? {
        guard let store, let tab = store.tabs.first(where: { $0.id == tabID }) else { return nil }
        return store.fileDropBinding(destinationURL: tab.url,
            expectedDestinationIdentity: tab.directoryIdentity, tabID: tab.id)
    }

    private func clearFileDrop() {
        fileDropDestination?.invalidate()
        isFileDropHighlighted = false
        toolTip = ordinaryToolTip
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { store?.focus.focused(.tabs); needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        if pointerHover.isHovered, isEnabled, !dragInProgress {
            ExplorerHoverPalette.drawControl(in: bounds.insetBy(dx: 1, dy: 2))
        }
        if dragInProgress {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4.pt, yRadius: 4.pt).fill()
        }
        if isFileDropHighlighted {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4.pt, yRadius: 4.pt)
            border.lineWidth = 2
            border.stroke()
        }
        let iconSide = 18.pt
        let locationIcon = store?.tabs.first(where: { $0.id == tabID }).map { ExplorerIcons.locationIcon($0.url) } ?? ExplorerIcons.folder
        locationIcon.draw(in: NSRect(x: 9.pt, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.pt),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        text.draw(in: NSRect(x: 34.pt, y: (bounds.height - 16.pt) / 2, width: max(0, bounds.width - 38.pt), height: 16.pt))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 3.pt, yRadius: 3.pt)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        clearFileDrop()
        endPointerTracking()
        dragCancelled = false
        if event.modifierFlags.contains(.control) {
            showContextMenu(at: convert(event.locationInWindow, from: nil), keyboard: false)
            return
        }
        window?.makeFirstResponder(self)
        store?.activateTab(tabID)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        sourceWindowFrame = window?.frame
        // Keep cancellation active even if another responder consumes Escape.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] incoming in
            if incoming.keyCode == 53 { self?.cancelPointerGesture() }
            return incoming
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragCancelled, let origin = mouseDownPoint, let store,
              store.canDetachTab(tabID) else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Six AppKit points is the explicit Mac product policy, not a Windows measurement.
        guard dragInProgress || hypot(point.x - origin.x, point.y - origin.y) >= 6 else { return }
        if !dragInProgress {
            dragInProgress = true
            NSCursor.closedHand.push()
            hasPushedDragCursor = true
            needsDisplay = true
        }
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = dragInProgress
        let cancelled = dragCancelled
        let sourceFrame = sourceWindowFrame
        let releasePoint = window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        endPointerTracking()
        guard didDrag, let sourceFrame, let releasePoint, store?.canDetachTab(tabID) == true,
              TabDetachDecision.shouldDetach(didRelease: true, cancelled: cancelled,
                                             releasePoint: releasePoint, sourceFrame: sourceFrame) else { return }
        store?.detachTab(tabID, at: releasePoint)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && mouseDownPoint != nil { cancelPointerGesture(); return }
        if event.keyCode == 109 && event.modifierFlags.contains(.shift) {
            showKeyboardContextMenu()
            return
        }
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            store?.activateTab(tabID)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if mouseDownPoint != nil { cancelPointerGesture() }
        else { super.cancelOperation(sender) }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: convert(event.locationInWindow, from: nil), keyboard: false)
    }

    override func accessibilityPerformPress() -> Bool {
        store?.activateTab(tabID)
        return store != nil
    }

    override func accessibilityPerformShowMenu() -> Bool { showKeyboardContextMenu() }

    private func cancelPointerGesture() {
        guard mouseDownPoint != nil else { return }
        dragCancelled = true
        dragInProgress = false
        restoreCursor()
        needsDisplay = true
    }

    func endEventMonitoring() {
        dismissContextMenu()
        endPointerTracking()
        clearFileDrop()
    }

    private func endPointerTracking() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        dragInProgress = false
        mouseDownPoint = nil
        sourceWindowFrame = nil
        restoreCursor()
        needsDisplay = true
    }

    private func restoreCursor() {
        if hasPushedDragCursor { NSCursor.pop(); hasPushedDragCursor = false }
    }

    @discardableResult
    private func showKeyboardContextMenu() -> Bool {
        showContextMenu(at: NSPoint(x: 8, y: bounds.maxY), keyboard: true)
    }

    @discardableResult
    private func showContextMenu(at point: NSPoint, keyboard: Bool) -> Bool {
        dismissContextMenu()
        guard let store, window != nil, store.tabs.contains(where: { $0.id == tabID }) else { return false }
        let target = tabID
        store.cancelPointerRename()
        let presentation = ContextMenuPanelController(
            menu: makeContextMenu(), title: "Tab actions", accessibilityIdentifier: "explorer-tab-context-menu",
            origin: self, point: point, keyboard: keyboard,
            isCurrent: { [weak self, weak store] in
                guard let self, let store else { return false }
                return self.store === store && self.tabID == target && store.tabs.contains { $0.id == target }
            },
            onDismiss: { [weak self] _ in self?.contextMenu = nil })
        contextMenu = presentation
        presentation.show()
        return true
    }

    private func dismissContextMenu() {
        let presentation = contextMenu
        contextMenu = nil
        presentation?.dismiss(reason: .replacement)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addMenuItem("Close tab", id: "close", action: #selector(closeTab(_:)), glyph: .close, to: menu)
        addMenuItem("Close other tabs", id: "close-others", action: #selector(closeOtherTabs(_:)),
                    enabled: (store?.tabs.count ?? 0) > 1, to: menu)
        addMenuItem("Close tabs to the right", id: "close-right", action: #selector(closeRightTabs(_:)),
                    enabled: store?.tabs.last?.id != tabID, to: menu)
        addMenuItem("Duplicate tab", id: "duplicate", action: #selector(duplicateTab(_:)), glyph: .duplicate, to: menu)
        menu.addItem(.separator())
        addMenuItem("Move Tab to New Window", id: "detach", action: #selector(detachTab(_:)),
                    enabled: store?.canDetachTab(tabID) == true, glyph: .newWindow, to: menu)
        return menu
    }

    private func addMenuItem(_ title: String, id: String, action: Selector, enabled: Bool = true,
                             glyph: MenuIcons.Glyph? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.identifier = .init("context-tab-" + id)
        item.target = self
        item.representedObject = tabID
        item.isEnabled = enabled
        item.image = glyph?.image
        menu.addItem(item)
    }

    private func contextTab(for sender: NSMenuItem) -> UUID? {
        guard let id = sender.representedObject as? UUID, id == tabID,
              store?.tabs.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    @objc private func closeTab(_ sender: NSMenuItem) {
        if let id = contextTab(for: sender) { store?.closeTab(id) }
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        guard let id = contextTab(for: sender), let store, store.tabs.count > 1 else { return }
        store.closeOtherTabs(id)
    }

    @objc private func closeRightTabs(_ sender: NSMenuItem) {
        guard let id = contextTab(for: sender), let store, store.tabs.last?.id != id else { return }
        store.closeTabsToRight(id)
    }

    @objc private func duplicateTab(_ sender: NSMenuItem) {
        if let id = contextTab(for: sender) { store?.duplicateTab(id) }
    }

    @objc private func detachTab(_ sender: NSMenuItem) {
        guard let id = contextTab(for: sender), let store, store.canDetachTab(id) else { return }
        store.detachTab(id, at: nil)
    }
}
