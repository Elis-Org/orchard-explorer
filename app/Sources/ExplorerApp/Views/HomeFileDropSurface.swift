import AppKit
import ExplorerCore
import SwiftUI

/// One presenter owns file actions for the background and every realized row in this Home view.
@MainActor
protocol HomeResultMenuPresenting: AnyObject {
    func presentHome(row: HomeResultRow?, at point: NSPoint, in origin: NSView, keyboard: Bool) -> Bool
    func dismissPresentedMenu(from origin: NSView)
    func dismissPresentedMenu()
}

extension FileContextMenuController: HomeResultMenuPresenting {}

@MainActor
func presentHomeKeyboardMenu(from origin: NSView, focused: HomeResultRow?, store: ExplorerStore,
                             presenter: HomeResultMenuPresenting) -> Bool {
    guard let window = origin.window, let scope = store.homeResultScope else { return false }
    let results = store.activeTab.homeResults
    let selected = results.selection.selectedIDs
    let preferred = focused?.id ?? results.selection.focusedID
    let target = results.rows.first { $0.id == preferred && selected.contains($0.id) }
        ?? results.rows.first { selected.contains($0.id) }
    if let target, store.homeResultMembership(target, in: scope) == nil { return false }
    let host = (origin as? HomeDropBoundaryOwner) ?? homeDropHost(containing: origin)
    let control = target.flatMap { row in
        host?.rows.allObjects.first {
            $0.dropRow?.id == row.id && $0.rowIsCurrent?() == true && $0.window === window
                && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
    }
    let anchor: NSView = control ?? origin
    let rect = anchor.visibleRect
    let point = NSPoint(x: min(rect.maxX, rect.minX + 12.pt), y: rect.midY)
    return presenter.presentHome(row: target, at: origin.convert(point, from: anchor), in: origin, keyboard: true)
}

/// The results boundary keeps Quick access and the tag picker out of drop hit testing.
/// A single receiving view owns the drag sequence across rows and empty space.
@MainActor
protocol HomeDropBoundaryOwner: AnyObject {
    var resultsBoundary: NSView? { get set }
    var rows: NSHashTable<HomeResultInputControl> { get }
    var menuPresenter: HomeResultMenuPresenting { get }
}

@MainActor
func homeDropHost(containing view: NSView) -> HomeDropBoundaryOwner? {
    var ancestor = view.superview
    while let next = ancestor {
        if let owner = next as? HomeDropBoundaryOwner { return owner }
        ancestor = next.superview
    }
    return nil
}

struct HomeDropBoundary: NSViewRepresentable {
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { homeDropHost(containing: self)?.resultsBoundary = self }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker(frame: .zero) }
    func updateNSView(_ view: Marker, context: Context) {}
}

@MainActor
struct HomeFileDropSurface<Content: View>: NSViewRepresentable {
    let store: ExplorerStore
    let content: Content

    func makeNSView(context: Context) -> HomeDropHost<Content> { HomeDropHost(store: store, root: content) }
    func updateNSView(_ view: HomeDropHost<Content>, context: Context) { view.update(content, scope: store.homeResultScope) }
    static func dismantleNSView(_ view: HomeDropHost<Content>, coordinator: ()) {
        view.menuPresenter.dismissPresentedMenu()
        view.clearDrop()
    }
}

@MainActor
final class HomeDropHost<Content: View>: NSView, HomeDropBoundaryOwner {
    let host: NSHostingView<Content>
    let menuPresenter: HomeResultMenuPresenting
    private var menuScope: HomeResultScope?
    weak var resultsBoundary: NSView?
    let rows = NSHashTable<HomeResultInputControl>.weakObjects()
    private weak var store: ExplorerStore?
    private let receiver: FileDragDestination
    private weak var highlightedRow: HomeResultInputControl?
    private var highlightsBackground = false
    private var ready = false

