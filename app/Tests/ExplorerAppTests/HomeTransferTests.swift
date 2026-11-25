import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

@MainActor
struct HomeTransferTests {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }

    @Test func renameFromRecentUsesTheRealParentAndUndoKeepsHomeOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        let renamed = root.appendingPathComponent("renamed.txt")
        let bytes = Data("rename fixture".utf8)
        try bytes.write(to: source)
        let recent = RecentDocumentStore(defaults: nil)
        let document = try #require(await RecentDocument.sample(source))
        recent.record([document], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, recentDocuments: recent)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(recent: document)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        store.beginRename()
        try await waitFor { store.nameEdit != nil }
        let edit = try #require(store.nameEdit)
        #expect(edit.directoryURL.standardizedFileURL.path == source.deletingLastPathComponent().standardizedFileURL.path)
        store.updateProposedName("renamed.txt", sessionID: edit.id)
        store.commitNameEdit(sessionID: edit.id)
        try await waitFor { store.canUndoRename }
        #expect(try Data(contentsOf: renamed) == bytes)
        #expect(!recent.contains(document))
        #expect(store.activePage == .home)
        store.undoRename()
        try await waitFor { store.canRedoRename }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
        #expect(store.activePage == .home)
    }

    @Test func cancelledFolderChoicePreservesCutAndChangedClipboardPreventsPaste() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("synthetic contents".utf8).write(to: source)
        let entry = try await LocalDirectoryLoader.inspectorEntry(at: source)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, clipboard: clipboard,
                                  recentDocuments: RecentDocumentStore(defaults: nil))
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        store.replaceHomeResults([], in: scope)
        var reply: ((URL?) -> Void)?
        store.onChooseHomeFolder = { reply = $0 }
        clipboard.capture(entries: [entry], kind: .move)
        let token = try #require(clipboard.payload?.id)
        store.pasteSelection()
        try await waitFor { reply != nil }
        #expect(!store.canPaste && !store.isCommandIdle)
        reply?(nil)
        #expect(clipboard.payload?.id == token)
        #expect(FileManager.default.fileExists(atPath: source.path))
        reply = nil
        store.pasteSelection()
        try await waitFor { reply != nil }
        board.clearContents()
        board.setString("replacement", forType: .string)
        reply?(dest)
        try await waitFor { store.operationNotice != nil }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("sample.txt").path))
        #expect(board.string(forType: .string) == "replacement")
    }

    @Test(arguments: [false, true])
    func closingTheOwnerRevokesPendingDirectoryChoice(closeWindow: Bool) throws {
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: RecentDocumentStore(defaults: nil))
        defer { store.cancelLoads() }
        var delayed: ((URL?) -> Void)?
        var answered = false
        var delivered: FileOperationContext?
        store.onChooseHomeFolder = { delayed = $0 }
        let origin = try #require(store.homeOperationOrigin)
        #expect(store.chooseHomeDestination(for: origin) { delivered = $0; answered = true })
        let admittedSecond = store.chooseHomeDestination(for: origin) { #expect($0 == nil) }
        #expect(!admittedSecond)
        if closeWindow { store.cancelLoads() }
        else { store.closeTab(store.activeTabID) }
        delayed?(FileManager.default.temporaryDirectory)
        #expect(answered && delivered == nil && store.pendingHomeDestination == nil)
    }

    @Test func chooserCopiesIntoTheChosenFolderWithoutLeavingHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        let data = Data("home test".utf8)
        try data.write(to: source)
        let entry = try await LocalDirectoryLoader.inspectorEntry(at: source)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, clipboard: clipboard,
                                  recentDocuments: RecentDocumentStore(defaults: nil))
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        store.replaceHomeResults([], in: scope)
        clipboard.capture(entries: [entry], kind: .copy)
        store.onChooseHomeFolder = { $0(dest) }
        store.pasteSelection()
        let copy = dest.appendingPathComponent("sample.txt")
        try await waitFor { FileManager.default.fileExists(atPath: copy.path) && !store.isPerformingOperation }
        #expect(try Data(contentsOf: copy) == data)
        #expect(try Data(contentsOf: source) == data)
        #expect(store.activePage == .home)
        #expect(store.canPaste)
    }

    @Test func contextualPasteIntoFolderUsesItsOwnMembershipWhenAnotherSelectedFileIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        let bytes = Data("folder row".utf8)
        try bytes.write(to: source)
        let entry = try await LocalDirectoryLoader.operationEntry(at: source)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let choices = FinderTagShortcuts()
        choices.setShowsAllTagged(true)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, clipboard: clipboard, tagShortcuts: choices)
        defer { store.cancelLoads() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let target = try #require(FinderTagItem(indexedURL: folder, tags: ["Work"], contentTypes: ["public.directory"]))
        let missing = try #require(FinderTagItem(indexedURL: root.appendingPathComponent("gone"), tags: ["Work"], contentTypes: ["public.text"]))
        let row = HomeResultRow(item: target, group: "Work")
        let missingRow = HomeResultRow(item: missing, group: "Work")
        store.replaceHomeResults([row, missingRow], in: scope)
        store.selectHomeResult(row, in: scope)
        store.selectHomeResult(missingRow, in: scope, toggling: true)
        clipboard.capture(entries: [entry], kind: .copy)
        #expect(store.canPaste(toHomeRow: row))
        store.pasteSelection(toHomeRow: row)
        let copy = folder.appendingPathComponent("sample.txt")
        try await waitFor { FileManager.default.fileExists(atPath: copy.path) && !store.isPerformingOperation }
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(store.activePage == .home && store.activeTab.homeSection == .tags)
    }
}
