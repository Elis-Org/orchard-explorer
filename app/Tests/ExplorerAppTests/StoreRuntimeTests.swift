import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

private actor RuntimeContentProbe: ItemContentProviding {
    private(set) var purposes: [String] = []
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        switch request.purpose {
        case .preview: purposes.append("preview")
        case .download: purposes.append("download")
        case .externalOpen: purposes.append("open")
        case .clipboardExport: purposes.append("clipboard")
        case .transfer: purposes.append("transfer")
        }
        throw ItemContentError.unsupportedType
    }
}

private actor RuntimeSnapshotGate: DirectoryListing {
    private var next: URL?
    private var reply: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var isHolding: Bool { reply != nil }
    func hold(_ url: URL) { next = url }
    func release() { let value = reply; reply = nil; value?.resume() }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        calls += 1
        let value = try await BrowsingDirectoryLoader().snapshot(of: url, showHidden: showHidden)
        if next == url { next = nil; await withCheckedContinuation { reply = $0 } }
        return value
    }
}

private actor RuntimeContentGate: ItemContentProviding {
    private var reply: CheckedContinuation<any MaterializedContentLease, Error>?
    var isHolding: Bool { reply != nil }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        try await withCheckedThrowingContinuation { reply = $0 }
    }
    func finish(_ lease: any MaterializedContentLease) { let value = reply; reply = nil; value?.resume(returning: lease) }
    func cancel() { let value = reply; reply = nil; value?.resume(throwing: CancellationError()) }
}

private final class RuntimeLease: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    let sourceURL: URL
    let archiveRevision: ArchiveRevision?
    var fileURL: URL { physicalEntry.item.url }
    var byteCount: UInt64 { 0 }
    private let lock = NSLock()
    private var count = 0
    var releases: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(entry: TransferEntry, source: FileItem) {
        physicalEntry = entry; sourceURL = source.url; archiveRevision = source.archiveRevision
    }
    func validateForUse() async throws {}
    func release() async -> ContentLeaseReleaseResult {
        increment()
        return ContentLeaseReleaseResult(disposition: .retired)
    }
    private func increment() { lock.lock(); count += 1; lock.unlock() }
}

private actor RuntimeTransferGate: FileTransferring {
    private var reply: CheckedContinuation<FileOperationResult, Error>?
    private(set) var control: TransferControl?
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        self.control = control
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func cancel() { let value = reply; reply = nil; value?.resume(throwing: CancellationError()) }
}