    init(store: ExplorerStore, root: Content, menuPresenter: HomeResultMenuPresenting? = nil) {
        self.menuPresenter = menuPresenter ?? FileContextMenuController(store: store)
        menuScope = store.homeResultScope
        host = NSHostingView(rootView: root)
        receiver = FileDragCoordinator.shared.makeDestination(store: store)
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("home-results-view")
        setAccessibilityLabel("Home results")
        addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)])
        registerForDraggedTypes(FileDragCoordinator.registeredTypes)
    }
    required init?(coder: NSCoder) { fatalError("Home results are created in code") }

    func update(_ content: Content, scope: HomeResultScope?) {
        if menuScope != scope { menuPresenter.dismissPresentedMenu() }
        menuScope = scope
        host.rootView = content
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { menuPresenter.dismissPresentedMenu() }
    }

    private func isInResults(_ windowPoint: NSPoint) -> Bool {
        guard let marker = resultsBoundary, window != nil, marker.window === window,
              let scroll = marker.enclosingScrollView else { return false }
        let clipped = scroll.contentView
        let region = clipped.convert(clipped.bounds, to: nil)
        let top = marker.convert(marker.bounds, to: nil).maxY
        return region.contains(windowPoint) && windowPoint.y <= top
    }

    private func nativeResult(at windowPoint: NSPoint) -> (row: HomeResultInputControl?, background: Bool) {
        guard isInResults(windowPoint) else { return (nil, false) }
        var current = host.hitTest(convert(windowPoint, from: nil))
        while let view = current, view !== self {
            if let row = view as? HomeResultInputControl { return (row, false) }
            if view is NSScroller || view is NSControl || view is NSText { return (nil, false) }
            current = view.superview
        }
        // SwiftUI can return the hosting or clip view for the AppKit overlay.
        // Resolve that gap using only live row controls and their clipped visible geometry.
        var match: HomeResultInputControl?
        for row in rows.allObjects where row.window === window && !row.isHiddenOrHasHiddenAncestor {
            let local = row.convert(windowPoint, from: nil)
            guard row.bounds.contains(local), row.visibleRect.contains(local) else { continue }
            guard match == nil, row.rowIsCurrent?() == true else { return (nil, false) }
            match = row
        }
        return (match, match == nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let native = super.hitTest(point), window != nil else { return nil }
        let localPoint = convert(point, from: superview)
        let target = nativeResult(at: convert(localPoint, to: nil))
        if let row = target.row { return row }
        return target.background ? self : native
    }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func scrollWheel(with event: NSEvent) {
        if let scroll = resultsBoundary?.enclosingScrollView { scroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 1, nativeResult(at: event.locationInWindow).background,
              let window, window.makeFirstResponder(self) else { return }
        _ = menuPresenter.presentHome(row: nil, at: convert(event.locationInWindow, from: nil), in: self, keyboard: false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.intersection([.shift, .control, .command, .option]) == .shift {
            _ = accessibilityPerformShowMenu()
        } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let store, let window, window.makeFirstResponder(self) else { return false }
        return presentHomeKeyboardMenu(from: self, focused: nil, store: store, presenter: menuPresenter)
    }

    @objc func paste(_ sender: Any?) {
        if window?.firstResponder === self, store?.canPaste == true { store?.pasteSelection() }
    }

    private func target(_ info: NSDraggingInfo) -> (FileDropTarget?, HomeResultInputControl?) {
        guard info.draggingDestinationWindow === window else { return (nil, nil) }
        let hit = nativeResult(at: info.draggingLocation)
        if let row = hit.row {
            guard row.rowIsCurrent?() == true, let item = row.dropRow else { return (nil, nil) }
            return (store?.homeFileDropTarget(row: item), item.isDirectory ? row : nil)
        }
        return (hit.background ? store?.homeFileDropTarget(row: nil) : nil, nil)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let (target, row) = target(sender)
        let operation = receiver.update(sender, target: target)
        ready = !operation.isEmpty
        let show = ready || receiver.isPreparing
        highlightedRow?.isDropTarget = false
        highlightedRow = show ? row : nil
        highlightedRow?.isDropTarget = true
        let background = show && row == nil
        if background != highlightsBackground { highlightsBackground = background; needsDisplay = true }
        return operation
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ready }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDrop() }
        return receiver.accept(sender, target: target(sender).0)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDrop() }

    func clearDrop() {
        receiver.invalidate()
        highlightedRow?.isDropTarget = false
        highlightedRow = nil
        ready = false
        if highlightsBackground { highlightsBackground = false; needsDisplay = true }
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        if highlightsBackground {
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        }
    }
}
