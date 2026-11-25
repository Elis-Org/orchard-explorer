import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

/// NATIVE-P14 native view checks with the real store, loader and searcher over a
/// disposable fixture. These are in-process AppKit/SwiftUI tests, not desktop
/// acceptance. FR-SEARCH-001/002/004, UI-SEARCH-001; MAC-062–065.
@MainActor
final class SearchViewTests {
    private let root: URL

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerSearchView-\(UUID().uuidString)", isDirectory: true)
        let deep = root.appendingPathComponent("Nested/Level 2/Level 3", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("Deep content token quartzmarigold731.".utf8).write(to: deep.appendingPathComponent("needle-name.txt"))
        try Data("decoy".utf8).write(to: root.appendingPathComponent("decoy.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), "Expected state was not reached")
    }

    private func loadedStore() async throws -> ExplorerStore {
        let store = ExplorerStore(initialURL: root, homeURL: root)
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        return store
    }

    /// The Folder column exists only while searching and shows each result's
    /// actual parent; removing it cannot leave header focus on a missing column.
    @Test
    func detailsFolderColumnFollowsSearchPresentationAndShowsActualParent() async throws {
        let store = try await loadedStore()
        defer { store.cancelLoads() }
        let coordinator = DetailsTableView.Coordinator(store: store)
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        table.headerView = header
        for (key, title, width) in DetailsTableView.Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator

        coordinator.synchronizeFolderColumn(searching: store.isSearching)
        #expect(table.tableColumns.count == 4)

        store.submitSearch("needle-name")
        try await waitUntil { store.activeSearch?.phase == .complete }
        coordinator.items = store.displayedItems
        coordinator.synchronizeFolderColumn(searching: store.isSearching)
        #expect(table.tableColumns.map(\.title) == ["Name", "Folder", "Date modified", "Type", "Size"])
        coordinator.synchronizeFolderColumn(searching: true)
        #expect(table.tableColumns.count == 5, "Synchronization is idempotent")
        let folderColumn = table.tableColumns[1]
        let cell = try #require(coordinator.tableView(table, viewFor: folderColumn, row: 0) as? NSTableCellView)
        let expectedParent = root.appendingPathComponent("Nested/Level 2/Level 3", isDirectory: true)
        #expect(cell.toolTip == expectedParent.path)
        #expect(cell.textField?.stringValue == (expectedParent.path as NSString).abbreviatingWithTildeInPath)

        header.focusedColumn = 4
        store.closeSearch()
        coordinator.synchronizeFolderColumn(searching: store.isSearching)
        #expect(table.tableColumns.count == 4)
        #expect(header.focusedColumn == 3, "Size keeps header focus after Folder is removed")
        #expect(table.tableColumns[header.focusedColumn].title == "Size")

        header.focusedColumn = 2
        store.submitSearch("needle-name")
        try await waitUntil { store.activeSearch?.phase == .complete }
        coordinator.synchronizeFolderColumn(searching: true)
        #expect(table.tableColumns[header.focusedColumn].title == "Type", "Type keeps header focus after Folder is inserted")
    }

    /// FR-SEARCH-001/002 native adaptation: typing in the real field and pressing
    /// Return submits a filename search; Escape returns to the original folder.
    @Test
    func searchFieldReturnSubmitsAndEscapeReturnsToFolder() async throws {
        let store = try await loadedStore()
        defer { store.cancelLoads() }
        let host = NSHostingView(rootView: ExplorerSearchField(store: store).frame(width: 260, height: 32))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try #require(Self.textField(in: host))
        #expect(field.placeholderString == "Search \(root.lastPathComponent)")
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("needle-name", replacementRange: NSRange(location: 0, length: 0))
        window.sendEvent(try Self.key("\r", code: 36, window: window))
        try await waitUntil { store.activeSearch?.phase == .complete }
        #expect(store.activeTab.title == "needle-name - Search Results")
        #expect(store.displayedItems.map(\.name) == ["needle-name.txt"])
        #expect(store.activeTab.items.map(\.name).sorted() == ["Nested", "decoy.txt"],
                "The folder snapshot stays intact beneath search results")

        store.requestSearchFocus()
        try await waitUntil { field.currentEditor() != nil }
        window.sendEvent(try Self.key("\u{1b}", code: 53, window: window))
        try await waitUntil { store.activeSearch == nil }
        #expect(store.displayedItems.map(\.name).sorted() == ["Nested", "decoy.txt"])
        #expect(!store.activeTab.history.canGoBack, "Closing search adds no history entry")
    }

    /// MAC-0528 regression: opening a window must not give the search field
    /// keyboard focus; ⌘F (requestSearchFocus) does.
    @Test
    func windowLaunchKeepsSearchFieldUnfocusedUntilFindIsRequested() async throws {
        let store = try await loadedStore()
        defer { store.cancelLoads() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1127, height: 635),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ExplorerShell(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let content = try #require(window.contentView)
        let field = try #require(Self.searchField(in: content))
        #expect(field.currentEditor() == nil, "Launch must not focus the search field")
        #expect(!(window.firstResponder is NSTextView))

        store.requestSearchFocus()
        try await waitUntil { field.currentEditor() != nil }
        #expect(window.firstResponder === field.currentEditor())
    }

    private static func searchField(in view: NSView) -> ExplorerSearchTextField? {
        if let field = view as? ExplorerSearchTextField { return field }
        for child in view.subviews {
            if let found = searchField(in: child) { return found }
        }
        return nil
    }

    /// MAC-077 / MAC-065, NATIVE-P18A: the search-results menu adds only the read-only
    /// Copy as Pathname and Show in Finder; folder-relative writes stay out, and the
    /// background menu offers only Close Search. Commands run through the real menu items.
    @Test
    func searchResultMenuAddsOnlyReadOnlyCommands() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("p18a-search-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.submitSearch("needle-name")
        try await waitUntil { store.activeSearch?.phase == .complete }
        let result = try #require(store.displayedItems.first)
        store.setSelection([result.id], focusedID: result.id)

        let controller = FileContextMenuController(store: store)
        let menu = controller.menu(for: result)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Open", "Open File Location", "Cut", "Copy", "Move to Trash", "Copy as Pathname", "Properties", "Show in Finder", "Tags…"])
        for title in ["Rename", "Share…", "New", "Paste", "Move Here", "Compress to", "Make Alias", "Open With"] {
            #expect(menu.item(withTitle: title) == nil, "\(title) is folder-relative or not offered for results")
        }
        let copyPath = try #require(menu.item(withTitle: "Copy as Pathname"))
        #expect(copyPath.isEnabled)
        menu.performActionForItem(at: menu.index(of: copyPath))
        #expect(board.string(forType: .string) == result.url.path)

        // Astra review 4980d3b6 finding 3 (MAC-065): several results never open
        // together, because each result opens only through its validated activation.
        store.submitSearch(".txt")
        try await waitUntil { store.activeSearch?.phase == .complete && store.displayedItems.count == 2 }
        store.setSelection(Set(store.displayedItems.map(\.id)), focusedID: store.displayedItems.first?.id)
        #expect(store.selectedItemsInOrder.count == 2 && !store.canOpenSelection)
        #expect(controller.menu(for: store.displayedItems[0]).item(withTitle: "Open")?.isEnabled == false)

        let background = controller.menu(for: nil)
        #expect(background.items.map(\.title) == ["Close Search"])
        background.performActionForItem(at: 0)
        #expect(!store.isSearching)
    }

    private static func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = textField(in: child) { return found }
        }
        return nil
    }
}