@MainActor
struct StoreRuntimeTests {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
    }

    private func fixture(_ body: (URL, URL, ContentLeaseRegistry, TransferClipboard) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoreRuntime-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Bundle.zip")
        try #require(Data(base64Encoded: PreviewZIPFeatureTests.zipBase64)).write(to: archive)
        try Data("Physical input".utf8).write(to: root.appendingPathComponent("incoming.txt"))
        let board = NSPasteboard(name: .init("StoreRuntime-\(UUID())"))
        defer { board.releaseGlobally() }
        let registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("owned-content", isDirectory: true))
        do {
            try await body(root, archive, registry, TransferClipboard(pasteboard: board))
            _ = try await registry.shutdown()
        } catch {
            _ = try? await registry.shutdown()
            throw error
        }
    }

    @Test
    func constructorProviderIsSharedByPreviewOpenAndClipboard() async throws {
        try await fixture { root, archive, registry, clipboard in
            let provider = RuntimeContentProbe()
            let store = ExplorerStore(initialURL: try ArchiveLocation(archiveURL: archive).url, homeURL: root,
                clipboard: clipboard, contentRegistry: registry, contentProvider: provider,
                archiveBroadcaster: ArchiveMutationBroadcaster())
            defer { store.cancelLoads() }
            try await wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
            let note = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([note.id], focusedID: note.id)
            store.setPreviewSurfaceVisible(true)
            store.togglePreviewPane()
            try await wait { await provider.purposes.contains("preview") }
            store.setPreviewSurfaceVisible(false)
            store.openSelection()
            try await wait {
                let purposes = await provider.purposes
                return !store.isPerformingOperation && purposes.contains("open")
            }
            store.copySelection()
            try await wait {
                let purposes = await provider.purposes
                return !store.isPerformingOperation && purposes.contains("clipboard")
            }
            #expect(await provider.purposes == ["preview", "open", "clipboard"])
            #expect(clipboard.payload == nil)
        }
    }

    @Test
    func defaultProviderUsesTheInjectedRegistry() async throws {
        try await fixture { root, archive, registry, clipboard in
            let store = ExplorerStore(initialURL: try ArchiveLocation(archiveURL: archive).url, homeURL: root,
                clipboard: clipboard, contentRegistry: registry, archiveBroadcaster: ArchiveMutationBroadcaster())
            defer { store.cancelLoads() }
            try await wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
            let note = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([note.id], focusedID: note.id)
            store.copySelection()
            try await wait { !store.isPerformingOperation }
            let export = try #require(clipboard.payload?.leases.first?.fileURL)
            #expect(registry.containsManagedURL(export))
            #expect(try Data(contentsOf: export) == Data("Synthetic archived note.".utf8))
        }
    }

    @Test
    func injectedBroadcastersIsolateGroupsAndSelectOnlyTheOrigin() async throws {
        try await fixture { root, archive, registry, clipboard in
            let location = try ArchiveLocation(archiveURL: archive).url
            let firstBus = ArchiveMutationBroadcaster(), secondBus = ArchiveMutationBroadcaster()
            @MainActor func make(_ bus: ArchiveMutationBroadcaster) -> ExplorerStore {
                ExplorerStore(initialURL: location, homeURL: root, clipboard: clipboard,
                    contentRegistry: registry, archiveBroadcaster: bus)
            }
            let origin = make(firstBus), sibling = make(firstBus), isolated = make(secondBus)
            let stores = [origin, sibling, isolated]
            defer { stores.forEach { $0.cancelLoads() } }
            try await wait { stores.allSatisfy { $0.activeTab.hasLoaded && !$0.activeTab.isLoading } }
            for store in stores {
                let note = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
                store.setSelection([note.id], focusedID: note.id)
            }
            let before = isolated.contextMenuLoadGeneration
            let selected = try #require(origin.selectedItemsInOrder.first)
            let revision = try #require(origin.activeTab.archiveRevision)
            firstBus.publish(ArchiveMutationResult(archiveURL: archive, previousRevision: revision, revision: revision),
                origin: origin, selecting: [selected.url])
            #expect(origin.activeTab.isLoading && sibling.activeTab.isLoading)
            #expect(!isolated.activeTab.isLoading && isolated.contextMenuLoadGeneration == before)
            try await wait { !origin.activeTab.isLoading && !sibling.activeTab.isLoading }
            #expect(origin.currentSelection.selectedIDs == [selected.id])
            #expect(sibling.currentSelection.selectedIDs.isEmpty)
            #expect(isolated.currentSelection.selectedIDs == [selected.id] && isolated.contextMenuLoadGeneration == before)
        }
    }

    @Test(arguments: [false, true])
    func obsoleteArchiveReconciliationCannotReplaceNavigationOrReopenClosedTab(_ closeTab: Bool) async throws {
        try await fixture { root, archive, registry, clipboard in
            let loader = RuntimeSnapshotGate()
            let location = try ArchiveLocation(archiveURL: archive).url
            let store = ExplorerStore(initialURL: location, loader: loader, homeURL: root, clipboard: clipboard,
                contentRegistry: registry, archiveBroadcaster: ArchiveMutationBroadcaster())
            defer { store.cancelLoads(); Task { await loader.release() } }
            try await wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
            let archiveTab = store.activeTabID
            let revision = try #require(store.activeTab.archiveRevision)
            await loader.hold(location)
            store.archiveDidCommit(ArchiveMutationResult(archiveURL: archive, previousRevision: revision, revision: revision), selecting: [])
            try await wait { await loader.isHolding }
            if closeTab { store.openTab(at: root); store.closeTab(archiveTab) }
            else { store.navigate(to: root) }
            try await wait { store.activeTab.url == root && !store.activeTab.isLoading }
            let epoch = store.contextMenuLoadGeneration
            let reads = await loader.calls
            await loader.release()
            try await Task.sleep(for: .milliseconds(30))
            #expect(store.activeTab.url == root && store.contextMenuLoadGeneration == epoch)
            #expect(await loader.calls == reads)
            #expect(!closeTab || !store.tabs.contains { $0.id == archiveTab })
        }
    }

    @Test
    func cancelledArchivePreparationCannotFinishANewerPhysicalTransfer() async throws {
        try await fixture { root, archive, registry, clipboard in
            let provider = RuntimeContentGate(), transfers = RuntimeTransferGate()
            let store = ExplorerStore(initialURL: try ArchiveLocation(archiveURL: archive).url, homeURL: root,
                transfers: transfers, clipboard: clipboard, contentRegistry: registry, contentProvider: provider,
                archiveBroadcaster: ArchiveMutationBroadcaster())
            defer { store.cancelTransfer(); store.cancelLoads(); Task { await provider.cancel(); await transfers.cancel() } }
            try await wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
            let note = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            store.setSelection([note.id], focusedID: note.id)
            store.copySelection()
            try await wait { await provider.isHolding }
            store.cancelTransfer()
            try #require(!store.isPerformingOperation)
            store.navigate(to: root)
            try await wait { store.activeTab.url == root && !store.activeTab.isLoading }
            let physical = try #require(store.activeTab.items.first { $0.name == "incoming.txt" })
            let entry = TransferEntry(source: FileOperationContext(directoryURL: root,
                directoryIdentity: try #require(store.activeTab.directoryIdentity)), item: physical)
            let lateLease = RuntimeLease(entry: entry, source: note)
            store.setSelection([physical.id], focusedID: physical.id)
            store.copySelection()
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            store.navigate(to: destination)
            try await wait { store.activeTab.url == destination && !store.activeTab.isLoading }
            store.pasteSelection()
            try await wait { await transfers.control != nil }
            let session = try #require(store.transfer?.id)
            await provider.finish(lateLease)
            try await wait { lateLease.releases == 1 }
            #expect(store.transfer?.id == session && store.isPerformingOperation)
            let control = try #require(await transfers.control)
            try control.checkpoint()
            await transfers.cancel()
            try await wait { !store.isPerformingOperation && !store.activeTab.isLoading }
            #expect(store.operationNotice?.contains("Cancelled; completed items were retained") == true)
        }
    }
}
