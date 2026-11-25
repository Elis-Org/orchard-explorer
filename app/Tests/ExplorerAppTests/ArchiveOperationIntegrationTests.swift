import AppKit
import Darwin
@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor ArchiveCommandProbe: ArchiveModifying {
    private(set) var calls = 0
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func modify(_ edits: [ArchiveEdit], in context: ArchiveOperationContext, control: TransferControl,
                onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ArchiveMutationResult {
        calls += 1
        if fails { throw ArchiveOperationError.unsupported("Synthetic precommit refusal") }
        return ArchiveMutationResult(archiveURL: context.location.archiveURL, previousRevision: context.revision,
            revision: nil, warning: "Synthetic publication could not be verified")
    }
}

@MainActor
private final class RepeatedArchiveConflictChoices {
    private(set) var names: [String] = []
    func keepBoth(_ info: TransferConflictInfo) -> TransferConflictChoice {
        names.append(info.name)
        // A wrong retry loop must fail finitely instead of blocking the suite.
        return names.count <= 2 ? .keepBoth : .cancel
    }
}
private actor ArchiveSourceRecoveryProbe: FileRecovering {
    private(set) var trashes = 0
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        trashes += 1
        return TrashResult(receipt: nil, warning: "Synthetic cleanup")
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("Not used")
    }
}

/// Injects an independent writer after physical copy finalization, before the
/// real archive transaction. It cannot turn a claim into deletion authority.
private struct ArchiveBeforeModify: ArchiveModifying {
    let perform: @Sendable ([ArchiveEdit]) throws -> Void
    func modify(_ edits: [ArchiveEdit], in context: ArchiveOperationContext, control: TransferControl,
                onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ArchiveMutationResult {
        try perform(edits)
        return try await LocalArchiveOperations().modify(edits, in: context, control: control, onProgress: onProgress)
    }
}

private actor ArchiveBackgroundSnapshotGate: DirectoryListing {
    private var nextURL: URL?
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func holdNext(_ url: URL) { nextURL = url }
    func release() { held?.resume(); held = nil }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let captured = try await BrowsingDirectoryLoader().snapshot(of: url, showHidden: showHidden)
        if nextURL == url {
            nextURL = nil
            // Deliberately returns the old snapshot after cancellation, like a
            // filesystem read that was already in progress on its worker.
            await withCheckedContinuation { held = $0 }
        }
        return captured
    }
}

private final class ArchiveExportProbeLease: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    let sourceURL: URL
    let archiveRevision: ArchiveRevision?
    var fileURL: URL { physicalEntry.item.url }
    var byteCount: UInt64 { UInt64(max(0, physicalEntry.item.size ?? 0)) }
    private let lock = NSLock()
    private var releaseCount = 0
    var releases: Int { lock.lock(); defer { lock.unlock() }; return releaseCount }
    init(physicalEntry: TransferEntry, source: FileItem) {
        self.physicalEntry = physicalEntry; sourceURL = source.url; archiveRevision = source.archiveRevision
    }
    func validateForUse() async throws {
        guard releases == 0 else { throw ItemContentError.staleSource }
    }
    func release() async -> ContentLeaseReleaseResult {
        recordRelease()
        return ContentLeaseReleaseResult(disposition: .retired)
    }
    private func recordRelease() { lock.lock(); releaseCount += 1; lock.unlock() }
}
private actor ArchiveExportGate: ItemContentProviding {
    private(set) var calls = 0
    private var reply: CheckedContinuation<any MaterializedContentLease, Error>?
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        calls += 1
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func finish(_ lease: any MaterializedContentLease) { reply?.resume(returning: lease); reply = nil }
    func cancel() { reply?.resume(throwing: CancellationError()); reply = nil }
}

private actor ArchiveTransferGate: FileTransferring {
    private struct Call {
        let destination: URL
        let progress: @Sendable (TransferProgress) -> Void
        let reply: CheckedContinuation<FileOperationResult, Error>
    }
    private var calls: [Call] = []
    private var completed: Set<Int> = []
    var callCount: Int { calls.count }
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        try await withCheckedThrowingContinuation { reply in
            calls.append(Call(destination: to.directoryURL.appendingPathComponent(name), progress: onProgress, reply: reply))
        }
    }
    func emit(_ index: Int, bytes: Int64, phase: TransferPhase, name: String) {
        calls[index].progress(TransferProgress(currentName: name, bytesCopied: bytes, phase: phase))
    }
    func finish(_ index: Int) {
        guard completed.insert(index).inserted else { return }
        calls[index].reply.resume(returning: FileOperationResult(url: calls[index].destination, identity: nil, warning: nil))
    }
    func cancel() {
        for index in calls.indices where completed.insert(index).inserted { calls[index].reply.resume(throwing: CancellationError()) }
    }
}

