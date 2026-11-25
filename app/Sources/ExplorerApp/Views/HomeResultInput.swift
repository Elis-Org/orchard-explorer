import AppKit
import ExplorerCore
import SwiftUI

struct HomeResultClickTarget: Equatable {
    let id: String
    let membership: UUID?
    let identity: LocalFileIdentity?
}

@MainActor
private final class HomeResultProofRefresh: ObservableObject {
    @Published var request = 0
}

@MainActor
struct HomeSelectableResult: View {
    @ObservedObject var store: ExplorerStore
    let row: HomeResultRow
    let scope: HomeResultScope
    let revision: UUID?
    let keyboard: HomeResultKeyboardFocus
    @StateObject private var proof = HomeResultProofRefresh()

    private struct Sample: Equatable {
        let scope: HomeResultScope
        let membership: UUID?
        let revision: UUID?
        let request: Int
    }

    var body: some View {
        let token = store.homeResultMembership(row, in: scope)
        let target = store.activeTab.homeResults.target(of: row)
        let identity = target?.identity
        let selected = token != nil && store.activeTab.homeResults.selection.selectedIDs.contains(row.id)
        let sample = Sample(scope: scope, membership: token, revision: revision, request: proof.request)
        return HomeItemLabel(name: row.url.lastPathComponent, url: row.url, folder: row.isDirectory,
                             symbol: row.isDirectory ? "folder.fill" : "doc", tile: false)
            .accessibilityHidden(true)
            .background(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3.pt))
            .overlay {
                HomeResultInput { view in
                    view.setAccessibilityIdentifier(row.recent == nil ? "home-tag-result" : "home-recent-item")
                    view.setAccessibilityLabel(row.url.lastPathComponent)
                    view.setAccessibilityHelp(row.url.path)
                    view.clickTarget = HomeResultClickTarget(id: row.id, membership: token, identity: identity)
                    view.focusController = keyboard
                    view.commandStore = store
                    view.rowIsCurrent = { isCurrent() }
                    view.dragOrigin = { isCurrent() ? store.homeOperationOrigin : nil }
                    view.dropRow = row
                    view.selectedState = selected
                    @MainActor func isCurrent() -> Bool {
                        token != nil && store.homeResultMembership(row, in: scope) == token
                    }
                    view.selectedNow = { isCurrent() && store.activeTab.homeResults.selection.selectedIDs.contains(row.id) }
                    view.onSelect = { extending, toggling in
                        guard isCurrent() else { return }
                        store.selectHomeResult(row, in: scope, extending: extending, toggling: toggling)
                        if row.recent == nil && identity == nil { proof.request += 1 }
                    }
                    view.onMove = { offset, extend, source in
                        guard isCurrent(), let next = store.moveHomeResultFocus(from: row, in: scope,
                                                                               by: offset, extending: extend) else { return }
                        keyboard.move(to: next.id, scope: scope, from: source)
                    }
                    view.restoreKeyboardFocus = { [weak view] in
                        if let view, isCurrent() { keyboard.takeFocus(view, id: row.id, scope: scope) }
                    }
                    view.restoreKeyboardFocus?()
                    @MainActor func perform(_ action: ExplorerStore.PageItemAction) -> Bool {
                        guard isCurrent(), let identity,
                              store.activeTab.homeResults.target(of: row)?.identity == identity else { return false }
                        store.performHomeResultAction(action, row: row, in: scope, identity: identity)
                        return true
                    }
                    view.onOpen = { perform(.open) }
                    view.canOpenWithReturn = {
                        guard isCurrent(), store.activeTab.homeResults.selection.selectedIDs.contains(row.id) else { return false }
                        return store.activeTab.homeResults.selectedTargets.count == 1
                    }
                }
            }
            .task(id: sample) {
                guard row.recent == nil, let token = sample.membership else { return }
                let value = try? await FinderTagFile.resultIdentity(at: row.url)
                if !Task.isCancelled {
                    store.bindHomeResultIdentity(value?.identity, for: row, in: scope, membership: token,
                                                 isSymbolicLink: value?.isSymbolicLink)
                }
            }
    }
}

