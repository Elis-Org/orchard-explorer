import AppKit
import SwiftUI
import ExplorerCore

/// NATIVE-P11 / FR-NAV-005/007/009, UI-NAV-002; EV-0404–0406;
/// AT-NAV-005/007/009, AT-UINAV-002. Completion is a native adaptation.
struct AddressBar: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    @ObservedObject private var address: AddressNavigationModel

    init(store: ExplorerStore) {
        self.store = store
        self.address = store.address
    }

    func makeNSView(context: Context) -> NativeAddressBar { NativeAddressBar(store: store) }
    func updateNSView(_ view: NativeAddressBar, context: Context) { view.scheduleSynchronization() }
    static func dismantleNSView(_ view: NativeAddressBar, coordinator: ()) { view.tearDown(deferModelCancellation: true) }
}

/// AppKit owns the field editor throughout completion. The child panel never
/// becomes key/main, so ordinary text commands stay in the browser field editor.
@MainActor
final class NativeAddressBar: NSView, NSTextFieldDelegate {
    weak var store: ExplorerStore?
    let editor = NSTextField()
    private let crumbs = NSStackView()
    private let icon = NSImageView()
    private let editButton = AddressActionButton()
    private let historyButton = AddressActionButton()
    private(set) var suggestionPanel: AddressSuggestionPanel?
    private struct ContextLocation: Equatable {
        let tab: UUID
        let url: URL
        let searchLocation: String?

        @MainActor init(store: ExplorerStore) {
            tab = store.activeTabID
            url = store.activeTab.url
            searchLocation = store.activeSearch?.locationTitle
        }
    }

    private var contextMenu: ContextMenuPanelController?
    private var contextMenuTookKey = false
    private let contextMenuPanelFactory: (() -> NSPanel)?
    private let isContextMenuApplicationActive: @MainActor () -> Bool
    private weak var priorResponder: NSResponder?
    private weak var attachedWindow: NSWindow?
    private weak var popupAnchor: NSView?
    private var lastFocusRequest: Int
    private var lastLocation: URL?
    private var lastTab: UUID?
    private var lastCurrentHasSubfolders: Bool?
    private var lastSearchLocation: String?
    private var wasEditing = false
    private var needsEditorFocus = false
    private var synchronizationScheduled = false
    private var isTornDown = false
    private var invalidatedPopupRequestID: UUID?
    private var lastCrumbWidth: CGFloat = -1
    private var breadcrumbButtons: [NSButton] = []
    private struct Breadcrumb {
        let url: URL
        let title: String
    }
    private var hiddenBreadcrumbs: [Breadcrumb] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var outsideMonitor: Any?
    private var endingEditing = false
    private var changingEditorText = false
    private var trackingAddressButton = false
    private var renderedRequestID: UUID?
    private var renderedPresentation: AddressNavigationModel.Presentation?