@Suite(.serialized)
@MainActor
struct ArchiveOperationIntegrationTests {
    private func withFixture(transfers: any FileTransferring = LocalFileTransfers(),
                             loader: any DirectoryListing = BrowsingDirectoryLoader(),
                             archiveData: Data? = nil,
                             contentProvider: (any ItemContentProviding)? = nil,
                             _ body: (ExplorerStore, URL, URL, Data) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveIntegration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Bundle.zip")
        let original = try #require(archiveData ?? Data(base64Encoded: PreviewZIPFeatureTests.zipBase64))
        try original.write(to: archive)
        try Data("Synthetic incoming bytes".utf8).write(to: root.appendingPathComponent("incoming.txt"))
        let board = NSPasteboard(name: .init("ArchiveIntegration-\(UUID())"))
        defer { board.releaseGlobally() }
        let registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("store-content-registry", isDirectory: true))
        let store = ExplorerStore(initialURL: try ArchiveLocation(archiveURL: archive).url,
            loader: loader, homeURL: root, transfers: transfers, clipboard: TransferClipboard(pasteboard: board),
            contentRegistry: registry, contentProvider: contentProvider, archiveBroadcaster: ArchiveMutationBroadcaster())
        defer { store.cancelLoads() }
        try await waitFor { !store.activeTab.isLoading && store.activeTab.hasLoaded }
        try #require(store.activeTab.archiveRevision != nil)
        do {
            try await body(store, root, archive, original)
            _ = try await registry.shutdown()
        } catch {
            _ = try? await registry.shutdown()
            throw error
        }
    }
    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
    }
    private func exportLease(_ source: FileItem, root: URL) async throws -> ArchiveExportProbeLease {
        let folder = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("Synthetic archived note.".utf8).write(to: folder.appendingPathComponent(source.name))
        let snapshot = try await LocalDirectoryLoader().snapshot(of: folder, showHidden: true)
        return ArchiveExportProbeLease(physicalEntry: TransferEntry(source: FileOperationContext(directoryURL: folder,
            directoryIdentity: try #require(snapshot.directoryIdentity)), item: try #require(snapshot.items.first)), source: source)
    }

    private func beginRealCut(_ names: Set<String>, in store: ExplorerStore, to destination: URL) async throws {
        let selected = store.activeTab.items.filter { names.contains($0.name) }
        try #require(selected.count == names.count)
        store.setSelection(Set(selected.map(\.id)), focusedID: selected.first?.id)
        store.cutSelection()
        try await waitFor { !store.isPerformingOperation }
        try #require(store.clipboard.payload?.logicalEntries.count == names.count)
        store.navigate(to: destination)
        try await waitFor { store.activeTab.url == destination && !store.activeTab.isLoading }
        try #require(store.canPaste)
        store.pasteSelection()
    }

    @Test
    func typedZIPClipboardPastesThroughHomesChosenPhysicalFolder() async throws {
        try await withFixture { store, root, archive, original in
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let destination = root.appendingPathComponent("Chosen", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let output = destination.appendingPathComponent(source.name)
            store.setSelection([source.id], focusedID: source.id)
            store.copySelection()
            try await waitFor { store.clipboard.payload?.hasArchiveOrigin == true && !store.isPerformingOperation }
            let payload = try #require(store.clipboard.payload)
            let clipboardGeneration = store.clipboard.pasteboard.changeCount
            store.navigate(to: BrowserPage.home.url)
            try await waitFor { store.activePage == .home && store.canPaste }
            var choose: ((URL?) -> Void)?
            store.onChooseHomeFolder = { choose = $0 }
            store.pasteSelection()
            try await waitFor { choose != nil }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            let pickFolder = try #require(choose)
            pickFolder(destination)
            try await waitFor { FileManager.default.fileExists(atPath: output.path) && !store.isPerformingOperation }
            #expect(try Data(contentsOf: output) == Data("Synthetic archived note.".utf8))
            #expect(try Data(contentsOf: archive) == original)
            #expect(store.activePage == .home)
            #expect(store.clipboard.payload?.id == payload.id)
            #expect(store.clipboard.pasteboard.changeCount == clipboardGeneration)
        }
    }

    @Test
    func archivePasteUsesCommittedPhysicalSnapshotDuringBackgroundRefresh() async throws {
        let loader = ArchiveBackgroundSnapshotGate()
        defer { Task { await loader.release() } }
        try await withFixture(loader: loader) { store, root, archive, original in
            let registry = store.contentRegistry
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([source.id], focusedID: source.id)
            store.copySelection()
            try await waitFor { !store.isPerformingOperation }
            try #require(store.clipboard.payload?.hasArchiveOrigin == true)
            let destination = root.appendingPathComponent("background-paste-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            store.navigate(to: destination)
            try await waitFor { store.activeTab.url == destination && !store.activeTab.isLoading }
            await loader.holdNext(destination)
            store.refreshAfterActivation()
            try await waitFor { await loader.isHolding }
            try #require(store.activeTab.isRefreshing && !store.activeTab.isLoading)
            #expect(store.canPaste, "A physical committed destination remains usable during a passive read")
            store.pasteSelection()
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
            let output = destination.appendingPathComponent(source.name)
            #expect(FileManager.default.fileExists(atPath: output.path), "Starting the operation must not invalidate its own captured generation")
            if FileManager.default.fileExists(atPath: output.path) {
                #expect(try Data(contentsOf: output) == Data("Synthetic archived note.".utf8))
            }
            #expect(store.operationNotice?.contains("Copied 1") == true)
            await loader.release()
            try await Task.sleep(for: .milliseconds(20))
            #expect(store.activeTab.items.contains { $0.name == source.name }, "The obsolete passive snapshot must not replace the committed transfer result")
            #expect(try Data(contentsOf: archive) == original)
            _ = try await registry.shutdown()
        }
    }

    @Test
    func archiveDeleteCancelAndChangedRevisionNeverDispatchMutation() async throws {
        try await withFixture { store, _, archive, original in
            let probe = ArchiveCommandProbe()
            store.archiveModifier = probe
            let item = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([item.id], focusedID: item.id)
            store.deleteSelection()
            #expect(store.archiveDeleteConfirmation?.entries.map(\.item.id) == [item.id])
            store.cancelArchiveDelete()
            #expect(store.archiveDeleteConfirmation == nil)
            #expect(await probe.calls == 0)
            #expect(try Data(contentsOf: archive) == original)
            store.deleteSelection()
            try (original + Data([0])).write(to: archive)
            store.confirmArchiveDelete()
            try await waitFor { !store.isPerformingOperation }
            #expect(await probe.calls == 0)
            #expect(store.operationNotice?.contains("changed") == true)
            #expect(try Data(contentsOf: archive) == original + Data([0]))
        }
    }

    @Test
    func archiveRenameRefusalRetainsDraftAndNeverCreatesPhysicalUndo() async throws {
        try await withFixture { store, _, archive, original in
            let probe = ArchiveCommandProbe(fails: true)
            store.archiveModifier = probe
            let item = try #require(store.activeTab.items.first { $0.name == "inside" })
            store.setSelection([item.id], focusedID: item.id)
            store.beginRename()
            let edit = try #require(store.nameEdit)
            store.updateProposedName("Changed subtree", sessionID: edit.id)
            store.commitNameEdit(sessionID: edit.id)
            try await waitFor { !store.isPerformingOperation }
            #expect(await probe.calls == 1)
            #expect(store.nameEdit?.id == edit.id && store.nameEdit?.proposedName == "Changed subtree")
            #expect(store.nameEdit?.isSubmitting == false && store.nameEdit?.errorMessage?.contains("precommit refusal") == true)
            #expect(!store.canUndoRename && !store.canRedoRename)
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test
    func committedArchiveWithoutVerificationRetainsEveryPhysicalMoveSource() async throws {
        try await withFixture { store, root, archive, original in
            let archiveProbe = ArchiveCommandProbe(), recovery = ArchiveSourceRecoveryProbe()
            let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
            let item = try #require(snapshot.items.first { $0.name == "incoming.txt" })
            let entry = ItemOperationEntry(item: item, context: .filesystem(FileOperationContext(directoryURL: root,
                directoryIdentity: try #require(snapshot.directoryIdentity))))
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let coordinator = ItemOperationCoordinator(archives: archiveProbe, transfers: LocalFileTransfers(),
                recovery: recovery, loader: BrowsingDirectoryLoader(), conflicts: LocalConflictInspector(),
                registry: ContentLeaseRegistry(rootURL: root.appendingPathComponent("owned-content", isDirectory: true)))
            let outcome = try await coordinator.add([entry], to: context, moving: true, control: TransferControl(),
                progress: { { _ in } }, conflict: { _ in .cancel })
            #expect(await archiveProbe.calls == 1)
            #expect(await recovery.trashes == 0)
            #expect(outcome.copied == 1 && outcome.moved == 0)
            #expect(outcome.summary.contains("originals were retained"))
            #expect(try Data(contentsOf: item.url) == Data("Synthetic incoming bytes".utf8))
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test
    func archiveToArchiveAndManagedExportSourcesRefuseBeforeAnyWriter() async throws {
        try await withFixture { store, root, archive, _ in
            let probe = ArchiveCommandProbe(), recovery = ArchiveSourceRecoveryProbe()
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let item = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let owned = root.appendingPathComponent("owned-content", isDirectory: true)
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
            let exported = owned.appendingPathComponent("exported.txt")
            try Data("Synthetic export".utf8).write(to: exported)
            let snapshot = try await LocalDirectoryLoader().snapshot(of: owned, showHidden: true)
            let physical = ItemOperationEntry(item: try #require(snapshot.items.first),
                context: .filesystem(FileOperationContext(directoryURL: owned, directoryIdentity: try #require(snapshot.directoryIdentity))))
            let coordinator = ItemOperationCoordinator(archives: probe, transfers: LocalFileTransfers(), recovery: recovery,
                loader: BrowsingDirectoryLoader(), conflicts: LocalConflictInspector(), registry: ContentLeaseRegistry(rootURL: owned))
            for source in [ItemOperationEntry(item: item, context: .archive(context)), physical] {
                do {
                    _ = try await coordinator.add([source], to: context, moving: true, control: TransferControl(),
                        progress: { { _ in } }, conflict: { _ in .cancel })
                    Issue.record("A ZIP-derived source was accepted for a ZIP destination")
                } catch ArchiveOperationError.unsupported { }
            }
            #expect(await probe.calls == 0)
            #expect(await recovery.trashes == 0)
        }
    }

    @Test
    func renameRemapsArchivedHistoryWhileCurrentTabShowsPhysicalFolder() async throws {
        try await withFixture { store, root, archive, _ in
            let old = try ArchiveLocation(archiveURL: archive, components: ["inside", "nested"])
            store.navigate(to: old.url)
            try await waitFor { !store.activeTab.isLoading && store.activeTab.url == old.url }
            let note = try #require(store.activeTab.items.first)
            store.setSelection([note.id], focusedID: note.id)
            let revision = try #require(store.activeTab.archiveRevision)
            let snapshot = DirectorySnapshot(items: store.activeTab.items, directoryIdentity: nil, archiveRevision: revision)
            store.navigate(to: root)
            try await waitFor { !store.activeTab.isLoading && store.activeTab.url == root }
            let before = store.activeTab.history
            let renamed = try ArchiveLocation(archiveURL: archive, components: ["renamed", "nested"])
            store.archiveDidCommit(ArchiveMutationResult(archiveURL: archive, previousRevision: revision, revision: revision,
                renamedLocations: [ArchiveRenameMapping(
                    sourceURL: try ArchiveLocation(archiveURL: archive, components: ["inside"]).url,
                    destinationURL: try ArchiveLocation(archiveURL: archive, components: ["renamed"]).url)]), selecting: [])
            #expect(store.activeTab.url == root && store.activeTab.history.backStack.count == before.backStack.count)
            #expect(store.activeTab.history.backStack.last == renamed.url)
            #expect(!store.activeTab.history.backStack.contains(old.url))
            #expect(store.tabs[0].navigationSelections.restoredSelection(location: old.url, snapshot: snapshot).selectedIDs.isEmpty)
        }
    }

    @Test
    func clipboardExportPublishesRealURLsAndRetainsPrivateArchiveCutIntent() async throws {
        let gate = ArchiveExportGate()
        try await withFixture(contentProvider: gate) { store, root, _, _ in
            defer { Task { await gate.cancel() } }
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let lease = try await exportLease(source, root: root)
            store.setSelection([source.id], focusedID: source.id)
            store.cutSelection()
            try await waitFor { await gate.calls == 1 }
            await gate.finish(lease)
            try await waitFor { !store.isPerformingOperation }
            let payload = try #require(store.clipboard.payload)
            #expect(payload.kind == .move && payload.hasArchiveOrigin)
            #expect(payload.logicalEntries.map(\.item.url) == [source.url])
            let urls = store.clipboard.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
            #expect(urls?.map { $0 as URL } == [lease.fileURL])
            #expect(!store.canPaste && !store.canMoveHere)
            store.clipboard.pasteboard.setString("unowned-token", forType: .init("com.native-explorer.internal-transfer-token"))
            #expect(store.clipboard.payload == nil && !store.canPaste)
            #expect(store.clipboard.archivePasteRefusal(isManagedURL: store.contentRegistry.containsManagedURL) == .archiveOrigin)
            store.clipboard.refresh()
            try await waitFor { lease.releases == 1 }
            #expect(FileManager.default.fileExists(atPath: lease.fileURL.path), "Retirement does not delete an export on clipboard refresh")
            let board = store.clipboard.pasteboard
            board.clearContents()
            try #require(board.writeObjects([lease.fileURL as NSURL]))
            let tokenType = NSPasteboard.PasteboardType("com.native-explorer.internal-transfer-token")
            board.addTypes([tokenType], owner: nil)
            try #require(board.setString("unowned-token-without-archive-marker", forType: tokenType))
            // Prepared logical archive origin still wins after the public archive
            // marker disappears, ahead of the unowned token and managed URL.
            #expect(store.clipboard.archivePasteRefusal(for: payload,
                isManagedURL: { _ in true }) == .archiveOrigin)
        }
    }

    @Test(arguments: [false, true])
    func unownedOrdinaryClipboardExplainsArchiveRefusalWithoutClaimingMove(_ moving: Bool) async throws {
        try await withFixture { store, root, archive, original in
            defer { store.cancelTransfer() }
            let sourceURL = root.appendingPathComponent("incoming.txt")
            let originalSource = try Data(contentsOf: sourceURL)
            let source = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
            let item = try #require(source.items.first { $0.url == sourceURL })
            let context = FileOperationContext(directoryURL: root, directoryIdentity: try #require(source.directoryIdentity))
            let board = store.clipboard.pasteboard
            // Recreated app ownership: public URLs/token survive, but this Store
            // never receives the other instance's captured transfer authority.
            let owner = TransferClipboard(pasteboard: board)
            owner.capture(items: [item], source: context, kind: .copy)
            let owned = try #require(owner.payload)
            try #require(store.clipboard.payload == nil)
            let generation = board.changeCount, types = board.types
            let tokenType = NSPasteboard.PasteboardType("com.native-explorer.internal-transfer-token")
            let token = try #require(board.data(forType: tokenType))
            let beforeURLs = try store.clipboard.externalSnapshot().urlStrings

            #expect(store.canPaste)
            #expect(store.canMoveHere)
            if moving { store.moveHere() } else { store.pasteSelection() }
            #expect(store.operationNotice == "Copy the files again before adding them to a ZIP. Maxplorer can’t verify this clipboard selection.")
            #expect(store.transfer == nil && !store.isPerformingOperation)
            #expect(try Data(contentsOf: archive) == original)
            #expect(try Data(contentsOf: sourceURL) == originalSource)
            #expect(board.changeCount == generation && board.types == types)
            #expect(board.data(forType: tokenType) == token && owner.payload?.id == owned.id)
            let after = try store.clipboard.externalSnapshot()
            #expect(after.urlStrings == beforeURLs)
            // Refusal must happen before claimMove, even for Move Here. The same
            // unchanged generation remains claimable by a later legitimate flow.
            try store.clipboard.claimMove(after)
            #expect(store.clipboard.stillMatches(after))
        }
    }

    @Test(arguments: [false, true])
    func lateClipboardExportCannotReplaceNewClipboardOrSurviveCancellation(_ cancel: Bool) async throws {
        let gate = ArchiveExportGate()
        try await withFixture(contentProvider: gate) { store, root, archive, original in
            defer { Task { await gate.cancel() } }
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let lease = try await exportLease(source, root: root)
            let board = store.clipboard.pasteboard
            board.clearContents(); board.setString("Earlier clipboard", forType: .string)
            store.setSelection([source.id], focusedID: source.id)
            store.copySelection()
            try await waitFor { await gate.calls == 1 }
            if cancel { store.cancelTransfer() }
            else { board.clearContents(); board.setString("Newer clipboard", forType: .string) }
            await gate.finish(lease)
            try await waitFor { lease.releases == 1 && !store.isPerformingOperation }
            #expect(board.string(forType: .string) == (cancel ? "Earlier clipboard" : "Newer clipboard"))
            #expect(store.clipboard.payload == nil)
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test(arguments: [false, true])
    func archiveOpenUsesPhysicalLeaseAndRejectsChangedSelection(_ changeSelection: Bool) async throws {
        let gate = ArchiveExportGate()
        try await withFixture(contentProvider: gate) { store, root, _, _ in
            let router = ZIPAppRouter(), contents = ExternalOpenContents()
            store.applications = router; store.externalOpenContents = contents
            defer { Task { await gate.cancel() }; contents.endSession() }
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let lease = try await exportLease(source, root: root)
            store.setSelection([source.id], focusedID: source.id)
            store.openSelection()
            try await waitFor { await gate.calls == 1 }
            if changeSelection {
                let folder = try #require(store.activeTab.items.first { $0.name == "inside" })
                store.setSelection([folder.id], focusedID: folder.id)
                #expect(store.currentSelection.selectedIDs == [source.id], "Busy operations reject ordinary selection input")
                // Model an independent context replacement, which must also
                // invalidate an already preparing external Open.
                let index = try #require(store.tabs.firstIndex { $0.id == store.activeTabID })
                store.tabs[index].selection.selectedIDs = [folder.id]
                store.tabs[index].selection.focusedID = folder.id
            }
            await gate.finish(lease)
            try await waitFor { !store.isPerformingOperation }
            if changeSelection {
                #expect(router.opened.isEmpty && contents.retainedCount == 0 && lease.releases == 1)
            } else {
                #expect(router.opened == [lease.fileURL] && router.opened.allSatisfy { $0.isFileURL })
                store.setPreviewSurfaceVisible(false)
                store.cancelLoads()
                #expect(contents.retainedCount == 1 && lease.releases == 0,
                    "Window/preview teardown cannot revoke an external application's distinct lease")
            }
        }
    }

    @Test
    func unchangedArchiveRenameDoesNotWriteOrLoseSelection() async throws {
        try await withFixture { store, _, archive, original in
            let probe = ArchiveCommandProbe(fails: true)
            store.archiveModifier = probe
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([source.id], focusedID: source.id)
            store.beginRename()
            store.commitNameEdit(sessionID: try #require(store.nameEdit?.id))
            #expect(store.nameEdit == nil && !store.isPerformingOperation)
            #expect(store.currentSelection.selectedIDs == [source.id])
            #expect(await probe.calls == 0)
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test
    func realArchiveCutOutKeepsTransferLeaseAliveAfterClipboardConsumption() async throws {
        try await withFixture { store, root, archive, _ in
            let registry = store.contentRegistry
            let source = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([source.id], focusedID: source.id)
            store.cutSelection()
            try await waitFor { !store.isPerformingOperation }
            let clipboardPayload = try #require(store.clipboard.payload)
            let exportedURL = try #require(clipboardPayload.leases.first?.fileURL)
            let expected = try Data(contentsOf: exportedURL)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            store.navigate(to: destination)
            try await waitFor { store.activeTab.url == destination && !store.activeTab.isLoading }
            try #require(store.canPaste)
            store.pasteSelection()
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            let output = destination.appendingPathComponent(source.name)
            #expect(FileManager.default.fileExists(atPath: output.path), "Cut-out must copy from an operation-owned live lease")
            if FileManager.default.fileExists(atPath: output.path) { #expect(try Data(contentsOf: output) == expected) }
            let remaining = try await LocalZIPDirectoryLoader().snapshot(of: try ArchiveLocation(archiveURL: archive).url, showHidden: true)
            #expect(!remaining.items.contains { $0.name == source.name }, "Verified output permits only the selected source member removal")
            #expect(try Data(contentsOf: exportedURL) == expected, "Consuming private Cut intent retires public exports without deleting them")
            #expect(store.clipboard.payload == nil)
            _ = try await registry.shutdown()
        }
    }

    @Test
    func realArchiveCutOutMissingPublishedChildRetainsCompleteZIPSource() async throws {
        // Stored synthetic ZIP: inside/kept.txt and inside/nested/missing.txt,
        // plus an unrelated root file. Publication loses only one descendant;
        // its parent directory and the published root retain their identities.
        let bytes = try #require(Data(base64Encoded: "UEsDBBQAAAAAAIMYIlwAAAAAAAAAAAAAAAAHAAAAaW5zaWRlL1BLAwQUAAAAAACDGCJcAAAAAAAAAAAAAAAADgAAAGluc2lkZS9uZXN0ZWQvUEsDBBQAAAAAAIMYIlxqDL30GAAAABgAAAAZAAAAaW5zaWRlL25lc3RlZC9taXNzaW5nLnR4dFN5bnRoZXRpYyBtaXNzaW5nIGNoaWxkLlBLAwQUAAAAAACDGCJczzs2lhkAAAAZAAAADwAAAGluc2lkZS9rZXB0LnR4dFN5bnRoZXRpYyByZXRhaW5lZCBjaGlsZC5QSwMEFAAAAAAAgxgiXKYflmgZAAAAGQAAAA0AAAByb290LW5vdGUudHh0U3ludGhldGljIHVucmVsYXRlZCByb290LlBLAQIUABQAAAAAAIMYIlwAAAAAAAAAAAAAAAAHAAAAAAAAAAAAAACAAQAAAABpbnNpZGUvUEsBAhQAFAAAAAAAgxgiXAAAAAAAAAAAAAAAAA4AAAAAAAAAAAAAAIABJQAAAGluc2lkZS9uZXN0ZWQvUEsBAhQAFAAAAAAAgxgiXGoMvfQYAAAAGAAAABkAAAAAAAAAAAAAAIABUQAAAGluc2lkZS9uZXN0ZWQvbWlzc2luZy50eHRQSwECFAAUAAAAAACDGCJczzs2lhkAAAAZAAAADwAAAAAAAAAAAAAAgAGgAAAAaW5zaWRlL2tlcHQudHh0UEsBAhQAFAAAAAAAgxgiXKYflmgZAAAAGQAAAA0AAAAAAAAAAAAAAIAB5gAAAHJvb3Qtbm90ZS50eHRQSwUGAAAAAAUABQAwAQAAKgEAAAAA"))
        let transfers = LocalFileTransfers(afterCommit: { published in
            try? FileManager.default.removeItem(at: published.appendingPathComponent("nested/missing.txt"))
        })
        try await withFixture(transfers: transfers, archiveData: bytes) { store, root, archive, original in
            let registry = store.contentRegistry
            let source = try #require(store.activeTab.items.first { $0.name == "inside" && $0.isDirectory })
            store.setSelection([source.id], focusedID: source.id)
            store.cutSelection()
            try await waitFor { !store.isPerformingOperation }
            let payload = try #require(store.clipboard.payload)
            let export = try #require(payload.leases.first?.fileURL)
            try #require(FileManager.default.fileExists(atPath: export.appendingPathComponent("nested/missing.txt").path))
            let destination = root.appendingPathComponent("cut-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            store.navigate(to: destination)
            try await waitFor { store.activeTab.url == destination && !store.activeTab.isLoading }
            try #require(store.canPaste)
            store.pasteSelection()
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }

            let published = destination.appendingPathComponent(source.name, isDirectory: true)
            try #require(FileManager.default.fileExists(atPath: published.appendingPathComponent("kept.txt").path),
                         "The real physical publication must have completed before this regression is meaningful")
            #expect(try Data(contentsOf: published.appendingPathComponent("kept.txt")) == Data("Synthetic retained child.".utf8))
            #expect(!FileManager.default.fileExists(atPath: published.appendingPathComponent("nested/missing.txt").path),
                    "The afterCommit seam must actually remove the expected child")
            #expect(try Data(contentsOf: archive) == original, "Incomplete destination publication must retain the entire original ZIP")
            let remaining = try await LocalZIPDirectoryLoader().snapshot(of: try ArchiveLocation(archiveURL: archive).url, showHidden: true)
            #expect(remaining.items.contains { $0.name == "inside" }, "The selected source subtree must remain")
            #expect(store.operationNotice?.contains("Moved 1") != true, "Incomplete publication must not be reported as a completed move")
            #expect(store.operationNotice?.contains("retained") == true, "The copied-but-not-moved outcome must explain retained files")
            #expect(store.clipboard.payload == nil, "This exercises the real consumed Cut intent, not a fabricated transfer payload")
            _ = try await registry.shutdown()
        }
    }

    @Test
    func realArchiveCutOutSameSizePublishedEditRetainsZIPSource() async throws {
        let changed = Data(repeating: 0x58, count: 24)
        let transfers = LocalFileTransfers(afterCommit: { published in
            if let handle = try? FileHandle(forWritingTo: published.appendingPathComponent("nested/archived-note.txt")) {
                try? handle.write(contentsOf: changed)
                try? handle.close()
            }
        })
        try await withFixture(transfers: transfers) { store, root, archive, original in
            let registry = store.contentRegistry
            let destination = root.appendingPathComponent("same-size-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try await beginRealCut(["inside"], in: store, to: destination)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(try Data(contentsOf: destination.appendingPathComponent("inside/nested/archived-note.txt")) == changed,
                    "The real afterCommit seam must change bytes without changing file size")
            #expect(try Data(contentsOf: archive) == original)
            #expect(store.operationNotice?.contains("Moved 1") != true)
            #expect(store.operationNotice?.contains("retained") == true)
            _ = try await registry.shutdown()
        }
    }

    @Test
    func realArchiveCutOutAllowsExtraDestinationEntryAfterFinalization() async throws {
        try await withFixture { store, root, archive, _ in
            let registry = store.contentRegistry
            store.archiveModifier = ArchiveBeforeModify { edits in
                guard edits.count == 1, case .removeAfterVerifiedCopy(_, let claim) = edits[0] else {
                    throw ArchiveOperationError.unsupported("Cut must submit only a destination claim, never explicit Delete")
                }
                let published = claim.parent.directoryURL.appendingPathComponent(claim.name, isDirectory: true)
                let identityBefore = try LocalFileIdentity.read(at: published, ifLocal: true)
                try #require(identityBefore == claim.identity)
                try Data("Synthetic Finder metadata".utf8).write(to: published.appendingPathComponent(".DS_Store"))
                // Backdating before birth can change APFS birth identity. This
                // test changes only harmless directory contents/timestamps.
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3_600)],
                                                      ofItemAtPath: published.path)
                let identityAfter = try LocalFileIdentity.read(at: published, ifLocal: true)
                try #require(identityAfter == identityBefore)
            }
            let destination = root.appendingPathComponent("extra-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try await beginRealCut(["inside"], in: store, to: destination)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(try Data(contentsOf: destination.appendingPathComponent("inside/nested/archived-note.txt")) == Data("Synthetic archived note.".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent("inside/.DS_Store")) == Data("Synthetic Finder metadata".utf8))
            let remaining = try await LocalZIPDirectoryLoader().snapshot(of: try ArchiveLocation(archiveURL: archive).url, showHidden: true)
            #expect(!remaining.items.contains { $0.name == "inside" })
            #expect(store.operationNotice?.contains("Moved 1") == true)
            _ = try await registry.shutdown()
        }
    }

    @Test(arguments: [false, true])
    func realArchiveCutOutPartialBatchRetainsSkippedOrInvalidSources(changeDestination: Bool) async throws {
        let transfers = LocalFileTransfers(afterCommit: { published in
            if changeDestination, published.lastPathComponent == "inside" {
                try? FileManager.default.removeItem(at: published.appendingPathComponent("nested/archived-note.txt"))
            }
        })
        try await withFixture(transfers: transfers) { store, root, archive, original in
            let registry = store.contentRegistry
            let destination = root.appendingPathComponent("partial-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let existing = Data("Keep the existing destination".utf8)
            if !changeDestination { try existing.write(to: destination.appendingPathComponent("root-note.txt")) }
            try await beginRealCut(["inside", "root-note.txt"], in: store, to: destination)
            if !changeDestination {
                try await waitFor { store.transfer?.conflict != nil }
                store.resolveTransferConflict(.skip)
            }
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            let remaining = try await LocalZIPDirectoryLoader().snapshot(of: try ArchiveLocation(archiveURL: archive).url, showHidden: true)
            #expect(remaining.items.contains { $0.name == "root-note.txt" })
            if changeDestination {
                #expect(try Data(contentsOf: archive) == original, "One failing final witness keeps the entire attempted source-removal batch")
                #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == Data("Synthetic archived note.".utf8))
                #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("inside/nested/archived-note.txt").path))
                #expect(store.operationNotice?.contains("Moved") != true)
            } else {
                #expect(!remaining.items.contains { $0.name == "inside" })
                #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == existing)
                #expect(store.operationNotice?.contains("Moved 1") == true)
                #expect(store.operationNotice?.contains("Skipped 1") == true)
            }
            _ = try await registry.shutdown()
        }
    }

    @Test
    func realArchiveCutOutCancelledLaterConflictRetainsEarlierOriginal() async throws {
        try await withFixture { store, root, archive, original in
            let registry = store.contentRegistry
            let destination = root.appendingPathComponent("cancel-cut-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let existing = Data("Keep the existing conflict target".utf8)
            try existing.write(to: destination.appendingPathComponent("root-note.txt"))
            try await beginRealCut(["inside", "root-note.txt"], in: store, to: destination)
            try await waitFor { store.transfer?.conflict != nil }
            let conflict = try #require(store.transfer?.conflict)
            try #require(conflict.name == "root-note.txt")
            let completed = destination.appendingPathComponent("inside/nested/archived-note.txt")
            try #require(FileManager.default.fileExists(atPath: completed.path),
                         "The first item must already be copied before the later conflict is cancelled")
            store.resolveTransferConflict(.cancel)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(try Data(contentsOf: completed) == Data("Synthetic archived note.".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == existing)
            #expect(try Data(contentsOf: archive) == original, "Conflict Cancel must retain the earlier copied ZIP original")
            let remaining = try await LocalZIPDirectoryLoader().snapshot(of: try ArchiveLocation(archiveURL: archive).url, showHidden: true)
            #expect(remaining.items.contains { $0.name == "inside" })
            #expect(store.operationNotice?.contains("Moved") != true)
            #expect(store.operationNotice?.contains("Cancelled") == true)
            _ = try await registry.shutdown()
        }
    }

    @Test
    func realArchiveCutOutRemovesSupportedOriginCompanionWithItsMember() async throws {
        try await withFixture { store, root, archive, _ in
            let sourceURL = root.appendingPathComponent("incoming.txt")
            let origin = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/cut-origin"], format: .binary, options: 0)
            let marked = origin.withUnsafeBytes { setxattr(sourceURL.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
            try #require(marked == 0)
            let imported = try await LocalFileTransferImporter().capture(urlStrings: [sourceURL.absoluteString])
            let entry = try #require(imported.first)
            let location = try ArchiveLocation(archiveURL: archive)
            let context = ArchiveOperationContext(location: location, revision: try #require(store.activeTab.archiveRevision))
            let added = try await LocalArchiveOperations().modify([.add(source: entry,
                destination: try ArchiveLocation(archiveURL: archive, components: ["downloaded.txt"]), replacing: nil)],
                in: context, control: TransferControl(), onProgress: { _ in })
            try #require(added.verifiedDestination != nil)
            let before = try ZIPArchiveManifest.read(from: ZIPFileReader(url: archive))
            try #require(before.records.contains { $0.components == ["__MACOSX", "._downloaded.txt"] })
            store.refresh()
            try await waitFor { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
            let registry = store.contentRegistry
            let destination = root.appendingPathComponent("origin-cut-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try await beginRealCut(["downloaded.txt"], in: store, to: destination)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            let copied = destination.appendingPathComponent("downloaded.txt")
            #expect(try Data(contentsOf: copied) == Data("Synthetic incoming bytes".utf8))
            var actual = Data(count: origin.count)
            let count = actual.withUnsafeMutableBytes { getxattr(copied.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
            #expect(count == origin.count && actual == origin)
            let after = try ZIPArchiveManifest.read(from: ZIPFileReader(url: archive))
            #expect(!after.records.contains { $0.components == ["downloaded.txt"] || $0.components == ["__MACOSX", "._downloaded.txt"] })
            #expect(store.operationNotice?.contains("Moved 1") == true)
            #expect(try Data(contentsOf: sourceURL) == Data("Synthetic incoming bytes".utf8))
            _ = try await registry.shutdown()
        }
    }

    @Test
    func inFlightCopyOwnsItsLeasesAndRejectsPreviousAttemptProgress() async throws {
        let gate = ArchiveTransferGate()
        defer { Task { await gate.cancel() } }
        try await withFixture(transfers: gate) { store, root, archive, original in
            let registry = store.contentRegistry
            let files = store.activeTab.items.filter { $0.name == "root-note.txt" || $0.name == "empty" }
            try #require(files.count == 2)
            store.setSelection(Set(files.map(\.id)), focusedID: files[0].id)
            store.copySelection()
            try await waitFor { !store.isPerformingOperation }
            try #require(store.clipboard.payload?.leases.count == 2)
            let destination = root.appendingPathComponent("copy-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            store.navigate(to: destination)
            try await waitFor { !store.activeTab.isLoading }
            store.pasteSelection()
            try await waitFor { await gate.callCount == 1 }
            await gate.emit(0, bytes: 100, phase: .finalizing, name: "First")
            try await waitFor { store.transfer?.phase == .finalizing }
            let board = store.clipboard.pasteboard
            board.clearContents(); board.setString("Newer clipboard during copy", forType: .string)
            store.clipboard.refresh()
            await gate.finish(0)
            try await waitFor { await gate.callCount == 2 }
            #expect(store.transfer?.phase == .copying && store.transfer?.bytesCopied == 0 && store.transfer?.canCancel == true)
            await gate.emit(0, bytes: 999, phase: .removingOriginals, name: "Late previous item")
            await gate.emit(1, bytes: 7, phase: .copying, name: "Current item")
            try await waitFor { store.transfer?.currentName == "Current item" }
            #expect(store.transfer?.phase == .copying && store.transfer?.bytesCopied == 7 && store.transfer?.canCancel == true)
            await gate.finish(1)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(board.string(forType: .string) == "Newer clipboard during copy")
            #expect(try Data(contentsOf: archive) == original)
            _ = try await registry.shutdown()
        }
    }

    @Test(arguments: ["replace", "skip", "keepBoth", "cancel"])
    func realPasteIntoArchiveResolvesComparedFileConflicts(_ choice: String) async throws {
        try await withFixture { store, root, archive, original in
            let sourceURL = root.appendingPathComponent("root-note.txt")
            let incoming = Data("Distinct synthetic replacement bytes".utf8)
            try incoming.write(to: sourceURL)
            let source = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
            store.clipboard.capture(items: [try #require(source.items.first { $0.url == sourceURL })],
                source: FileOperationContext(directoryURL: root, directoryIdentity: try #require(source.directoryIdentity)), kind: .copy)
            store.pasteSelection()
            try await waitFor { store.transfer?.conflict != nil }
            let conflict = try #require(store.transfer?.conflict)
            #expect(conflict.archiveExisting?.name == "root-note.txt" && conflict.archiveTarget != nil)
            #expect(conflict.existing == nil && conflict.canReplace)
            store.resolveTransferConflict(choice == "replace" ? .replace : choice == "keepBoth" ? .keepBoth : choice == "skip" ? .skip : .cancel)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(try Data(contentsOf: sourceURL) == incoming)
            if choice == "skip" || choice == "cancel" {
                #expect(try Data(contentsOf: archive) == original)
                return
            }
            let name = choice == "replace" ? "root-note.txt" : "root-note - Copy.txt"
            let added = try #require(store.activeTab.items.first { $0.name == name })
            #expect(store.selectedItemsInOrder.map(\.name) == [name])
            let registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("verification", isDirectory: true))
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let lease = try await LocalItemContentProvider(registry: registry).materialize(ContentRequest(
                source: ItemOperationEntry(item: added, context: .archive(context)), purpose: .transfer), control: TransferControl())
            #expect(try Data(contentsOf: lease.fileURL) == incoming)
            _ = await lease.release()
            _ = try await registry.shutdown()
        }
    }

    @Test
    func archiveAddAsksAgainWhenFirstKeepBothNameIsOccupied() async throws {
        // Independent stored fixture: both the requested name and first
        // generated alternate already contain distinct bytes.
        let bytes = try #require(Data(base64Encoded: "UEsDBBQAAAAAAKMgQ1j0R32xDwAAAA8AAAANAAAAcm9vdC1ub3RlLnR4dE9yaWdpbmFsIG1lbWJlclBLAwQUAAAAAACjIENYcyVbuRIAAAASAAAAFAAAAHJvb3Qtbm90ZSAtIENvcHkudHh0T2NjdXBpZWQgYWx0ZXJuYXRlUEsBAhQDFAAAAAAAoyBDWPRHfbEPAAAADwAAAA0AAAAAAAAAAAAAAKSBAAAAAHJvb3Qtbm90ZS50eHRQSwECFAMUAAAAAACjIENYcyVbuRIAAAASAAAAFAAAAAAAAAAAAAAApIE6AAAAcm9vdC1ub3RlIC0gQ29weS50eHRQSwUGAAAAAAIAAgB9AAAAfgAAAAAA"))
        try await withFixture(archiveData: bytes) { store, root, archive, _ in
            let incoming = Data("New source bytes".utf8)
            let sourceURL = root.appendingPathComponent("root-note.txt")
            try incoming.write(to: sourceURL)
            let source = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
            let entry = ItemOperationEntry(item: try #require(source.items.first { $0.url == sourceURL }),
                context: .filesystem(FileOperationContext(directoryURL: root,
                    directoryIdentity: try #require(source.directoryIdentity))))
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let coordinator = ItemOperationCoordinator(archives: LocalArchiveOperations(), transfers: LocalFileTransfers(),
                recovery: ArchiveSourceRecoveryProbe(), loader: BrowsingDirectoryLoader(),
                conflicts: LocalConflictInspector(), registry: store.contentRegistry)
            let choices = RepeatedArchiveConflictChoices()
            let outcome = try await coordinator.add([entry], to: context, moving: false,
                control: TransferControl(), progress: { { _ in } }, conflict: { choices.keepBoth($0) })
            #expect(choices.names == ["root-note.txt", "root-note - Copy.txt"])
            #expect(outcome.copied == 1 && outcome.skipped == 0 && outcome.messages.isEmpty)
            let after = try await LocalZIPDirectoryLoader().snapshot(of: context.location.url, showHidden: true)
            #expect(Set(after.items.map(\.name)) == ["root-note.txt", "root-note - Copy.txt", "root-note - Copy (2).txt"])
            let afterContext = ArchiveOperationContext(location: context.location, revision: try #require(after.archiveRevision))
            let expected = ["root-note.txt": Data("Original member".utf8),
                            "root-note - Copy.txt": Data("Occupied alternate".utf8),
                            "root-note - Copy (2).txt": incoming]
            for item in after.items {
                let lease = try await LocalItemContentProvider(registry: store.contentRegistry).materialize(ContentRequest(
                    source: ItemOperationEntry(item: item, context: .archive(afterContext)), purpose: .transfer), control: TransferControl())
                let actual = try Data(contentsOf: lease.fileURL)
                _ = await lease.release()
                #expect(actual == expected[item.name])
            }
            #expect(try Data(contentsOf: sourceURL) == incoming)
        }
    }

    @Test
    func archiveCopyOutAsksAgainWhenFirstKeepBothNameIsOccupied() async throws {
        try await withFixture { store, root, archive, original in
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let source = ItemOperationEntry(item: try #require(store.activeTab.items.first { $0.name == "root-note.txt" }),
                                           context: .archive(context))
            let lease = try await LocalItemContentProvider(registry: store.contentRegistry).materialize(
                ContentRequest(source: source, purpose: .transfer), control: TransferControl())
            let payload = TransferClipboardPayload(id: UUID(), entries: [lease.physicalEntry], kind: .copy,
                                                  logicalEntries: [source], leases: [lease])
            let destination = root.appendingPathComponent("occupied-copyout", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let originalDestination = Data("Existing destination".utf8)
            let occupiedAlternate = Data("Existing alternate".utf8)
            try originalDestination.write(to: destination.appendingPathComponent("root-note.txt"))
            try occupiedAlternate.write(to: destination.appendingPathComponent("root-note - Copy.txt"))
            let snapshot = try await LocalDirectoryLoader().snapshot(of: destination, showHidden: true)
            let coordinator = ItemOperationCoordinator(archives: LocalArchiveOperations(), transfers: LocalFileTransfers(),
                recovery: ArchiveSourceRecoveryProbe(), loader: BrowsingDirectoryLoader(),
                conflicts: LocalConflictInspector(), registry: store.contentRegistry)
            let choices = RepeatedArchiveConflictChoices()
            let outcome = await coordinator.copyOut(payload, to: FileOperationContext(directoryURL: destination,
                directoryIdentity: try #require(snapshot.directoryIdentity)), moving: false,
                control: TransferControl(), progress: { { _ in } }, conflict: { choices.keepBoth($0) })
            _ = await lease.release()
            #expect(choices.names == ["root-note.txt", "root-note - Copy.txt"])
            #expect(outcome.copied == 1 && outcome.skipped == 0 && outcome.messages.isEmpty)
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == originalDestination)
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note - Copy.txt")) == occupiedAlternate)
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note - Copy (2).txt")) == Data("Synthetic archived note.".utf8))
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test
    func copyOutMoveRemovesOnlyVerifiedNonSkippedMembers() async throws {
        try await withFixture { store, root, archive, _ in
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            let sources = try ["root-note.txt", "empty"].map { name in
                ItemOperationEntry(item: try #require(store.activeTab.items.first { $0.name == name }), context: .archive(context))
            }
            let registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("copyout-content", isDirectory: true))
            let provider = LocalItemContentProvider(registry: registry)
            var leases: [any MaterializedContentLease] = []
            for source in sources { leases.append(try await provider.materialize(ContentRequest(source: source, purpose: .transfer), control: TransferControl())) }
            let payload = TransferClipboardPayload(id: UUID(), entries: leases.map(\.physicalEntry), kind: .move,
                logicalEntries: sources, leases: leases)
            let destination = root.appendingPathComponent("copyout", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let existing = Data("Keep the existing destination".utf8)
            try existing.write(to: destination.appendingPathComponent("root-note.txt"))
            let target = try await LocalDirectoryLoader().snapshot(of: destination, showHidden: true)
            let coordinator = ItemOperationCoordinator(archives: LocalArchiveOperations(), transfers: LocalFileTransfers(),
                recovery: ArchiveSourceRecoveryProbe(), loader: BrowsingDirectoryLoader(), conflicts: LocalConflictInspector(), registry: registry)
            let outcome = await coordinator.copyOut(payload, to: FileOperationContext(directoryURL: destination,
                directoryIdentity: try #require(target.directoryIdentity)), moving: true, control: TransferControl(),
                progress: { { _ in } }, conflict: { info in
                    #expect(info.existing != nil && info.archiveTarget == nil)
                    return .skip
                })
            #expect(outcome.copied == 1 && outcome.moved == 1 && outcome.skipped == 1)
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == existing)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("empty").path))
            let after = try await LocalZIPDirectoryLoader().snapshot(of: context.location.url, showHidden: true)
            #expect(Set(after.items.map(\.name)) == ["inside", "root-note.txt"])
            for lease in leases { _ = await lease.release() }
            _ = try await registry.shutdown()
        }
    }

    @Test
    func coordinatorConflictCancelRetainsEarlierCopyWithoutMutatingControl() async throws {
        try await withFixture { store, root, archive, original in
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive),
                revision: try #require(store.activeTab.archiveRevision))
            // Deliberate source order: regular-file copy first, then a conflict.
            // This does not rely on the folder destination-content verifier.
            let sources = try ["root-note.txt", "empty"].map { name in
                ItemOperationEntry(item: try #require(store.activeTab.items.first { $0.name == name }), context: .archive(context))
            }
            let registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("coordinator-cancel-content"))
            let provider = LocalItemContentProvider(registry: registry)
            var leases: [any MaterializedContentLease] = []
            for source in sources {
                leases.append(try await provider.materialize(ContentRequest(source: source, purpose: .transfer), control: TransferControl()))
            }
            let payload = TransferClipboardPayload(id: UUID(), entries: leases.map(\.physicalEntry), kind: .move,
                logicalEntries: sources, leases: leases)
            let destination = root.appendingPathComponent("coordinator-cancel-target", isDirectory: true)
            try FileManager.default.createDirectory(at: destination.appendingPathComponent("empty", isDirectory: true), withIntermediateDirectories: true)
            let snapshot = try await LocalDirectoryLoader().snapshot(of: destination, showHidden: true)
            let coordinator = ItemOperationCoordinator(archives: LocalArchiveOperations(), transfers: LocalFileTransfers(),
                recovery: ArchiveSourceRecoveryProbe(), loader: BrowsingDirectoryLoader(), conflicts: LocalConflictInspector(), registry: registry)
            let control = TransferControl()
            let outcome = await coordinator.copyOut(payload, to: FileOperationContext(directoryURL: destination,
                directoryIdentity: try #require(snapshot.directoryIdentity)), moving: true, control: control,
                progress: { { _ in } }, conflict: { info in
                    #expect(info.name == "empty")
                    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("root-note.txt").path))
                    // Returning Cancel is sufficient; a caller must not also
                    // need to know how the coordinator checks TransferControl.
                    return .cancel
                })
            #expect(outcome.copied == 1)
            #expect(outcome.moved == 0)
            #expect(outcome.archiveResults.isEmpty)
            #expect(outcome.summary.contains("Cancelled"))
            #expect(try Data(contentsOf: archive) == original)
            #expect(try Data(contentsOf: destination.appendingPathComponent("root-note.txt")) == Data("Synthetic archived note.".utf8))
            for lease in leases { _ = await lease.release() }
            _ = try await registry.shutdown()
        }
    }

    @Test
    func verifiedArchiveAddEnablesCleanupButUnverifiedTrashIsReported() async throws {
        try await withFixture { store, root, archive, _ in
            let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
            let source = try #require(snapshot.items.first { $0.name == "incoming.txt" })
            let entry = ItemOperationEntry(item: source, context: .filesystem(FileOperationContext(directoryURL: root,
                directoryIdentity: try #require(snapshot.directoryIdentity))))
            let context = ArchiveOperationContext(location: try ArchiveLocation(archiveURL: archive), revision: try #require(store.activeTab.archiveRevision))
            let recovery = ArchiveSourceRecoveryProbe()
            let coordinator = ItemOperationCoordinator(archives: LocalArchiveOperations(), transfers: LocalFileTransfers(),
                recovery: recovery, loader: BrowsingDirectoryLoader(), conflicts: LocalConflictInspector(),
                registry: ContentLeaseRegistry(rootURL: root.appendingPathComponent("unused-registry")))
            let outcome = try await coordinator.add([entry], to: context, moving: true, control: TransferControl(),
                progress: { { _ in } }, conflict: { _ in .cancel })
            #expect(outcome.archiveResults.first?.verifiedDestination != nil)
            #expect(await recovery.trashes == 1)
            #expect(outcome.copied == 1 && outcome.moved == 0 && outcome.trashReceipts.isEmpty)
            #expect(outcome.summary.contains("cleanup") && outcome.summary.contains("could not be verified"))
            #expect(FileManager.default.fileExists(atPath: source.url.path))
        }
    }

    @Test
    func realSubtreeRenameAndDeleteReconcileEveryOpenArchiveTab() async throws {
        try await withFixture { store, root, archive, _ in
            let nested = try ArchiveLocation(archiveURL: archive, components: ["inside", "nested"])
            let second = ExplorerStore(initialURL: nested.url, homeURL: root, clipboard: store.clipboard,
                contentRegistry: store.contentRegistry, archiveBroadcaster: store.archiveBroadcaster)
            defer { second.cancelLoads() }
            try await waitFor { second.activeTab.hasLoaded && !second.activeTab.isLoading }
            let folder = try #require(store.activeTab.items.first { $0.name == "inside" })
            store.setSelection([folder.id], focusedID: folder.id)
            store.beginRename()
            let edit = try #require(store.nameEdit)
            store.updateProposedName("renamed", sessionID: edit.id)
            store.commitNameEdit(sessionID: edit.id)
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading && !second.activeTab.isLoading }
            let renamed = try ArchiveLocation(archiveURL: archive, components: ["renamed", "nested"])
            #expect(second.activeTab.url == renamed.url)
            #expect(second.activeTab.items.map(\.name) == ["archived-note.txt"])
            #expect(store.selectedItemsInOrder.map(\.name) == ["renamed"])
            #expect(!store.canUndoRename)
            store.deleteSelection()
            try #require(store.archiveDeleteConfirmation != nil)
            store.confirmArchiveDelete()
            try await waitFor { !store.isPerformingOperation && !store.activeTab.isLoading && !second.activeTab.isLoading }
            #expect(second.activeTab.url == store.activeTab.url)
            #expect(Set(store.activeTab.items.map(\.name)) == ["root-note.txt", "empty"])
            #expect(Set(second.activeTab.items.map(\.name)) == ["root-note.txt", "empty"])
            #expect(try Data(contentsOf: root.appendingPathComponent("incoming.txt")) == Data("Synthetic incoming bytes".utf8))
        }
    }
}
