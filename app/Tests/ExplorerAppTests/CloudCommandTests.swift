import Combine
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor CommandContentProvider: ItemContentProviding {
    private(set) var requests: [ContentRequest] = []
    private var pending: [Int: CheckedContinuation<any MaterializedContentLease, Error>] = [:]
    private var controls: [TransferControl] = []
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        let index = requests.count
        requests.append(request); controls.append(control)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func progress(_ index: Int, _ phase: ContentPreparationPhase) { requests[index].onProgress?(phase) }
    func finish(_ index: Int, _ lease: any MaterializedContentLease) { pending.removeValue(forKey: index)?.resume(returning: lease) }
    func fail(_ index: Int, _ error: ItemContentError) { pending.removeValue(forKey: index)?.resume(throwing: error) }
    func cancelled(_ index: Int) -> Bool {
        do { try controls[index].checkpoint(); return false } catch { return true }
    }
    func finishAll() {
        let values = Array(pending.values); pending.removeAll()
        values.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class CommandLease: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    let isBorrowed = true
    let archiveRevision: ArchiveRevision? = nil
    var fileURL: URL { physicalEntry.item.url }
    var sourceURL: URL { fileURL }
    var byteCount: UInt64 { UInt64(max(0, physicalEntry.item.size ?? 0)) }
    private let lock = NSLock()
    private var count = 0
    var releases: Int { lock.withLock { count } }
    init(_ entry: TransferEntry) { physicalEntry = entry }
    func validateForUse() async throws {}
    func release() async -> ContentLeaseReleaseResult {
        lock.withLock { count += 1 }; return .init(disposition: .released)
    }
}

private actor CommandDirectoryLoader: DirectoryListing {
    private var value: DirectorySnapshot
    private(set) var reads = 0
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    init(_ value: DirectorySnapshot) { self.value = value }
    func set(_ value: DirectorySnapshot) { self.value = value }
    func holdNextRead() { holdNext = true }
    func finishHeldRead() { held?.resume(); held = nil }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        reads += 1
        if holdNext { holdNext = false; await withCheckedContinuation { held = $0 } }
        return value
    }
}

private struct CommandSearcher: FilenameSearching {
    let result: FilenameSearchResult
    func search(_ request: FilenameSearchRequest) -> AsyncThrowingStream<FilenameSearchEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(results: [result], coverage: SearchCoverage()))
            continuation.yield(.finished(SearchCoverage())); continuation.finish()
        }
    }
}

private actor SearchMetadataOverlapLoader: DirectoryListing {
    let initial: DirectorySnapshot
    private(set) var reads = 0
    private var pending: [Int: CheckedContinuation<DirectorySnapshot, Never>] = [:]
    private(set) var completed: Set<Int> = []
    private(set) var cancelled: Set<Int> = []
    init(_ initial: DirectorySnapshot) { self.initial = initial }
    func finish(_ index: Int) { pending.removeValue(forKey: index)?.resume(returning: initial) }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        reads += 1; let index = reads
        if index == 1 { return initial }
        let result = await withCheckedContinuation { pending[index] = $0 }
        completed.insert(index)
        if Task.isCancelled { cancelled.insert(index) }
        return result
    }
}

