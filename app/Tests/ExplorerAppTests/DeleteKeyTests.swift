import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// MAC-079 (amends MAC-036) — FR-FILE-005 / EV-0444–0448 / AT-FILE-005 routing subset;
/// FR-FILE-006/021 stay unimplemented (Shift+Delete never deletes). Synthetic events,
/// a synthetic loader and a recording Trash double: no filesystem writes.
@Suite(.serialized) @MainActor
struct DeleteKeyTests {
    static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false, window: Int = 0) throws -> NSEvent {
        let character = code == 117 ? String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!) : "\u{7f}"
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: isRepeat, keyCode: code))
    }

    @Test func classification() throws {
        for code: UInt16 in [51, 117] {
            #expect(FileListDeleteKey(try Self.key(code)) == .trash)
            #expect(FileListDeleteKey(try Self.key(code, .command)) == .trash)
            #expect(FileListDeleteKey(try Self.key(code, .shift)) == .permanentUnavailable)
            #expect(FileListDeleteKey(try Self.key(code, repeat: true)) == .ignoredRepeat)
            #expect(FileListDeleteKey(try Self.key(code, .shift, repeat: true)) == .ignoredRepeat)
            for other: NSEvent.ModifierFlags in [.option, .control, [.command, .shift], [.command, .option]] {
                #expect(FileListDeleteKey(try Self.key(code, other)) == nil, "keeps its previous behavior")
            }
        }
        // fn is reported with Forward Delete on laptop keyboards and must not change the intent.
        #expect(FileListDeleteKey(try Self.key(117, .function)) == .trash)
        #expect(FileListDeleteKey(try Self.key(36)) == nil)
    }

    /// Details: ⌫ / ⌦ / ⌘⌫ request Trash only when eligible; repeats are ignored;
    /// Shift+Delete explains instead of deleting.
    @Test func detailsRouting() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView?.addSubview(table)
        #expect(window.makeFirstResponder(table))
        var eligible = false, trash = 0, explained = 0
        table.canTrashSelection = { eligible }
        table.onTrash = { trash += 1 }
        table.onPermanentDeleteUnavailable = { explained += 1 }
        let n = window.windowNumber
        table.keyDown(with: try Self.key(51, window: n)); #expect(trash == 0, "ineligible selection")
        eligible = true
        table.keyDown(with: try Self.key(51, window: n))
        table.keyDown(with: try Self.key(117, .function, window: n))
        table.keyDown(with: try Self.key(51, .command, window: n))
        #expect(trash == 3)
        table.keyDown(with: try Self.key(51, repeat: true, window: n))
        table.keyDown(with: try Self.key(117, repeat: true, window: n))
        #expect(trash == 3, "auto-repeat never trashes again")
        table.keyDown(with: try Self.key(51, .shift, window: n))
        table.keyDown(with: try Self.key(117, .shift, window: n))
        #expect(trash == 3 && explained == 2)
    }

    /// Icon layouts through the real store: ⌫ and ⌦ reach the Trash service for the
    /// selection; Shift+Delete posts the explanation and trashes nothing; an open
    /// name editor blocks the route.
    @Test func collectionRoutingThroughStore() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        let n = f.window?.windowNumber ?? 0
        func trashed() async -> [String] { await f.operations.trashedNames }
        func select(_ index: Int) async throws {
            try await p18Wait { !f.store.isPerformingOperation && !f.store.activeTab.isLoading }
            view.selectItem(at: index, extending: false, toggling: false)
            try await p18Wait { f.store.canTrashSelection }
        }
        // Shift+Delete explains and trashes nothing.
        try await select(1)
        view.keyDown(with: try Self.key(51, .shift, window: n))
        #expect(f.store.operationNotice?.hasPrefix("Permanent deletion isn’t available.") == true)
        // An open name editor blocks the route.
        f.store.beginRename(); #expect(f.store.nameEdit != nil)
        view.keyDown(with: try Self.key(51, window: n))
        f.store.cancelNameEdit()
        try await Task.sleep(for: .milliseconds(50)); #expect(await trashed().isEmpty)
        // ⌫ then ⌦ reach the Trash service for the selection; a repeat does nothing.
        view.keyDown(with: try Self.key(51, window: n))
        try await p18Wait { !f.store.isPerformingOperation }; #expect(await trashed() == [f.items[1].name])
        view.keyDown(with: try Self.key(51, repeat: true, window: n))
        try await Task.sleep(for: .milliseconds(50)); #expect(await trashed().count == 1)
        try await select(2)
        view.keyDown(with: try Self.key(117, .function, window: n))
        try await p18Wait { !f.store.isPerformingOperation }; #expect(await trashed() == [f.items[1].name, f.items[2].name])
    }

    /// Review a6fd3c08 finding 1: ⌘⌫ is a main-menu key equivalent that reaches
    /// moveToTrash: without the list's keyDown. Its auto-repeat must be ignored
    /// too, in both views; a first press and a mouse-chosen menu item still trash.
    @Test func menuKeyEquivalentRepeatIsIgnoredInBothViews() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView?.addSubview(table); #expect(window.makeFirstResponder(table))
        var trash = 0; table.canTrashSelection = { true }; table.onTrash = { trash += 1 }
        let menu = NSMenu(), item = NSMenuItem(title: "Move to Trash", action: #selector(ExplorerTableView.moveToTrash(_:)), keyEquivalent: "\u{7f}")
        item.target = table; menu.addItem(item)
        let first = try Self.key(51, .command, window: window.windowNumber), repeated = try Self.key(51, .command, repeat: true, window: window.windowNumber)
        table.triggeringEvent = { first }; #expect(menu.performKeyEquivalent(with: first)); #expect(trash == 1)
        table.triggeringEvent = { repeated }; _ = menu.performKeyEquivalent(with: repeated); #expect(trash == 1, "a held ⌘⌫ does not trash again through the menu")
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        table.triggeringEvent = { click }; menu.performActionForItem(at: 0); #expect(trash == 2, "a mouse-chosen menu item still trashes")

        let f = try await P18Fixture.make(); defer { f.close() }
        f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        view.selectItem(at: 1, extending: false, toggling: false); try await p18Wait { f.store.canTrashSelection }
        view.triggeringEvent = { repeated }; view.moveToTrash(nil)
        try await Task.sleep(for: .milliseconds(50)); #expect(await f.operations.trashedNames.isEmpty)
        view.triggeringEvent = { first }; view.moveToTrash(nil)
        try await p18Wait { !f.store.isPerformingOperation }; #expect(await f.operations.trashedNames == [f.items[1].name])
    }
}
