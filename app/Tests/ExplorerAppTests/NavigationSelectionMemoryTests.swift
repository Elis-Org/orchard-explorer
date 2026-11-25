import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor NavigationMemoryLoader: DirectoryListing {
    private(set) var requests: [URL] = []
    private var pending: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await withCheckedThrowingContinuation { pending[requests.count] = $0; requests.append(url) }
    }
    func finish(_ index: Int, _ snapshot: DirectorySnapshot) { pending.removeValue(forKey: index)?.resume(returning: snapshot) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoSuchFile)) }
    func stop() { let calls = Array(pending.values); pending.removeAll(); for call in calls { call.resume(throwing: CancellationError()) } }
}

/// WPHY10–15, WZIP10: controlled reads distinguish navigation intent, commit
/// timing, retry and identity from native desktop evidence.
@Suite(.serialized) @MainActor
struct NavigationSelectionMemoryTests {
    private func identity(_ value: UInt64) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: value, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String, root: URL, inode: UInt64, directory: Bool = false) -> FileItem {
        FileItem(url: root.appendingPathComponent(name, isDirectory: directory), name: name, isDirectory: directory,
            isSymbolicLink: false, size: nil, modifiedAt: nil, kind: directory ? "Folder" : "Text", identity: identity(inode))
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let result = await predicate()
        try #require(result, "Controlled navigation did not settle")
    }

    @Test func historyUsesLatestCommittedSelectionWhileAncestorsRevealChildAndRetryRetainsIntent() async throws {
        let root = URL(fileURLWithPath: "/tmp/Navigation Memory", isDirectory: true)
        let grandchild = root.appendingPathComponent("Child/Grandchild", isDirectory: true)
        let child = item("Child", root: root, inode: 2, directory: true)
        let note = item("parent-note.txt", root: root, inode: 3)
        let parentSnapshot = DirectorySnapshot(items: [child, note], directoryIdentity: identity(1))
        let childSnapshot = DirectorySnapshot(items: [], directoryIdentity: identity(4))
        let driver = NavigationMemoryLoader()
        let board = NSPasteboard(name: .init("NavigationMemory-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, loader: driver, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads(); Task { await driver.stop() } }
        try await wait { await driver.requests.count == 1 }
        await driver.finish(0, parentSnapshot)
        try await wait { !store.activeTab.isLoading }
        store.setSelection([note.id], focusedID: note.id)
        store.submitAddress(grandchild)
        try await wait { await driver.requests.count == 2 }
        store.setSelection([child.id], focusedID: child.id)
        await driver.finish(1, childSnapshot)
        try await wait { !store.activeTab.isLoading }
        store.back()
        try await wait { await driver.requests.count == 3 }
        await driver.finish(2, parentSnapshot)
        try await wait { !store.activeTab.isLoading }
        #expect(store.currentSelection.selectedIDs == [child.id], "Save selection at commit, not at request dispatch")

        store.setSelection([note.id], focusedID: note.id)
        store.submitAddress(grandchild)
        try await wait { await driver.requests.count == 4 }
        await driver.finish(3, childSnapshot)
        try await wait { !store.activeTab.isLoading }
        store.navigateBreadcrumb(to: root)
        try await wait { await driver.requests.count == 5 }
        await driver.finish(4, parentSnapshot)
        try await wait { !store.activeTab.isLoading }
        #expect(store.currentSelection.selectedIDs == [child.id], "Breadcrumb intent overrides earlier parent-note selection")

        store.setSelection([note.id], focusedID: note.id)
        store.submitAddress(grandchild)
        try await wait { await driver.requests.count == 6 }
        await driver.finish(5, childSnapshot)
        try await wait { !store.activeTab.isLoading }
        let history = store.activeTab.history
        store.back()
        try await wait { await driver.requests.count == 7 }
        await driver.fail(6)
        try await wait { !store.activeTab.isLoading }
        #expect(store.activeTab.history == history)
        store.retry()
        try await wait { await driver.requests.count == 8 }
        await driver.finish(7, parentSnapshot)
        try await wait { !store.activeTab.isLoading }
        #expect(store.currentSelection.selectedIDs == [note.id], "Retry must remain a history restore, not ancestor reveal")
        #expect(store.operationNotice == nil)
    }

    @Test func unknownOrReplacedIdentityCannotRestore() async throws {
        let root = URL(fileURLWithPath: "/tmp/Memory Identity", isDirectory: true)
        let file = item("note.txt", root: root, inode: 2)
        var selection = SelectionState(); selection.select(file.id, orderedIDs: [file.id])
        var memory = NavigationSelectionMemory()
        memory.remember(location: root, selection: selection, snapshot: DirectorySnapshot(items: [file]))
        #expect(memory.restoredSelection(location: root, snapshot: DirectorySnapshot(items: [file])).selectedIDs.isEmpty)
        memory.remember(location: root, selection: selection,
            snapshot: DirectorySnapshot(items: [file], directoryIdentity: identity(1)))
        #expect(memory.restoredSelection(location: root,
            snapshot: DirectorySnapshot(items: [file], directoryIdentity: identity(10))).selectedIDs.isEmpty)
        memory.remember(location: root, selection: selection,
            snapshot: DirectorySnapshot(items: [file], directoryIdentity: identity(1)))
        let replacement = item("note.txt", root: root, inode: 20)
        #expect(memory.restoredSelection(location: root,
            snapshot: DirectorySnapshot(items: [replacement], directoryIdentity: identity(1))).selectedIDs.isEmpty)
    }

    @Test func memoryEvictsLeastRecentLocationsAndNeverKeepsPartialOversizedSelection() {
        var memory = NavigationSelectionMemory()
        let root = URL(fileURLWithPath: "/tmp/Memory Budget", isDirectory: true)
        for index in 0..<33 {
            let location = root.appendingPathComponent(String(index), isDirectory: true)
            let file = item("note.txt", root: location, inode: UInt64(index + 100))
            var selection = SelectionState(); selection.select(file.id, orderedIDs: [file.id])
            memory.remember(location: location, selection: selection,
                snapshot: DirectorySnapshot(items: [file], directoryIdentity: identity(UInt64(index + 1000))))
        }
        let first = root.appendingPathComponent("0", isDirectory: true)
        #expect(memory.restoredSelection(location: first,
            snapshot: DirectorySnapshot(items: [item("note.txt", root: first, inode: 100)], directoryIdentity: identity(1000))).selectedIDs.isEmpty)
        let last = root.appendingPathComponent("32", isDirectory: true)
        let lastFile = item("note.txt", root: last, inode: 132)
        #expect(memory.restoredSelection(location: last,
            snapshot: DirectorySnapshot(items: [lastFile], directoryIdentity: identity(1032))).selectedIDs == [lastFile.id])
        let many = (0..<10_001).map { item("\($0).txt", root: last, inode: UInt64($0 + 2000)) }
        var selection = SelectionState(); selection.selectAll(many.map(\.id))
        let snapshot = DirectorySnapshot(items: many, directoryIdentity: identity(1032))
        memory.remember(location: last, selection: selection, snapshot: snapshot)
        #expect(memory.restoredSelection(location: last, snapshot: snapshot).selectedIDs.isEmpty)
    }
}
