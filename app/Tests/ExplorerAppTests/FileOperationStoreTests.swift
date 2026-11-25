import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// No filesystem access: reads and writes complete only when a test explicitly releases them.
private actor WriteStoreDriver: DirectoryListing, FileOperating {
    struct Write: Sendable {
        let item: FileItem?
        let name: String
        let context: FileOperationContext
    }
    private(set) var reads: [URL] = []
    private(set) var writes: [Write] = []
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingWrites: [Int: CheckedContinuation<FileOperationResult, Error>] = [:]

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pendingReads[reads.count] = continuation
            reads.append(url)
        }
    }
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await write(item: nil, name: name, context: context)
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await write(item: item, name: name, context: context)
    }
    private func write(item: FileItem?, name: String, context: FileOperationContext) async throws -> FileOperationResult {
        try await withCheckedThrowingContinuation { continuation in
            pendingWrites[writes.count] = continuation
            writes.append(Write(item: item, name: name, context: context))
        }
    }
    func finishRead(_ index: Int, _ value: DirectorySnapshot) {
        pendingReads.removeValue(forKey: index)?.resume(returning: value)
    }
    func failRead(_ index: Int) {
        pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
    func finishWrite(_ index: Int, _ value: FileOperationResult) {
        pendingWrites.removeValue(forKey: index)?.resume(returning: value)
    }
    func failWrite(_ index: Int) {
        pendingWrites.removeValue(forKey: index)?.resume(throwing: FileOperationError.collision("taken.txt"))
    }
    func releasePending() {
        let reads = Array(pendingReads.values), writes = Array(pendingWrites.values)
        pendingReads.removeAll()
        pendingWrites.removeAll()
        for continuation in reads { continuation.resume(throwing: CancellationError()) }
        for continuation in writes { continuation.resume(throwing: CancellationError()) }
    }
}

private struct DraftChangeObserver: DirectoryObserving {
    let events = AsyncThrowingStream<DirectoryChange, Error>.makeStream()
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> { events.stream }
    func changed() { events.continuation.yield(.changed) }
}

