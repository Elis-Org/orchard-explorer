import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor HomeTrashRecorder: FileRecovering {
    var items: [TransferEntry] = []
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        items.append(TransferEntry(source: context, item: item))
        if items.count == 2 { throw FileOperationError.staleSource }
        return TrashResult(receipt: TrashReceipt(original: item, originalContext: context, trashed: item,
            trashContext: context), warning: nil)
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult { throw FileOperationError.staleSource }
}

@MainActor
struct HomeFileOperationTests {
    @Test func recentCommandXCutsBothParentsAndMovesBothFilesToTheChosenFolder() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parents = ["Source A", "Source B"].map { root.appendingPathComponent($0, isDirectory: true) }
        let destination = root.appendingPathComponent("Chosen", isDirectory: true)
        for folder in parents + [destination] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? manager.removeItem(at: root) }
        let sources = parents.map { $0.appendingPathComponent("shared.txt", isDirectory: false) }
        let contents = [Data("first source".utf8), Data("second source".utf8)]
        var documents: [RecentDocument] = []
        for (source, bytes) in zip(sources, contents) {
            try bytes.write(to: source)
            documents.append(try #require(await RecentDocument.sample(source)))
        }
        let recent = RecentDocumentStore(defaults: nil)
        recent.record(documents, excluding: [])
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, clipboard: clipboard, recentDocuments: recent)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let rows = documents.map(HomeResultRow.init(recent:))
        store.replaceHomeResults(rows, in: scope)
        store.selectHomeResult(rows[0], in: scope)
        store.selectHomeResult(rows[1], in: scope, toggling: true)

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = HomeResultInputControl(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        row.commandStore = store
        let token = try #require(store.homeResultMembership(rows[1], in: scope))
        row.rowIsCurrent = { store.homeResultMembership(rows[1], in: scope) == token }
        window.contentView?.addSubview(row)
        try #require(window.makeFirstResponder(row))
        let cut = NSMenuItem(title: "Cut", action: #selector(HomeResultInputControl.cut(_:)), keyEquivalent: "x")
        cut.target = window.firstResponder
        let menu = NSMenu()
        menu.addItem(cut)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        try #require(row.validateUserInterfaceItem(cut))
        try #require(menu.performKeyEquivalent(with: event))
        try await waitFor { clipboard.payload != nil }
        let payload = try #require(clipboard.payload)
        let expectedURLs = documents.map(\.url)
        #expect(payload.kind == .move)
        #expect(payload.entries.map(\.item.url.path) == expectedURLs.map(\.path))
        #expect(payload.entries.map(\.item.identity) == documents.map { Optional($0.identity) })
        #expect(payload.entries.map(\.source.directoryURL.path) == expectedURLs.map { $0.deletingLastPathComponent().path })
        let items = try #require(board.pasteboardItems)
        let publicURLs = try items.map { item in
            let data = try #require(item.data(forType: .fileURL))
            let spelling = try #require(String(data: data, encoding: .utf8))
            return try #require(URL(string: spelling))
        }
        #expect(publicURLs.map(\.path) == expectedURLs.map(\.path))
        let readURLs = try #require(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])
        #expect(readURLs.map { ($0 as URL).path } == expectedURLs.map(\.path))
        let hasToken = items.contains { item in
            item.string(forType: .init("com.native-explorer.internal-transfer-token")).flatMap(UUID.init(uuidString:)) != nil
        }
        #expect(items.count == 2 && hasToken)
        #expect(sources.allSatisfy { manager.fileExists(atPath: $0.path) })

        var choices = 0
        store.onChooseHomeFolder = { reply in choices += 1; reply(destination) }
        store.pasteSelection()
        try await waitFor { store.transfer?.conflict != nil }
        store.resolveTransferConflict(.keepBoth)
        try await waitFor { !store.isPerformingOperation }
        #expect(choices == 1 && store.activePage == .home && clipboard.payload == nil)
        #expect(sources.allSatisfy { !manager.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: destination.appendingPathComponent("shared.txt")) == contents[0])
        #expect(try Data(contentsOf: destination.appendingPathComponent("shared (2).txt")) == contents[1])
    }

    @Test func projectionRejectsDuplicateNormalizedPathsAndKeepsDifferentNameBytes() throws {
        let root = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let identity = LocalFileIdentity(device: 1, inode: 10, birthSeconds: 1, birthNanoseconds: 0)
        let parent = FileOperationContext(directoryURL: root, directoryIdentity: identity)
        func entry(_ url: URL) -> TransferEntry {
            return TransferEntry(source: parent, item: FileItem(url: url, name: url.lastPathComponent,
                isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "File", identity: identity))
        }
        let plain = entry(root.appendingPathComponent("child", isDirectory: false))
        let alternate = entry(try #require(URL(string: "file:///fixture/nested/.././child")))
        #expect(HomeFileOperationSampler.indexedEntries([plain, alternate]) == nil)
        let composed = try #require(URL(string: "file:///fixture/Caf%C3%A9"))
        let decomposed = try #require(URL(string: "file:///fixture/Cafe%CC%81"))
        #expect(HomeFileLocations.pathKey(composed) == Data("/fixture/Caf\u{00e9}".utf8))
        #expect(HomeFileLocations.pathKey(decomposed) == Data("/fixture/Cafe\u{0301}".utf8))
        let dotted = try #require(URL(string: "file:///fixture/temp/.././Cafe%CC%81"))
        #expect(HomeFileLocations.pathKey(dotted) == HomeFileLocations.pathKey(decomposed))

        // FileItem accepts a Foundation-standardized URL. A projection must
        // refuse collisions if its supplied URLs already have the same bytes.
        let entries = [entry(composed), entry(decomposed)]
        let storedNames = Set(entries.map { Data($0.item.url.path(percentEncoded: false).utf8) })
        let projected = HomeFileOperationSampler.indexedEntries(entries)
        if storedNames.count == 2 {
            #expect(projected?.count == 2)
        } else {
            #expect(projected == nil)
        }
        print("Home Unicode fixture: 2 input spellings, \(storedNames.count) after FileItem standardization.")
    }

    @Test func failedDestinationReadPreservesSourceCommandsAndReplacementStillRefuses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source")
        try Data("original".utf8).write(to: url)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(item: try #require(FinderTagItem(indexedURL: url, tags: ["Group"], contentTypes: [])), group: "Group")
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        try await waitFor { store.homeOperationEntries != nil }
        let origin = try #require(store.homeOperationOrigin)
        let read = store.readHomeOperationEntry
        store.readHomeOperationEntry = { _ in throw POSIXError(.EAGAIN) }
        await #expect(throws: (any Error).self) { try await store.verifiedHomeDestinationEntries(for: origin) }
        #expect(store.canCopySelection && store.canCutSelection && store.canDeleteSelection)
        store.readHomeOperationEntry = read
        store.copySelection()
        try await waitFor { store.clipboard.payload != nil }
        let previousClipboard = store.clipboard.payload?.id
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("held"))
        try Data("replacement".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await store.verifiedHomeDestinationEntries(for: origin) }
        await #expect(throws: (any Error).self) { try await store.verifiedHomeOperationEntries(for: origin) }
        #expect(store.clipboard.payload?.id == previousClipboard)
    }

    @Test func folderAndChildAgreeForPasteButCannotBeCopiedOrTrashedTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("selection", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = folder.appendingPathComponent("child.txt")
        let incoming = root.appendingPathComponent("incoming.txt")
        try Data("child".utf8).write(to: child)
        let bytes = Data("incoming".utf8)
        try bytes.write(to: incoming)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, clipboard: clipboard)
        defer { store.cancelLoads() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let members = [(folder, ["public.directory"]), (child, ["public.text"])]
        let rows = try members.map { url, types in
            HomeResultRow(item: try #require(FinderTagItem(indexedURL: url, tags: ["Group"], contentTypes: types)), group: "Group")
        }
        store.replaceHomeResults(rows, in: scope)
        store.selectHomeResult(rows[0], in: scope)
        store.selectHomeResult(rows[1], in: scope, extending: true)
        let origin = try #require(store.homeOperationOrigin)
        let destination = try await FileOperationContext.verifiedDirectory(at: folder)
        let facts = try await store.verifiedHomeDestinationEntries(for: origin)
        guard case .folder(let candidate) = ExplorerStore.homeDestination(for: facts) else {
            Issue.record("The folder and child should supply one destination")
            return
        }
        #expect(candidate.directoryIdentity == destination.directoryIdentity)
        #expect(candidate.directoryURL.standardizedFileURL.path == folder.standardizedFileURL.path)
        await #expect(throws: (any Error).self) { try await store.verifiedHomeOperationEntries(for: origin) }
        try await waitFor { !store.canCopySelection }
        #expect(!store.canDeleteSelection && store.homeOperationEntries == nil)
        #expect(store.canAttemptHomeDestination && store.homeDestination == .folder(candidate))
        clipboard.capture(entries: [try await LocalDirectoryLoader.operationEntry(at: incoming)], kind: .copy)
        var asked = false
        store.onChooseHomeFolder = { reply in asked = true; reply(nil) }
        store.pasteSelection()
        let copy = folder.appendingPathComponent(incoming.lastPathComponent)
        try await waitFor { FileManager.default.fileExists(atPath: copy.path) && !store.isPerformingOperation }
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(!asked && FileManager.default.fileExists(atPath: child.path))
    }

    @Test(arguments: [false, true])
    func taggedDirectoryLinkContributesItsLexicalParent(folderClaim: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("links", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        for url in [parent, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let link = parent.appendingPathComponent("shortcut", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let visible = try await FinderTagFile.resultIdentity(at: link)
        #expect(visible.isSymbolicLink)
        await #expect(throws: (any Error).self) { try await FinderTagFile.identity(at: link) }
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root)
        defer { store.cancelLoads() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let item = try #require(FinderTagItem(indexedURL: link, tags: ["Group"],
                                             contentTypes: [folderClaim ? "public.directory" : "public.symlink"]))
        let row = HomeResultRow(item: item, group: "Group")
        store.replaceHomeResults([row], in: scope)
        let membership = try #require(store.homeResultMembership(row, in: scope))
        store.bindHomeResultIdentity(visible.identity, for: row, in: scope, membership: membership, isSymbolicLink: true)
        if folderClaim {
            #expect(store.homeFileDropTarget(row: row) == nil)
            await #expect(throws: (any Error).self) { try await store.verifiedHomeFolder(for: row, in: scope, membership: membership) }
        }
        store.selectHomeResult(row, in: scope)
        let origin = try #require(store.homeOperationOrigin)
        let entries = try await store.verifiedHomeDestinationEntries(for: origin)
        let lexical = try #require(entries.first)
        #expect(lexical.item.isSymbolicLink && lexical.item.identity == visible.identity)
        #expect(lexical.source.directoryURL.path == parent.path)
        #expect(ExplorerStore.homeDestination(for: entries) == .folder(lexical.source))
        #expect(!store.canEditSelectionTags)
    }

    @Test func immediateCopyFromTwoParentsWorksWithBothPanesClosed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [folder, nested].map { $0.appendingPathComponent("same.txt") }
        for url in urls { try Data(url.path.utf8).write(to: url) }
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let rows = try urls.map { url in
            HomeResultRow(item: try #require(FinderTagItem(indexedURL: url, tags: ["Group"], contentTypes: [])), group: "Group")
        }
        store.replaceHomeResults(rows, in: scope)
        store.selectHomeResult(rows[0], in: scope)
        store.selectHomeResult(rows[1], in: scope, extending: true)
        #expect(store.canCopySelection)
        store.copySelection()
        try await waitFor { store.clipboard.payload != nil }
        #expect(store.clipboard.payload?.entries.map(\.item.url.path) == urls.map(\.path))
        #expect(store.clipboard.payload?.entries.map(\.source.directoryURL.path) == [folder.path, nested.path])
        #expect(store.homeDestination == .chooseFolder)
        #expect(store.inspectorPane.mode == .none)
    }

    @Test func trashComponentsAreExcludedFromIndexedTagResults() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/.Trash/a", "/Volumes/Test/.Trashes/501/a"] {
            #expect(FinderTagItem(indexedURL: URL(fileURLWithPath: path), tags: ["Group"], contentTypes: []) == nil)
            #expect(!SystemRecentProvider.allows(path: path, home: home))
        }
        #expect(FinderTagItem(indexedURL: URL(fileURLWithPath: "/Users/example/Trash notes/a"), tags: ["Group"], contentTypes: []) != nil)
        #expect(FinderTagItem(indexedURL: URL(fileURLWithPath: home + "/Projects/.Trash/a"), tags: ["Group"], contentTypes: []) != nil)
        #expect(FinderTagItem(indexedURL: URL(fileURLWithPath: "/Volumes/Test/Project/.Trashes/a"), tags: ["Group"], contentTypes: []) != nil)
    }

    @Test func delayedCopyHonorsNewClipboardAndRefusesReplacedEntries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("entry.txt")
        try Data("original".utf8).write(to: url)
        let original = try await LocalDirectoryLoader.operationEntry(at: url)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder, clipboard: TransferClipboard(pasteboard: board))
        let held = HeldInspectorReads()
        defer { store.cancelLoads(); Task { await held.stop() } }
        store.readHomeOperationEntry = { _ in try await held.sample() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let match = try #require(FinderTagItem(indexedURL: url, tags: ["One", "Two"], contentTypes: []))
        let rows = ["One", "Two"].map { HomeResultRow(item: match, group: $0) }
        store.replaceHomeResults(rows, in: scope)
        store.selectHomeResult(rows[0], in: scope)
        store.selectHomeResult(rows[1], in: scope, extending: true)
        let origin = try #require(store.homeOperationOrigin)
        #expect(origin.selectedUniqueCount == 1)
        store.cutSelection()
        try await waitFor { await held.count == 1 }
        await held.finish(0, with: original)
        try await waitFor { await held.count == 2 }
        board.clearContents()
        board.setString("newer clipboard", forType: .string)
        await held.finish(1, with: original)
        try await waitFor { store.homeFileOperations.command == nil }
        #expect(board.string(forType: .string) == "newer clipboard")
        #expect(store.clipboard.payload == nil)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("held.txt"))
        try Data("replacement".utf8).write(to: url)
        let replacement = try await LocalDirectoryLoader.operationEntry(at: url)
        store.copySelection()
        try await waitFor { await held.count == 3 }
        await held.finish(2, with: replacement)
        try await waitFor { store.homeFileOperations.command == nil }
        #expect(store.clipboard.payload == nil)
        #expect(board.string(forType: .string) == "newer clipboard")
        #expect(store.operationNotice != nil)
    }

    @Test func recentTrashUsesDistinctParentsRetainsFailuresAndDoesNotReopenAnything() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var docs: [RecentDocument] = []
        for parent in [folder, nested] {
            let url = parent.appendingPathComponent("sample.txt")
            try Data("text".utf8).write(to: url)
            docs.append(try #require(await RecentDocument.sample(url)))
        }
        let recent = RecentDocumentStore(), recorder = HomeTrashRecorder()
        recent.record(docs, excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder, recovery: recorder,
                                  recoveryHistory: RecoveryHistory(), recentDocuments: recent)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let rows = docs.map(HomeResultRow.init(recent:))
        store.replaceHomeResults(rows, in: scope)
        store.selectHomeResult(rows[0], in: scope)
        store.selectHomeResult(rows[1], in: scope, extending: true)
        let originalActivity = try #require(recent.entries.first { $0.id == docs[1].id }?.openedAt)
        store.deleteSelection()
        try await waitFor { store.trashProgress == nil && store.operationNotice != nil }
        #expect(await recorder.items.map(\.source.directoryURL.path) == [folder.path, nested.path])
        #expect(store.recoveryHistory.entries.map(\.original.url.path) == [docs[0].url.path])
        #expect(store.activeTab.url == BrowserPage.home.url)
        #expect(store.activeTab.homeResults.selection.selectedIDs == [rows[1].id])
        #expect(recent.entries.map(\.id) == [docs[1].id])
        #expect(recent.entries.first?.openedAt == originalActivity)
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let reached = await condition()
        try #require(reached)
    }
}