@MainActor
final class HomeResultKeyboardFocus: ObservableObject {
    struct Request: Equatable {
        let scope: HomeResultScope
        let id: String
        let nonce = UUID()
    }

    @Published private(set) var request: Request?
    var firstPress: HomeResultClickTarget?
    private weak var originWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var applied: UUID?

    func move(to id: String, scope: HomeResultScope, from view: NSView) {
        originWindow = view.window
        sourceResponder = view
        request = Request(scope: scope, id: id)
    }

    func takeFocus(_ view: NSView, id: String, scope: HomeResultScope) {
        guard let request, request.id == id, request.scope == scope, applied != request.nonce,
              let window = view.window, window === originWindow, window.isKeyWindow else { return }
        guard window.firstResponder === sourceResponder || window.firstResponder === window
                || window.firstResponder === view || window.firstResponder == nil else { return }
        if window.makeFirstResponder(view) { applied = request.nonce }
    }
}

@MainActor
final class HomeResultInputControl: PointerHoverButton {
    var clickTarget: HomeResultClickTarget? {
        didSet {
            guard let oldValue else { return }
            if oldValue.id != clickTarget?.id || oldValue.membership != clickTarget?.membership
                || (oldValue.identity != nil && oldValue.identity != clickTarget?.identity) {
                dismissMenu()
            }
        }
    }
    weak var commandStore: ExplorerStore?
    var rowIsCurrent: (() -> Bool)?
    var dragOrigin: (() -> HomeOperationOrigin?)?
    var dropRow: HomeResultRow?
    private var pendingDrag: (point: NSPoint, target: HomeResultClickTarget?, origin: HomeOperationOrigin?, collapse: Bool)?
    private var fileDragSource: FileDragSource?
    private var sourcePreparation: Task<Void, Never>?
    private var latestDragEvent: NSEvent?
    var focusController = HomeResultKeyboardFocus()
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    var selectedState = false { didSet { if oldValue != selectedState { needsDisplay = true } } }
    var selectedNow: (() -> Bool)?
    var onSelect: ((_ extending: Bool, _ toggling: Bool) -> Void)?
    var onMove: ((_ offset: Int, _ extending: Bool, _ view: NSView) -> Void)?
    var onOpen: (() -> Bool)?
    var canOpenWithReturn: (() -> Bool)?
    weak var menuPresenter: HomeResultMenuPresenting?
    var restoreKeyboardFocus: (() -> Void)?
    private weak var containingDropHost: HomeDropBoundaryOwner?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("Home result inputs are created in code") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ rect: NSRect) {
        if pointerHover.isHovered, !selectedState { ExplorerHoverPalette.drawControl(in: bounds) }
        if isDropTarget || window?.firstResponder === self {
            (isDropTarget ? NSColor.controlAccentColor : NSColor.keyboardFocusIndicatorColor).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3.pt, yRadius: 3.pt)
            border.lineWidth = 1.5
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        cancelDragPreparation()
        pendingDrag = nil
        window?.makeFirstResponder(self)
        let flags = event.modifierFlags
        let extending = flags.contains(.shift)
        let toggling = !flags.intersection([.control, .command]).isEmpty
        let plain = flags.intersection([.control, .command, .shift, .option]).isEmpty
        let first = focusController.firstPress
        focusController.firstPress = nil
        guard event.clickCount <= 2 else { return }
        if plain, event.clickCount == 2, let clickTarget,
           first == clickTarget, clickTarget.identity != nil, clickTarget.membership != nil {
            _ = onOpen?()
        } else {
            if plain && event.clickCount == 1 { focusController.firstPress = clickTarget }
            let collapse = plain && event.clickCount == 1 && (selectedNow?() ?? selectedState)
            if !collapse { onSelect?(extending, toggling) }
            if event.clickCount == 1 {
                pendingDrag = (event.locationInWindow, clickTarget, dragOrigin?(), collapse)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        latestDragEvent = event
        guard let pending = pendingDrag,
              ExplorerFileCollectionView.crossedFileDragThreshold(from: pending.point, to: event.locationInWindow) else { return }
        pendingDrag = nil
        focusController.firstPress = nil
        guard stillRepresents(pending.target), rowIsCurrent?() == true, selectedNow?() == true,
              let origin = pending.origin, let store = commandStore, let originalWindow = window,
              store.isHomeOperationOriginCurrent(origin) else { return }
        sourcePreparation = Task { @MainActor [weak self, weak store, weak originalWindow] in
            guard let store else { return }
            let entries = try? await store.verifiedHomeOperationEntries(for: origin)
            guard !Task.isCancelled, let self, let originalWindow, self.window === originalWindow,
                  self.rowIsCurrent?() == true, self.stillRepresents(pending.target),
                  self.selectedNow?() == true, store.isHomeOperationOriginCurrent(origin),
                  let event = self.latestDragEvent, NSEvent.pressedMouseButtons & 1 != 0,
                  let entries else { return }
            self.sourcePreparation = nil
            self.startFileDrag(entries, at: pending.point, event: event)
        }
    }

    private func stillRepresents(_ pressed: HomeResultClickTarget?) -> Bool {
        guard let pressed, let clickTarget else { return false }
        return pressed.id == clickTarget.id && pressed.membership != nil && pressed.membership == clickTarget.membership
            && (pressed.identity == nil || pressed.identity == clickTarget.identity)
    }

    private func cancelDragPreparation() {
        sourcePreparation?.cancel()
        sourcePreparation = nil
        latestDragEvent = nil
    }

    private func startFileDrag(_ entries: [TransferEntry], at point: NSPoint, event: NSEvent) {
        guard let source = FileDragCoordinator.shared.beginSource(entries: entries, owner: self) else { return }
        let items = entries.compactMap { entry -> NSDraggingItem? in
            guard let writer = source.pasteboardWriter(itemID: entry.item.id) else { return nil }
            let drag = NSDraggingItem(pasteboardWriter: writer)
            let start = convert(point, from: nil)
            drag.setDraggingFrame(NSRect(origin: start, size: NSSize(width: 32, height: 32)),
                                  contents: ItemMetadataFormatting.genericIcon(for: entry.item))
            return drag
        }
        guard items.count == entries.count else { source.finish(); return }
        fileDragSource = source
        source.startSession()
        let session = beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        cancelDragPreparation()
        defer { pendingDrag = nil }
        guard let pending = pendingDrag, pending.collapse, stillRepresents(pending.target),
              pending.origin.map({ commandStore?.isHomeOperationOriginCurrent($0) == true }) != false,
              rowIsCurrent?() != false else { return }
        onSelect?(false, false)
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func showMenu(at point: NSPoint, keyboard: Bool) -> Bool {
        focusController.firstPress = nil
        guard let window, let menuPresenter, let row = dropRow, rowIsCurrent?() == true else { return false }
        cancelDragPreparation()
        pendingDrag = nil
        guard window.makeFirstResponder(self) else { return false }
        if keyboard {
            guard let store = commandStore else { return false }
            return presentHomeKeyboardMenu(from: self, focused: row, store: store, presenter: menuPresenter)
        }
        if !(selectedNow?() ?? selectedState) { onSelect?(false, false) }
        guard rowIsCurrent?() == true else { return false }
        return menuPresenter.presentHome(row: row, at: point, in: self, keyboard: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        if event.buttonNumber == 0 { mouseDown(with: event); return }
        if event.buttonNumber == 1 { _ = showMenu(at: convert(event.locationInWindow, from: nil), keyboard: false) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .command, .option])
        focusController.firstPress = nil
        if let deleteKey = FileListDeleteKey(event) {
            if deleteKey == .trash { moveToTrash(nil) }
            if deleteKey == .permanentUnavailable, ownsCommandFocus { commandStore?.notePermanentDeleteUnavailable() }
            return
        }
        switch (event.keyCode, flags) {
        case (120, []): if ownsCommandFocus { commandStore?.beginRename() }
        case (125, []), (125, .shift): onMove?(1, flags.contains(.shift), self)
        case (126, []), (126, .shift): onMove?(-1, flags.contains(.shift), self)
        case (49, []): onSelect?(false, true)
        case (36, []), (76, []):
            if canOpenWithReturn?() == true { _ = onOpen?() }
        case (109, .shift): _ = accessibilityPerformShowMenu()
        default: super.keyDown(with: event)
        }
    }

    override func isAccessibilitySelected() -> Bool { selectedNow?() ?? selectedState }
    override func setAccessibilitySelected(_ selected: Bool) {
        if selected != isAccessibilitySelected() { onSelect?(false, true) }
    }
    override func isAccessibilityFocused() -> Bool { window != nil && window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { window?.makeFirstResponder(self) } }
    override func accessibilityPerformPress() -> Bool { onOpen?() ?? false }
    override func accessibilityPerformShowMenu() -> Bool { showMenu(at: .zero, keyboard: true) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissMenu()
        containingDropHost?.rows.remove(self)
        containingDropHost = window == nil ? nil : homeDropHost(containing: self)
        menuPresenter = containingDropHost?.menuPresenter
        containingDropHost?.rows.add(self)
        if window == nil {
            cancelDragPreparation()
            pendingDrag = nil
            fileDragSource?.finishIfInactive()
            fileDragSource = nil
        } else { restoreKeyboardFocus?() }
    }

    private var ownsCommandFocus: Bool { window?.firstResponder === self && rowIsCurrent?() == true }

    private var commands: FileCommandEligibility {
        FileCommandEligibility(ownsFileFocus: ownsCommandFocus,
            copy: commandStore?.canCopySelection == true, cut: commandStore?.canCutSelection == true,
            paste: commandStore?.canPaste == true, delete: commandStore?.canDeleteSelection == true,
            undo: commandStore?.canUndoRename == true, redo: commandStore?.canRedoRename == true)
    }

    @objc func copy(_ sender: Any?) { if commands.allows(.copy) { commandStore?.copySelection() } }
    @objc func cut(_ sender: Any?) { if commands.allows(.cut) { commandStore?.cutSelection() } }
    @objc func paste(_ sender: Any?) { if commands.allows(.paste) { commandStore?.pasteSelection() } }
    @objc func moveToTrash(_ sender: Any?) {
        if commands.allows(.delete), !FileListDeleteKey.isAutoRepeat(NSApp.currentEvent) { commandStore?.deleteSelection() }
    }
    @objc func undo(_ sender: Any?) { if commands.allows(.undo) { commandStore?.undoRename() } }
    @objc func redo(_ sender: Any?) { if commands.allows(.redo) { commandStore?.redoRename() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): commands.allows(.copy)
        case #selector(cut(_:)): commands.allows(.cut)
        case #selector(paste(_:)): commands.allows(.paste)
        case #selector(moveToTrash(_:)): commands.allows(.delete)
        case #selector(undo(_:)): commands.allows(.undo)
        case #selector(redo(_:)): commands.allows(.redo)
        default: super.validateUserInterfaceItem(item)
        }
    }

    func dismissMenu() { menuPresenter?.dismissPresentedMenu(from: self) }
}

@MainActor
struct HomeResultInput: NSViewRepresentable {
    let configure: (HomeResultInputControl) -> Void
    func makeNSView(context: Context) -> HomeResultInputControl { HomeResultInputControl(frame: .zero) }
    func updateNSView(_ view: HomeResultInputControl, context: Context) { configure(view) }
    static func dismantleNSView(_ view: HomeResultInputControl, coordinator: ()) {
        view.dismissMenu()
        view.commandStore = nil
        view.dragOrigin = nil
        view.rowIsCurrent = nil
        view.dropRow = nil
        view.restoreKeyboardFocus = nil
        view.menuPresenter = nil
        view.onSelect = nil
        view.onOpen = nil
        view.onMove = nil
        view.selectedNow = nil
        view.canOpenWithReturn = nil
    }
}
