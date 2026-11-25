import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@MainActor
struct HomeSharedMenuTests {
    @Test func coldMenuCancelsOnReplacementTeardownAndWindowDeactivation() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("cold menu".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let history = RecentDocumentStore(defaults: nil)
        let document = try #require(await RecentDocument.sample(url))
        history.record([document], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: history)
        defer { store.cancelLoads() }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        store.readHomeOperationEntry = { url in
            for await _ in gate.stream { break }
            return try await LocalDirectoryLoader.operationEntry(at: url)
        }
        let row = HomeResultRow(recent: document)
        let scope = try #require(store.homeResultScope)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        let controller = FileContextMenuController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let origin = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = origin
        func requestMenu() throws -> Task<Void, Never> {
            try #require(controller.presentHome(row: row, at: .zero, in: origin, keyboard: false))
            return try #require(controller.pendingHome)
        }
        let first = try requestMenu()
        controller.dismissPresentedMenu(from: NSView())
        #expect(!first.isCancelled)
        let second = try requestMenu()
        #expect(first.isCancelled)
        controller.dismissPresentedMenu(from: origin)
        #expect(second.isCancelled)
        let third = try requestMenu()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(third.isCancelled)
        #expect(controller.pendingHome == nil)
        gate.continuation.finish()
        await third.value
        #expect(controller.pendingHome == nil)
    }

    @Test func sharedMenuUsesTheSameCommandsForOneFileAcrossViews() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("menu comparison".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let recent = RecentDocumentStore(defaults: nil)
        let document = try #require(await RecentDocument.sample(file))
        recent.record([document], excluding: [])
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: BrowserPage.home.url, clipboard: TransferClipboard(pasteboard: board), recentDocuments: recent)
        defer { store.cancelLoads() }
        let menus = FileContextMenuController(store: store)
        let row = HomeResultRow(recent: document)
        func menu(for rows: [HomeResultRow]) async throws -> ContextCommandMenu {
            let scope = try #require(store.homeResultScope)
            store.replaceHomeResults(rows, in: scope)
            store.selectHomeResult(rows[0], in: scope)
            for extra in rows.dropFirst() { store.selectHomeResult(extra, in: scope, toggling: true) }
            let invocation = try #require(HomeFileMenuOrigin(store: store, row: rows[0]))
            await store.finishHomeSelectionPreparation(for: invocation.selection)
            return try #require(menus.menu(for: invocation))
        }
        let recentMenu = try await menu(for: [row])
        let item = try #require(recentMenu.snapshot.items.first)
        let ordinary = try await P18Fixture.make()
        defer { ordinary.close() }
        ordinary.store.tabs[0].items = [item]
        ordinary.select([item])
        let files = FileContextMenuController(store: ordinary.store)
        let folderMenu = try #require(files.menu(for: item) as? ContextCommandMenu)
        store.selectHomeSection(.tags)
        let tag = try #require(FinderTagItem(indexedURL: file, tags: ["One","Two"], contentTypes: ["public.text"]))
        let tagMenu = try await menu(for: ["One", "Two"].map { HomeResultRow(item: tag, group: $0) })
        #expect(tagMenu.snapshot.items.count == 1)
        let ids = folderMenu.items.compactMap { $0.identifier?.rawValue }
        for homeMenu in [recentMenu, tagMenu] {
            let shared = homeMenu.items.compactMap { $0.identifier?.rawValue }.filter { !["context-paste", "context-removeFromRecent"].contains($0) }
            #expect(shared == ids)
            let strip = ContextMenuNavigation(menu: homeMenu, keyboard: true).rowItems.compactMap { $0.identifier?.rawValue }
            #expect(strip == ["context-cut","context-copy","context-rename","context-share","context-moveToTrash"])
            #expect(homeMenu.item(withTitle: "Compress to")?.submenu?.items.map(\.title) == folderMenu.item(withTitle: "Compress to")?.submenu?.items.map(\.title))
        }
        #expect(recentMenu.item(withTitle: "Remove from Recent") != nil)
        #expect(tagMenu.item(withTitle: "Remove from Recent") == nil)
        #expect(!recentMenu.snapshot.matches(store))
    }

    @Test func removingStaleRecentHistoryKeepsTheReplacementFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.txt")
        try Data("old".utf8).write(to: url)
        let document = try #require(await RecentDocument.sample(url))
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old.txt"))
        let replacement = Data("replacement".utf8)
        try replacement.write(to: url)
        let history = RecentDocumentStore(defaults: nil)
        history.record([document], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: history)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(recent: document)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        let invocation = try #require(HomeFileMenuOrigin(store: store, row: row))
        await store.finishHomeSelectionPreparation(for: invocation.selection)
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: invocation))
        #expect(menu.snapshot.items.isEmpty)
        #expect(menu.item(withTitle: "Open")?.isEnabled == true)
        #expect(menu.item(withTitle: "Move to Trash")?.isEnabled == false)
        let remove = try #require(menu.item(withTitle: "Remove from Recent"))
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        try #require(session.activate(remove))
        try await p18Wait { !history.contains(document) }
        #expect(try Data(contentsOf: url) == replacement)
        #expect(session.state == .completed)
    }
}
