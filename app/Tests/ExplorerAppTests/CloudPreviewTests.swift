import AppKit
import CoreGraphics
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor CloudPreviewProvider: ItemContentProviding {
    private let reportsDownload: Bool
    private(set) var requests: [ContentRequest] = []
    private var pending: [Int: CheckedContinuation<any MaterializedContentLease, Error>] = [:]
    private var controls: [TransferControl] = []
    init(reportsDownload: Bool = true) { self.reportsDownload = reportsDownload }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        let index = requests.count
        requests.append(request)
        controls.append(control)
        if reportsDownload { request.onProgress?(.downloading) }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func fail(_ index: Int, _ error: ItemContentError = .downloadFailed("Synthetic provider failure")) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }
    func progress(_ index: Int, _ phase: ContentPreparationPhase) { requests[index].onProgress?(phase) }
    func finish(_ index: Int, _ lease: any MaterializedContentLease) {
        pending.removeValue(forKey: index)?.resume(returning: lease)
    }
    func wasCancelled(_ index: Int) -> Bool {
        do { try controls[index].checkpoint(); return false } catch { return error is CancellationError }
    }
    func cancelAll() {
        let continuations = Array(pending.values); pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private final class CloudPreviewLease: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    var fileURL: URL { physicalEntry.item.url }
    var sourceURL: URL { fileURL }
    let archiveRevision: ArchiveRevision? = nil
    let byteCount: UInt64 = 24
    init(_ entry: TransferEntry) { physicalEntry = entry }
    func validateForUse() async throws {}
    func release() async -> ContentLeaseReleaseResult { .init(disposition: .released) }
}

private actor CloudPreviewLoader: DirectoryListing {
    var result: DirectorySnapshot
    private(set) var reads = 0
    private(set) var locations: [URL] = []
    private var holdNext = false
    private var held: CheckedContinuation<DirectorySnapshot, Never>?
    init(_ result: DirectorySnapshot) { self.result = result }
    func setResult(_ result: DirectorySnapshot) { self.result = result }
    func holdNextRead() { holdNext = true }
    func completeHeld(_ result: DirectorySnapshot) { held?.resume(returning: result); held = nil }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        reads += 1; locations.append(url)
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { held = $0 }
        }
        return result
    }
}

private struct FastCloudPreviewProvider: ItemContentProviding {
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        try control.checkpoint()
        guard case .filesystem(let parent) = request.source.context else { throw ItemContentError.unsupportedType }
        if request.source.item.availability == .onlineOnly {
            request.onProgress?(.downloading); request.onProgress?(.preparing)
        }
        return CloudPreviewLease(TransferEntry(source: parent, item: request.source.item))
    }
}

private actor RefusingCloudPreviewProvider: ItemContentProviding {
    let permissionFailure: Bool
    private(set) var requests = 0
    init(permissionFailure: Bool) { self.permissionFailure = permissionFailure }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        try control.checkpoint()
        requests += 1
        // These refusals happen before hydration, so no progress is emitted.
        if permissionFailure { throw POSIXError(.EACCES) }
        throw ItemContentError.limitExceeded
    }
}

private struct CloudPreviewSearcher: FilenameSearching {
    let result: FilenameSearchResult
    func search(_ request: FilenameSearchRequest) -> AsyncThrowingStream<FilenameSearchEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(results: [result], coverage: SearchCoverage()))
            continuation.yield(.finished(SearchCoverage()))
            continuation.finish()
        }
    }
}

private final class CloudPreviewObserver: DirectoryObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation?
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        let pair = AsyncThrowingStream<DirectoryChange, Error>.makeStream()
        lock.withLock { continuation = pair.continuation }
        return pair.stream
    }
    func change() { _ = lock.withLock { continuation?.yield(.changed) } }
}