    init(store: ExplorerStore, contextMenuPanelFactory: (() -> NSPanel)? = nil,
         isContextMenuApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.store = store
        self.contextMenuPanelFactory = contextMenuPanelFactory
        self.isContextMenuApplicationActive = isContextMenuApplicationActive
        self.lastFocusRequest = store.addressFocusRequest
        super.init(frame: .zero)
        setAccessibilityIdentifier("address-bar")
        icon.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.pt, weight: .regular)
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12.pt)
        editor.focusRingType = .none
        editor.cell?.usesSingleLineMode = true
        editor.cell?.isScrollable = true
        editor.delegate = self
        editor.isHidden = true
        editor.setAccessibilityLabel("Address bar")
        editor.setAccessibilityIdentifier("address-editor")
        crumbs.orientation = .horizontal
        crumbs.spacing = 2.pt
        crumbs.alignment = .centerY
        configure(editButton, symbol: "pencil", label: "Edit address", action: #selector(editAddress(_:)))
        editButton.toolTip = "Edit address (⌘L)"
        configure(historyButton, symbol: "chevron.down", label: "Recent addresses", action: #selector(showHistory(_:)))
        for view in [icon, crumbs, editor, editButton, historyButton] { addSubview(view) }
        synchronize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32.pt) }

    override func draw(_ dirtyRect: NSRect) {
        NavigationFieldSurface.color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4.pt, yRadius: 4.pt).fill()
    }

    override func layout() {
        super.layout()
        let previousEditorWidth = editor.frame.width
        icon.frame = NSRect(x: 12.pt, y: 8.pt, width: 16.pt, height: 16.pt)
        historyButton.frame = NSRect(x: max(30.pt, bounds.width - 25.pt), y: 3.pt, width: 22.pt, height: 26.pt)
        editButton.frame = NSRect(x: max(30.pt, bounds.width - 49.pt), y: 3.pt, width: 22.pt, height: 26.pt)
        editor.frame = NSRect(x: 36.pt, y: 7.pt, width: max(0, bounds.width - 67.pt), height: 20.pt)
        crumbs.frame = NSRect(x: 34.pt, y: 2.pt, width: max(0, bounds.width - 86.pt), height: 28.pt)
        if lastCrumbWidth != bounds.width {
            lastCrumbWidth = bounds.width
            // Resizing invalidates the displayed anchor, never reopens a popup.
            if suggestionPanel != nil { dismissPopupAfterLayout() }
            rebuildBreadcrumbs()
        }
        if editor.frame.width != previousEditorWidth, editor.frame.width > 0,
           !editor.isHiddenOrHasHiddenAncestor, ownsEditorFocus,
           let text = editor.currentEditor() as? NSTextView {
            text.scrollRangeToVisible(text.selectedRange())
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissContextMenu() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else { tearDown(deferModelCancellation: true); return }
        attachedWindow = window
        isTornDown = false
        scheduleSynchronization()
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearPointerHover()
                    if name == NSWindow.didResignKeyNotification, self.contextMenu?.isPresented == true {
                        self.contextMenuTookKey = true
                        return
                    }
                    if name == NSWindow.willCloseNotification { self.dismissContextMenu() }
                    self.cancelEditing(restoreFocus: false)
                }
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcilePointerHover() }
            })
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.store?.address.isEditing == true else { return }
                    self.cancelEditing(restoreFocus: false)
                }
            })
    }

    /// SwiftUI lifecycle callbacks schedule responder work outside its update
    /// pass: ending a native editor can itself publish focus/model changes.
    func scheduleSynchronization() {
        guard !synchronizationScheduled, !isTornDown else { return }
        synchronizationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synchronizationScheduled = false
            guard !self.isTornDown else { return }
            self.synchronize()
        }
    }

    func synchronize() {
        guard let store, !isTornDown else { return }
        let model = store.address
        let locationChanged = lastLocation != store.activeTab.url || lastTab != store.activeTabID
            || lastSearchLocation != store.activeSearch?.locationTitle
        let childrenChanged = lastCurrentHasSubfolders != currentHasSubfolders
        if locationChanged { contextMenu?.dismiss(reason: .replacement) }
        if locationChanged || childrenChanged {
            if childrenChanged, lastCurrentHasSubfolders != nil,
               case .children(let url) = model.presentation, url == store.activeTab.url {
                model.dismissPopup()
            }
            lastCurrentHasSubfolders = currentHasSubfolders
            lastLocation = store.activeTab.url
            lastTab = store.activeTabID
            lastSearchLocation = store.activeSearch?.locationTitle
            closePanel()
            rebuildBreadcrumbs()
        }
        let startsEditing = model.isEditing && !wasEditing
        let endedOwnedEditing = !model.isEditing && wasEditing && ownsEditorFocus
        wasEditing = model.isEditing
        if !model.isEditing, editor.currentEditor() != nil {
            endingEditing = true
            window?.endEditing(for: editor)
            endingEditing = false
        }
        editor.isHidden = !model.isEditing
        crumbs.isHidden = model.isEditing
        editButton.isHidden = model.isEditing
        editButton.isEnabled = store.canUseAddress
        historyButton.isEnabled = store.canUseAddress
        editor.isEnabled = store.canUseAddress
        for button in addressButtons(in: crumbs) { button.isEnabled = store.canUseAddress }
        if model.isEditing { clearPointerHover() }
        else { reconcilePointerHover() }
        if model.isEditing {
            if editor.currentEditor() == nil, editor.stringValue != model.text { editor.stringValue = model.text }
            let focusRequested = lastFocusRequest != store.addressFocusRequest
            lastFocusRequest = store.addressFocusRequest
            if startsEditing || focusRequested {
                if editor.currentEditor() != nil, editor.stringValue != model.text { replaceEditorText(model.text) }
                needsEditorFocus = true
            }
            if needsEditorFocus { focusEditor(selectAll: true) }
        } else {
            needsEditorFocus = false
            editor.stringValue = BrowsingPresentation.path(store.activeTab.url)
            if endedOwnedEditing { restorePriorResponder() }
        }
        if model.presentation != nil, store.canUseAddress { renderPopup() }
        else { closePanel() }
        updateOutsideMonitor()
    }

    private func configure(_ button: AddressActionButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11.pt, weight: .regular))
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        prepareButton(button)
        button.onContextMenu = { [weak self] event in self?.presentContextMenu(with: event) }
    }

    private func prepareButton(_ button: AddressActionButton) {
        button.isEnabled = store?.canUseAddress == true
        // NSButton may take focus when Full Keyboard Access is enabled. Capture
        // the content/text owner before AppKit begins native mouse tracking.
        button.onMouseDown = { [weak self] in
            self?.capturePriorResponder()
            self?.trackingAddressButton = true
        }
        button.onMouseTrackingEnded = { [weak self] in
            guard let self else { return }
            self.trackingAddressButton = false
            if self.store?.address.isEditing == true, !self.ownsEditorFocus { self.focusEditor(selectAll: false) }
        }
    }

    static func breadcrumbURLs(for url: URL) -> [URL] {
        BrowsingLocation(url: url)?.breadcrumbURLs ?? []
    }

    static func visibleBreadcrumbCount(width: CGFloat, scale: CGFloat = ExplorerScale.factor) -> Int {
        let unit = width / scale
        return unit >= 560 ? 5 : unit >= 350 ? 3 : 1
    }

    /// Titles are presentation only. The committed route still supplies every
    /// action and tooltip; this lexical projection performs no provider I/O.
    private static func breadcrumbPresentation(for url: URL, homeURL: URL) -> (all: [Breadcrumb], preferredStart: Int) {
        let urls = breadcrumbURLs(for: url)
        var all = urls.map { Breadcrumb(url: $0, title: BrowsingPresentation.title($0)) }
        guard let root = OneDriveRetentionService.accountRoot(in: url, homeURL: homeURL),
              let index = urls.firstIndex(where: { $0.path == root.path }) else { return (all, 0) }
        let name = root.lastPathComponent
        let title = name == "OneDrive" ? name : "OneDrive – " + String(name.dropFirst("OneDrive-".count))
        all[index] = Breadcrumb(url: urls[index], title: title)
        return (all, index)
    }

    private var currentHasSubfolders: Bool {
        guard let tab = store?.activeTab, tab.hasLoaded, !tab.isUnavailable else { return false }
        // The committed listing already applies hidden/package/symlink policy.
        // Breadcrumb presentation must not perform another filesystem read.
        return tab.items.contains { $0.isDirectory }
    }

    private func rebuildBreadcrumbs() {
        guard let store else { return }
        for view in crumbs.arrangedSubviews { crumbs.removeArrangedSubview(view); view.removeFromSuperview() }
        breadcrumbButtons = []
        hiddenBreadcrumbs = []
        if let search = store.activeSearch {
            // EV-0345/0349: the location reads “Search Results in ‹folder›”.
            // Editing (⌘L) still starts from the committed folder path.
            let label = NSTextField(labelWithString: search.locationTitle)
            label.font = .systemFont(ofSize: 12.pt)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "Search results in \(search.rootURL.path)"
            label.setAccessibilityLabel(search.locationTitle)
            label.setAccessibilityIdentifier("search-location")
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            crumbs.addArrangedSubview(label)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            crumbs.addArrangedSubview(spacer)
            return
        }
        let route = Self.breadcrumbPresentation(for: store.activeTab.url, homeURL: store.homeURL)
        let all = route.all
        // Prefer the account and its descendants over storage containers. At
        // compact widths the account remains available in the same overflow.
        let count = min(Self.visibleBreadcrumbCount(width: bounds.width), all.count - route.preferredStart)
        hiddenBreadcrumbs = Array(all.dropLast(count))
        if all.count > count {
            let overflow = AddressActionButton(title: "…", target: self, action: #selector(showAncestors(_:)))
            overflow.isBordered = false
            prepareButton(overflow)
            overflow.setAccessibilityLabel("Ancestor folders")
            overflow.font = .systemFont(ofSize: 12.pt)
            overflow.widthAnchor.constraint(equalToConstant: 22.pt).isActive = true
            crumbs.addArrangedSubview(overflow)
        }
        for (index, crumb) in all.suffix(count).enumerated() {
            let url = crumb.url
            let button = AddressActionButton(title: crumb.title,
                                             target: self, action: #selector(navigateBreadcrumb(_:)))
            button.representedURL = url
            prepareButton(button)
            button.isBordered = false
            button.font = .systemFont(ofSize: 12.pt)
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = BrowsingPresentation.path(url)
            button.onContextMenu = { [weak self] event in self?.presentContextMenu(with: event) }
            button.setAccessibilityLabel(button.title)
            // Distinct priorities make compression deterministic: older
            // ancestors truncate first, and a short current name stays whole.
            // Equal ancestor priorities leave multiple valid label widths.
            let compression: NSLayoutConstraint.Priority = url == store.activeTab.url
                ? .defaultHigh : .init(rawValue: 500 + Float(index))
            button.setContentCompressionResistancePriority(compression, for: .horizontal)
            breadcrumbButtons.append(button)
            // An ancestor contains the next segment of the committed route.
            // Only the current segment needs its child-listing availability test.
            var dropdown: AddressActionButton?
            if BrowserPage(url: url) == nil && (url != store.activeTab.url || currentHasSubfolders) {
                let arrow = AddressActionButton()
                arrow.representedURL = url
                configure(arrow, symbol: "chevron.right", label: "Subfolders of \(button.title)", action: #selector(showChildren(_:)))
                arrow.toolTip = "Show subfolders of \(BrowsingPresentation.path(url))"
                arrow.widthAnchor.constraint(equalToConstant: 17.pt).isActive = true
                dropdown = arrow
            }
            let segment = BreadcrumbSegmentView(label: button, disclosure: dropdown)
            segment.setContentCompressionResistancePriority(compression, for: .horizontal)
            crumbs.addArrangedSubview(segment)
            if BrowserPage(url: url) != nil && url != store.activeTab.url {
                let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                separator.contentTintColor = .secondaryLabelColor
                separator.symbolConfiguration = .init(pointSize: 9.pt, weight: .regular)
                separator.setAccessibilityElement(false)
                crumbs.addArrangedSubview(separator)
            }
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        crumbs.addArrangedSubview(spacer)
    }

    @objc private func editAddress(_ sender: Any?) {
        guard let store else { return }
        capturePriorResponder()
        if !store.address.isEditing { store.requestAddressEditing() }
        synchronize()
        if store.address.isEditing, editor.currentEditor() == nil { focusEditor(selectAll: false) }
    }

    private var ownsEditorFocus: Bool {
        editor.currentEditor().map { window?.firstResponder === $0 } ?? false
    }

    private func capturePriorResponder() {
        guard let window, let responder = window.firstResponder else { return }
        let owner: NSResponder
        if let fieldEditor = responder as? NSTextView, let control = fieldEditor.delegate as? NSView { owner = control }
        else { owner = responder }
        if let view = owner as? NSView, view === self || view.isDescendant(of: self) { return }
        // A window is not a useful return target. Keep a captured content owner
        // when a native control has already ended its shared field editor.
        guard owner !== window else { return }
        priorResponder = owner
    }

    private func focusEditor(selectAll: Bool) {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        if editor.currentEditor() == nil { capturePriorResponder() }
        guard window.makeFirstResponder(editor), let text = editor.currentEditor() as? NSTextView else { return }
        needsEditorFocus = false
        text.allowsUndo = true
        if selectAll { text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length)) }
    }

    @objc private func navigateBreadcrumb(_ sender: AddressActionButton) {
        guard let store, store.canUseAddress, let url = sender.representedURL else { return }
        capturePriorResponder()
        dismissPopup()
        restorePriorResponder()
        store.navigateBreadcrumb(to: url)
    }

    @objc private func showChildren(_ sender: AddressActionButton) {
        guard let store, store.canUseAddress, let url = sender.representedURL else { return }
        capturePriorResponder()
        popupAnchor = sender
        store.address.showChildren(of: url, showHidden: store.showHidden)
        synchronize()
        restorePriorResponder(clear: false)
    }

    @objc private func showHistory(_ sender: Any?) {
        guard let store, store.canUseAddress else { return }
        capturePriorResponder()
        popupAnchor = historyButton
        store.address.showHistory()
        synchronize()
        restorePriorResponder(clear: false)
    }

    @objc private func showAncestors(_ sender: NSButton) {
        capturePriorResponder()
        dismissPopup()
        guard let store, store.canUseAddress else { return }
        let menu = ancestorOverflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        restorePriorResponder()
    }

    func ancestorOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        // Use the snapshot which produced the visible suffix, rather than
        // recomputing from potentially newer store state or another width.
        for crumb in hiddenBreadcrumbs {
            let item = NSMenuItem(title: crumb.title,
                                  action: #selector(navigateAncestor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = crumb.url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func navigateAncestor(_ sender: NSMenuItem) {
        guard let store, store.canUseAddress, let url = sender.representedObject as? URL else { return }
        restorePriorResponder()
        store.navigateBreadcrumb(to: url)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { presentContextMenu(with: event) }
        else { editAddress(nil) }
    }

    override func rightMouseDown(with event: NSEvent) { presentContextMenu(with: event) }

    private func presentContextMenu(with event: NSEvent) {
        contextMenu?.dismiss(reason: .replacement)
        guard let store, let window else { return }
        dismissContextSuggestions()
        store.cancelPointerRename()

        let location = ContextLocation(store: store)
        let wasEnabled = store.canUseAddress
        let request = store.address.requestID
        let fieldEditor = ownsEditorFocus ? editor.currentEditor() as? NSTextView : nil
        let selection = fieldEditor?.selectedRanges
        let menu = ContextMenuPanelController(
            menu: addressContextMenu(), title: "Address actions",
            accessibilityIdentifier: "explorer-address-context-menu", origin: self,
            point: convert(event.locationInWindow, from: nil), keyboard: false,
            isCurrent: { [weak self, weak store] in
                guard let self, let store else { return false }
                return !self.isTornDown && self.store === store && ContextLocation(store: store) == location
                    && store.canUseAddress == wasEnabled
            },
            onDismiss: { [weak self, weak fieldEditor, weak window] reason in
                guard let self, self.contextMenu != nil else { return }
                self.contextMenu = nil
                let tookKey = self.contextMenuTookKey
                self.contextMenuTookKey = false
                guard tookKey, let model = self.store?.address, model.isEditing, model.requestID == request else { return }
                switch reason {
                case .keyboard, .command:
                    guard let window, window === self.window, window.isKeyWindow,
                          let fieldEditor, self.editor.currentEditor() === fieldEditor,
                          window.firstResponder === fieldEditor, let selection else { return }
                    if fieldEditor.selectedRanges != selection { fieldEditor.selectedRanges = selection }
                case .outside:
                    // The address click monitor decides whether this press leaves the field.
                    break
                case .deactivated, .replacement:
                    self.cancelEditing(restoreFocus: false)
                }
            },
            panel: contextMenuPanelFactory?(), isApplicationActive: isContextMenuApplicationActive)
        contextMenu = menu
        menu.show()
    }

    private func dismissContextMenu() {
        let menu = contextMenu
        contextMenu = nil
        contextMenuTookKey = false
        menu?.dismiss(reason: .replacement)
    }

    func addressContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let location = store.map { ContextLocation(store: $0) }
        let actions: [(String, String, Selector)] = [
            ("Copy Address", "copy", #selector(copyAddress(_:))),
            ("Copy Address as Text", "copy-text", #selector(copyAddressText(_:))),
            ("Edit Address", "edit", #selector(editContextAddress(_:))),
            ("Delete History", "delete-history", #selector(clearHistory(_:)))
        ]
        for (title, id, selector) in actions {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.identifier = .init("context-address-" + id)
            item.target = self
            item.representedObject = location
            item.isEnabled = store?.canUseAddress == true
            menu.addItem(item)
        }
        return menu
    }

    private func contextStore(for sender: NSMenuItem) -> ExplorerStore? {
        guard let store, store.canUseAddress, let location = sender.representedObject as? ContextLocation,
              ContextLocation(store: store) == location else { return nil }
        return store
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let store = contextStore(for: sender) else { return }
        store.copyAddress(asText: false, to: store.clipboard.pasteboard)
    }

    @objc private func copyAddressText(_ sender: NSMenuItem) {
        guard let store = contextStore(for: sender) else { return }
        store.copyAddress(asText: true, to: store.clipboard.pasteboard)
    }

    @objc private func editContextAddress(_ sender: NSMenuItem) {
        if contextStore(for: sender) != nil { editAddress(sender) }
    }

    @objc private func clearHistory(_ sender: NSMenuItem) { contextStore(for: sender)?.clearAddressHistory() }

    func controlTextDidChange(_ notification: Notification) {
        guard !changingEditorText, let store, store.address.isEditing else { return }
        store.address.updateText(editor.stringValue, showHidden: store.showHidden)
        synchronize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let store, store.address.isEditing else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            guard hasCurrentPopup else { return store.address.presentation != nil }
            if store.address.completeHighlighted(showHidden: store.showHidden) {
                replaceEditorText(store.address.text)
                synchronize()
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if textView.string != store.address.text {
                store.address.updateText(textView.string, showHidden: store.showHidden)
            }
            if hasCurrentPopup, let index = store.address.highlightedIndex,
               let generation = renderedRequestID,
               store.address.suggestion(at: index, requestID: generation) != nil {
                activateSuggestion(index: index, generation: generation)
                return true
            }
            if store.activePage != nil, store.address.text == BrowsingPresentation.path(store.activeTab.url) {
                store.address.cancel()
                synchronize()
                restorePriorResponder()
                return true
            }
            if let url = store.address.submissionURL(relativeTo: store.activeTab.url) {
                let ownedEditor = window?.firstResponder === textView
                store.submitTypedAddress(url)
                synchronize()
                if ownedEditor { restorePriorResponder() }
            } else {
                synchronize()
            }
            return true
        }
        return handlePopupCommand(commandSelector)
    }

    private func replaceEditorText(_ value: String) {
        changingEditorText = true
        defer { changingEditorText = false }
        if let text = editor.currentEditor() as? NSTextView {
            // Use the field editor's native replacement path so completion is undoable.
            let range = NSRange(location: 0, length: (text.string as NSString).length)
            if text.shouldChangeText(in: range, replacementString: value) {
                text.replaceCharacters(in: range, with: value)
                text.didChangeText()
                let selection = NSRange(location: (value as NSString).length, length: 0)
                text.setSelectedRange(selection)
                text.scrollRangeToVisible(selection)
            }
        } else { editor.stringValue = value }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !endingEditing, !trackingAddressButton, contextMenu?.isPresented != true,
              store?.address.isEditing == true else { return }
        // Focus loss cancels the draft; it never submits a destination.
        cancelEditing(restoreFocus: false)
    }

    @discardableResult
    func handlePopupCommand(_ selector: Selector) -> Bool {
        guard let store else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing(restoreFocus: true)
            return true
        }
        guard store.address.presentation != nil else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard hasCurrentPopup else { return true }
            store.address.moveHighlight(by: selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            synchronize()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard hasCurrentPopup else { return true }
            if let index = store.address.highlightedIndex, let generation = renderedRequestID {
                activateSuggestion(index: index, generation: generation)
            }
            return true
        }
        return false
    }

    private var hasCurrentPopup: Bool {
        guard let store, let window, let panel = suggestionPanel else { return false }
        return panel.parent === window && panel.isVisible && renderedRequestID == store.address.requestID
    }

    func activateSuggestion(index: Int, generation: UUID) {
        guard let store, store.canUseAddress, hasCurrentPopup, renderedRequestID == generation,
              generation != invalidatedPopupRequestID,
              let url = store.address.suggestion(at: index, requestID: generation) else { return }
        let children: Bool
        if case .children = renderedPresentation { children = true } else { children = false }
        let shouldRestoreFocus = ownsEditorFocus || store.address.presentation != .completion
        store.address.cancel()
        closePanel()
        if children { store.navigate(to: url) }
        else { store.submitAddress(url) }
        synchronize()
        if shouldRestoreFocus { restorePriorResponder() }
        else { priorResponder = nil }
    }

    func cancelEditing(restoreFocus: Bool, deferModelCancellation: Bool = false) {
        let ownedEditor = ownsEditorFocus
        if deferModelCancellation, let model = store?.address {
            let requestID = model.requestID
            DispatchQueue.main.async { [weak model] in
                guard let model, model.requestID == requestID else { return }
                model.cancel()
            }
        } else { store?.address.cancel() }
        endingEditing = true
        if ownedEditor { window?.endEditing(for: editor) }
        endingEditing = false
        editor.stringValue = store.map { BrowsingPresentation.path($0.activeTab.url) } ?? ""
        wasEditing = false
        needsEditorFocus = false
        editor.isHidden = true
        crumbs.isHidden = false
        editButton.isHidden = false
        closePanel()
        if !deferModelCancellation { updateOutsideMonitor() }
        if restoreFocus, deferModelCancellation {
            let responder = priorResponder
            let returnWindow = window ?? attachedWindow
            priorResponder = nil
            DispatchQueue.main.async { [weak responder, weak returnWindow] in
                guard let responder, let window = returnWindow,
                      window.firstResponder == nil || window.firstResponder === window else { return }
                if let view = responder as? NSView {
                    guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return }
                }
                _ = window.makeFirstResponder(responder)
            }
        } else if restoreFocus { restorePriorResponder() }
        else { priorResponder = nil }
    }

    private func restorePriorResponder(clear: Bool = true) {
        defer { if clear { priorResponder = nil } }
        guard let responder = priorResponder, let window = window ?? attachedWindow else { return }
        if let view = responder as? NSView {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return }
        } else if responder !== window { return }
        if let current = window.firstResponder, current !== window, current !== responder {
            let owner = (current as? NSTextView)?.delegate as? NSView ?? current as? NSView
            guard owner === responder || owner === self || owner?.isDescendant(of: self) == true else { return }
        }
        _ = window.makeFirstResponder(responder)
    }

    private func dismissPopup() { store?.address.dismissPopup(); closePanel(); updateOutsideMonitor() }

    private func dismissContextSuggestions() {
        if store?.address.presentation != nil || suggestionPanel != nil { dismissPopup() }
    }

    private func dismissPopupAfterLayout() {
        guard let model = store?.address else { closePanel(); return }
        let requestID = model.requestID
        invalidatedPopupRequestID = requestID
        closePanel()
        DispatchQueue.main.async { [weak model] in
            guard let model, model.requestID == requestID else { return }
            model.dismissPopup()
        }
    }

    private func renderPopup() {
        guard let store, let window, let presentation = store.address.presentation,
              store.address.requestID != invalidatedPopupRequestID else { return }
        let anchor = presentation == .completion ? editor : (popupAnchor ?? self)
        guard !isHiddenOrHasHiddenAncestor, anchor.window === window else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let leading = presentation == .completion ? rect.minX : anchorRect.minX
        guard let screen = window.screen?.visibleFrame,
              let frame = AddressSuggestionPanel.placementFrame(addressFrame: rect, preferredLeadingX: leading,
                  ownerFrame: window.frame, visibleScreen: screen,
                  preferredHeight: AddressSuggestionPanel.preferredHeight(suggestionCount: store.address.suggestions.count,
                                                                         scale: ExplorerScale.factor),
                  scale: ExplorerScale.factor) else {
            closePanel()
            return
        }
        let panel: AddressSuggestionPanel
        if let existing = suggestionPanel { panel = existing }
        else {
            panel = AddressSuggestionPanel()
            panel.onActivate = { [weak self] row, generation in self?.activateSuggestion(index: row, generation: generation) }
            panel.onHighlight = { [weak self] row, generation in
                guard let self, let model = self.store?.address, model.requestID == generation else { return }
                if let row, model.suggestion(at: row, requestID: generation) == nil { return }
                model.highlight(row)
            }
            suggestionPanel = panel
            window.addChildWindow(panel, ordered: .above)
        }
        renderedRequestID = store.address.requestID
        renderedPresentation = presentation
        panel.update(model: store.address)
        panel.setFrame(frame, display: true)
        panel.fitColumn()
        panel.orderFront(nil)
    }

    private func closePanel() {
        if let panel = suggestionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.onActivate = nil
            panel.onHighlight = nil
        }
        suggestionPanel = nil
        renderedRequestID = nil
        renderedPresentation = nil
    }

    private func updateOutsideMonitor() {
        let needed = store?.address.isEditing == true || suggestionPanel != nil
        if needed, outsideMonitor == nil {
            outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    if event.type == .keyDown {
                        guard event.window === self.window,
                              let model = self.store?.address, model.presentation != nil, !model.isEditing,
                              (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                        let selector: Selector?
                        switch event.keyCode {
                        case 125: selector = #selector(NSResponder.moveDown(_:))
                        case 126: selector = #selector(NSResponder.moveUp(_:))
                        case 36, 76: selector = #selector(NSResponder.insertNewline(_:))
                        case 53: selector = #selector(NSResponder.cancelOperation(_:))
                        default: selector = nil
                        }
                        if let selector { return self.handlePopupCommand(selector) }
                        // Let native Tab/type selection continue after closing the popup.
                        self.cancelEditing(restoreFocus: false)
                        return false
                    }
                    if event.window === self.suggestionPanel || self.contextMenu?.owns(event.window) == true {
                        return false
                    }
                    // Menu-bar clicks have no content window. Preserve the native
                    // text responder so Edit menu Cut/Copy/Paste remains usable.
                    guard event.window != nil else { return false }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if event.window !== self.window || !self.bounds.contains(point) {
                        self.cancelEditing(restoreFocus: false)
                    } else if event.type == .rightMouseDown { self.dismissContextSuggestions() }
                    return false
                }
                return consumed ? nil : event
            }
        } else if !needed, let monitor = outsideMonitor { NSEvent.removeMonitor(monitor); outsideMonitor = nil }
    }

    private func removeWindowObservers() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    private func addressButtons(in view: NSView) -> [AddressActionButton] {
        view.subviews.flatMap { child in
            (child as? AddressActionButton).map { [$0] } ?? addressButtons(in: child)
        }
    }

    private func clearPointerHover() {
        addressButtons(in: self).forEach { $0.clearPointerHover() }
    }

    private func reconcilePointerHover() {
        addressButtons(in: self).forEach { $0.reconcilePointerHover() }
    }

    func tearDown(deferModelCancellation: Bool = false) {
        isTornDown = true
        dismissContextMenu()
        clearPointerHover()
        cancelEditing(restoreFocus: ownsEditorFocus, deferModelCancellation: deferModelCancellation)
        removeWindowObservers()
        if let monitor = outsideMonitor { NSEvent.removeMonitor(monitor); outsideMonitor = nil }
    }
}

