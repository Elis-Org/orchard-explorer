import AppKit
import Combine
import ExplorerCore

@MainActor
class FileActionsPanel: NSPanel {
    var routeKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if routeKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        routeKey?(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class MenuFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private struct ContextBodyLayout {
    let hasIconColumn: Bool
    let trailingWidth: CGFloat

    private var inset: CGFloat { 8.pt }
    private var markerWidth: CGFloat { 10.pt }
    private var markerGap: CGFloat { 4.pt }
    private var iconWidth: CGFloat { hasIconColumn ? MenuIcons.side.pt : 0 }
    private var iconGap: CGFloat { hasIconColumn ? 6.pt : 0 }
    private var trailingGap: CGFloat { trailingWidth > 0 ? 8.pt : 0 }
    var reservedWidth: CGFloat {
        2 * inset + markerWidth + markerGap + iconWidth + iconGap + trailingWidth + trailingGap
    }

    func regions(in bounds: NSRect) -> (marker: NSRect, icon: NSRect, title: NSRect, trailing: NSRect) {
        var left = min(bounds.maxX, bounds.minX + inset)
        func take(_ width: CGFloat, gap: CGFloat) -> NSRect {
            let size = min(width, max(0, bounds.maxX - left))
            let result = NSRect(x: left, y: bounds.minY, width: size, height: bounds.height)
            left = min(bounds.maxX, result.maxX + gap)
            return result
        }
        let marker = take(markerWidth, gap: markerGap)
        let icon = take(iconWidth, gap: iconGap)
        let right = max(left, bounds.maxX - inset)
        let trailingStart = max(left, right - trailingWidth)
        let titleEnd = max(left, trailingStart - trailingGap)
        return (marker, icon, NSRect(x: left, y: bounds.minY, width: titleEnd - left, height: bounds.height),
                NSRect(x: trailingStart, y: bounds.minY, width: right - trailingStart, height: bounds.height))
    }
}

@MainActor
private final class ContextMenuButtonCell: NSButtonCell {
    var bodyLayout: ContextBodyLayout?
    // Keep native cell drawing: custom drawing overrides changed menu ink in
    // observed AppKit rendering. These regions align content without replacing it.
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        if imagePosition == .imageAbove { return actionRowRegions(in: rect).title }
        let title = super.titleRect(forBounds: rect)
        guard let bodyLayout else { return title }
        let region = bodyLayout.regions(in: rect).title
        let y = min(rect.maxY, max(rect.minY, title.minY))
        return NSRect(x: region.minX, y: y, width: region.width,
                      height: max(0, min(rect.maxY - y, title.height)))
    }
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        if imagePosition == .imageAbove { return actionRowRegions(in: rect).image }
        guard let bodyLayout else { return super.imageRect(forBounds: rect) }
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let slot = bodyLayout.regions(in: rect).icon
        let scale = min(1, slot.width / image.size.width, slot.height / image.size.height,
                        MenuIcons.side.pt / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    private func actionRowRegions(in rect: NSRect) -> (image: NSRect, title: NSRect) {
        let textFont = font ?? .systemFont(ofSize: 12.pt)
        let titleHeight = min(rect.height, ceil(textFont.ascender - textFont.descender + textFont.leading))
        let gap = min(4.pt, max(0, rect.height - titleHeight))
        let imageSide = max(0, min(24.pt, rect.width, rect.height - titleHeight - gap))
        let contentHeight = imageSide + gap + titleHeight
        let start = rect.midY - contentHeight / 2
        let flipped = controlView?.isFlipped == true
        let image = NSRect(x: rect.midX - imageSide / 2,
            y: flipped ? start : start + titleHeight + gap, width: imageSide, height: imageSide)
        let title = NSRect(x: rect.minX + 2.pt,
            y: flipped ? start + imageSide + gap : start,
            width: max(0, rect.width - 4.pt), height: titleHeight)
        return (image, title)
    }
}

/// Accessibility-only grouping of existing controls; their view hierarchy,
/// hit testing, tracking and target/action dispatch remain unchanged.
@MainActor
private final class ContextChoiceGroup: NSAccessibilityElement {
    override func accessibilityFrame() -> NSRect {
        let choices = accessibilityChildren() as? [ContextActionButton] ?? []
        return choices.reduce(NSRect.null) { $0.union($1.accessibilityFrame()) }
    }
}

@MainActor
private final class ContextDecorationLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A real accessible button; decorative cell contents are not additional AX stops.
@MainActor
final class ContextActionButton: NSButton {
    var invoke: (() -> Bool)?
    var pointerEntered: (() -> Void)?
    var pointerExited: (() -> Void)?
    var pointerMoved: (() -> Void)?
    var routeKey: ((NSEvent) -> Bool)?
    var isPointerContextActive: (() -> Bool)?
    var hasSubmenu = false
    var keyboardFocused = false { didSet { updateFeedback() } }
    var commandHighlighted = false { didSet { updateFeedback() } }
    private var area: NSTrackingArea?
    private var markerLabel: NSTextField?
    private var trailingLabel: NSTextField?
    private(set) var pointerInside = false

    override var acceptsFirstResponder: Bool { true }
    override var isEnabled: Bool {
        didSet {
            markerLabel?.textColor = decorationColor
            trailingLabel?.textColor = decorationColor
            reconcilePointer(); updateFeedback()
        }
    }
    override var isHidden: Bool { didSet { reconcilePointer() } }

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        cell = ContextMenuButtonCell(textCell: title)
        self.title = title
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(title)
        setAccessibilityTitle(title)
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
    fileprivate func configureBody(hasIconColumn: Bool, marker: String, trailing: String) {
        markerLabel = decoration(marker, alignment: .center)
        trailingLabel = decoration(trailing, alignment: .right)
        (cell as? ContextMenuButtonCell)?.bodyLayout = ContextBodyLayout(hasIconColumn: hasIconColumn,
            trailingWidth: Self.decorationWidth(trailing, font: font ?? .systemFont(ofSize: 12.pt)))
        needsLayout = true
    }
    fileprivate static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    fileprivate static func decorationWidth(_ text: String, font: NSFont) -> CGFloat {
        text.isEmpty ? 0 : textWidth(text, font: font) + 4.pt
    }
    private var decorationColor: NSColor { isEnabled ? .secondaryLabelColor : .disabledControlTextColor }
    private func decoration(_ text: String, alignment: NSTextAlignment) -> NSTextField? {
        guard !text.isEmpty else { return nil }
        let label = ContextDecorationLabel(labelWithString: text)
        label.font = font
        label.alignment = alignment
        label.textColor = decorationColor
        label.setAccessibilityElement(false)
        addSubview(label)
        return label
    }
    override func layout() {
        super.layout()
        guard let layout = (cell as? ContextMenuButtonCell)?.bodyLayout else { return }
        let regions = layout.regions(in: bounds)
        func place(_ label: NSTextField?, in region: NSRect) {
            guard let label else { return }
            let height = min(region.height, label.intrinsicContentSize.height)
            label.frame = NSRect(x: region.minX, y: region.midY - height / 2, width: region.width, height: height)
        }
        place(markerLabel, in: regions.marker)
        place(trailingLabel, in: regions.trailing)
    }
    @objc private func pressed() { _ = invoke?() }
    override func accessibilityPerformPress() -> Bool { isEnabled && (invoke?() ?? false) }
    override func accessibilityPerformShowMenu() -> Bool { hasSubmenu && accessibilityPerformPress() }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformShowMenu) { return hasSubmenu }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityFrame() -> NSRect {
        guard imagePosition == .imageAbove else { return super.accessibilityFrame() }
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    override func keyDown(with event: NSEvent) {
        if routeKey?(event) != true { super.keyDown(with: event) }
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateFeedback() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: pointerRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
        area = tracking
        addTrackingArea(tracking)
        reconcilePointer()
    }
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === area else { super.mouseEntered(with: event); return }
        guard let window, event.window === window else { return }
        reconcilePointer()
    }
    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === area else { super.mouseExited(with: event); return }
        guard let window, event.window === window else { return }
        reconcilePointer()
    }
    override func mouseMoved(with event: NSEvent) {
        guard let window, event.window === window else { return }
        let wasInside = pointerInside
        reconcilePointer()
        if wasInside && pointerInside { pointerMoved?() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setPointerInside(false)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFeedback()
    }
    private var pointerRect: NSRect {
        let rect = bounds.intersection(visibleRect)
        return rect.isNull ? .zero : rect
    }
    private func reconcilePointer() {
        guard let window, (isPointerContextActive?() ?? window.isKeyWindow), window.isVisible, isEnabled,
              !isHiddenOrHasHiddenAncestor else { setPointerInside(false); return }
        setPointerInside(pointerRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
    private func setPointerInside(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        updateFeedback()
        if inside { pointerEntered?() } else { pointerExited?() }
    }
    private func updateFeedback() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let highlighted = isEnabled && (pointerInside || commandHighlighted)
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(isEnabled && isHighlighted ? 0.14 : (highlighted ? 0.07 : 0)).cgColor
            layer.cornerRadius = 4.pt
            layer.borderWidth = isEnabled && keyboardFocused ? 2 : 0
            layer.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }
}

@MainActor
private final class MenuScrollView: NSScrollView {
    override func tile() {
        super.tile()
        synchronizeDocumentWidth()
    }

    func synchronizeDocumentWidth() {
        guard let documentView, documentView.frame.width != contentSize.width else { return }
        documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
    }
}

@MainActor
private final class ContextMenuSurface {
    let panel: NSPanel
    let menu: NSMenu
    let depth: Int
    let scroll = MenuScrollView()
    var observations: [NSObjectProtocol] = []

    init(panel: NSPanel, menu: NSMenu, depth: Int) {
        self.panel = panel; self.menu = menu; self.depth = depth
    }
}

/// One invocation owns the root and independent submenu panels. Ancestor
/// controls and frames survive child changes without AppKit menu tracking.
@MainActor
class ContextMenuPanelController: NSObject {
    enum DismissReason { case keyboard, outside, deactivated, replacement, command }
    fileprivate weak var origin: NSView?
    fileprivate weak var originWindow: NSWindow?
    fileprivate weak var originResponder: NSResponder?
    fileprivate let originPoint: NSPoint
    let navigation: ContextMenuNavigation
    private let title: String
    private let accessibilityIdentifier: String
    private let panel: NSPanel
    private let panelFactory: @MainActor () -> NSPanel
    private let isApplicationActive: @MainActor () -> Bool
    private let isCurrent: () -> Bool
    private var onDismiss: ((DismissReason) -> Void)?
    private var buttons: [(NSMenuItem, ContextActionButton, Int)] = []
    private var observations: [NSObjectProtocol] = []
    private var outsideMonitor: Any?
    private var submenuWork: DispatchWorkItem?
    private(set) var isPresented = false
    private var finished = false
    private var keyboardFocus: Bool
    private var keyboardPointerScreen: NSPoint?
    private var surfaces: [ContextMenuSurface] = []
    private var updatingPresentation = false

    convenience init(menu: NSMenu, title: String, accessibilityIdentifier: String,
                     origin: NSView, point: NSPoint, keyboard: Bool,
                     isCurrent: @escaping () -> Bool = { true },
                     onDismiss: ((DismissReason) -> Void)? = nil, panel: NSPanel? = nil,
                     panelFactory: @escaping @MainActor () -> NSPanel = {
                         FileActionsPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                     }, isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.init(navigation: ContextMenuNavigation(menu: menu, keyboard: keyboard), title: title,
                  accessibilityIdentifier: accessibilityIdentifier, origin: origin, point: point, keyboard: keyboard,
                  isCurrent: isCurrent, onDismiss: onDismiss, panel: panel, panelFactory: panelFactory,
                  isApplicationActive: isApplicationActive)
    }

    fileprivate init(navigation: ContextMenuNavigation, title: String, accessibilityIdentifier: String,
                     origin: NSView, point: NSPoint, keyboard: Bool, isCurrent: @escaping () -> Bool,
                     onDismiss: ((DismissReason) -> Void)?, panel: NSPanel?,
                     panelFactory: @escaping @MainActor () -> NSPanel,
                     isApplicationActive: @escaping @MainActor () -> Bool) {
        self.navigation = navigation
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.origin = origin
        originWindow = origin.window
        originResponder = origin.window?.firstResponder
        originPoint = point
        keyboardFocus = keyboard
        self.panelFactory = panelFactory
        self.panel = panel ?? panelFactory()
        self.isApplicationActive = isApplicationActive
        self.isCurrent = isCurrent
        self.onDismiss = onDismiss
        super.init()
        configure(self.panel, depth: 0)
    }

    fileprivate var fixedRootWidth: CGFloat? { nil }

    private var liveOriginWindow: NSWindow? {
        guard let origin, let window = originWindow, origin.window === window,
              window.isVisible, !origin.isHiddenOrHasHiddenAncestor, isCurrent() else { return nil }
        return window
    }

    private var currentCommandWindow: NSWindow? {
        guard isApplicationActive(), let window = liveOriginWindow, window.isMainWindow else { return nil }
        return window
    }

    fileprivate func didShow() {}

    private func isCurrentCommand(_ item: NSMenuItem) -> Bool {
        guard item.isEnabled, !item.isHidden, !item.isSeparatorItem, item.submenu == nil,
              var menu = item.menu else { return false }
        while menu !== navigation.root {
            guard let parent = menu.supermenu, parent.items.contains(where: {
                $0.submenu === menu && $0.isEnabled && !$0.isHidden
            }) else { return false }
            menu = parent
        }
        return true
    }

    fileprivate func activateCommand(_ item: NSMenuItem) -> Bool {
        guard isPresented, surfaces.contains(where: { $0.panel.isKeyWindow }),
              let window = currentCommandWindow, isCurrentCommand(item),
              let action = item.action, let target = item.target else { return false }
        dismiss(reason: .command)
        guard currentCommandWindow === window, window.isKeyWindow, isCurrentCommand(item),
              item.action == action, item.target === target else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    fileprivate func shouldConsumeWithoutActivation(_ item: NSMenuItem, event: NSEvent) -> Bool { false }

    private func configure(_ panel: NSPanel, depth: Int) {
        panel.title = title
        let root = accessibilityIdentifier
        let stem = root.hasSuffix("-menu") ? String(root.dropLast("-menu".count)) : root
        panel.setAccessibilityIdentifier(depth == 0 ? root : "\(stem)-submenu-\(depth)")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        (panel as? FileActionsPanel)?.routeKey = { [weak self, weak panel] event in
            guard let self, self.owns(panel) else { return false }
            return self.handleKey(event)
        }
    }

    func show() {
        guard !isPresented, !finished else { return }
        guard liveOriginWindow != nil, !navigation.bodyItems(at: 0).isEmpty || !navigation.rowItems.isEmpty else {
            dismiss(reason: .replacement)
            return
        }
        if !isApplicationActive() {
            // An explicit invocation may need asynchronous app activation.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in self?.showOwnedPanel() }
        } else {
            showOwnedPanel()
        }
    }

    private func showOwnedPanel() {
        guard !isPresented, !finished else { return }
        guard isApplicationActive(), let window = liveOriginWindow else { dismiss(reason: .replacement); return }
        // Acquire the captured origin before the non-main panel becomes key.
        window.makeKeyAndOrderFront(nil)
        guard !finished, liveOriginWindow === window, window.isMainWindow, window.isKeyWindow else {
            dismiss(reason: .replacement)
            return
        }
        isPresented = true
        if keyboardFocus { claimKeyboardFocus() }
        rebuild()
        panel.makeKeyAndOrderFront(nil)
        guard isPresented else { return }
        guard panel.isVisible, panel.isKeyWindow else { dismiss(reason: .replacement); return }
        updateFocus()
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, !self.owns(event.window) else { return }
                self.dismiss(reason: .outside)
            }
            return event
        }
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(reason: .deactivated) }
        })
        observations.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(reason: .replacement) }
        })
        didShow()
    }

    func dismiss(reason: DismissReason) {
        guard !finished else { return }
        finished = true
        let ownedKey = surfaces.first { $0.panel.isKeyWindow }?.panel
        isPresented = false
        submenuWork?.cancel(); submenuWork = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        observations.forEach { NotificationCenter.default.removeObserver($0) }; observations.removeAll()
        closeSurfaces(from: 0)
        restoreFocusAfterDismissal(reason, ownedKey: ownedKey)
        let callback = onDismiss
        onDismiss = nil
        callback?(reason)
    }

    fileprivate func restoreFocusAfterDismissal(_ reason: DismissReason, ownedKey: NSWindow?) {
        guard let ownedKey, reason == .keyboard || reason == .command,
              let window = currentCommandWindow,
              NSApp.keyWindow == nil || NSApp.keyWindow === window || NSApp.keyWindow === ownedKey else { return }
        if !window.isKeyWindow { window.makeKey() }
        guard reason == .keyboard, window.isKeyWindow,
              let responder = originResponder as? NSView, responder.window === window,
              !responder.isHiddenOrHasHiddenAncestor, responder.acceptsFirstResponder,
              window.firstResponder == nil || window.firstResponder === window else { return }
        _ = window.makeFirstResponder(responder)
    }

    private func makeButton(_ item: NSMenuItem, row: Bool, column: Int, hasIconColumn: Bool = false) -> ContextActionButton {
        let title = row ? actionRowTitle(for: item) : item.title
        let button = ContextActionButton(title: title, identifier: item.identifier?.rawValue ?? "context-command")
        button.font = .systemFont(ofSize: 12.pt)
        button.isEnabled = item.isEnabled
        button.alignment = row ? .center : .left
        if row {
            styleActionRowButton(button, item: item)
        } else {
            let radio = isRadioChoice(item)
            let marker = item.state == .on ? (radio ? "•" : "✓") : ""
            button.configureBody(hasIconColumn: hasIconColumn, marker: marker, trailing: Self.trailingText(for: item))
            button.setAccessibilityLabel(title)
            button.setAccessibilityIdentifier(accessibilityIdentifier(for: item))
            if item.submenu != nil {
                button.hasSubmenu = true
                button.setAccessibilityRole(.popUpButton)
                button.setAccessibilityExpanded(navigation.parents.contains(item))
            } else if radio {
                // These are mutually exclusive choices, not file selection or
                // transient keyboard focus. Preserve the canonical check state.
                button.setAccessibilityRole(.radioButton)
                button.setAccessibilityValue(NSNumber(value: item.state.rawValue))
            }
            button.image = item.image
            button.imagePosition = item.image == nil ? .noImage : .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = item.toolTip ?? title
            button.setAccessibilityHelp(item.toolTip)
        }
        button.invoke = { [weak self, weak item, weak button] in
            guard let self, let item, let button, self.isLive(button, item: item, column: column) else { return false }
            if item.submenu != nil {
                self.claimKeyboardFocus()
                guard self.navigation.openSubmenu(item) else { return false }
                self.rebuild(); self.updateFocus(); return true
            }
            return self.activateCommand(item)
        }
        button.routeKey = { [weak self, weak item, weak button] event in
            guard let self, let item, let button, self.isLive(button, item: item, column: column) else { return false }
            return self.handleKey(event)
        }
        button.isPointerContextActive = { [weak self, weak button] in
            guard let self, let button else { return false }
            return self.isPresented && self.isApplicationActive() && self.owns(button.window)
                && self.surfaces.contains { $0.panel.isKeyWindow }
        }
        button.pointerEntered = { [weak self, weak item, weak button] in
            // Tracking-area installation/replacement may synchronously reconcile
            // the pointer. Do not rebuild AppKit's view tree inside that callback.
            DispatchQueue.main.async {
                guard let self, let item, let button, self.isLive(button, item: item, column: column),
                      button.pointerInside,
                      self.claimPointerFocusIfMoved() else { return }
                self.submenuWork?.cancel()
                let previousCount = self.navigation.parents.count
                self.navigation.hover(item)
                if previousCount != self.navigation.parents.count { self.rebuild() }
                self.updateFocus()
                if item.submenu != nil, !self.navigation.parents.contains(item) {
                    let work = DispatchWorkItem { [weak self, weak item, weak button] in
                        guard let self, let item, let button, self.isLive(button, item: item, column: column),
                              self.navigation.focused === item,
                              !self.navigation.parents.contains(item) else { return }
                        if self.navigation.openSubmenu(item, focusChild: false) { self.rebuild(); self.updateFocus() }
                    }
                    self.submenuWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                }
            }
        }
        button.pointerMoved = { [weak self, weak button] in
            // A new enter transition is not required when the pointer moves
            // within the same parent after keyboard navigation opened a child.
            guard self?.keyboardFocus == true else { return }
            button?.pointerEntered?()
        }
        button.pointerExited = { [weak self, weak item, weak button] in
            DispatchQueue.main.async {
                guard let self, let item, let button, self.isLive(button, item: item, column: column),
                      !button.pointerInside,
                      self.claimPointerFocusIfMoved() else { return }
                self.navigation.clearHover(item)
                self.updateFocus()
            }
        }
        buttons.append((item, button, column))
        return button
    }

    fileprivate func actionRowTitle(for item: NSMenuItem) -> String { item.title }
    fileprivate func styleActionRowButton(_ button: ContextActionButton, item: NSMenuItem) {}
    fileprivate func isRadioChoice(_ item: NSMenuItem) -> Bool { false }

    fileprivate func accessibilityIdentifier(for item: NSMenuItem) -> String {
        item.identifier?.rawValue ?? "context-command"
    }

    fileprivate func groupBodyAccessibility(_ body: NSView, parent: NSMenuItem,
                                            choices: [(NSMenuItem, ContextActionButton)]) {}

    private static func shortcutText(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        let modifierSymbols: [(NSEvent.ModifierFlags, String)] =
            [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        for (flag, symbol) in modifierSymbols {
            if modifiers.contains(flag) { text += symbol }
        }
        if let scalar = item.keyEquivalent.unicodeScalars.first, item.keyEquivalent.unicodeScalars.count == 1 {
            if scalar.value >= UInt32(NSF1FunctionKey), scalar.value <= UInt32(NSF35FunctionKey) {
                return text + "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
            }
            let glyphs: [UInt32: String] = [0x08: "⌫", 0x7f: "⌫", 0x09: "⇥", 0x0d: "↩", 0x1b: "⎋",
                UInt32(NSDeleteFunctionKey): "⌦", UInt32(NSLeftArrowFunctionKey): "←",
                UInt32(NSRightArrowFunctionKey): "→", UInt32(NSUpArrowFunctionKey): "↑", UInt32(NSDownArrowFunctionKey): "↓"]
            if let glyph = glyphs[scalar.value] { return text + glyph }
        }
        return text + item.keyEquivalent.uppercased()
    }

    private static func trailingText(for item: NSMenuItem) -> String {
        item.submenu == nil ? shortcutText(for: item) : "›"
    }

    private var pointerScreen: NSPoint {
        panel.convertPoint(toScreen: panel.mouseLocationOutsideOfEventStream)
    }

    private func claimKeyboardFocus() {
        keyboardFocus = true
        keyboardPointerScreen = pointerScreen
    }

    private func claimPointerFocusIfMoved() -> Bool {
        // Tracking replacement, clipping and panel placement can change which
        // button contains a stationary pointer. Paint may reconcile, but that
        // geometry change is not a request to abandon keyboard navigation.
        guard !keyboardFocus || pointerScreen != keyboardPointerScreen else { return false }
        keyboardFocus = false
        keyboardPointerScreen = nil
        return true
    }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return surfaces.contains { $0.panel === window }
    }

    private func isLive(_ button: ContextActionButton, item: NSMenuItem, column: Int) -> Bool {
        isPresented && surfaces.indices.contains(column) && button.window === surfaces[column].panel
            && surfaces[column].panel.isVisible && !button.isHiddenOrHasHiddenAncestor
            && buttons.contains { $0.0 === item && $0.1 === button && $0.2 == column }
    }

    private func availableFrame(at anchor: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? originWindow?.screen ?? NSScreen.main
        return (screen?.visibleFrame ?? originWindow?.frame ?? .zero).insetBy(dx: 8, dy: 8)
    }

    private func fittingWidth(for items: [NSMenuItem]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.pt)
        let hasIconColumn = items.contains { $0.image != nil }
        let widest = items.filter { !$0.isSeparatorItem }.map { item -> CGFloat in
            let layout = ContextBodyLayout(hasIconColumn: hasIconColumn,
                trailingWidth: ContextActionButton.decorationWidth(Self.trailingText(for: item), font: font))
            return ContextActionButton.textWidth(item.title, font: font) + layout.reservedWidth
        }.max() ?? 0
        return max(220, ceil(widest + 12.pt))
    }

    private func closeSurfaces(from depth: Int) {
        guard surfaces.indices.contains(depth) else { return }
        let removed = Array(surfaces.dropFirst(depth))
        let losesKey = removed.contains { $0.panel.isKeyWindow }
        surfaces.removeSubrange(depth...)
        buttons.removeAll { $0.2 >= depth }
        for surface in removed.reversed() {
            surface.observations.forEach { NotificationCenter.default.removeObserver($0) }
            surface.observations.removeAll()
            surface.panel.parent?.removeChildWindow(surface.panel)
            surface.panel.orderOut(nil)
            surface.panel.close()
            surface.panel.contentView = nil
        }
        if isPresented, losesKey, isApplicationActive() { surfaces.last?.panel.makeKeyAndOrderFront(nil) }
    }

    private func observe(_ surface: ContextMenuSurface) {
        let center = NotificationCenter.default
        surface.observations.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
            object: surface.panel, queue: .main) { [weak self] _ in
            // A key transfer to another owned panel is internal to this session.
            DispatchQueue.main.async {
                guard let self, self.isPresented, !self.updatingPresentation else { return }
                if !self.surfaces.contains(where: { $0.panel.isKeyWindow }) { self.dismiss(reason: .outside) }
            }
        })
        surface.scroll.contentView.postsBoundsChangedNotifications = true
        surface.observations.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
            object: surface.scroll.contentView, queue: .main) { [weak self, weak surface] _ in
            MainActor.assumeIsolated {
                guard let self, let surface, self.isPresented, !self.updatingPresentation,
                      self.surfaces.indices.contains(surface.depth + 1),
                      self.surfaces[surface.depth] === surface else { return }
                let child = self.surfaces[surface.depth + 1]
                DispatchQueue.main.async { [weak self, weak surface, weak child] in
                    guard let self, let surface, let child, self.isPresented,
                          self.surfaces.indices.contains(surface.depth + 1),
                          self.surfaces[surface.depth] === surface,
                          self.surfaces[surface.depth + 1] === child else { return }
                    self.submenuWork?.cancel(); self.submenuWork = nil
                    self.keyboardFocus = false; self.keyboardPointerScreen = nil
                    self.navigation.closeSubmenus(after: surface.depth)
                    self.rebuild(); self.updateFocus()
                }
            }
        })
    }

    private func rebuild() {
        guard let origin, let window = originWindow else { return }
        updatingPresentation = true
        defer { updatingPresentation = false }
        let menus = navigation.menus
        var common = 0
        while common < min(surfaces.count, menus.count), surfaces[common].menu === menus[common] { common += 1 }
        closeSurfaces(from: common)
        for depth in common..<menus.count {
            let items = navigation.bodyItems(at: depth)
            let bodyHeight = items.reduce(CGFloat(8.pt)) {
                $0 + ($1.isSeparatorItem ? 9.pt : 26.pt)
            }
            let rowHeight: CGFloat = depth == 0 && !navigation.rowItems.isEmpty ? 70.pt : 0
            let width = (depth == 0 ? fixedRootWidth : nil) ?? fittingWidth(for: items)
            let size = NSSize(width: width, height: bodyHeight + rowHeight + 8.pt)
            let frame: NSRect
            let actionsAtBottom: Bool
            if depth == 0 {
                let anchor = window.convertPoint(toScreen: origin.convert(originPoint, to: nil))
                let placement = ContextMenuPlacement.root(anchor: anchor, size: size, actionRowHeight: rowHeight,
                                                          availableFrame: availableFrame(at: anchor))
                frame = placement.frame; actionsAtBottom = placement.actionsAtBottom
            } else {
                let parent = surfaces[depth - 1]
                guard let (_, button, _) = buttons.first(where: {
                    $0.0 === navigation.parents[depth - 1] && $0.2 == depth - 1
                }) else { break }
                button.scrollToVisible(button.bounds)
                let visible = button.bounds.intersection(button.visibleRect)
                guard !visible.isEmpty else { navigation.closeSubmenus(after: depth - 1); break }
                let row = parent.panel.convertToScreen(button.convert(visible, to: nil))
                frame = ContextMenuPlacement.submenu(parentFrame: parent.panel.frame, parentRow: row, size: size,
                    availableFrame: availableFrame(at: NSPoint(x: row.midX, y: row.midY)))
                actionsAtBottom = false
            }
            let surface = ContextMenuSurface(panel: depth == 0 ? panel : panelFactory(), menu: menus[depth], depth: depth)
            configure(surface.panel, depth: depth)
            surface.panel.setFrame(frame, display: false)
            surfaces.append(surface)
            buildContents(of: surface, bodyHeight: bodyHeight, rowHeight: rowHeight, actionsAtBottom: actionsAtBottom)
            observe(surface)
            if depth > 0 {
                surfaces[depth - 1].panel.addChildWindow(surface.panel, ordered: .above)
                surface.panel.orderFront(nil)
            }
        }
        for (item, button, column) in buttons where item.submenu != nil {
            button.setAccessibilityExpanded(navigation.parents.indices.contains(column) && navigation.parents[column] === item)
        }
        buttons.forEach { $0.1.updateTrackingAreas() }
    }

    private func buildContents(of surface: ContextMenuSurface, bodyHeight: CGFloat,
                               rowHeight: CGFloat, actionsAtBottom: Bool) {
        let depth = surface.depth
        let size = surface.panel.frame.size
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .menu; content.blendingMode = .behindWindow; content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 7.pt; content.layer?.masksToBounds = true
        let document = MenuFlippedView(frame: content.bounds)
        let header = min(rowHeight, max(0, size.height - 4.pt))
        if depth == 0, !navigation.rowItems.isEmpty {
            let group = MenuFlippedView(frame: NSRect(x: 6.pt,
                y: actionsAtBottom ? size.height - header + 4.pt : 4.pt,
                width: max(0, size.width - 12.pt), height: max(0, header - 6.pt)))
            group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
            group.setAccessibilityLabel("File actions")
            let cellWidth = group.bounds.width / CGFloat(navigation.rowItems.count)
            for (index, item) in navigation.rowItems.enumerated() {
                let button = makeButton(item, row: true, column: depth)
                button.frame = NSRect(x: CGFloat(index) * cellWidth + 2.pt, y: 3.pt,
                    width: max(0, cellWidth - 4.pt), height: max(0, group.bounds.height - 6.pt))
                group.addSubview(button)
                if index > 0 {
                    let separator = NSBox(frame: NSRect(x: CGFloat(index) * cellWidth, y: 10.pt,
                        width: 1, height: max(0, group.bounds.height - 20.pt)))
                    separator.boxType = .separator; group.addSubview(separator)
                }
            }
            document.addSubview(group)
            let divider = NSBox(frame: NSRect(x: 6.pt,
                y: actionsAtBottom ? size.height - header : header - 1,
                width: max(0, size.width - 12.pt), height: 1))
            divider.boxType = .separator; document.addSubview(divider)
        }
        let scroll = surface.scroll
        scroll.frame = NSRect(x: 4.pt, y: actionsAtBottom ? 0 : header,
            width: max(0, size.width - 8.pt), height: max(0, size.height - header - 4.pt))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let body = MenuFlippedView(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: bodyHeight))
        body.setAccessibilityElement(true); body.setAccessibilityRole(.group)
        body.setAccessibilityLabel(depth == 0 ? "Commands" : navigation.parents[depth - 1].title)
        var y: CGFloat = 4.pt
        let items = navigation.bodyItems(at: depth)
        let hasIconColumn = items.contains { $0.image != nil }
        for item in items {
            if item.isSeparatorItem {
                let divider = NSBox(frame: NSRect(x: 5.pt, y: y + 4.pt, width: max(0, body.bounds.width - 10.pt), height: 1))
                divider.autoresizingMask = .width
                divider.boxType = .separator; body.addSubview(divider); y += 9.pt
            } else {
                let button = makeButton(item, row: false, column: depth, hasIconColumn: hasIconColumn)
                button.frame = NSRect(x: 2.pt, y: y, width: max(0, body.bounds.width - 4.pt), height: 26.pt)
                button.autoresizingMask = .width
                body.addSubview(button); y += 26.pt
            }
        }
        if depth > 0 {
            groupBodyAccessibility(body, parent: navigation.parents[depth - 1],
                                   choices: buttons.filter { $0.2 == depth }.map { ($0.0, $0.1) })
        }
        scroll.documentView = body
        scroll.synchronizeDocumentWidth()
        document.addSubview(scroll)
        if actionsAtBottom {
            // Match visual reading order without changing the established row-first key policy.
            let groups = document.subviews.filter { $0.isAccessibilityElement() }
            let actionGroup = groups.first { $0.accessibilityLabel() == "File actions" }
            if let actionGroup { document.setAccessibilityChildren([scroll, actionGroup]) }
        }
        content.addSubview(document)
        surface.panel.contentView = content
    }

    private func updateFocus() {
        for (item, button, _) in buttons {
            button.commandHighlighted = (keyboardFocus && item === navigation.focused) || navigation.parents.contains(item)
            button.keyboardFocused = keyboardFocus && item === navigation.focused
        }
        guard keyboardFocus, let (_, button, column) = buttons.first(where: { $0.0 === navigation.focused }),
              surfaces.indices.contains(column) else { return }
        updatingPresentation = true
        defer { updatingPresentation = false }
        let owner = surfaces[column].panel
        if !owner.isKeyWindow { owner.makeKeyAndOrderFront(nil) }
        _ = owner.makeFirstResponder(button)
        button.scrollToVisible(button.bounds)
        buttons.forEach { $0.1.updateTrackingAreas() }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // VoiceOver owns Control-Option chords; no global interception.
        if modifiers.contains([.control, .option]) { return false }
        submenuWork?.cancel()
        if modifiers == [] || modifiers == .shift {
            switch event.keyCode {
            case 53, 48: dismiss(reason: .keyboard); return true
            case 123...126:
                let previous = navigation.parents
                claimKeyboardFocus(); navigation.move(event.keyCode)
                if previous != navigation.parents { rebuild() }
                updateFocus(); return true
            case 36, 49:
                guard let item = navigation.focused else { return true }
                if item.submenu != nil { claimKeyboardFocus(); _ = navigation.openSubmenu(item); rebuild(); updateFocus() }
                else { _ = activateCommand(item) }
                return true
            default: break
            }
        }
        if let key = event.charactersIgnoringModifiers,
           let item = navigation.commandEquivalent(key: key, modifiers: modifiers) {
            if shouldConsumeWithoutActivation(item, event: event) { return true }
            _ = activateCommand(item); return true
        }
        // An open context surface owns Command shortcuts. Falling through here
        // would let the main menu operate on its current selection, bypassing
        // this invocation's immutable targets and once-only dispatcher.
        if modifiers.contains(.command) { return true }
        if !modifiers.isEmpty { return false }
        if let text = event.charactersIgnoringModifiers, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            let previous = navigation.parents
            navigation.typeSelect(text, timestamp: event.timestamp)
            if previous != navigation.parents { rebuild() }
            claimKeyboardFocus(); updateFocus(); return true
        }
        return false
    }
}

