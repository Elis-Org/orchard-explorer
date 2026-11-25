import AppKit
import Testing
@testable import ExplorerApp

/// FR-FILE-005/011 / EV-0448, EV-0240 / AT-FILE-005/011 command-routing
/// subsets. Synthetic native events and text edits perform no filesystem writes.
@Suite(.serialized)
@MainActor
final class RecoveryResponderTests {
    @Test
    func recoveryCommandsRecheckEligibilityAfterMenuValidation() {
        let (window, table) = focusedFileTable()
        defer { window.close() }
        var eligible = false
        var actions: [String] = []
        table.canTrashSelection = { eligible }
        table.canUndoRename = { eligible }
        table.canRedoRename = { eligible }
        table.onTrash = { actions.append("trash") }
        table.onUndoRename = { actions.append("undo") }
        table.onRedoRename = { actions.append("redo") }
        let selectors = [#selector(ExplorerTableView.moveToTrash(_:)),
                         #selector(ExplorerTableView.undo(_:)), #selector(ExplorerTableView.redo(_:))]
        let commands = selectors.map { NSMenuItem(title: "Recovery", action: $0, keyEquivalent: "") }
        for command in commands { #expect(!table.validateUserInterfaceItem(command)) }
        eligible = true
        for command in commands { #expect(table.validateUserInterfaceItem(command)) }
        eligible = false
        table.moveToTrash(nil)
        table.undo(nil)
        table.redo(nil)
        #expect(actions.isEmpty)
        eligible = true
        table.moveToTrash(nil)
        table.undo(nil)
        table.redo(nil)
        #expect(actions == ["trash", "undo", "redo"])
    }

    @Test
    func commandDeleteRoutesOnlyEligibleTrashIntent() throws {
        let (window, table) = focusedFileTable()
        defer { window.close() }
        var eligible = false
        var requests = 0
        table.canTrashSelection = { eligible }
        table.onTrash = { requests += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        table.keyDown(with: event)
        #expect(requests == 0)
        eligible = true
        table.keyDown(with: event)
        #expect(requests == 1)
    }

    @Test
    func staleTableTargetAndHeaderResponderRouteCannotRecoverFiles() {
        let (window, table) = focusedFileTable()
        defer { window.close() }
        var requests = 0
        table.canTrashSelection = { true }
        table.canUndoRename = { true }
        table.canRedoRename = { true }
        table.onTrash = { requests += 1 }
        table.onUndoRename = { requests += 1 }
        table.onRedoRename = { requests += 1 }
        let selectors = [#selector(ExplorerTableView.moveToTrash(_:)),
                         #selector(ExplorerTableView.undo(_:)), #selector(ExplorerTableView.redo(_:))]
        let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 180, width: 400, height: 24))
        let unrelated = RecoveryFocusView(frame: NSRect(x: 0, y: 150, width: 400, height: 24))
        for responder in [header, unrelated] as [NSView] {
            window.contentView?.addSubview(responder)
            responder.nextResponder = table
            #expect(window.makeFirstResponder(responder))
            #expect(window.firstResponder === responder)
            for selector in selectors {
                let item = NSMenuItem(title: "Recovery", action: selector, keyEquivalent: "")
                #expect(!table.validateUserInterfaceItem(item))
                // The chain can reach the table, but focus is not a file intent.
                _ = responder.tryToPerform(selector, with: nil)
            }
            table.moveToTrash(nil)
            table.undo(nil)
            table.redo(nil)
        }
        #expect(requests == 0)
    }

    @Test
    func nonFileResponderHasNoApplicationRecoveryFallback() {
        _ = NSApplication.shared
        let delegate = ExplorerAppDelegate()
        let sidebar = NSView()
        for selector in [#selector(ExplorerTableView.moveToTrash(_:)),
                         #selector(ExplorerTableView.undo(_:)), #selector(ExplorerTableView.redo(_:))] {
            #expect(!delegate.responds(to: selector))
            #expect(!sidebar.tryToPerform(selector, with: nil))
        }
    }

    @Test
    func nativeNameEditorUndoAndRedoNeverRequestFileRecovery() throws {
        _ = NSApplication.shared
        let window = RecoveryUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView?.addSubview(table)
        let field = NameEditorTextField()
        field.frame = NSRect(x: 20, y: 100, width: 280, height: 24)
        table.addSubview(field)
        var fileRequests = 0
        table.canTrashSelection = { true }
        table.canUndoRename = { true }
        table.canRedoRename = { true }
        table.onTrash = { fileRequests += 1 }
        table.onUndoRename = { fileRequests += 1 }
        table.onRedoRename = { fileRequests += 1 }
        defer { field.finishSession(); window.close() }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        editor.allowsUndo = true
        let manager = try #require(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.insertText("Edited", replacementRange: NSRange(location: 0, length: 8))
        manager.endUndoGrouping()
        editor.breakUndoCoalescing()
        #expect(editor.string == "Edited.txt")
        #expect(manager.canUndo)
        let undo = NSMenuItem(title: "Undo Rename", action: #selector(ExplorerTableView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo Rename", action: #selector(ExplorerTableView.redo(_:)), keyEquivalent: "z")
        #expect(table.validateUserInterfaceItem(undo))
        #expect(undo.title == manager.undoMenuItemTitle)
        #expect(undo.title != "Undo Rename")
        #expect(!table.validateUserInterfaceItem(redo))
        #expect(redo.title == manager.redoMenuItemTitle)
        #expect(redo.title != "Redo Rename")
        #expect(editor.tryToPerform(#selector(ExplorerTableView.undo(_:)), with: nil))
        #expect(editor.string == "Original.txt")
        #expect(manager.canRedo)
        #expect(table.validateUserInterfaceItem(redo))
        #expect(redo.title == manager.redoMenuItemTitle)
        #expect(redo.title != "Redo Rename")
        #expect(editor.tryToPerform(#selector(ExplorerTableView.redo(_:)), with: nil))
        #expect(editor.string == "Edited.txt")
        // Validation and dispatch remain text-only even with a stale table target.
        table.undo(undo)
        #expect(editor.string == "Original.txt")
        table.redo(redo)
        #expect(editor.string == "Edited.txt")
        // Even an explicit stale target must not turn text editing into Trash.
        let trash = NSMenuItem(title: "Move to Trash", action: #selector(ExplorerTableView.moveToTrash(_:)), keyEquivalent: "")
        #expect(!table.validateUserInterfaceItem(trash))
        table.moveToTrash(nil)
        #expect(fileRequests == 0)
    }

    private func focusedFileTable() -> (NSWindow, ExplorerTableView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView?.addSubview(table)
        #expect(window.makeFirstResponder(table))
        #expect(window.firstResponder === table)
        return (window, table)
    }
}

@MainActor
private final class RecoveryFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class RecoveryUndoWindow: NSWindow {
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
}