/// Model coverage for FR-FILE-001 / EV-0263–0267 / AT-FILE-001, FR-FILE-002/008
/// / EV-0226–0232 / AT-FILE-002/008, and FR-FILE-018 / EV-0233–0235 / AT-FILE-018.
/// Staging, exclusive operation guards and identity-verified reconciliation are explicit
/// native policies in ARCHITECTURE.md; these tests do not establish full GUI acceptance.
@MainActor
final class FileOperationStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-write-model", isDirectory: true)

    private func identity(_ inode: UInt64 = 100) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String = "rename-me.txt", inode: UInt64? = 101,
                      directory: Bool = false, link: Bool = false) -> FileItem {
        FileItem(url: root.appendingPathComponent(name, isDirectory: directory), name: name,
                 isDirectory: directory, isSymbolicLink: link, size: directory ? nil : 26,
                 modifiedAt: nil, kind: directory ? "File folder" : "Text Document",
                 identity: inode.map { identity($0) })
    }
    private func snapshot(_ items: [FileItem] = [], parent: UInt64? = 100) -> DirectorySnapshot {
        DirectorySnapshot(items: items, directoryIdentity: parent.map { identity($0) })
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Store did not reach the expected state before the bounded deadline")
    }
    private func ready(_ items: [FileItem] = [], observer: DraftChangeObserver? = nil)
        async throws -> (ExplorerStore, WriteStoreDriver) {
        let driver = WriteStoreDriver()
        let store = ExplorerStore(initialURL: root, loader: driver, homeURL: root,
                                  observer: observer, operations: driver)
        try await waitUntil { await driver.reads.count == 1 }
        await driver.finishRead(0, snapshot(items))
        try await waitUntil { !store.activeTab.isLoading }
        return (store, driver)
    }
    private func stop(_ store: ExplorerStore, _ driver: WriteStoreDriver) {
        store.cancelLoads()
        Task { await driver.releasePending() }
    }
    private func beginRename(_ store: ExplorerStore, _ item: FileItem) throws -> NameEditSession {
        store.setSelection([item.id], focusedID: item.id)
        store.beginRename()
        return try #require(store.nameEdit)
    }

    @Test
    func newFolderDraftDoesNotChangeTheSnapshotOrItemCount() async throws {
        for names in [[], ["New folder", "New folder (2)"]] as [[String]] {
            let entries = names.enumerated().map { item($0.element, inode: UInt64(101 + $0.offset), directory: true) }
            let (store, driver) = try await ready(entries)
            defer { stop(store, driver) }
            store.beginCreateFolder()
            let draft = try #require(store.nameEdit)
            let expected = names.isEmpty ? "New folder" : "New folder (3)"
            #expect(draft.proposedName == expected)
            #expect(draft.initialSelection == NSRange(location: 0, length: (expected as NSString).length))
            #expect(draft.isNewFolder)
            #expect(store.activeTab.items == entries)
            #expect(store.sortedItems.count == entries.count)
            #expect(store.displayedItems.count == entries.count + 1)
            #expect(store.displayedItems.last?.id == draft.rowID)
            #expect(store.activeTab.selection.selectedIDs.isEmpty)
            store.updateProposedName("DropTarget", sessionID: draft.id)
            store.cancelNameEdit(sessionID: draft.id)
            #expect(store.nameEdit == nil)
            #expect(store.displayedItems.count == entries.count)
            #expect(await driver.writes.isEmpty)
        }
    }

    @Test
    func renameSelectsTheBasenameAndCancelPreservesTheOriginalSelection() async throws {
        let original = item("Café😀.txt")
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        #expect(draft.initialSelection == NSRange(location: 0, length: ("Café😀" as NSString).length))
        #expect(draft.originalName == original.name)
        #expect(draft.placeholder == nil)
        store.updateProposedName("tentative.txt", sessionID: draft.id)
        store.cancelNameEdit(sessionID: draft.id)
        #expect(store.activeTab.items == [original])
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        #expect(store.activeTab.selection.focusedID == original.id)
        #expect(store.nameEdit == nil)
        #expect(await driver.writes.isEmpty)
    }

    @Test
    func folderDotfileAndSymbolicLinkDraftsSelectTheirWholeName() async throws {
        let entries = [item("dotted.folder", directory: true), item(".hidden.txt", inode: 102),
                       item("shortcut.txt", inode: 103, link: true)]
        let (store, driver) = try await ready(entries)
        defer { stop(store, driver) }
        for entry in entries {
            let draft = try beginRename(store, entry)
            #expect(draft.initialSelection == NSRange(location: 0, length: (entry.name as NSString).length))
            store.cancelNameEdit()
        }
        #expect(await driver.writes.isEmpty)
    }

    @Test
    func navigationCancelsAnUnsubmittedDraftWithoutCallingTheWriteService() async throws {
        let original = item()
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        store.updateProposedName("tentative.txt", sessionID: draft.id)
        let destination = root.appendingPathComponent("Target", isDirectory: true)
        store.navigate(to: destination)
        #expect(store.nameEdit == nil)
        try await waitUntil { await driver.reads.count == 2 }
        #expect(await driver.reads.last == destination)
        await driver.finishRead(1, snapshot(parent: 200))
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.url == destination)
        #expect(await driver.writes.isEmpty)
    }

    @Test
    func unknownIdentityLoadingUnavailableAndMultipleSelectionDisableCommands() async throws {
        let driver = WriteStoreDriver(), original = item(), unknown = item("unknown.txt", inode: nil)
        let store = ExplorerStore(initialURL: root, loader: driver, operations: driver)
        defer { stop(store, driver) }
        #expect(!store.canCreateFolder)
        try await waitUntil { await driver.reads.count == 1 }
        await driver.finishRead(0, snapshot([original, unknown], parent: nil))
        try await waitUntil { !store.activeTab.isLoading }
        store.setSelection([original.id], focusedID: original.id)
        store.beginCreateFolder()
        store.beginRename()
        #expect(!store.canCreateFolder && !store.canRenameSelection && store.nameEdit == nil)
        store.refresh()
        try await waitUntil { await driver.reads.count == 2 }
        await driver.finishRead(1, snapshot([original, unknown]))
        try await waitUntil { !store.activeTab.isLoading }
        store.setSelection([unknown.id], focusedID: unknown.id)
        #expect(!store.canRenameSelection)
        // NATIVE-P18A / FR-FILE-025: with several selected, Rename edits the focused
        // item (only when its identity is known) and keeps the selection.
        store.setSelection([original.id, unknown.id], focusedID: unknown.id)
        store.beginRename()
        #expect(!store.canRenameSelection && store.nameEdit == nil)
        store.setSelection([original.id, unknown.id], focusedID: original.id)
        #expect(store.canRenameSelection)
        store.beginRename()
        #expect(store.nameEdit?.item?.id == original.id)
        #expect(store.activeTab.selection.selectedIDs == [original.id, unknown.id])
        store.cancelNameEdit()
        #expect(store.activeTab.selection.selectedIDs == [original.id, unknown.id])
        store.setSelection([original.id], focusedID: original.id)
        #expect(store.canRenameSelection)
        store.refresh()
        #expect(!store.canCreateFolder && !store.canRenameSelection)
        try await waitUntil { await driver.reads.count == 3 }
        await driver.failRead(2)
        try await waitUntil { !store.activeTab.isLoading }
        #expect(store.activeTab.isUnavailable)
        #expect(!store.canCreateFolder && !store.canRenameSelection)
        #expect(await driver.writes.isEmpty)
    }

    @Test
    func submissionCapturesParentSourceAndTextAndRejectsDuplicateEnter() async throws {
        let original = item()
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        store.updateProposedName("renamed-proof.txt", sessionID: draft.id)
        store.commitNameEdit(sessionID: draft.id)
        store.commitNameEdit(sessionID: draft.id)
        store.updateProposedName("too-late.txt", sessionID: draft.id)
        store.cancelNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        let call = try #require(await driver.writes.first)
        #expect(call.item == original)
        #expect(call.name == "renamed-proof.txt")
        #expect(call.context == FileOperationContext(directoryURL: root, directoryIdentity: identity()))
        #expect(store.nameEdit?.proposedName == call.name)
        #expect(store.nameEdit?.isSubmitting == true)
        #expect(store.isPerformingOperation)
        #expect(await driver.reads.count == 1)
        await driver.failWrite(0)
        try await waitUntil { !store.isPerformingOperation }
        #expect(await driver.writes.count == 1)
    }

    @Test
    func sidebarSettingsMenuStaysEnabledDuringAnExclusiveWrite() async throws {
        let (store, driver) = try await ready()
        defer { stop(store, driver) }
        store.beginCreateFolder()
        let draft = try #require(store.nameEdit)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        try #require(store.isPerformingOperation)

        let app = NSApplication.shared
        let preferences = SidebarBackgroundCheckPreferences()
        let delegate = ExplorerAppDelegate(sidebarBackgroundCheckPreferences: preferences)
        let view = NSMenu(title: "View")
        delegate.populateViewMenu(view)
        let appearance = try #require(view.item(withTitle: "Dark Appearance"))
        #expect(!delegate.validateMenuItem(appearance, currentStore: store))
        let cloud = try #require(view.item(withTitle: "Background Folder Checks")?.submenu?.item(withTitle: "Cloud Folders"))
        #expect(delegate.validateMenuItem(cloud, currentStore: store))
        #expect(app.sendAction(try #require(cloud.action), to: cloud.target, from: cloud))
        #expect(cloud.state == .on && preferences.options.cloud)
        #expect(store.isPerformingOperation && store.activeTab.url == root)
    }

    @Test
    func pendingWriteAndItsVerificationBlockNavigationTabChangesAndWindowClose() async throws {
        let (store, driver) = try await ready()
        defer { stop(store, driver) }
        let firstID = store.activeTabID
        store.openTab(at: root)
        try await waitUntil { await driver.reads.count == 2 }
        await driver.finishRead(1, snapshot())
        try await waitUntil { !store.activeTab.isLoading }
        let activeID = store.activeTabID, ids = store.tabs.map(\.id)
        var detached = false, closed = false
        store.onDetachTab = { _, _ in detached = true }
        store.onLastTabClosed = { closed = true }
        store.beginCreateFolder()
        let edit = try #require(store.nameEdit)
        store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await driver.writes.count == 1 }
        for verification in [false, true] {
            if verification {
                await driver.finishWrite(0, FileOperationResult(url: root.appendingPathComponent("New folder", isDirectory: true),
                                                                identity: identity(200), warning: nil))
                try await waitUntil { await driver.reads.count == 3 }
                #expect(store.nameEdit == nil && store.isPerformingOperation)
            }
            store.navigate(to: root.appendingPathComponent("elsewhere", isDirectory: true))
            store.back(); store.forward(); store.up(); store.refresh(); store.retry(); store.toggleHidden()
            store.addTab(); store.duplicateTab(activeID); store.activateTab(firstID); store.cycleTab()
            store.closeTab(activeID); store.closeOtherTabs(firstID); store.closeTabsToRight(firstID)
            store.detachTab(activeID)
            store.beginCreateFolder(); store.beginRename()
            #expect(store.tabs.map(\.id) == ids && store.activeTabID == activeID)
            #expect(store.activeTab.url == root && !store.showHidden)
            #expect(!store.canDetachTab(activeID) && !detached && !closed)
            #expect(await driver.reads.count == (verification ? 3 : 2))
            #expect(await driver.writes.count == 1)
        }
        await driver.finishRead(2, snapshot([item("New folder", inode: 200, directory: true)]))
        try await waitUntil { !store.isPerformingOperation }
        store.closeOtherTabs(activeID)
        store.beginCreateFolder()
        let lastEdit = try #require(store.nameEdit)
        store.commitNameEdit(sessionID: lastEdit.id)
        try await waitUntil { await driver.writes.count == 2 }
        store.closeTab(activeID)
        #expect(!closed)
        await driver.failWrite(1)
        try await waitUntil { !store.isPerformingOperation }
        store.cancelNameEdit()
        store.closeTab(activeID)
        #expect(closed)
    }

    @Test
    func failureKeepsTheDraftAndExplicitResubmissionUsesTheCapturedContext() async throws {
        let original = item()
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        store.updateProposedName("taken.txt", sessionID: draft.id)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        await driver.failWrite(0)
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.nameEdit?.id == draft.id && store.nameEdit?.proposedName == "taken.txt")
        #expect(store.nameEdit?.isSubmitting == false && store.nameEdit?.errorMessage != nil)
        #expect(store.activeTab.errorMessage == nil && store.operationNotice == nil)
        #expect(store.activeTab.items == [original] && store.activeTab.selection.selectedIDs == [original.id])
        #expect(await driver.reads.count == 1)
        store.updateProposedName("corrected.txt", sessionID: draft.id)
        #expect(store.nameEdit?.errorMessage == nil)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 2 }
        let calls = await driver.writes
        #expect(calls[1].context == calls[0].context && calls[1].item == original)
        #expect(calls[0].name == "taken.txt" && calls[1].name == "corrected.txt")
        await driver.failWrite(1)
        try await waitUntil { !store.isPerformingOperation }
    }

    @Test
    func successfulCreateSelectsTheResultOnlyAfterAConfirmingSnapshot() async throws {
        let original = item(), created = item("DropTarget", inode: 200, directory: true)
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        store.setSelection([original.id], focusedID: original.id)
        store.beginCreateFolder()
        let edit = try #require(store.nameEdit)
        store.updateProposedName(created.name, sessionID: edit.id)
        store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await driver.writes.count == 1 }
        let call = try #require(await driver.writes.first)
        #expect(call.item == nil && call.name == created.name && call.context.directoryURL == root)
        await driver.finishWrite(0, FileOperationResult(url: created.url, identity: created.identity, warning: nil))
        try await waitUntil { await driver.reads.count == 2 }
        #expect(store.isPerformingOperation && store.nameEdit == nil)
        #expect(store.activeTab.items == [original])
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        await driver.finishRead(1, snapshot([original, created]))
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.activeTab.selection.selectedIDs == [created.id])
        #expect(store.activeTab.selection.focusedID == created.id && store.activeTab.selection.anchorID == created.id)
        #expect(store.displayedItems.count == 2 && store.operationNotice == nil)
    }

    @Test
    func successfulRenameSelectsItsVerifiedResultAndRetainsAServiceWarning() async throws {
        let original = item(), renamed = item("renamed-proof.txt")
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let edit = try beginRename(store, original)
        store.updateProposedName(renamed.name, sessionID: edit.id)
        store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await driver.writes.count == 1 }
        let warning = "The item was renamed; a follow-up metadata check was unavailable."
        await driver.finishWrite(0, FileOperationResult(url: renamed.url, identity: renamed.identity, warning: warning))
        try await waitUntil { await driver.reads.count == 2 }
        await driver.finishRead(1, snapshot([renamed]))
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.activeTab.items == [renamed])
        #expect(store.activeTab.selection.selectedIDs == [renamed.id])
        #expect(store.activeTab.selection.focusedID == renamed.id)
        #expect(store.nameEdit == nil && store.operationNotice == warning)
        #expect(await driver.writes.count == 1)
    }

    @Test(arguments: ["replacement", "parent replacement", "unknown result identity", "moved result"])
    func anUnverifiedResultCannotInheritSelection(_ mismatch: String) async throws {
        let original = item(), renamed = item("renamed.txt")
        let (store, driver) = try await ready([original])
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        store.updateProposedName(renamed.name, sessionID: draft.id)
        store.commitNameEdit(sessionID: draft.id)
        try await waitUntil { await driver.writes.count == 1 }
        let resultIdentity = mismatch == "unknown result identity" ? nil : renamed.identity
        await driver.finishWrite(0, FileOperationResult(url: renamed.url, identity: resultIdentity, warning: nil))
        try await waitUntil { await driver.reads.count == 2 }
        let visible = mismatch == "replacement" ? item(renamed.name, inode: 999)
            : mismatch == "moved result" ? item("moved-again.txt") : renamed
        await driver.finishRead(1, snapshot([visible], parent: mismatch == "parent replacement" ? 999 : 100))
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.selection.focusedID == nil && store.activeTab.selection.anchorID == nil)
        #expect(store.operationNotice?.contains("completed") == true)
        #expect(store.nameEdit == nil && store.activeTab.errorMessage == nil)
        #expect(await driver.writes.count == 1)
    }

    @Test
    func aCommittedWriteWithReloadFailureRetriesOnlyTheRead() async throws {
        let (store, driver) = try await ready()
        defer { stop(store, driver) }
        store.beginCreateFolder()
        let edit = try #require(store.nameEdit)
        store.commitNameEdit(sessionID: edit.id)
        try await waitUntil { await driver.writes.count == 1 }
        let created = item("New folder", inode: 200, directory: true)
        await driver.finishWrite(0, FileOperationResult(url: created.url, identity: created.identity, warning: nil))
        try await waitUntil { await driver.reads.count == 2 }
        await driver.failRead(1)
        try await waitUntil { !store.isPerformingOperation }
        #expect(store.nameEdit == nil && store.activeTab.isUnavailable)
        #expect(store.operationNotice?.contains("change completed") == true)
        #expect(store.operationNotice?.contains("Retry only reloads") == true)
        #expect(store.activeTab.errorMessage != nil)
        store.retry()
        try await waitUntil { await driver.reads.count == 3 }
        #expect(await driver.reads.last == root)
        #expect(await driver.writes.count == 1)
        await driver.finishRead(2, snapshot([created]))
        try await waitUntil { !store.activeTab.isLoading }
        #expect(!store.activeTab.isUnavailable && store.activeTab.errorMessage == nil)
        #expect(store.activeTab.items == [created])
        #expect(await driver.writes.count == 1)
    }

    @Test
    func callbacksFromAnOldEditorCannotChangeCancelOrSubmitTheNewDraft() async throws {
        let (store, driver) = try await ready()
        defer { stop(store, driver) }
        store.beginCreateFolder()
        let old = try #require(store.nameEdit)
        store.cancelNameEdit()
        store.beginCreateFolder()
        let current = try #require(store.nameEdit)
        #expect(current.id != old.id)
        store.updateProposedName("stale", sessionID: old.id)
        store.cancelNameEdit(sessionID: old.id)
        store.commitNameEdit(sessionID: old.id)
        #expect(store.nameEdit?.id == current.id && store.nameEdit?.proposedName == "New folder")
        #expect(!store.isPerformingOperation)
        #expect(await driver.writes.isEmpty)
    }

    @Test
    func observationDuringADraftPreservesTextAndDrainsAfterCancellation() async throws {
        let observer = DraftChangeObserver(), original = item()
        let (store, driver) = try await ready([original], observer: observer)
        defer { stop(store, driver) }
        let draft = try beginRename(store, original)
        store.updateProposedName("unfinished.txt", sessionID: draft.id)
        for _ in 0..<20 { observer.changed() }
        store.refresh(); store.sort(by: .size)
        // The negative observation window exceeds the documented 150 ms debounce policy.
        try await Task.sleep(for: .milliseconds(240))
        #expect(await driver.reads.count == 1)
        #expect(store.nameEdit?.id == draft.id && store.nameEdit?.proposedName == "unfinished.txt")
        #expect(store.activeTab.items == [original] && store.activeTab.sort.key == .name)
        store.cancelNameEdit()
        try await waitUntil { await driver.reads.count == 2 }
        let added = item("external.txt", inode: 200)
        await driver.finishRead(1, snapshot([original, added]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [original, added])
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        #expect(store.nameEdit == nil)
        #expect(await driver.writes.isEmpty)
    }
}