@Suite(.serialized)
@MainActor
struct CloudCommandTests {
    private func source(_ name: String = "Cloud.pptx", availability: FileAvailability = .onlineOnly,
                        size: Int64? = 24, regular: Bool? = true) -> TransferEntry {
        let root = URL(fileURLWithPath: "/tmp/cloud-command-fixture", isDirectory: true)
        let parent = LocalFileIdentity(device: 1, inode: 90, birthSeconds: 1, birthNanoseconds: 0)
        let item = FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: size, modifiedAt: nil, kind: "Presentation",
            identity: LocalFileIdentity(device: 1, inode: name == "Cloud.pptx" ? 91 : 92, birthSeconds: 1, birthNanoseconds: 0),
            availability: availability, isRegularFile: regular)
        return TransferEntry(source: .init(directoryURL: root, directoryIdentity: parent), item: item)
    }
    private func waitFor(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            try #require(Date() < deadline, "Timed out waiting for cloud command")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func setup(_ entry: TransferEntry, provider: CommandContentProvider) async throws -> (ExplorerStore, CommandDirectoryLoader) {
        let loader = CommandDirectoryLoader(.init(items: [entry.item], directoryIdentity: entry.source.directoryIdentity))
        let store = ExplorerStore(initialURL: entry.source.directoryURL, loader: loader,
            homeURL: entry.source.directoryURL, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        return (store, loader)
    }

    @Test
    func downloadDispatchesOnceRefreshesOnceAndReleasesLease() async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, loader) = try await setup(entry, provider: provider)
        store.downloadSelection(); store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        #expect(store.cloudCommandProgress?.phase == .queued)
        #expect(!store.isPerformingOperation)
        await provider.progress(0, .downloading)
        try await waitFor { store.downloadingItemID == entry.item.id }
        let local = source(availability: .availableLocally)
        await loader.set(.init(items: [local.item], directoryIdentity: local.source.directoryIdentity))
        let lease = CommandLease(local)
        await provider.finish(0, lease)
        try await waitFor { store.cloudCommandProgress == nil && lease.releases == 1 }
        #expect(store.operationNotice == "Downloaded ‘Cloud.pptx’.")
        #expect(await loader.reads == 2)
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        #expect(await provider.requests.count == 1)
        store.cancelLoads()
    }

    @Test(arguments: ["cancel", "selection", "navigation", "refresh", "teardown"])
    func invalidationCancelsControlAndDisposesLateLease(_ intent: String) async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        switch intent {
        case "cancel": store.cancelCloudCommand()
        case "selection": store.setSelection([], focusedID: nil)
        case "navigation": store.navigate(to: entry.source.directoryURL.appendingPathComponent("Other"))
        case "refresh": store.refresh()
        default: store.cancelLoads()
        }
        #expect(store.cloudCommandProgress == nil)
        #expect(await provider.cancelled(0))
        let notice = store.operationNotice
        if intent == "cancel" || intent == "selection" { #expect(notice == "Stopped waiting for the download.") }
        let lease = CommandLease(entry)
        await provider.finish(0, lease)
        try await waitFor { lease.releases == 1 }
        #expect(store.operationNotice == notice)
        store.cancelLoads()
    }

    @Test
    func identicalSelectionAndViewModeDoNotCancelCommand() async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        store.setViewMode(.details)
        #expect(store.cloudCommandProgress != nil)
        #expect(!(await provider.cancelled(0)))
        store.cancelLoads(); await provider.finishAll()
    }

    @Test
    func queuedTimeoutDoesNotClaimDownloadStarted() async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.cloudCommandTimeoutSeconds = 0.025
        store.downloadSelection()
        try await waitFor { store.cloudCommandProgress == nil && store.operationNotice != nil }
        #expect(store.operationNotice == "Timed out waiting to start the download.")
        #expect(await provider.requests.count == 1)
        #expect(await provider.cancelled(0))
        store.cancelLoads(); await provider.finishAll()
    }

    @Test
    func timeoutUsesNativeStartFactBeforeDelayedUIProgressHop() {
        let original = source(), entry = ItemOperationEntry(original)
        let origin = CloudContentOrigin(tabID: UUID(), location: original.source.directoryURL,
            searchID: nil, searchGeneration: nil, intentID: UUID(), url: original.item.url.absoluteString,
            identity: original.item.identity, context: entry.context)
        let session = CloudCommandSession(entry: entry, origin: origin, timeout: 1)
        #expect(session.timeoutNotice == "Timed out waiting to start the download.")
        // The native callback has executed; intentionally do not deliver its
        // separate MainActor presentation hop before checking the timer input.
        session.execution.record(.downloading)
        #expect(session.phase == .queued)
        #expect(session.timeoutNotice == ItemContentError.downloadTimedOut.localizedDescription)
    }

    @Test
    func lateProgressCannotRegressOwnedSearchVerificationOrStrandCommand() async throws {
        let entry = source(), local = source(availability: .availableLocally), provider = CommandContentProvider()
        let loader = CommandDirectoryLoader(.init(items: [entry.item], directoryIdentity: entry.source.directoryIdentity))
        let store = ExplorerStore(initialURL: entry.source.directoryURL, loader: loader, homeURL: entry.source.directoryURL,
            searcher: CommandSearcher(result: FilenameSearchResult(item: entry.item, parent: entry.source)), contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded }
        store.submitSearch("Cloud")
        try await waitFor { store.displayedItems.count == 1 && store.activeTab.search?.isRunning == false }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        await loader.set(.init(items: [local.item], directoryIdentity: local.source.directoryIdentity))
        await loader.holdNextRead()
        await provider.finish(0, CommandLease(local))
        try await waitFor { await loader.reads == 2 && store.cloudCommandProgress?.phase == .verifying }
        var progressUpdates = 0
        let subscription = store.$cloudCommandProgress.dropFirst().sink { _ in progressUpdates += 1 }
        defer { subscription.cancel() }
        await provider.progress(0, .queued); await provider.progress(0, .downloading)
        try await waitFor { progressUpdates == 2 }
        #expect(store.cloudCommandProgress?.phase == .verifying)
        await loader.finishHeldRead()
        try await waitFor { store.cloudCommandProgress == nil }
        #expect(store.operationNotice == "Downloaded ‘Cloud.pptx’.")
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        store.cancelLoads()
    }

    @Test
    func oldCancelledSearchRefreshCannotDiscardNewRefreshCancellationHandle() async throws {
        let entry = source(), provider = CommandContentProvider()
        let loader = SearchMetadataOverlapLoader(.init(items: [entry.item], directoryIdentity: entry.source.directoryIdentity))
        let store = ExplorerStore(initialURL: entry.source.directoryURL, loader: loader, homeURL: entry.source.directoryURL,
            searcher: CommandSearcher(result: FilenameSearchResult(item: entry.item, parent: entry.source)), contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded }
        store.submitSearch("Cloud")
        try await waitFor { store.displayedItems.count == 1 && store.activeTab.search?.isRunning == false }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 1 }
        await provider.fail(0, .downloadFailed("First attempt"))
        try await waitFor { await loader.reads == 2 && store.preview.canRetry }
        store.preview.retry()
        try await waitFor { await provider.requests.count == 2 }
        await provider.fail(1, .downloadFailed("Second attempt"))
        try await waitFor { await loader.reads == 3 && store.preview.canRetry }
        await loader.finish(2)
        try await waitFor { await loader.completed.contains(2) }
        store.cancelLoads()
        await loader.finish(3)
        try await waitFor { await loader.completed.contains(3) }
        #expect(await loader.cancelled.contains(3), "Teardown must still own and cancel the newer metadata read")
        await provider.finishAll()
    }

    @Test(arguments: [FileAvailability.availableLocally, .unknown])
    func downloadWaitsForPreviewThenUsesResidentOnly(_ presentationAvailability: FileAvailability) async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, loader) = try await setup(entry, provider: provider)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 1 }
        store.downloadSelection()
        #expect(store.cloudCommandProgress?.phase == .waitingForPreview)
        #expect(await provider.requests.count == 1)
        let local = source(availability: presentationAvailability)
        await loader.set(.init(items: [local.item], directoryIdentity: local.source.directoryIdentity))
        await provider.finish(0, CommandLease(local))
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        try await waitFor { await provider.requests.count == 2 }
        let requests = await provider.requests
        #expect(requests[1].purpose == .download)
        #expect(requests[1].hydrationPolicy == .residentOnly)
        await provider.finish(1, CommandLease(local))
        try await waitFor { store.cloudCommandProgress == nil }
        #expect(await loader.reads == 2, "The verified continuation must not repeat Preview's authoritative refresh")
        _ = await presentation.lease.release()
        store.cancelLoads(); await provider.finishAll()
    }

    @Test
    func cancellingWaitingDownloadDoesNotCancelPreview() async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 1 }
        store.downloadSelection(); store.cancelCloudCommand()
        #expect(!(await provider.cancelled(0)))
        #expect(await provider.requests.count == 1)
        store.cancelLoads(); await provider.finishAll()
    }

    @Test(arguments: ["hide", "details", "surface"])
    func implicitPreviewStopEndsWaitingDownloadWithTruthfulNotice(_ action: String) async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 1 }
        store.downloadSelection()
        #expect(store.cloudCommandProgress?.phase == .waitingForPreview)
        switch action {
        case "hide": store.togglePreviewPane()
        case "details": store.toggleDetailsPane()
        default: store.setPreviewSurfaceVisible(false)
        }
        try await waitFor { store.cloudCommandProgress == nil }
        #expect(await provider.requests.count == 1)
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        #expect(store.operationNotice == "Stopped waiting for the download.")
        store.cancelLoads(); await provider.finishAll()
    }

    @Test(arguments: [false, true])
    func verificationDeadlineReportsResidentSuccessOnlyAfterLeaseValidation(_ validatedResident: Bool) async throws {
        let entry = source(), local = source(availability: .availableLocally), provider = CommandContentProvider()
        let (store, loader) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); Task { await provider.finishAll(); await loader.finishHeldRead() } }
        store.cloudCommandTimeoutSeconds = 0.2
        store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        await provider.progress(0, .downloading)
        await provider.progress(0, .preparing)
        let lease = CommandLease(local)
        if validatedResident {
            await loader.set(.init(items: [local.item], directoryIdentity: local.source.directoryIdentity))
            await loader.holdNextRead()
            await provider.finish(0, lease)
            try await waitFor { await loader.reads == 2 }
        }
        try await waitFor { store.cloudCommandProgress?.phase == .verifying }
        try await waitFor { store.cloudCommandProgress == nil }
        if validatedResident {
            #expect(store.operationNotice == "Downloaded ‘Cloud.pptx’. The folder could not be refreshed.")
            try await waitFor { lease.releases == 1 }
        } else {
            #expect(store.operationNotice == ItemContentError.downloadTimedOut.localizedDescription,
                    "Preparing progress alone is not evidence of a validated resident lease")
        }
    }

    @Test
    func replacementPreviewCannotStrandWaitingSearchDownloadAtMetadataHandoff() async throws {
        let entry = source(), local = source(availability: .availableLocally), provider = CommandContentProvider()
        let loader = CommandDirectoryLoader(.init(items: [entry.item], directoryIdentity: entry.source.directoryIdentity))
        let store = ExplorerStore(initialURL: entry.source.directoryURL, loader: loader, homeURL: entry.source.directoryURL,
            searcher: CommandSearcher(result: FilenameSearchResult(item: entry.item, parent: entry.source)), contentProvider: provider)
        defer { store.cancelLoads(); Task { await provider.finishAll() } }
        try await waitFor { store.activeTab.hasLoaded }
        store.submitSearch("Cloud")
        try await waitFor { store.displayedItems.count == 1 && store.activeTab.search?.isRunning == false }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 1 }
        store.downloadSelection()
        await provider.finish(0, CommandLease(local))
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        defer { Task { _ = await presentation.lease.release() } }
        // Both real surface transitions precede the queued terminal callback.
        // Its old handoff now meets a different active Preview attempt.
        store.setPreviewSurfaceVisible(false); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 2 }
        #expect(await provider.requests[1].purpose == .preview)
        #expect(await provider.requests[1].hydrationPolicy == .residentOnly)
        #expect(store.cloudCommandProgress == nil, "A refused old search handoff must finish its owned waiting Download")
        #expect(store.operationNotice == "Stopped waiting for the download.")
        #expect(!(await provider.cancelled(1)), "Finishing the old handoff must not cancel the newer Preview")
    }

    @Test
    func cancelledDownloadKeepsResidentOnlyBarrierAcrossSurfaceRemountAndRetryIsExplicit() async throws {
        let entry = source(), provider = CommandContentProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.downloadSelection()
        try await waitFor { await provider.requests.count == 1 }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        #expect(await provider.requests.count == 1)
        store.cancelCloudCommand()
        try await waitFor { await provider.requests.count == 2 }
        #expect(await provider.requests[1].hydrationPolicy == .residentOnly)
        await provider.fail(1, .cloudNotDownloaded)
        try await waitFor { store.preview.canRetry && !store.activeTab.isRefreshing }
        store.setPreviewSurfaceVisible(false); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 3 }
        #expect(await provider.requests[2].hydrationPolicy == .residentOnly)
        await provider.fail(2, .cloudNotDownloaded)
        try await waitFor { store.preview.canRetry && !store.activeTab.isRefreshing }
        store.preview.retry()
        try await waitFor { await provider.requests.count == 4 }
        #expect(await provider.requests[3].hydrationPolicy == .whenNeeded)
        store.cancelLoads(); await provider.finishAll()
    }
}
