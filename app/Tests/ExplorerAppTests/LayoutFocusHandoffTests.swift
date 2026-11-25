import AppKit
import Testing
@testable import ExplorerApp

@MainActor
private final class LayoutFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Native layout-replacement focus policy. These are window-local responder
/// checks, not desktop key/main routing or spoken-accessibility claims.
@Suite(.serialized)
@MainActor
final class LayoutFocusHandoffTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }

    private func view(in window: NSWindow) -> LayoutFocusView {
        let result = LayoutFocusView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(result)
        return result
    }

    private func register(_ region: ExplorerFocusRegion, _ view: NSView,
                          with coordinator: ExplorerFocusCoordinator) {
        coordinator.register(region, owner: view) { [weak view] in
            guard let view, let window = view.window else { return false }
            return window.makeFirstResponder(view)
        }
    }

    @Test(arguments: [ExplorerFocusRegion.list, .header])
    func actualContentFocusMovesOnceToReplacement(_ source: ExplorerFocusRegion) {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        register(source, old, with: coordinator)
        #expect(window.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()
        coordinator.unregister(source, owner: old)
        window.makeFirstResponder(nil)
        old.removeFromSuperview()
        let replacement = view(in: window)
        register(.list, replacement, with: coordinator)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === replacement)
        #expect(coordinator.currentRegion == .list)

        window.makeFirstResponder(nil)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder !== replacement)
    }

    @Test
    func staleRememberedListDoesNotRequestHandoffFromSidebar() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        let sidebar = view(in: window)
        register(.list, old, with: coordinator)
        register(.sidebar, sidebar, with: coordinator)
        coordinator.focused(.list)
        #expect(window.makeFirstResponder(sidebar))
        coordinator.prepareContentReplacementFocus()
        let replacement = view(in: window)
        register(.list, replacement, with: coordinator)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === sidebar)
        window.makeFirstResponder(nil)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder !== replacement)
    }

    @Test
    func textEditorInsideContentNeverRequestsHandoff() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        let editor = NSTextView(frame: old.bounds)
        old.addSubview(editor)
        register(.list, old, with: coordinator)
        #expect(window.makeFirstResponder(editor))
        coordinator.prepareContentReplacementFocus()
        let replacement = view(in: window)
        register(.list, replacement, with: coordinator)
        window.makeFirstResponder(nil)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder !== replacement)
    }

    @Test(arguments: [false, true])
    func userFocusChangeCancelsPendingHandoff(useTextEditor: Bool) {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        register(.list, old, with: coordinator)
        #expect(window.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()

        let destination: NSView = useTextEditor
            ? NSTextView(frame: NSRect(x: 0, y: 110, width: 200, height: 40))
            : LayoutFocusView(frame: NSRect(x: 0, y: 110, width: 200, height: 40))
        window.contentView?.addSubview(destination)
        if !useTextEditor { register(.sidebar, destination, with: coordinator) }
        #expect(window.makeFirstResponder(destination))
        let replacement = view(in: window)
        register(.list, replacement, with: coordinator)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === destination)
        window.makeFirstResponder(nil)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder !== replacement)
    }

    @Test
    func waitsForRegisteredReplacementAttachmentAndIgnoresOldCallback() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        register(.list, old, with: coordinator)
        #expect(window.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()
        let replacement = LayoutFocusView(frame: old.frame)
        register(.list, replacement, with: coordinator)
        coordinator.restorePendingContentFocus(owner: old)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === old)
        window.contentView?.addSubview(replacement)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === replacement)
    }

    @Test(arguments: [ExplorerFocusRegion.list, .header])
    func outgoingLayoutCannotConsumeHandoffBeforeReplacementRegisters(_ source: ExplorerFocusRegion) {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let outgoing = view(in: window)
        let header = LayoutFocusView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        outgoing.addSubview(header)
        var outgoingAttempts = 0
        coordinator.register(.list, owner: outgoing) { [weak outgoing] in
            outgoingAttempts += 1
            guard let outgoing, let window = outgoing.window else { return false }
            return window.makeFirstResponder(outgoing)
        }
        register(.header, header, with: coordinator)
        let focusedView = source == .header ? header : outgoing
        #expect(window.makeFirstResponder(focusedView))
        coordinator.prepareContentReplacementFocus()

        // The outgoing table/collection can lay out after prepare but before
        // SwiftUI registers its replacement. These callbacks must not consume it.
        coordinator.restorePendingContentFocus(owner: outgoing)
        coordinator.restorePendingContentFocus(owner: outgoing)
        #expect(outgoingAttempts == 0)
        #expect(window.firstResponder === focusedView)

        coordinator.unregister(.list, owner: outgoing)
        coordinator.unregister(.header, owner: header)
        window.makeFirstResponder(nil)
        outgoing.removeFromSuperview()
        let replacement = view(in: window)
        var replacementAttempts = 0
        coordinator.register(.list, owner: replacement) { [weak replacement] in
            replacementAttempts += 1
            guard let replacement, let window = replacement.window else { return false }
            return window.makeFirstResponder(replacement)
        }
        coordinator.restorePendingContentFocus(owner: replacement)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(window.firstResponder === replacement)
        #expect(replacementAttempts == 1)
        #expect(outgoingAttempts == 0)
    }

    @Test
    func emptyTableRestoresPendingFocusWhenLayoutMakesItAvailable() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        register(.list, old, with: coordinator)
        #expect(window.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()
        window.makeFirstResponder(nil)
        old.removeFromSuperview()

        let replacement = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        // NSTableView normalizes zero geometry. Use a native hidden table to
        // exercise the same unavailable-view deferral, and attach before handing
        // it the coordinator so only a later layout can restore pending focus.
        replacement.isHidden = true
        window.contentView?.addSubview(replacement)
        #expect(replacement.window === window)
        #expect(replacement.isHiddenOrHasHiddenAncestor)
        replacement.focusCoordinator = coordinator
        var attempts = 0
        coordinator.register(.list, owner: replacement) { [weak replacement] in
            attempts += 1
            guard let replacement, let window = replacement.window else { return false }
            return window.makeFirstResponder(replacement)
        }
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(replacement.isHiddenOrHasHiddenAncestor)
        #expect(replacement.numberOfRows == 0)
        #expect(attempts == 0)
        #expect(window.firstResponder !== replacement)

        replacement.isHidden = false
        replacement.needsLayout = true
        replacement.layoutSubtreeIfNeeded()
        #expect(!replacement.isHiddenOrHasHiddenAncestor)
        #expect(replacement.numberOfRows == 0)
        #expect(window.firstResponder === replacement)
        #expect(attempts == 1)

        let sidebar = view(in: window)
        register(.sidebar, sidebar, with: coordinator)
        #expect(window.makeFirstResponder(sidebar))
        replacement.frame.size.width = 420
        replacement.needsLayout = true
        replacement.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === sidebar)
        #expect(attempts == 1)
    }

    @Test
    func aDifferentWindowCannotReceiveOrRetainPendingFocus() {
        let originalWindow = window()
        let otherWindow = window()
        defer { originalWindow.close(); otherWindow.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: originalWindow)
        register(.list, old, with: coordinator)
        #expect(originalWindow.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()
        let wrongWindow = view(in: otherWindow)
        register(.list, wrongWindow, with: coordinator)
        coordinator.restorePendingContentFocus(owner: wrongWindow)
        #expect(otherWindow.firstResponder !== wrongWindow)
        let replacement = view(in: originalWindow)
        register(.list, replacement, with: coordinator)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(originalWindow.firstResponder === old)
    }

    @Test
    func refusedFocusAttemptIsNotRetriedByLaterLifecycleCallbacks() {
        let window = window()
        defer { window.close() }
        let coordinator = ExplorerFocusCoordinator()
        let old = view(in: window)
        register(.list, old, with: coordinator)
        #expect(window.makeFirstResponder(old))
        coordinator.prepareContentReplacementFocus()
        let replacement = view(in: window)
        var attempts = 0
        coordinator.register(.list, owner: replacement) { attempts += 1; return false }
        coordinator.restorePendingContentFocus(owner: replacement)
        coordinator.restorePendingContentFocus(owner: replacement)
        #expect(attempts == 1)
        #expect(window.firstResponder === old)
    }
}
