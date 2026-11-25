import AppKit

/// Pointer-only presentation shared by native controls. HV-OBS-002/003 supports
/// pale-blue item/sidebar feedback; dark and other control fills are semantic
/// macOS adaptations, not measured Windows color matches.
@MainActor
enum ExplorerHoverPalette {
    static func item(for view: NSView) -> NSColor {
        if view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22)
        }
        return NSColor(srgbRed: 0.91, green: 0.96, blue: 1, alpha: 1)
    }
    static func drawControl(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.pt, yRadius: 3.pt)
        path.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.labelColor.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Owns one explicit tracking area; tooltip/native areas cannot mutate hover.
/// Geometry and window lifecycle reconcile the live pointer, including a
/// stationary pointer during scroll/resize. No selection or action is dispatched.
@MainActor
final class PointerHoverTracker: NSObject {
    private weak var view: NSView?
    private weak var observedWindow: NSWindow?
    private weak var observedClip: NSClipView?
    private var area: NSTrackingArea?
    private let enabled: () -> Bool
    private let interactionRegion: @MainActor (NSView) -> NSRect
    private(set) var point: NSPoint?
    var isHovered: Bool { point != nil }

    init(view: NSView, enabled: @escaping () -> Bool = { true },
         interactionRegion: @escaping @MainActor (NSView) -> NSRect = { $0.bounds }) {
        self.view = view
        self.enabled = enabled
        self.interactionRegion = interactionRegion
        super.init()
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update() {
        guard let view else { return }
        bindLifecycle()
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: trackingRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: view, userInfo: nil)
        area = next
        view.addTrackingArea(next)
        reconcile()
    }
    func movedToWindow() {
        clear()
        bindLifecycle()
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .mouseMoved || event.trackingArea === area else { return false }
        guard let window = view?.window, event.window === window else { return true }
        reconcile()
        return true
    }
    func clear() { setPoint(nil) }
    func reconcile() {
        guard let view, let window = view.window, window.isKeyWindow, window.isVisible,
              enabled(), !view.isHiddenOrHasHiddenAncestor else { clear(); return }
        let current = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setPoint(trackingRect.contains(current) ? current : nil)
    }
    private var trackingRect: NSRect {
        guard let view else { return .zero }
        // Modern nonclipping visibleRect may exceed bounds. inVisibleRect would
        // ignore this explicit intersection and recreate oversized hit regions.
        let rect = view.bounds.intersection(view.visibleRect).intersection(interactionRegion(view))
        return rect.isNull ? .zero : rect
    }
    private func setPoint(_ next: NSPoint?) {
        guard point != next else { return }
        point = next
        view?.needsDisplay = true
    }
    private func bindLifecycle() {
        guard observedWindow !== view?.window || observedClip !== view?.enclosingScrollView?.contentView else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        observedWindow = view?.window
        observedClip = view?.enclosingScrollView?.contentView
        if let window = observedWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(clearFromNotification(_:)), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(refreshFromNotification(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(clearFromNotification(_:)),
                name: NSApplication.didResignActiveNotification, object: nil)
        }
        if let clip = observedClip {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(geometryChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    @objc private func clearFromNotification(_ notification: Notification) { clear() }
    @objc private func refreshFromNotification(_ notification: Notification) { reconcile() }
    @objc private func geometryChanged(_ notification: Notification) { update() }
}

/// Native buttons keep their existing action, selection and focus behavior.
@MainActor
class PointerHoverButton: NSButton {
    lazy var pointerHover = PointerHoverTracker(view: self, enabled: { [weak self] in self?.isEnabled == true })
    override var isEnabled: Bool { didSet { pointerHover.reconcile() } }
    override var isHidden: Bool { didSet { if isHidden { pointerHover.clear() } } }
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
}

/// Native row selection stays authoritative. Draw hover in the background pass
/// so text, selection, keyboard focus and drop feedback remain above it.
@MainActor
class PointerHoverRowView: NSTableRowView {
    var allowsPointerHover = true { didSet { pointerHover.reconcile() } }
    var pointerInteractionRect: NSRect { bounds }
    var pointerHoverRect: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    private lazy var pointerHover = PointerHoverTracker(view: self,
        enabled: { [weak self] in self?.allowsPointerHover == true },
        interactionRegion: { [weak self] _ in self?.pointerInteractionRect ?? .zero })
    override var isHidden: Bool { didSet { if isHidden { pointerHover.clear() } } }
    override func updateTrackingAreas() { super.updateTrackingAreas(); pointerHover.update() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); pointerHover.movedToWindow() }
    override func prepareForReuse() { pointerHover.clear(); super.prepareForReuse() }
    override func mouseEntered(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseEntered(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseExited(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseMoved(with: event) }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if pointerHover.isHovered, !isSelected {
            ExplorerHoverPalette.item(for: self).setFill()
            pointerHoverRect.fill()
        }
    }
}