@Suite(.serialized)
@MainActor
struct CloudPreviewTests {
    @Test
    func ordinaryLocalFailureRetriesAfterAutomaticRefresh() async throws {
        let source = entry(availability: .unknown), provider = CloudPreviewProvider(reportsDownload: false)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        defer { store.cancelLoads(); Task { await provider.cancelAll() } }
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { await provider.requests.count == 1 }
        await provider.fail(0, .staleSource)
        try await waitFor { if case .failed = store.preview.state { return true }; return false }
        #expect(!store.preview.canRetry)
        store.refreshAfterActivation()
        try await waitFor { await loader.reads == 2 && !store.activeTab.isRefreshing }
        #expect(store.preview.state == .preparing, "A local read race must not latch a cloud failure across automatic refresh")
        // show() publishes preparing before its new MainActor task enters the
        // provider actor; refresh completion does not fence that second hop.
        try await waitFor { await provider.requests.count == 2 }
        #expect(await provider.requests.count == 2)
        #expect(store.currentSelection.selectedIDs == [source.item.id])
    }

    @Test
    func ordinaryLocalPreparationDoesNotHoldAutomaticRefresh() async throws {
        let source = entry(availability: .unknown), provider = CloudPreviewProvider(reportsDownload: false)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        defer { store.cancelLoads(); Task { await provider.cancelAll() } }
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { await provider.requests.count == 1 }
        await loader.holdNextRead()
        store.refreshAfterActivation()
        // Loading state is published synchronously by automatic-refresh admission;
        // no provider completion is needed to observe whether that admission ran.
        #expect(store.activeTab.isRefreshing, "An ordinary local Preview must not defer directory maintenance")
        #expect(await provider.wasCancelled(0))
        if store.activeTab.isRefreshing {
            try await waitFor { await loader.reads == 2 }
            await loader.completeHeld(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
            try await waitFor { !store.activeTab.isRefreshing }
            #expect(store.currentSelection.selectedIDs == [source.item.id])
        }
    }

    @Test
    func waiterReturnsOnItsFirstSuccessfulObservation() async throws {
        var observations = 0
        try await waitFor {
            observations += 1
            return observations == 1
        }
        #expect(observations == 1)
    }

    private func entry(availability: FileAvailability = .onlineOnly,
                       parentPath: String = "/tmp/cloud-preview-fixture") -> TransferEntry {
        let root = URL(fileURLWithPath: parentPath, isDirectory: true)
        let parent = LocalFileIdentity(device: 1, inode: 80, birthSeconds: 1, birthNanoseconds: 0)
        let item = FileItem(url: root.appendingPathComponent("Cloud.pptx"), name: "Cloud.pptx",
            isDirectory: false, isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Presentation",
            identity: LocalFileIdentity(device: 1, inode: 81, birthSeconds: 1, birthNanoseconds: 0),
            availability: availability)
        return TransferEntry(source: FileOperationContext(directoryURL: root, directoryIdentity: parent), item: item)
    }
    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            if await condition() { return }
            try #require(Date() < deadline, "Timed out waiting for the cloud preview test condition")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(arguments: [false, true])
    func homeCloudReconcilesOnlyTheSelectedChildAndHonorsRetention(deselectBeforeRefresh: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Synthetic.pptx")
        try Data(repeating: 32, count: 24).write(to: url)
        let real = try await LocalDirectoryLoader.inspectorEntry(at: url)
        let doc = try #require(await RecentDocument.sample(url))
        let placeholder = FileItem(url: real.item.url, name: real.item.name, isDirectory: false,
            isSymbolicLink: false, size: 24, modifiedAt: real.item.modifiedAt, kind: "Presentation",
            identity: real.item.identity, availability: .onlineOnly, isRegularFile: true)
        let source = TransferEntry(source: real.source, item: placeholder)
        let provider = CloudPreviewProvider()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: []))
        let recent = RecentDocumentStore()
        recent.record([doc], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, loader: loader, homeURL: folder,
                                  contentProvider: provider, recentDocuments: recent)
        let childReads = HeldInspectorReads()
        defer { store.cancelLoads(); Task { await provider.cancelAll(); await childReads.stop() } }
        store.readHomeInspectorEntry = { _ in try await childReads.sample() }
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(recent: doc)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        store.setPreviewSurfaceVisible(true)
        store.toggleDetailsPane()
        try await waitFor { await childReads.count == 1 }
        await childReads.finish(0, with: source)
        try await waitFor { store.inspectorDetails.item?.availability == .onlineOnly }
        store.retentionActivityChanged(blocking: PhysicalContentTarget(source))
        store.togglePreviewPane()
        try await waitFor { await provider.requests.count == 1 }
        #expect(await provider.requests[0].hydrationPolicy == .residentOnly)
        #expect(!store.canDownloadSelection && !store.canChangeOneDriveRetention)
        await provider.finish(0, CloudPreviewLease(source))
        try await waitFor { if case .ready = store.preview.state { true } else { false } }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        try await waitFor { await childReads.count == 2 }
        if deselectBeforeRefresh { store.replaceHomeResults([], in: scope) }
        await childReads.finish(1, with: real)
        if deselectBeforeRefresh {
            await Task.yield()
            #expect(store.inspectorDetails == .empty)
            #expect(store.preview.state == .empty)
        } else {
            try await waitFor { store.inspectorDetails.item?.availability == real.item.availability }
        }
        #expect(await loader.reads == 0)
        #expect(store.activeTab.url == BrowserPage.home.url)
        #expect(recent.contains(doc))
        _ = await presentation.lease.release()
    }
    private func captureComponent(_ host: NSView, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["MAXPLORER_CLOUD_PREVIEW_EVIDENCE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording is not already authorized; capture refused without a permission request")
        let window = try #require(host.window)
        window.backgroundColor = .textBackgroundColor
        window.animationBehavior = .none
        if !window.isVisible { window.orderFrontRegardless() }
        // Keep this one test window visible between states; its existing test
        // teardown closes it. Ordering out/in can race WindowServer animation.
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        // Native controls finish their display work on the run loop. An
        // offscreen cacheDisplay bitmap does not capture those control layers.
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        window.display()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for button in descendants(host).compactMap({ $0 as? NSButton }) {
            let frame = host.convert(button.bounds, from: button)
            try #require(button.title == "Retry" && button.isEnabled && !button.isHiddenOrHasHiddenAncestor)
            try #require(frame.width > 0 && frame.height > 0 && host.bounds.contains(frame))
        }
        try #require(window.isVisible && window.windowNumber > 0)
        let number = CGWindowID(window.windowNumber)
        let deadline = Date().addingTimeInterval(1)
        var records = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? []
        while (records.first?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            records = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? []
        }
        try #require(records.count == 1)
        try #require((records[0][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier)
        try #require((records[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value == number)
        try #require((records[0][kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPreviewCapture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let captured = temporary.appendingPathComponent("component.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(number), captured.path]
        try capture.run()
        capture.waitUntilExit()
        try #require(capture.terminationStatus == 0, "Owned test-window capture refused; no desktop fallback")
        let png = try Data(contentsOf: captured)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        var firstVisible: (CGFloat, CGFloat, CGFloat)?
        var variedPixels = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                if let first = firstVisible {
                    if abs(color.redComponent - first.0) + abs(color.greenComponent - first.1)
                        + abs(color.blueComponent - first.2) > 0.05 { variedPixels = true }
                } else { firstVisible = (color.redComponent, color.greenComponent, color.blueComponent) }
            }
        }
        try #require(variedPixels, "Owned component capture is blank; no fallback or visual pass")
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
    }

    @Test(arguments: [false, true])
    func nonDownloadCloudFailureDoesNotLoopOnAutomaticMetadataRefresh(_ permissionFailure: Bool) async throws {
        let source = entry(), provider = RefusingCloudPreviewProvider(permissionFailure: permissionFailure)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        defer { store.cancelLoads() }
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { await provider.requests >= 1 }
        // A bounded negative observation window covers the automatic refresh and
        // catches a new materialization started by its changed load epoch.
        try await Task.sleep(for: .milliseconds(100))
        let attempts = await provider.requests, reads = await loader.reads
        #expect(attempts == 1)
        #expect(reads <= 2, "Initial listing plus at most one metadata refresh")
        #expect(!store.preview.canRetry, "Size/permission errors keep ordinary preview wording and no download Retry")
        let detail = permissionFailure ? POSIXError(.EACCES).localizedDescription : ItemContentError.limitExceeded.localizedDescription
        #expect(store.preview.state == .failed(detail))
        store.preview.retry()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await provider.requests == 1, "Download Retry remains unavailable for ordinary preview failures")
        store.refresh()
        try await waitFor { await provider.requests >= 2 && store.preview.state == .failed(detail) && !store.activeTab.isRefreshing }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await provider.requests == 2, "Explicit Refresh permits one fresh attempt")
        #expect(await loader.reads <= 4, "Each explicit attempt permits at most one metadata refresh")
        #expect(!store.preview.canRetry && store.preview.state == .failed(detail))
    }

    @Test
    func failedCloudPreviewDoesNotRestartForSameSelectionAfterPassiveLoadEpochChanges() async throws {
        let source = entry(), tab = UUID(), provider = CloudPreviewProvider()
        let model = ItemPreviewModel(provider: provider)
        func request() -> PreviewRequest {
            PreviewRequest(tabID: tab, generation: UUID(), searchGeneration: nil,
                items: [source.item], entry: ItemOperationEntry(source))
        }
        model.show(request())
        try await waitFor { await provider.requests.count == 1 }
        await provider.fail(0)
        try await waitFor { if case .failed = model.state { return true }; return false }
        let failure = model.state
        model.show(request())
        try await Task.sleep(for: .milliseconds(40))
        #expect(await provider.requests.count == 1)
        #expect(model.state == failure)
        model.show(nil)
        await provider.cancelAll()
    }

    @Test
    func activationRefreshWaitsUntilCloudPreparationEnds() async throws {
        let source = entry(), provider = CloudPreviewProvider()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane()
        store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { await provider.requests.count == 1 }
        store.refreshAfterActivation()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await loader.reads == 1)
        #expect(await provider.requests.count == 1)
        #expect(!store.activeTab.isRefreshing)
        store.cancelLoads()
        await provider.cancelAll()
    }

    @Test
    func progressGuardLastsThroughPreparingAndRendererAdmission() async throws {
        let source = entry(), provider = CloudPreviewProvider()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { store.preview.state == .downloading }
        #expect(store.downloadingItemID == source.item.id && store.showsCloudStatusColumn)
        await provider.progress(0, .preparing)
        try await waitFor { store.preview.state == .preparing }
        for _ in 0..<5 { store.refreshAfterActivation() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await loader.reads == 1)
        await provider.finish(0, CloudPreviewLease(source))
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        store.refreshAfterActivation()
        #expect(await loader.reads == 1)
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        try await waitFor { await loader.reads == 2 }
        #expect(store.activeTab.selection.selectedIDs == [source.item.id])
        _ = await presentation.lease.release()
        store.cancelLoads(); await provider.cancelAll()
    }

    @Test
    func failureRefreshCoalescesAndRetryIsExplicit() async throws {
        let source = entry(), provider = CloudPreviewProvider()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { await provider.requests.count == 1 }
        for _ in 0..<5 { store.refreshAfterActivation() }
        await provider.fail(0, .downloadTimedOut)
        try await waitFor { await loader.reads == 2 && store.preview.canRetry && !store.activeTab.isRefreshing }
        #expect(await provider.requests.count == 1)
        store.preview.retry()
        try await waitFor { await provider.requests.count == 2 }
        #expect(!store.preview.canRetry)
        store.refresh()
        try await waitFor { await provider.requests.count == 3 }
        await provider.progress(1, .preparing)
        await provider.fail(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.preview.state == .downloading && !store.preview.canRetry)
        store.cancelLoads(); await provider.cancelAll()
    }

    @Test
    func nativeRetryButtonUsesCurrentModelAndClearsFailureContent() async throws {
        _ = NSApplication.shared
        let source = entry(), provider = CloudPreviewProvider(), model = ItemPreviewModel(provider: provider)
        // This standalone renderer harness supplies the same explicit admission
        // boundary the production store owns; the button never starts content itself.
        model.onRetryRequested = { [weak model] intent in
            var request = intent.request; request.hydrationPolicy = .whenNeeded
            model?.restartAfterExplicitRetry(intent, request: request)
        }
        let host = PreviewHostView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        let coordinator = PreviewRenderer.Coordinator(model: model)
        coordinator.attach(host, focus: ExplorerFocusCoordinator())
        defer { coordinator.detach(); model.show(nil) }
        model.show(PreviewRequest(tabID: UUID(), generation: UUID(), searchGeneration: nil,
            items: [source.item], entry: ItemOperationEntry(source)))
        try await waitFor { model.state == .downloading }
        coordinator.update(model.state)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let downloadingLabels = descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(downloadingLabels.contains("Downloading…"))
        try await captureComponent(host, name: "cloud-downloading")
        await provider.fail(0, .downloadTimedOut)
        try await waitFor { model.canRetry }
        coordinator.update(model.state)
        let button = try #require(descendants(host).compactMap { $0 as? NSButton }.first)
        #expect(button.accessibilityIdentifier() == "preview-retry" && button.title == "Retry")
        try await captureComponent(host, name: "cloud-timeout-retry")
        try #require(button.sendAction(button.action, to: button.target))
        try await waitFor { await provider.requests.count == 2 }
        coordinator.update(model.state)
        let hasRetry = descendants(host).contains { $0 is NSButton }
        let hasTimeout = descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("took too long") }
        #expect(!hasRetry && !hasTimeout)
        await provider.fail(1)
        try await waitFor { model.canRetry }
        coordinator.update(model.state)
        try await captureComponent(host, name: "cloud-provider-error-retry")
        model.show(nil); await provider.progress(1, .preparing)
        await provider.cancelAll()
        #expect(model.state == .empty)
    }

    @Test
    func watcherBurstRefreshesMetadataOnceWithoutRetryingFailure() async throws {
        let source = entry(), provider = CloudPreviewProvider(), observer = CloudPreviewObserver()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, observer: observer, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { store.preview.state == .downloading }
        for _ in 0..<30 { observer.change() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(await loader.reads == 1)
        let refreshed = entry(availability: .availableLocally)
        await loader.setResult(DirectorySnapshot(items: [refreshed.item], directoryIdentity: refreshed.source.directoryIdentity))
        await provider.fail(0)
        try await waitFor { await loader.reads == 2 && store.preview.canRetry && !store.activeTab.isRefreshing }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.reads == 2)
        #expect(await provider.requests.count == 1)
        #expect(store.activeTab.items.first?.availability == .availableLocally)
        #expect(store.activeTab.selection.selectedIDs == [source.item.id])
        store.cancelLoads(); await provider.cancelAll()
    }

    @Test(arguments: ["selection", "navigation", "hide", "refresh"])
    func explicitIntentCancelsCloudWaitAndRejectsItsLateProgress(_ intent: String) async throws {
        let source = entry(), provider = CloudPreviewProvider()
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { store.preview.state == .downloading }
        switch intent {
        case "selection": store.setSelection([], focusedID: nil)
        case "navigation": store.navigate(to: source.source.directoryURL.appendingPathComponent("Elsewhere", isDirectory: true))
        case "hide": store.togglePreviewPane()
        default: store.refresh()
        }
        try await waitFor { await provider.wasCancelled(0) }
        await provider.progress(0, .downloading)
        await provider.fail(0)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!store.preview.canRetry)
        if intent != "refresh" { #expect(store.preview.state == .empty) }
        store.cancelLoads(); await provider.cancelAll()
    }

    @Test
    func cloudColumnRemembersCurrentScopeButResetsAfterNavigation() async throws {
        let source = entry(), plain = entry(availability: .unknown)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader, homeURL: source.source.directoryURL)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        #expect(store.showsCloudStatusColumn)
        await loader.setResult(DirectorySnapshot(items: [plain.item], directoryIdentity: plain.source.directoryIdentity))
        store.refresh()
        try await waitFor { await loader.reads == 2 && !store.activeTab.isLoading }
        #expect(store.showsCloudStatusColumn)
        store.navigate(to: source.source.directoryURL.appendingPathComponent("Plain", isDirectory: true))
        try await waitFor { await loader.reads == 3 && !store.activeTab.isLoading }
        #expect(!store.showsCloudStatusColumn)
        store.cancelLoads()
    }

    @Test
    func searchHydrationRefreshesOnlyCapturedParentAndInvalidatesOldMenuMetadata() async throws {
        let nested = "/tmp/cloud-preview-fixture/Nested"
        let source = entry(parentPath: nested), local = entry(availability: .availableLocally, parentPath: nested)
        let root = source.source.directoryURL.deletingLastPathComponent()
        let rootIdentity = LocalFileIdentity(device: 1, inode: 99, birthSeconds: 1, birthNanoseconds: 0)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [], directoryIdentity: rootIdentity))
        let provider = CloudPreviewProvider()
        let searcher = CloudPreviewSearcher(result: FilenameSearchResult(item: source.item, parent: source.source))
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
            searcher: searcher, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.submitSearch("Cloud")
        try await waitFor { store.activeTab.search?.phase == .complete }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { store.preview.state == .downloading }
        let searchID = store.activeTab.search?.id, searchGeneration = store.activeTab.search?.generation
        let captured = ContextMenuSnapshot(store: store, item: source.item)
        #expect(captured.matches(store))
        await loader.setResult(DirectorySnapshot(items: [local.item], directoryIdentity: local.source.directoryIdentity))
        await provider.fail(0)
        try await waitFor { store.activeTab.search?.displayedItems.first?.availability == .availableLocally }
        #expect(await loader.locations == [root, source.source.directoryURL])
        #expect(store.activeTab.search?.id == searchID && store.activeTab.search?.generation == searchGeneration)
        #expect(store.activeTab.search?.selection.selectedIDs == [source.item.id])
        #expect(store.preview.canRetry && store.showsCloudStatusColumn)
        #expect(!captured.matches(store))
        #expect(await provider.requests.count == 1)
        store.cancelLoads(); await provider.cancelAll()
    }

    @Test
    func fastDownloadWithoutWatcherStillRefreshesAvailabilityAfterAdmission() async throws {
        let source = entry(), local = entry(availability: .availableLocally)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [source.item], directoryIdentity: source.source.directoryIdentity))
        let store = ExplorerStore(initialURL: source.source.directoryURL, loader: loader,
            homeURL: source.source.directoryURL, contentProvider: FastCloudPreviewProvider())
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        await loader.setResult(DirectorySnapshot(items: [local.item], directoryIdentity: local.source.directoryIdentity))
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        try await waitFor { store.activeTab.items.first?.availability == .availableLocally }
        #expect(await loader.reads == 2)
        #expect(store.showsCloudStatusColumn && store.downloadingItemID == nil)
        _ = await presentation.lease.release()
        store.cancelLoads()
    }

    @Test
    func oldSearchMetadataResponseCannotCancelRetryDownload() async throws {
        let nested = "/tmp/cloud-preview-fixture/Nested"
        let source = entry(parentPath: nested), local = entry(availability: .availableLocally, parentPath: nested)
        let root = source.source.directoryURL.deletingLastPathComponent()
        let rootIdentity = LocalFileIdentity(device: 1, inode: 99, birthSeconds: 1, birthNanoseconds: 0)
        let loader = CloudPreviewLoader(DirectorySnapshot(items: [], directoryIdentity: rootIdentity))
        let provider = CloudPreviewProvider()
        let searcher = CloudPreviewSearcher(result: FilenameSearchResult(item: source.item, parent: source.source))
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
            searcher: searcher, contentProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.submitSearch("Cloud")
        try await waitFor { store.activeTab.search?.phase == .complete }
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        store.setSelection([source.item.id], focusedID: source.item.id)
        try await waitFor { store.preview.state == .downloading }
        let refreshed = DirectorySnapshot(items: [local.item], directoryIdentity: local.source.directoryIdentity)
        await loader.setResult(refreshed)
        await loader.holdNextRead()
        await provider.fail(0)
        try await waitFor { await loader.reads == 2 && store.preview.canRetry }
        store.preview.retry()
        try await waitFor { await provider.requests.count == 2 && store.preview.state == .downloading }
        await loader.completeHeld(refreshed)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await provider.requests.count == 2)
        #expect(!(await provider.wasCancelled(1)))
        #expect(store.preview.state == .downloading)
        await provider.finish(1, CloudPreviewLease(source))
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        try await waitFor { store.activeTab.search?.displayedItems.first?.availability == .availableLocally }
        #expect(await loader.reads == 3)
        _ = await presentation.lease.release()
        store.cancelLoads(); await provider.cancelAll()
    }
}
