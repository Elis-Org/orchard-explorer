import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

private actor DropStoreWriter: FileTransferring {
    struct Call: Sendable {
        let source: URL
        let destination: URL
        let kind: TransferKind
    }
    private(set) var calls: [Call] = []

    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        calls.append(Call(source: from.directoryURL, destination: to.directoryURL, kind: kind))
        return try await LocalFileTransfers().transfer(item, from: from, to: to, name: name,
            kind: kind, control: control, onProgress: onProgress)
    }
}

@MainActor
private final class DropStoreFiles {
    let root: URL
    let source: URL
    let target: URL
    let child: URL
    let file: URL
    let retained: URL
    let bytes = Data([0, 10, 127, 128, 255])
    let board = NSPasteboard(name: .init("ExplorerDropStore-\(UUID().uuidString)"))
    let writer = DropStoreWriter()
    let clipboard: TransferClipboard

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerDropStore-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        source = root.appendingPathComponent("Source", isDirectory: true)
        target = root.appendingPathComponent("Target", isDirectory: true)
        child = target.appendingPathComponent("Child", isDirectory: true)
        file = source.appendingPathComponent("payload.bin")
        retained = target.appendingPathComponent("retained.txt")
        clipboard = TransferClipboard(pasteboard: board)
        for folder in [source, child] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try bytes.write(to: file)
        try Data("retain my selection".utf8).write(to: retained)
        board.clearContents()
        try #require(board.setString("independent clipboard content", forType: .string))
    }

    func makeStore(at url: URL) -> ExplorerStore {
        ExplorerStore(initialURL: url, transfers: writer, clipboard: clipboard)
    }

    func cleanup() {
        board.releaseGlobally()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned drop-store fixture: \(error)") }
    }
}