@MainActor
final class AddressActionButton: NSButton {
    var representedURL: URL?
    var onMouseDown: (() -> Void)?
    var onMouseTrackingEnded: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { clearPointerHover() }
            else if !oldValue { reconcilePointerHover() }
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { clearPointerHover() }
            else if oldValue { reconcilePointerHover() }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        // With modern nonclipping NSViews, visibleRect can extend well outside
        // this button. inVisibleRect would ignore an explicit tracking rect and
        // make unrelated address controls track the same broad window region.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if superview is BreadcrumbSegmentView { options.insert(.mouseMoved) }
        let area = NSTrackingArea(rect: pointerHoverRect, options: options, owner: self, userInfo: nil)
        pointerTrackingArea = area
        addTrackingArea(area)
        reconcilePointerHover()
    }

    func reconcilePointerHover() {
        // Also reconcile stationary pointers after layout/visibility changes.
        guard let window, window.isKeyWindow, window.isVisible else { clearPointerHover(); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setPointerInside(isEnabled && !isHiddenOrHasHiddenAncestor && pointerHoverRect.contains(point))
    }

    private var pointerHoverRect: NSRect {
        let clipped = bounds.intersection(visibleRect)
        return clipped.isNull ? .zero : clipped
    }

    override func mouseEntered(with event: NSEvent) {
        guard let pointerTrackingArea, event.trackingArea === pointerTrackingArea else {
            // NSButton and tooltips own other tracking areas. Preserve their
            // native handling without treating them as our custom hover input.
            super.mouseEntered(with: event)
            return
        }
        guard let window, event.window === window else { return }
        // Tracking notifications may have queued before a popup or a layout
        // rebuild. Read the live pointer instead of trusting old event points.
        reconcilePointerHover()
    }

    override func mouseExited(with event: NSEvent) {
        guard let pointerTrackingArea, event.trackingArea === pointerTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        guard let window, event.window === window else { return }
        reconcilePointerHover()
    }

    override func mouseMoved(with event: NSEvent) {
        guard superview is BreadcrumbSegmentView else { super.mouseMoved(with: event); return }
        guard let window, event.window === window else { return }
        // A delivered move can recover a missed boundary notification without
        // moving focus or enabling window-wide mouse movement. Mouse-move
        // events do not support NSEvent.trackingArea; use current owned bounds.
        reconcilePointerHover()
    }

    func clearPointerHover() { setPointerInside(false) }

    private func setPointerInside(_ value: Bool) {
        guard isPointerInside != value else { return }
        isPointerInside = value
        (superview as? BreadcrumbSegmentView)?.updateHover(for: self, isInside: value)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPointerHover()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        (superview as? BreadcrumbSegmentView)?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPointerInside, isEnabled, !(superview is BreadcrumbSegmentView) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3.pt, yRadius: 3.pt).fill()
        }
        super.draw(dirtyRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onContextMenu { onContextMenu(event) }
        else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onContextMenu {
            onContextMenu(event)
            return
        }
        onMouseDown?()
        defer { onMouseTrackingEnded?() }
        super.mouseDown(with: event)
    }
}