/// The file invocation retains captured command authority and sharing.
@MainActor
final class FileContextMenuPanelController: ContextMenuPanelController, @preconcurrency NSSharingServicePickerDelegate {
    let session: ContextMenuActionSession
    private var storeObservation: AnyCancellable?
    private var sharingPicker: NSSharingServicePicker?

    init(controller: FileContextMenuController, menu: ContextCommandMenu, origin: NSView, point: NSPoint, keyboard: Bool,
         panel: NSPanel? = nil,
         panelFactory: @escaping @MainActor () -> NSPanel = {
             FileActionsPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
         }, isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        self.session = session
        super.init(navigation: ContextMenuNavigation(menu: menu, keyboard: keyboard), title: "File actions",
                   accessibilityIdentifier: "explorer-file-context-menu", origin: origin, point: point,
                   keyboard: keyboard, isCurrent: { [weak controller] in
                       guard let store = controller?.store else { return false }
                       return session.state == .open && menu.snapshot.matches(store)
                   }, onDismiss: nil, panel: panel, panelFactory: panelFactory, isApplicationActive: isApplicationActive)
        session.closeForAction = { [weak self] in self?.dismiss(reason: .command) }
        session.performShare = { [weak self] items in self?.share(items) }
        session.isOriginCurrent = { [weak origin, weak window = origin.window] in
            guard let origin, let window else { return false }
            return origin.window === window && window.isVisible && window.isMainWindow
                && isApplicationActive() && !origin.isHiddenOrHasHiddenAncestor
        }
    }