/// FR-DROP-001/002/004 → EV-9001/0265–0270 → AT-DROP-001/002/004;
/// NATIVE-P13 store/byte checks only. Pointer delivery and Windows cancellation
/// fidelity (FR-DROP-003 / UNVERIFIED) require separate evidence.
@MainActor
final class FileDropStoreTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let reached = await condition()
        try #require(reached, "Drop store did not reach the expected state before the bounded deadline")
    }

    private func ready(_ store: ExplorerStore) async throws {
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.hasLoaded }
        try #require(!store.activeTab.isUnavailable && store.activeTab.directoryIdentity != nil)
    }

    private func stop(_ store: ExplorerStore) {
        store.cancelTransfer()
        store.cancelLoads()
    }

    private func prepared(_ files: DropStoreFiles, binding: FileDropBinding,
                          kind: TransferKind = .copy) async throws -> PreparedFileDrop {
        let entries = try await LocalFileTransferImporter().capture(urlStrings: [files.file.absoluteString])
        return try await LocalFileDropPreparer().prepare(entries: entries,
            destinationURL: binding.destinationURL,
            expectedDestinationIdentity: binding.expectedDestinationIdentity,
            expectedEntryIdentity: binding.expectedEntryIdentity, kind: kind)
    }

    @Test
    func sourceCaptureUsesExactRequestedRowsAndRejectsPartialOrUnavailableSelections() async throws {
        let files = try DropStoreFiles()
        defer { files.cleanup() }
        let store = files.makeStore(at: files.source)
        defer { stop(store) }
        try await ready(store)
        let row = try #require(store.activeTab.items.first { $0.url == files.file })
        let entries = try #require(store.fileDragEntries(itemIDs: [row.id]))
        #expect(entries.count == 1 && entries[0].item.id == row.id)
        #expect(entries[0].source.directoryURL == files.source)
        #expect(entries[0].source.directoryIdentity == store.activeTab.directoryIdentity)
        #expect(store.fileDragEntries(itemIDs: []) == nil)
        #expect(store.fileDragEntries(itemIDs: [row.id, "missing-row"]) == nil)
        store.tabs[0].isUnavailable = true
        #expect(store.fileDragEntries(itemIDs: [row.id]) == nil)
        #expect(store.fileDropBinding(destinationURL: files.target) == nil)
        #expect(await files.writer.calls.isEmpty)
    }

    @Test(arguments: ["current", "child", "sidebar"])
    func dropCopiesExactBytesAndOnlySelectsResultsWhenReceivingTabDisplaysDestination(_ target: String) async throws {
        let files = try DropStoreFiles()
        defer { files.cleanup() }
        let store = files.makeStore(at: files.target)
        defer { stop(store) }
        try await ready(store)
        let retained = try #require(store.activeTab.items.first { $0.url == files.retained })
        store.setSelection([retained.id], focusedID: retained.id, anchorID: retained.id)
        let selection = store.activeTab.selection
        let destination = target == "current" ? files.target : target == "child" ? files.child : files.source
        // Sidebar destinations need not appear as a row in the receiving tab.
        // Avoid the source parent for this copy: it would be a same-parent refusal.
        let sidebar = files.root.appendingPathComponent("Sidebar", isDirectory: true)
        if target == "sidebar" {
            try FileManager.default.createDirectory(at: sidebar, withIntermediateDirectories: true)
        }
        let actualDestination = target == "sidebar" ? sidebar : destination
        let childIdentity = target == "child" ? store.activeTab.items.first { $0.url == files.child }?.identity : nil
        let binding = try #require(store.fileDropBinding(destinationURL: actualDestination,
            expectedDestinationIdentity: target == "current" ? store.activeTab.directoryIdentity : nil,
            expectedEntryIdentity: childIdentity))
        let drop = try await prepared(files, binding: binding)
        let clipboardCount = files.board.changeCount
        let generalCount = NSPasteboard.general.changeCount
        #expect(store.acceptPreparedFileDrop(drop, binding: binding))
        #expect(!store.acceptPreparedFileDrop(drop, binding: binding))
        try await waitUntil { !store.isPerformingOperation && !store.activeTab.isLoading }
        #expect(await files.writer.calls.count == 1)
        #expect(await files.writer.calls.first?.destination == actualDestination)
        #expect(try Data(contentsOf: actualDestination.appendingPathComponent(files.file.lastPathComponent)) == files.bytes)
        #expect(try Data(contentsOf: files.file) == files.bytes)
        if target == "current" {
            let copied = try #require(store.activeTab.items.first { $0.name == files.file.lastPathComponent })
            #expect(store.activeTab.selection.selectedIDs == [copied.id])
            #expect(store.activeTab.selection.focusedID == copied.id)
        } else {
            #expect(store.activeTab.selection.selectedIDs == selection.selectedIDs)
            #expect(store.activeTab.selection.focusedID == selection.focusedID)
            #expect(store.activeTab.selection.anchorID == selection.anchorID)
        }
        #expect(files.board.changeCount == clipboardCount)
        #expect(files.board.string(forType: .string) == "independent clipboard content")
        #expect(NSPasteboard.general.changeCount == generalCount)
    }

    @Test
    func sameFolderMovePreflightNeverSubmitsOrChangesSelection() async throws {
        let files = try DropStoreFiles()
        defer { files.cleanup() }
        let store = files.makeStore(at: files.source)
        defer { stop(store) }
        try await ready(store)
        let row = try #require(store.activeTab.items.first { $0.url == files.file })
        store.setSelection([row.id], focusedID: row.id, anchorID: row.id)
        let selection = store.activeTab.selection
        let binding = try #require(store.fileDropBinding(destinationURL: files.source))
        let clipboardCount = files.board.changeCount
        do {
            let drop = try await prepared(files, binding: binding, kind: .move)
            _ = store.acceptPreparedFileDrop(drop, binding: binding)
            Issue.record("A same-folder Move must be refused before store submission")
        } catch FileOperationError.unsupported(let message) {
            #expect(message == "Items cannot be moved into their current folder.")
        }
        try await waitUntil { !store.isPerformingOperation && !store.activeTab.isLoading }
        #expect(await files.writer.calls.isEmpty)
        #expect(store.activeTab.selection.selectedIDs == selection.selectedIDs)
        #expect(store.activeTab.selection.focusedID == selection.focusedID)
        #expect(store.activeTab.selection.anchorID == selection.anchorID)
        #expect(store.operationNotice == nil)
        #expect(files.board.changeCount == clipboardCount)
        #expect(try Data(contentsOf: files.file) == files.bytes)
    }

    @Test
    func internalPreparedMoveUsesExistingWriterAndPreservesClipboard() async throws {
        let files = try DropStoreFiles()
        defer { files.cleanup() }
        let store = files.makeStore(at: files.target)
        defer { stop(store) }
        try await ready(store)
        let binding = try #require(store.fileDropBinding(destinationURL: files.target))
        let drop = try await prepared(files, binding: binding, kind: .move)
        let count = files.board.changeCount
        #expect(store.acceptPreparedFileDrop(drop, binding: binding))
        try await waitUntil { !store.isPerformingOperation && !store.activeTab.isLoading }
        #expect(await files.writer.calls.count == 1)
        #expect(await files.writer.calls.first?.kind == .move)
        #expect(!FileManager.default.fileExists(atPath: files.file.path))
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.file.lastPathComponent)) == files.bytes)
        #expect(files.board.changeCount == count)
    }

    @Test(arguments: ["generation", "active-tab", "unavailable", "identity", "name-edit"])
    func staleOrBusyReceivingStateCannotSubmitPreparedWrites(_ change: String) async throws {
        let files = try DropStoreFiles()
        defer { files.cleanup() }
        let store = files.makeStore(at: files.target)
        defer { stop(store) }
        try await ready(store)
        let binding = try #require(store.fileDropBinding(destinationURL: files.target))
        let drop = try await prepared(files, binding: binding)
        switch change {
        case "generation": store.cancelLoads()
        case "active-tab":
            let tab = BrowserTab(url: files.source)
            store.tabs.append(tab)
            store.activeTabID = tab.id
        case "unavailable": store.tabs[0].isUnavailable = true
        case "identity":
            let old = try #require(store.tabs[0].directoryIdentity)
            store.tabs[0].directoryIdentity = LocalFileIdentity(device: old.device,
                inode: old.inode &+ 1, birthSeconds: old.birthSeconds, birthNanoseconds: old.birthNanoseconds)
        default: store.beginCreateFolder()
        }
        #expect(!store.isCurrentFileDropBinding(binding))
        #expect(!store.acceptPreparedFileDrop(drop, binding: binding))
        #expect(await files.writer.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.target.appendingPathComponent(files.file.lastPathComponent).path))
    }
}
