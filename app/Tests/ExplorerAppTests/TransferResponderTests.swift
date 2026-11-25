import AppKit
import Testing
@testable import ExplorerApp

/// FR-FILE-003/004 / EV-0252/0255 / AT-FILE-003/004: native command-routing
/// assertions only. These tests do not read/write the user's system clipboard.
@Suite(.serialized)
@MainActor
final class TransferResponderTests {
    @Test(arguments: [false, true])
    func detailsStaleExplicitClipboardTargetsRequireFileFocus(textEditing: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        let field = NameEditorTextField()
        field.frame = NSRect(x: 20, y: 185, width: 280, height: 24)
        window.contentView?.addSubview(table)
        window.contentView?.addSubview(field)
        defer { field.finishSession(); window.close() }
        try #require(window.makeFirstResponder(table))
        var actions: [String] = []
        table.canCopySelection = { true }
        table.canCutSelection = { true }
        table.canPasteSelection = { true }
        table.onCopy = { actions.append("copy") }
        table.onCut = { actions.append("cut") }
        table.onPaste = { actions.append("paste") }
        let commands = [
            NSMenuItem(title: "Copy", action: #selector(ExplorerTableView.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Cut", action: #selector(ExplorerTableView.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Paste", action: #selector(ExplorerTableView.paste(_:)), keyEquivalent: "v")
        ]
        for command in commands { #expect(table.validateUserInterfaceItem(command)) }
        if textEditing {
            field.beginSession(id: UUID(), name: "Selected text.txt", selection: NSRange(location: 0, length: 8))
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(window.firstResponder === editor)
            for command in commands {
                let target = NSApp.target(forAction: command.action!, to: editor, from: nil) as AnyObject?
                #expect(target === editor)
            }
        } else {
            try #require(window.makeFirstResponder(nil))
            try #require(window.firstResponder !== table)
        }
        // Capabilities remain true: stale native targets must independently
        // reject dispatch after focus changes, even after earlier validation.
        for command in commands { #expect(!table.validateUserInterfaceItem(command)) }
        table.copy(commands[0])
        table.cut(commands[1])
        table.paste(commands[2])
        #expect(actions.isEmpty)
    }

    @Test(arguments: [false, true])
    func detailsUnavailableCutNeverInheritsCopyEligibility(omitsCutCapability: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        window.contentView = table
        defer { window.close() }
        try #require(window.makeFirstResponder(table))
        var actions: [String] = []
        table.canCopySelection = { true }
        if !omitsCutCapability { table.canCutSelection = { false } }
        table.onCopy = { actions.append("copy") }
        table.onCut = { actions.append("cut") }
        let copy = NSMenuItem(title: "Copy", action: #selector(ExplorerTableView.copy(_:)), keyEquivalent: "c")
        let cut = NSMenuItem(title: "Cut", action: #selector(ExplorerTableView.cut(_:)), keyEquivalent: "x")
        #expect(table.validateUserInterfaceItem(copy))
        #expect(!table.validateUserInterfaceItem(cut))
        table.cut(cut)
        #expect(actions.isEmpty)
        table.copy(copy)
        #expect(actions == ["copy"])
    }

    @Test
    func menuValidationReadsCurrentEligibilityAndActionsRecheckIt() {
        let (window, table) = focusedTable()
        defer { window.close() }
        var canCopy = false
        var canCut = false
        var canPaste = false
        var actions: [String] = []
        table.canCopySelection = { canCopy }
        table.canCutSelection = { canCut }
        table.canPasteSelection = { canPaste }
        table.onCopy = { actions.append("copy") }
        table.onCut = { actions.append("cut") }
        table.onPaste = { actions.append("paste") }
        let copy = NSMenuItem(title: "Copy", action: #selector(ExplorerTableView.copy(_:)), keyEquivalent: "c")
        let cut = NSMenuItem(title: "Cut", action: #selector(ExplorerTableView.cut(_:)), keyEquivalent: "x")
        let paste = NSMenuItem(title: "Paste", action: #selector(ExplorerTableView.paste(_:)), keyEquivalent: "v")
        #expect(!table.validateUserInterfaceItem(copy))
        #expect(!table.validateUserInterfaceItem(cut))
        #expect(!table.validateUserInterfaceItem(paste))
        canCopy = true
        canCut = true
        #expect(table.validateUserInterfaceItem(copy))
        #expect(table.validateUserInterfaceItem(cut))
        #expect(!table.validateUserInterfaceItem(paste))
        canPaste = true
        #expect(table.validateUserInterfaceItem(paste))
        // Eligibility may change between menu validation and command dispatch.
        canCopy = false
        canCut = false
        canPaste = false
        table.copy(copy)
        table.cut(cut)
        table.paste(paste)
        #expect(actions.isEmpty)
    }

    @Test
    func fileResponderDispatchesOnlyTheRequestedIntent() {
        let (window, table) = focusedTable()
        defer { window.close() }
        var actions: [String] = []
        table.canCopySelection = { true }
        table.canCutSelection = { true }
        table.canPasteSelection = { true }
        table.onCopy = { actions.append("copy") }
        table.onCut = { actions.append("cut") }
        table.onPaste = { actions.append("paste") }
        table.copy(nil)
        table.cut(nil)
        table.paste(nil)
        #expect(actions == ["copy", "cut", "paste"])
    }

    @Test
    func nativeTextEditorOwnsClipboardSelectorsWhileEditingName() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView?.addSubview(table)
        let field = NameEditorTextField()
        field.frame = NSRect(x: 20, y: 100, width: 280, height: 24)
        table.addSubview(field)
        defer { field.finishSession(); window.close() }
        field.beginSession(id: UUID(), name: "Selected text.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        for selector in [#selector(ExplorerTableView.copy(_:)), #selector(ExplorerTableView.cut(_:)),
                         #selector(ExplorerTableView.paste(_:))] {
            // Resolve at the actual native first responder without performing a
            // clipboard mutation. The table is not the action target in this state.
            let target = NSApp.target(forAction: selector, to: window.firstResponder, from: nil) as AnyObject?
            #expect(target === editor)
            #expect(target !== table)
        }
    }

    private func focusedTable() -> (NSWindow, ExplorerTableView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView = table
        #expect(window.makeFirstResponder(table))
        return (window, table)
    }
}