    fileprivate override var fixedRootWidth: CGFloat? { 336.pt }

    fileprivate override func activateCommand(_ item: NSMenuItem) -> Bool { session.activate(item) }

    fileprivate override func shouldConsumeWithoutActivation(_ item: NSMenuItem, event: NSEvent) -> Bool {
        // MAC-079: a held Delete key must not start another Trash request.
        item.identifier?.rawValue == "context-moveToTrash" && FileListDeleteKey.isAutoRepeat(event)
    }

    fileprivate override func didShow() {
        guard let store = session.controller?.store else { return }
        storeObservation = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, let store = self.session.controller?.store else { return }
                if !self.session.menu.snapshot.matches(store) || store.isPerformingOperation || store.nameEdit != nil || store.isShowingRecovery {
                    self.dismiss(reason: .replacement)
                }
            }
        }
    }

    override func dismiss(reason: DismissReason) {
        storeObservation = nil
        if reason != .command { session.cancel() }
        super.dismiss(reason: reason)
    }

    fileprivate override func restoreFocusAfterDismissal(_ reason: DismissReason, ownedKey: NSWindow?) {
        if reason == .keyboard { restoreOriginFocus() }
    }

    private func restoreOriginFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, let origin = self.origin, let window = self.originWindow,
                  origin.window === window, window.isKeyWindow, !origin.isHiddenOrHasHiddenAncestor else { return }
            let responder = window.firstResponder
            guard responder === self.originResponder || responder === window || responder == nil else { return }
            _ = window.makeFirstResponder(origin)
        }
    }

    private func share(_ items: [FileItem]) {
        guard let origin, let window = originWindow, origin.window === window,
              NSApp.isActive, window.isVisible, !items.isEmpty,
              items.allSatisfy(BrowsingPresentation.isPhysical) else { return }
        let picker = NSSharingServicePicker(items: items.map { $0.url as NSURL })
        sharingPicker = picker
        picker.delegate = self
        let anchor = NSRect(origin: originPoint, size: NSSize(width: 1, height: 1)).intersection(origin.bounds)
        picker.show(relativeTo: anchor.isNull ? origin.bounds : anchor, of: origin, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        self.sharingPicker = nil
        if service == nil { restoreOriginFocus() }
    }

    fileprivate override func actionRowTitle(for item: NSMenuItem) -> String {
        let titles = ["context-moveToTrash": "Delete", "context-share": "Share"]
        return titles[item.identifier?.rawValue ?? ""] ?? item.title
    }

    fileprivate override func styleActionRowButton(_ button: ContextActionButton, item: NSMenuItem) {
        let rawCommand = (item.identifier?.rawValue ?? "").dropFirst("context-".count)
        let icon = FileContextMenuController.Command(rawValue: String(rawCommand))?.glyph.rawValue
        let configuration = NSImage.SymbolConfiguration(pointSize: 18.pt, weight: .regular)
        button.image = NSImage(systemSymbolName: icon ?? "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.symbolConfiguration = configuration
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        if item.identifier?.rawValue == "context-moveToTrash" {
            button.toolTip = "Move the selected items to Trash"
            button.setAccessibilityHelp("Moves the selected items to Trash; does not permanently delete them.")
        }
    }

    fileprivate override func isRadioChoice(_ item: NSMenuItem) -> Bool {
        ["context-view", "context-sortBy"].contains(item.identifier?.rawValue ?? "")
    }

    /// Presentation identities distinguish siblings without changing command IDs
    /// used by the captured invocation's validator and dispatcher.
    fileprivate override func accessibilityIdentifier(for item: NSMenuItem) -> String {
        let base = item.identifier?.rawValue ?? "context-command"
        guard item.submenu == nil else { return base }
        switch base {
        case "context-view":
            if let mode = item.representedObject as? Int { return "\(base)-\(mode)" }
        case "context-sortBy":
            if let key = item.representedObject as? String { return "\(base)-\(key)" }
            if let ascending = item.representedObject as? Bool { return base + (ascending ? "-ascending" : "-descending") }
        case "context-compress", "context-new":
            if let kind = item.representedObject as? String { return "\(base)-\(kind)" }
        case "context-openWith":
            if let payload = item.representedObject as? FileContextMenuController.OpenWithPayload {
                return "\(base)-\(payload.applicationURL.absoluteString)"
            }
            if item.representedObject is FileItem { return base + "-choose-application" }
        default: break
        }
        return base
    }

    fileprivate override func groupBodyAccessibility(_ body: NSView, parent: NSMenuItem,
                                                     choices: [(NSMenuItem, ContextActionButton)]) {
        guard parent.identifier?.rawValue == "context-sortBy" else { return }
        var groups: [ContextChoiceGroup] = []
        for (suffix, label, direction) in [("key", "Sort key", false), ("direction", "Sort direction", true)] {
            let members = choices.filter { ($0.0.representedObject is Bool) == direction }.map { $0.1 }
            let group = ContextChoiceGroup()
            group.setAccessibilityElement(true); group.setAccessibilityRole(.radioGroup)
            group.setAccessibilityIdentifier("context-sortBy-\(suffix)-group")
            group.setAccessibilityLabel(label); group.setAccessibilityParent(body)
            group.setAccessibilityChildren(members)
            members.forEach { $0.setAccessibilityParent(group) }
            groups.append(group)
        }
        body.setAccessibilityChildren(groups)
    }
}
