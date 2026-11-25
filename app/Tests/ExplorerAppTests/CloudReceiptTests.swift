import Darwin
import Foundation
import Testing
@testable import ExplorerCore
@testable import ExplorerApp

private final class ReceiptResidency: @unchecked Sendable {
    private let lock = NSLock()
    private var missing = true
    var dataless: Bool { lock.withLock { missing } }
    func materialized() { lock.withLock { missing = false } }
}

private final class ReceiptCoordinator: HydrationCoordinating, @unchecked Sendable {
    let entry: TransferEntry
    let state: ReceiptResidency
    init(_ entry: TransferEntry, state: ReceiptResidency) { self.entry = entry; self.state = state }
    func coordinateReading(at url: URL, accessor: (URL) throws -> Void) throws {
        try LocalFileOperations.withParent(entry.source) { parent, _ in
            let writer = openat(parent, entry.item.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard writer >= 0 else { throw ContentFileIO.failure() }
            defer { close(writer) }
            guard let original = entry.item.identity else { throw ItemContentError.staleSource }
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var creation = timespec(tv_sec: Int(original.birthSeconds - 1), tv_nsec: Int(original.birthNanoseconds))
            guard fsetattrlist(writer, &attributes, &creation, MemoryLayout<timespec>.size, 0) == 0 else { throw ContentFileIO.failure() }
        }
        state.materialized()
        try accessor(url)
    }
    func cancel() {}
}

private actor ReceiptLoader: DirectoryListing {
    let original: DirectorySnapshot
    let duplicate: Bool
    let holdRefresh: Bool
    private(set) var reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(original: DirectorySnapshot, duplicate: Bool = false, holdRefresh: Bool = false) {
        self.original = original; self.duplicate = duplicate; self.holdRefresh = holdRefresh
    }
    func finishRefresh() { continuation?.resume(); continuation = nil }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        reads += 1
        if reads == 1 { return original }
        if holdRefresh { await withCheckedContinuation { continuation = $0 } }
        let current = try await LocalDirectoryLoader().snapshot(of: url, showHidden: showHidden)
        let rows = current.items.filter { $0.id == original.items.first?.id }
        return DirectorySnapshot(items: duplicate ? rows + rows : rows, directoryIdentity: current.directoryIdentity)
    }
}

private actor TrackedReceiptProvider: ItemContentProviding {
    let provider: LocalItemContentProvider
    private(set) var requests: [ContentRequest] = []
    init(_ provider: LocalItemContentProvider) { self.provider = provider }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        requests.append(request)
        // Model the terminal result overtaking a scheduled progress hop: the
        // receipt must be admissible even when no progress callback ran yet.
        return try await provider.materialize(ContentRequest(source: request.source, purpose: request.purpose,
            requestID: request.requestID, hydrationPolicy: request.hydrationPolicy,
            hydrationTimeoutSeconds: request.hydrationTimeoutSeconds), control: control)
    }
}

private final class AppReceiptFixture: @unchecked Sendable {
    let root: URL
    let entry: TransferEntry
    let provider: LocalItemContentProvider
    init(invalidText: Bool = false, availability: FileAvailability = .onlineOnly) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudReceipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("synthetic.txt")
        try (invalidText ? Data([0xff, 0x00]) : Data("synthetic content".utf8)).write(to: url)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let row = try #require(snapshot.items.first { $0.url == url })
        let item = FileItem(url: row.url, name: row.name, isDirectory: false, isSymbolicLink: false,
            size: row.size, modifiedAt: row.modifiedAt, kind: row.kind, identity: row.identity,
            availability: availability, isRegularFile: true)
        entry = TransferEntry(source: FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity)), item: item)
        let state = ReceiptResidency()
        let access = PhysicalContentAccess(sample: { name, parent in
            var sample = try ContentFileIO.sample(name, at: parent)
            if state.dataless { sample.st_flags |= UInt32(SF_DATALESS) }
            return sample
        }, sampleDescriptor: { fd in
            var sample = try ContentFileIO.sample(fd)
            if state.dataless { sample.st_flags |= UInt32(SF_DATALESS) }
            return sample
        })
        let coordinator = ReceiptCoordinator(entry, state: state)
        provider = LocalItemContentProvider(registry: ContentLeaseRegistry(rootURL: root.appendingPathComponent("leases")),
            physicalAccess: access, hydrator: LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator }))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var original: DirectorySnapshot { DirectorySnapshot(items: [entry.item], directoryIdentity: entry.source.directoryIdentity) }
    func openDescriptors() -> Int {
        guard let identity = entry.item.identity else { return 0 }
        return (0..<getdtablesize()).reduce(0) { count, descriptor in
            var sample = stat()
            guard fstat(descriptor, &sample) == 0, let current = LocalFileIdentity.fromStat(sample),
                  current.device == identity.device, current.inode == identity.inode else { return count }
            return count + 1
        }
    }
}

