import AppKit
import ExplorerCore
import SwiftUI

/// FR-SEL-005 / EV-0440 / AT-SEL-005: real focus stop for the current Details layout.
struct StatusViewButton: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    var mode: FolderViewMode = .details
    var registersFocusStop = true
    func makeNSView(context: Context) -> DetailsStatusButton {
        let button = DetailsStatusButton()
        button.focus = store.focus
        button.image = NSImage(systemSymbolName: mode == .details ? "list.bullet" : "square.grid.2x2", accessibilityDescription: mode.title)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12.pt, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.toggle)
        button.setAccessibilityIdentifier(mode == .details ? "details-view-button" : "large-icons-view-button")
        button.toolTip = "\(mode.title) (⌃⇧\(mode.rawValue))"
        button.target = button
        button.action = #selector(DetailsStatusButton.activate)
        return button
    }
    func updateNSView(_ button: DetailsStatusButton, context: Context) {
        button.focus = store.focus
        button.state = store.activeTab.viewMode == mode ? .on : .off
        button.isEnabled = store.canChangeViewMode
        button.setAccessibilityLabel("\(mode.title) view\(button.state == .on ? ", selected" : "")")
        let requestedMode = mode
        button.onActivate = { [weak store, weak button] in
            guard let store else { return }
            store.setViewMode(requestedMode)
            // AppKit toggles before dispatch; selecting the already-current
            // mode makes no model publication, so restore its radio-like state.
            button?.state = store.activeTab.viewMode == requestedMode ? .on : .off
        }
        if registersFocusStop {
            store.focus.register(.status, owner: button) { [weak button] in
                guard let button, button.isEnabled else { return false }
                return button.window?.makeFirstResponder(button) == true
            }
        }
    }
    static func dismantleNSView(_ button: DetailsStatusButton, coordinator: ()) {
        button.focus?.unregister(.status, owner: button)
        button.onActivate = nil
    }
}

final class DetailsStatusButton: PointerHoverButton {
    weak var focus: ExplorerFocusCoordinator?
    var onActivate: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focus?.focused(.status); needsDisplay = true }
        return result
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    @objc func activate() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if let onActivate { onActivate() } else { state = .on }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { activate() }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if pointerHover.isHovered, isEnabled, state != .on {
            ExplorerHoverPalette.drawControl(in: bounds)
        }
        if state == .on {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 2, yRadius: 2)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