@Suite(.serialized)
@MainActor
struct CloudReceiptTests {
    private func waitFor(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            try #require(Date() < deadline, "Timed out waiting for receipt ownership")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    @Test(arguments: [false, true])
    func receiptUsesExistingLoadAndRefusalAlwaysFlushesPreview(_ duplicate: Bool) async throws {
        let fixture = try await AppReceiptFixture()
        let loader = ReceiptLoader(original: fixture.original, duplicate: duplicate)
        let store = ExplorerStore(initialURL: fixture.root, loader: loader, homeURL: fixture.root, contentProvider: fixture.provider)
        defer { store.cancelLoads() }
        try await waitFor { store.activeTab.hasLoaded }
        store.setSelection([fixture.entry.item.id], focusedID: fixture.entry.item.id)
        store.downloadSelection()
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { store.cloudCommandProgress == nil && store.operationNotice != nil && !store.activeTab.isRefreshing }
        #expect(await loader.reads == 2)
        if duplicate {
            #expect(store.currentSelection.selectedIDs.isEmpty)
            #expect(store.preview.state == .empty, "Refused proof must still flush the deferred Preview update")
        } else {
            #expect(store.currentSelection.selectedIDs == [fixture.entry.item.id])
            #expect(store.activeTab.items.first?.identity != fixture.entry.item.identity)
            #expect(store.operationNotice == "Downloaded ‘synthetic.txt’.")
        }
    }

    @Test
    func unknownCaptureAcceptsFastReceiptAndKeepsResidentOnlyBarrierAfterRemount() async throws {
        let fixture = try await AppReceiptFixture(invalidText: true, availability: .unknown)
        let loader = ReceiptLoader(original: fixture.original)
        let provider = TrackedReceiptProvider(fixture.provider)
        let store = ExplorerStore(initialURL: fixture.root, loader: loader, homeURL: fixture.root, contentProvider: provider)
        defer { store.cancelLoads() }
        try await waitFor { store.activeTab.hasLoaded }
        store.setSelection([fixture.entry.item.id], focusedID: fixture.entry.item.id)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { await loader.reads == 2 && !store.activeTab.isRefreshing && store.preview.state == .unsupported }
        #expect(store.currentSelection.selectedIDs == [fixture.entry.item.id])
        #expect(store.activeTab.items.first?.identity != fixture.entry.item.identity)
        #expect(await provider.requests.count == 1)
        store.setPreviewSurfaceVisible(false); store.setPreviewSurfaceVisible(true)
        try await waitFor { await provider.requests.count == 2 && store.preview.state == .unsupported }
        #expect(await provider.requests[1].hydrationPolicy == .residentOnly)
    }

    @Test
    func verifiedPreviewHandoffKeepsAcceptedPresentationWithoutAnotherFetch() async throws {
        let fixture = try await AppReceiptFixture(availability: .unknown)
        let loader = ReceiptLoader(original: fixture.original, holdRefresh: true)
        let provider = TrackedReceiptProvider(fixture.provider)
        let store = ExplorerStore(initialURL: fixture.root, loader: loader, homeURL: fixture.root, contentProvider: provider)
        defer { store.cancelLoads(); Task { await loader.finishRefresh() } }
        try await waitFor { store.activeTab.hasLoaded }
        store.setSelection([fixture.entry.item.id], focusedID: fixture.entry.item.id)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let presentationID) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(presentationID))
        defer { Task { _ = await presentation.lease.release() } }
        try await waitFor { await loader.reads == 2 }
        await loader.finishRefresh()
        try await waitFor {
            guard !store.activeTab.isRefreshing else { return false }
            if case .ready = store.preview.state { return true }; return false
        }
        #expect(store.activeTab.items.first?.identity != fixture.entry.item.identity)
        #expect(store.currentSelection.selectedIDs == [fixture.entry.item.id])
        #expect(store.preview.state == .ready(presentationID), "Verified metadata handoff must preserve the renderer's accepted presentation")
        #expect(await provider.requests.count == 1, "A one-use handoff must not cause a redundant resident-only fetch")
        #expect(store.preview.admittedRequest?.hydrationPolicy == .residentOnly)
    }

    @Test(arguments: ["hide", "duplicate"])
    func acceptedPreviewHandoffDoesNotSurviveHiddenSurfaceOrRefusedRefresh(_ change: String) async throws {
        let fixture = try await AppReceiptFixture(availability: .unknown)
        let loader = ReceiptLoader(original: fixture.original, duplicate: change == "duplicate", holdRefresh: true)
        let store = ExplorerStore(initialURL: fixture.root, loader: loader, homeURL: fixture.root, contentProvider: fixture.provider)
        defer { store.cancelLoads(); Task { await loader.finishRefresh() } }
        try await waitFor { store.activeTab.hasLoaded }
        store.setSelection([fixture.entry.item.id], focusedID: fixture.entry.item.id)
        store.togglePreviewPane(); store.setPreviewSurfaceVisible(true)
        try await waitFor { if case .ready = store.preview.state { return true }; return false }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        defer { Task { _ = await presentation.lease.release() } }
        try await waitFor { await loader.reads == 2 }
        if change == "hide" {
            store.setPreviewSurfaceVisible(false)
            #expect(store.preview.state == .empty)
        }
        await loader.finishRefresh()
        try await waitFor { !store.activeTab.isRefreshing }
        #expect(store.preview.state == .empty, "An owned receipt must not preserve a hidden or unverified presentation")
        if change == "duplicate" { #expect(store.currentSelection.selectedIDs.isEmpty) }
    }

    @Test(arguments: [false, true])
    func previewRenderFailureTransfersReceiptBeforeLeaseReleaseAndTeardownInvalidatesIt(_ deinitialize: Bool) async throws {
        let fixture = try await AppReceiptFixture(invalidText: true)
        let loader = ReceiptLoader(original: fixture.original, holdRefresh: true)
        var store: ExplorerStore? = ExplorerStore(initialURL: fixture.root, loader: loader,
            homeURL: fixture.root, contentProvider: fixture.provider)
        weak var weakStore = store
        try await waitFor { store?.activeTab.hasLoaded == true }
        let initialFDs = fixture.openDescriptors()
        store?.setSelection([fixture.entry.item.id], focusedID: fixture.entry.item.id)
        store?.togglePreviewPane(); store?.setPreviewSurfaceVisible(true)
        try await waitFor { await loader.reads == 2 && store?.preview.state == .unsupported }
        #expect(fixture.openDescriptors() > initialFDs, "Store receipt must retain the real anchor after the failed renderer releases its lease")
        if deinitialize { store = nil }
        else { store?.cancelLoads() }
        try await waitFor { fixture.openDescriptors() == initialFDs }
        if deinitialize { #expect(weakStore == nil) }
        await loader.finishRefresh()
        store?.cancelLoads(); store = nil
    }
}
