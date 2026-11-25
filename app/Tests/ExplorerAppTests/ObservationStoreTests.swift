import Foundation
import Darwin
import Testing
@testable import ExplorerApp
@testable import ExplorerCore

/// Requesting the next element proves the store finished handling the previous one.
/// This test-only wrapper avoids treating producer enqueue time as delivery time.
private actor AcknowledgedDirectoryIterator {
    private var iterator: AsyncThrowingStream<DirectoryChange, Error>.Iterator
    private var yieldedAnEvent = false
    private let acknowledge: @Sendable () -> Void

    init(_ stream: AsyncThrowingStream<DirectoryChange, Error>, acknowledge: @escaping @Sendable () -> Void) {
        iterator = stream.makeAsyncIterator()
        self.acknowledge = acknowledge
    }

    func next() async throws -> DirectoryChange? {
        if yieldedAnEvent { acknowledge(); yieldedAnEvent = false }
        var current = iterator
        let event = try await current.next()
        iterator = current
        yieldedAnEvent = event != nil
        return event
    }
}

/// Synchronous registration is important: a watch must be ready before its first read.
/// This test double records stream lifetime without starting native filesystem watches.
private final class RecordingDirectoryObserver: DirectoryObserving, @unchecked Sendable {
    private struct Watch {
        let url: URL
        let continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation
        var terminated = false
        var processedEvents = 0
    }
    private let lock = NSLock()
    private var watches: [Watch] = []
    private var remainingStartFailures = 0
    private let acknowledgeDelivery: Bool

    init(failingStarts: Int = 0, acknowledgeDelivery: Bool = false) {
        remainingStartFailures = failingStarts
        self.acknowledgeDelivery = acknowledgeDelivery
    }

    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }

    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        let mustFail = locked {
            guard remainingStartFailures > 0 else { return false }
            remainingStartFailures -= 1
            return true
        }
        if mustFail { throw CocoaError(.fileReadNoPermission) }
        let pair = AsyncThrowingStream<DirectoryChange, Error>.makeStream()
        let index = locked {
            let index = watches.count
            watches.append(Watch(url: url, continuation: pair.continuation))
            return index
        }
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.locked { self.watches[index].terminated = true }
        }
        if acknowledgeDelivery {
            let iterator = AcknowledgedDirectoryIterator(pair.stream) { [weak self] in
                guard let self else { return }
                self.locked { self.watches[index].processedEvents += 1 }
            }
            return AsyncThrowingStream(unfolding: { try await iterator.next() })
        }
        return pair.stream
    }

    var count: Int { locked { watches.count } }
    var activeCount: Int { locked { watches.filter { !$0.terminated }.count } }
    func isWatching(_ url: URL) -> Bool {
        locked { watches.contains { !$0.terminated && $0.url == url } }
    }
    func ended(_ index: Int) -> Bool {
        locked { watches.indices.contains(index) && watches[index].terminated }
    }
    func url(_ index: Int) -> URL? {
        locked { watches.indices.contains(index) ? watches[index].url : nil }
    }
    func processedEvents(_ index: Int) -> Int {
        locked { watches.indices.contains(index) ? watches[index].processedEvents : 0 }
    }
    func emit(_ index: Int, _ change: DirectoryChange = .changed) {
        let continuation = locked { watches.indices.contains(index) ? watches[index].continuation : nil }
        continuation?.yield(change)
    }
    func fail(_ index: Int) {
        let continuation = locked { watches.indices.contains(index) ? watches[index].continuation : nil }
        continuation?.finish(throwing: CocoaError(.fileReadUnknown))
    }
}

private final class NativeObservationStopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Reads deliberately ignore cancellation, so store generations remain independently tested.
private actor ObservationSnapshotLoader: DirectoryListing {
    struct Request: Sendable {
        let url: URL
        let showHidden: Bool
        let watchWasReady: Bool
    }
    private let observer: RecordingDirectoryObserver
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]

    init(observer: RecordingDirectoryObserver) { self.observer = observer }

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(Request(url: url, showHidden: showHidden, watchWasReady: observer.isWatching(url)))
            pending[index] = continuation
        }
    }
    func complete(_ index: Int, _ snapshot: DirectorySnapshot) {
        pending.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func fail(_ index: Int, code: CocoaError.Code = .fileReadNoSuchFile) {
        pending.removeValue(forKey: index)?.resume(throwing: CocoaError(code))
    }
    func cancelPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

/// A committed result without filesystem access, used to hold only the surrounding reads.
private actor ObservationRenameRecorder: FileOperating {
    private(set) var calls: [FileItem] = []
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("This test exercises rename only.")
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        calls.append(item)
        return FileOperationResult(url: context.directoryURL.appendingPathComponent(name), identity: item.identity, warning: nil)
    }
}

/// Native observation/identity policy from reference macOS adaptations and architecture
/// guidance. FR-SEL-007 / EV-0213 / AT-SEL-007, FR-NAV-007 / EV-0298 / AT-NAV-007,
/// FR-TAB-005 / EV-0290 / AT-TAB-005 provide the surrounding state contracts.
/// They do not establish a Windows filesystem-notification timing oracle.
@MainActor
final class ObservationStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-observation-fixture", isDirectory: true)

    private func identity(_ inode: UInt64) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private func item(_ name: String, inode: UInt64 = 101, under url: URL? = nil) -> FileItem {
        FileItem(url: (url ?? root).appendingPathComponent(name), name: name,
                 isDirectory: false, isSymbolicLink: false, size: 22, modifiedAt: nil,
                 kind: "Text Document", identity: identity(inode))
    }
    private func snapshot(_ items: [FileItem] = [], directory: UInt64 = 100) -> DirectorySnapshot {
        DirectorySnapshot(items: items, directoryIdentity: identity(directory))
    }
    // Bounded waits allow for main-actor contention when the full suite runs in
    // parallel on a busy machine (observed at load 6-13); they only cap failure latency.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try #require(condition(), "Observation state did not settle before the bounded deadline")
    }
    private func waitForReads(_ count: Int, _ loader: ObservationSnapshotLoader) async throws {
        let deadline = Date().addingTimeInterval(10)
        while await loader.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let actual = await loader.requests.count
        try #require(actual >= count, "Expected enumeration was not dispatched")
    }
    private func settleDebounce() async throws {
        // A bounded negative observation window exceeds the explicit 150 ms coalescing policy.
        try await Task.sleep(nanoseconds: 240_000_000)
    }
    private func stop(_ store: ExplorerStore, _ loader: ObservationSnapshotLoader) {
        store.cancelLoads()
        Task { await loader.cancelPending() }
    }

    @Test func launchAndNewTabsShowFreshHomeWithoutDirectoryReadsOrWatches() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let start = ExplorerAppDelegate.initialLocation(arguments: ["Maxplorer"])
        let store = ExplorerStore(initialURL: start, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let dashboard = BrowserPage.home.url
        #expect(store.tabs.count == 1 && store.activePage == .home && store.activeTab.hasLoaded)
        #expect(store.activeTab.homeSection == .recent && store.activeTab.history == NavigationHistory(initialURL: dashboard))
        #expect(observer.count == 0)
        #expect(await loader.requests.isEmpty)

        // Opening the physical home explicitly still enumerates it and watches for changes.
        let file = item("source.txt")
        store.openTab(at: root)
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([file]))
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        #expect(store.physicalFolderURL == root && observer.isWatching(root))
        store.setSelection([file.id], focusedID: file.id)
        let folder = store.activeTab

        store.addTab()
        try await waitUntil { observer.activeCount == 0 }
        #expect(store.activeTab.id != folder.id && store.activePage == .home && store.physicalFolderURL == nil)
        #expect(store.activeTab.homeSection == .recent && store.activeTab.history == NavigationHistory(initialURL: dashboard))
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        store.selectHomeSection(.tags)
        store.tagShortcuts.setVisible("Test tag", visible: true)
        store.selectHomeTag("Test tag")
        store.submitSearch("Source")
        let filtered = store.activeTab
        store.addTab()
        #expect(store.activeTab.id != filtered.id && store.activePage == .home && store.activeTab.hasLoaded)
        #expect(store.activeTab.homeSection == .recent && store.activeTab.homeTag == nil && store.activeTab.pageFilter.isEmpty)
        #expect(store.activeTab.history == NavigationHistory(initialURL: dashboard))
        #expect(store.tabs.first { $0.id == filtered.id }?.homeTag == "Test tag")
        #expect(observer.count == 1)
        #expect(await loader.requests.map(\.url) == [root])

        store.activateTab(folder.id)
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([file]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == root && store.activeTab.selection == folder.selection)
        #expect(store.activeTab.history == folder.history)
    }

    @Test
    func committedCloudListingCarriesNanosecondVersionWithoutChangingSelection() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/OneDrive-StatusTest-\(UUID())")
        func cloudRow(_ nanos: Int64) -> FileItem {
            FileItem(url: folder.appendingPathComponent("synthetic.txt"), name: "synthetic.txt",
                isDirectory: false, isSymbolicLink: false, size: 19,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_002), kind: "Text",
                identity: identity(101), availability: .availableLocally, isRegularFile: true,
                statusVersion: .init(size: 19, modificationSeconds: 1_700_000_002, modificationNanoseconds: nanos))
        }
        let first = cloudRow(700), changed = cloudRow(701)
        let parent = FileOperationContext(directoryURL: folder, directoryIdentity: identity(100))
        let store = ExplorerStore(initialURL: folder, loader: loader, homeURL: folder, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([first]))
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        let firstEntry = TransferEntry(source: parent, item: first)
        #expect(OneDriveBadgeCache.shared.snapshot(for: firstEntry)?.availability == .availableLocally,
                "The committed listing provides display facts before a native viewport or provider exists")
        store.tabs[0].selection.selectedIDs = [first.id]
        store.tabs[0].selection.focusedID = first.id
        store.tabs[0].selection.anchorID = first.id
        store.refreshAfterActivation()
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([changed]))
        try await waitUntil { !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [changed])
        #expect(store.activeTab.selection.selectedIDs == [first.id])
        #expect(store.activeTab.selection.focusedID == first.id)
        #expect(OneDriveBadgeCache.shared.snapshot(for: firstEntry) == nil)
        #expect(OneDriveBadgeCache.shared.snapshot(for: TransferEntry(source: parent, item: changed))?.availability == .availableLocally)
    }

    @Test
    func sidebarUsesTheAcceptedUnchangedPhysicalSnapshotAndRejectsOldPolicyAndArchiveResults() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let model = store.sidebarModel
        let home = try #require(model.roots.first { $0.key == "home" })
        let row = item("same.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([row]))
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        #expect(home.isExpandable)
        store.refreshAfterActivation()
        try await waitForReads(2, loader)
        await loader.complete(1, DirectorySnapshot(items: [row], directoryIdentity: identity(100),
                                                  isStructureComplete: true))
        try await waitUntil { !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [row])
        #expect(!home.isExpandable, "Accepted completeness is observed even when item rows did not change")

        store.refreshAfterActivation()
        try await waitForReads(3, loader)
        store.toggleHidden()
        #expect(model.showHidden && home.isExpandable)
        try await waitForReads(4, loader)
        await loader.complete(2, DirectorySnapshot(items: [row], directoryIdentity: identity(100),
                                                  isStructureComplete: true))
        let archive = ArchiveRevision(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5,
                                      changedSeconds: 6, changedNanoseconds: 7)
        await loader.complete(3, DirectorySnapshot(items: [row], archiveRevision: archive,
                                                  isStructureComplete: true))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.archiveRevision == archive)
        #expect(home.isExpandable)
        let requests = await loader.requests
        #expect(!requests[2].showHidden && requests[3].showHidden)
    }

    @Test
    func observationIsReadyBeforeTheInitialSnapshotRead() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        let requests = await loader.requests
        #expect(requests[0].watchWasReady)
        #expect(observer.count == 1)
        #expect(observer.url(0) == root)
        await loader.complete(0, snapshot([item("initial.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.directoryIdentity == identity(100))
        #expect(!store.activeTab.isUnavailable)
    }

    @Test
    func aFullyDeliveredEventBurstCoalescesIntoOneFollowupRefresh() async throws {
        let observer = RecordingDirectoryObserver(acknowledgeDelivery: true)
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        // Keep the read open until the whole burst has actually reached the store.
        // An idle-window burst can legitimately span multiple debounce periods when
        // AppKit work delays main-actor consumption of buffered events.
        for _ in 0..<30 { observer.emit(0) }
        try await waitUntil { observer.processedEvents(0) == 30 }
        #expect(await loader.requests.count == 1)
        #expect(store.activeTab.isLoading)
        await loader.complete(0, snapshot())
        try await waitForReads(2, loader)
        #expect(await loader.requests.count == 2)
        await loader.complete(1, snapshot([item("added.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        try await settleDebounce()
        #expect(await loader.requests.count == 2)
        #expect(store.activeTab.items.map(\.name) == ["added.txt"])
    }

    @Test
    func eventDuringEnumerationQueuesOneFollowupWithoutCancellingTheRead() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        for _ in 0..<5 { observer.emit(0) }
        try await settleDebounce()
        #expect(await loader.requests.count == 1)
        #expect(store.activeTab.isLoading)
        await loader.complete(0, snapshot([item("before.txt")]))
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([item("after.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        try await settleDebounce()
        #expect(await loader.requests.count == 2)
        #expect(store.activeTab.items.map(\.name) == ["after.txt"])
    }

    @Test
    func eventsWhileNavigatingCannotRedirectToThePreviousLocation() async throws {
        let observer = RecordingDirectoryObserver(acknowledgeDelivery: true)
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([item("old.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        observer.emit(0) // Queue an old-location event immediately before navigation.
        store.navigate(to: child)
        try await waitForReads(2, loader)
        try #require(observer.count == 2)
        for index in 0..<observer.count { observer.emit(index) }
        // Keep navigation open until the destination event actually reaches the
        // store, then retain the bounded negative check for an improper reload.
        try await waitUntil { observer.processedEvents(1) == 1 }
        try await settleDebounce()
        #expect(await loader.requests.count == 2, "An event must not replace in-flight navigation with a refresh")
        await loader.complete(1, snapshot([item("child.txt", under: child)], directory: 200))
        try await waitUntil { store.activeTab.url == child }
        // The acknowledged destination event requires one follow-up. Await its
        // registration instead of assuming a sleep also completed actor dispatch.
        try await waitForReads(3, loader)
        let requests = await loader.requests
        #expect(requests.dropFirst().allSatisfy { $0.url == child })
        #expect(requests.count == 3)
        await loader.complete(2, snapshot([item("child.txt", under: child)], directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == child)
        #expect(store.activeTab.history.backStack == [root])
    }

    /// M1: activation must reattach the requested location, not replace it with
    /// the last committed snapshot. All cases exercise the production observer path.
    @Test(arguments: ["activate", "close-active", "close-others"])
    func returningToAPendingTabPreservesItsRequestedDestination(_ transition: String) async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([item("root.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let firstID = store.activeTabID, child = root.appendingPathComponent("Child", isDirectory: true)
        store.navigate(to: child)
        try await waitForReads(2, loader)
        let secondURL = root.appendingPathComponent("Second", isDirectory: true)
        store.openTab(at: secondURL)
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let secondID = store.activeTabID
        switch transition {
        case "activate": store.activateTab(firstID)
        case "close-active": store.closeTab(secondID)
        default: store.closeOtherTabs(firstID)
        }
        try await waitForReads(4, loader)
        let requests = await loader.requests
        #expect(requests[3].url == child && requests[3].watchWasReady)
        #expect(store.activeTabID == firstID && store.activeTab.url == root)
        let current = item("current-child.txt", under: child)
        await loader.complete(3, snapshot([current], directory: 300))
        try await waitUntil { store.activeTab.url == child && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        await loader.complete(1, snapshot([item("obsolete-child.txt", under: child)], directory: 300))
        try await settleDebounce()
        #expect(store.activeTab.items == [current])
        #expect(store.activeTab.history.backStack == [root])
        #expect(await loader.requests.count == 4)
    }

    @Test
    func changingHiddenVisibilityRestartsEachPendingDestinationWithTheNewSetting() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let firstID = store.activeTabID, firstChild = root.appendingPathComponent("Child", isDirectory: true)
        store.navigate(to: firstChild)
        try await waitForReads(2, loader)
        let secondURL = root.appendingPathComponent("Second", isDirectory: true)
        store.openTab(at: secondURL)
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let secondID = store.activeTabID, secondChild = secondURL.appendingPathComponent("Child", isDirectory: true)
        store.navigate(to: secondChild)
        try await waitForReads(4, loader)
        store.toggleHidden()
        try await waitForReads(6, loader)
        let requests = await loader.requests
        #expect(Set(requests.suffix(2).map(\.url)) == [firstChild, secondChild])
        #expect(requests.suffix(2).allSatisfy { $0.showHidden })
        for index in 4..<6 {
            let url = requests[index].url
            await loader.complete(index, snapshot([item(".visible-now", under: url)], directory: url == firstChild ? 300 : 400))
        }
        try await waitUntil { store.tabs.allSatisfy { !$0.isLoading && !$0.isRefreshing } }
        #expect(store.tabs.first { $0.id == firstID }?.url == firstChild)
        #expect(store.tabs.first { $0.id == secondID }?.url == secondChild)
        await loader.complete(1, snapshot([item("obsolete", under: firstChild)], directory: 300))
        await loader.complete(3, snapshot([item("obsolete", under: secondChild)], directory: 400))
        try await settleDebounce()
        #expect(store.tabs.allSatisfy { $0.items.map(\.name) == [".visible-now"] })
        #expect(store.showHidden)
        #expect(await loader.requests.count == 6)
    }

    @Test
    func applicationActivationLeavesAnAlreadyPendingNavigationIntact() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        store.navigate(to: child)
        try await waitForReads(2, loader)
        store.refreshAfterActivation()
        #expect(await loader.requests.count == 2)
        let entry = item("child.txt", under: child)
        await loader.complete(1, snapshot([entry], directory: 200))
        try await waitUntil { store.activeTab.url == child && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [entry] && store.activeTab.history.backStack == [root])
        #expect(await loader.requests.count == 2)
    }

    @Test(arguments: ["activation", "tab-return", "visibility"])
    func passiveRefreshKeepsAFailedDestinationsErrorAndRetryTarget(_ trigger: String) async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let firstID = store.activeTabID, denied = root.appendingPathComponent("Denied", isDirectory: true)
        store.setSelection([original.id], focusedID: original.id)
        store.navigate(to: denied)
        try await waitForReads(2, loader)
        await loader.fail(1, code: .fileReadNoPermission)
        // Complete the automatic committed-folder read that closes the failed watch gap.
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let message = try #require(store.activeTab.errorMessage)
        var passiveRead = 3
        switch trigger {
        case "activation": store.refreshAfterActivation()
        case "visibility": store.toggleHidden()
        default:
            store.openTab(at: root.appendingPathComponent("Second", isDirectory: true))
            try await waitForReads(4, loader)
            await loader.complete(3, snapshot(directory: 200))
            try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
            store.activateTab(firstID)
            passiveRead = 4
        }
        try await waitForReads(passiveRead + 1, loader)
        #expect(await loader.requests[passiveRead].url == root)
        #expect(store.activeTab.errorMessage == message)
        await loader.complete(passiveRead, snapshot([original, item("updated.txt", inode: 102)]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.errorMessage == message && store.activeTab.url == root)
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        store.retry()
        try await waitForReads(passiveRead + 2, loader)
        let retry = await loader.requests[passiveRead + 1]
        #expect(retry.url == denied)
        #expect(retry.showHidden == (trigger == "visibility"))
        await loader.complete(passiveRead + 1, snapshot(directory: 300))
        try await waitUntil { store.activeTab.url == denied && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.errorMessage == nil && store.activeTab.history.backStack == [root])
    }

    @Test
    func aFailedPassiveRefreshMarksRowsUnavailableWithoutReplacingTheOriginalRetryTarget() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        let denied = root.appendingPathComponent("Denied", isDirectory: true)
        store.navigate(to: denied)
        try await waitForReads(2, loader)
        await loader.fail(1, code: .fileReadNoPermission)
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let originalError = try #require(store.activeTab.errorMessage)
        #expect(originalError.contains(denied.path))
        store.refreshAfterActivation()
        try await waitForReads(4, loader)
        #expect(await loader.requests[3].url == root)
        await loader.fail(3, code: .fileReadNoSuchFile)
        try await waitUntil { store.activeTab.isUnavailable && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == root && store.activeTab.items == [original])
        #expect(store.activeTab.errorMessage == originalError)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.selection.focusedID == nil && store.activeTab.selection.anchorID == nil)
        #expect(!store.canCreateFolder && !store.canRenameSelection && !store.canCopySelection && !store.canTrashSelection)
        store.setSelection([original.id], focusedID: original.id)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        store.retry()
        try await waitForReads(5, loader)
        #expect(await loader.requests[4].url == denied)
        let recovered = item("recovered.txt", inode: 201, under: denied)
        await loader.complete(4, snapshot([recovered], directory: 200))
        try await waitUntil { store.activeTab.url == denied && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(!store.activeTab.isUnavailable && store.activeTab.errorMessage == nil)
        #expect(store.activeTab.items == [recovered] && store.activeTab.history.backStack == [root])
        #expect(store.activeTab.selection.selectedIDs.isEmpty && store.canCreateFolder)
        store.setSelection([recovered.id], focusedID: recovered.id)
        #expect(store.canRenameSelection && store.canCopySelection && store.canTrashSelection)
    }

    /// L1: background work leaves commands usable; starting an editor must establish
    /// a stable snapshot even when the cancelled loader later returns changed entries.
    @Test(arguments: ["rename", "new-folder"])
    func aDraftInvalidatesBackgroundRefreshAndDefersItsChangedSnapshot(_ command: String) async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        observer.emit(0)
        try await waitForReads(2, loader)
        #expect(store.activeTab.isRefreshing && !store.activeTab.isLoading)
        #expect(store.canCreateFolder && store.canRenameSelection && store.canCopySelection && store.canTrashSelection)
        #expect(store.activeTab.items == [original] && store.activeTab.selection.selectedIDs == [original.id])
        if command == "rename" { store.beginRename() } else { store.beginCreateFolder() }
        let edit = try #require(store.nameEdit)
        store.updateProposedName("still-editing.txt", sessionID: edit.id)
        let replacement = item("original.txt", inode: 999)
        await loader.complete(1, snapshot([replacement, item("external.txt", inode: 102)]))
        try await settleDebounce()
        #expect(store.nameEdit?.id == edit.id && store.nameEdit?.proposedName == "still-editing.txt")
        #expect(store.activeTab.items == [original] && store.activeTab.selection.selectedIDs == [original.id])
        #expect(await loader.requests.count == 2)
        store.cancelNameEdit()
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([replacement]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [replacement] && store.activeTab.selection.selectedIDs.isEmpty)
    }

    /// Amendment C: deferral revokes background work, not the unchanged committed
    /// snapshot. A new request still renews the authorization epoch.
    @Test
    func deferredPassiveReadPreservesCapturedAuthorityButCannotCommit() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        let beforeRefresh = ContextMenuSnapshot(store: store, item: original)

        observer.emit(0)
        try await waitForReads(2, loader)
        try #require(store.activeTab.isRefreshing && !store.activeTab.isLoading)
        #expect(!beforeRefresh.matches(store), "Starting another request still invalidates older command captures")
        let captured = ContextMenuSnapshot(store: store, item: original)
        let epoch = try #require(captured.generation)
        store.beginRename()
        let edit = try #require(store.nameEdit)
        #expect(store.contextMenuLoadGeneration == epoch, "Deferral must retain the committed snapshot's authorization")
        #expect(!captured.matches(store), "An active editor independently blocks the earlier command capture")

        let replacement = item("original.txt", inode: 999)
        await loader.complete(1, snapshot([replacement, item("external.txt", inode: 102)]))
        try await settleDebounce()
        #expect(store.nameEdit?.id == edit.id)
        #expect(store.activeTab.items == [original] && store.activeTab.selection.selectedIDs == [original.id])
        #expect(await loader.requests.count == 2, "Deferral must not let obsolete work commit or start another read during the draft")

        // Check synchronously before the scheduled follow-up read starts. No
        // filesystem action is dispatched by the retained capture or drop binding.
        store.cancelNameEdit()
        #expect(store.contextMenuLoadGeneration == epoch)
        #expect(captured.matches(store), "An unchanged predeferral capture is usable again once the editor closes")
        #expect(store.canRenameSelection && store.canCopySelection)
        let drop = store.fileDropBinding(destinationURL: root)
        #expect(drop?.loadGeneration == epoch, "Committed physical rows retain fresh drop authority after deferral")

        try await waitForReads(3, loader)
        #expect(!captured.matches(store), "The next actual request renews authorization independently of deferral")
        await loader.complete(2, snapshot([replacement]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.items == [replacement] && store.activeTab.selection.selectedIDs.isEmpty)
    }

    @Test
    func anObsoleteBackgroundSnapshotCannotOverwriteACommittedRename() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let operations = ObservationRenameRecorder()
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
                                  observer: observer, operations: operations)
        defer { stop(store, loader) }
        let original = item("original.txt"), renamed = item("renamed.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        observer.emit(0)
        try await waitForReads(2, loader)
        #expect(store.canRenameSelection)
        store.beginRename()
        let edit = try #require(store.nameEdit)
        store.updateProposedName(renamed.name, sessionID: edit.id)
        store.commitNameEdit(sessionID: edit.id)
        try await waitForReads(3, loader)
        #expect(store.isPerformingOperation)
        #expect(await operations.calls == [original])
        await loader.complete(2, snapshot([renamed]))
        try await waitUntil { !store.isPerformingOperation && store.activeTab.selection.selectedIDs == [renamed.id] }
        await loader.complete(1, snapshot([item("obsolete.txt", inode: 999)]))
        try await settleDebounce()
        #expect(store.activeTab.items == [renamed] && store.activeTab.selection.selectedIDs == [renamed.id])
        // If completing the operation drains another queued hint, satisfy that new
        // read too. It must not cause another write or revive the obsolete snapshot.
        // A debounced hint can queue one more read after any single check (seen under
        // parallel load), so keep answering new reads until the tab settles.
        var answered = 3
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let count = await loader.requests.count
            while answered < count { await loader.complete(answered, snapshot([renamed])); answered += 1 }
            if !store.activeTab.isLoading, !store.activeTab.isRefreshing, await loader.requests.count == answered { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(await operations.calls.count == 1)
        #expect(store.activeTab.items == [renamed])
    }

    @Test
    func switchingAndClosingTabsRebindsOneWatchAndIgnoresQueuedOldEvents() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let firstID = store.activeTabID
        let secondURL = root.appendingPathComponent("Second", isDirectory: true)
        store.openTab(at: secondURL)
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing && observer.ended(0) }
        let secondID = store.activeTabID
        observer.emit(1)
        store.activateTab(firstID)
        try await waitForReads(3, loader)
        try await waitUntil { observer.ended(1) }
        await loader.complete(2, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        try await settleDebounce()
        #expect(await loader.requests.count == 3)
        #expect(observer.activeCount == 1)
        #expect(observer.isWatching(root))

        store.closeTab(firstID)
        try await waitForReads(4, loader)
        await loader.complete(3, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing && observer.ended(2) }
        #expect(store.activeTabID == secondID)
        #expect(observer.activeCount == 1)
        #expect(observer.isWatching(secondURL))
        store.cancelLoads()
        try await waitUntil { observer.activeCount == 0 }
    }

    @Test
    func observationSetupFailureWarnsWithoutPreventingBrowsing() async throws {
        let observer = RecordingDirectoryObserver(failingStarts: 1)
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        let requests = await loader.requests
        #expect(!requests[0].watchWasReady)
        await loader.complete(0, snapshot([item("readable.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.observationWarning != nil)
        #expect(store.activeTab.errorMessage == nil)
        #expect(store.activeTab.items.map(\.name) == ["readable.txt"])
        #expect(!store.activeTab.isUnavailable)
    }

    @Test
    func observationStreamFailureWarnsWhileManualRefreshStillWorks() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([item("readable.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        observer.fail(0)
        try await waitUntil { store.observationWarning != nil }
        #expect(!store.activeTab.isUnavailable)
        #expect(store.activeTab.errorMessage == nil)
        store.refresh()
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([item("refreshed.txt")]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.items.map(\.name) == ["refreshed.txt"])
    }

    /// FR-NAV-007 / EV-0298 / AT-NAV-007: unavailable-current-folder handling is native policy.
    @Test
    func currentDirectoryFailureRetainsLastRowsButClearsSelectionUntilRetryRecovers() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        store.refresh()
        try await waitForReads(2, loader)
        await loader.fail(1, code: .fileReadNoPermission)
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.isUnavailable)
        #expect(store.activeTab.items == [original])
        #expect(store.activeTab.url == root)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.selection.focusedID == nil)
        #expect(store.activeTab.selection.anchorID == nil)
        store.dismissError()
        #expect(store.activeTab.isUnavailable)
        #expect(store.activeTab.items == [original])
        store.retry()
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(!store.activeTab.isUnavailable)
        #expect(store.activeTab.errorMessage == nil)
        #expect(store.activeTab.selection.selectedIDs.isEmpty, "Recovery must not silently resurrect a stale selection")
    }

    @Test
    func automaticRefreshPreservesFailedNavigationErrorAndRetryDestination() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("original.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        store.navigate(to: missing)
        try await waitForReads(2, loader)
        await loader.fail(1)
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing && observer.isWatching(self.root) }
        #expect(!store.activeTab.isUnavailable)
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        // Find the active root stream: failed navigation may have attempted a destination watch.
        for index in 0..<observer.count where observer.url(index) == root && !observer.ended(index) {
            observer.emit(index)
        }
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([original, item("added.txt", inode: 102)]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.errorMessage?.contains("missing") == true)
        #expect(store.activeTab.selection.selectedIDs == [original.id])
        store.retry()
        try await waitForReads(4, loader)
        let requests = await loader.requests
        #expect(requests[2].url == root)
        #expect(requests[3].url == missing)
        await loader.complete(3, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == missing)
    }

    /// FR-SEL-007 / EV-0213 / AT-SEL-007: native external rename/replacement reconciliation.
    @Test
    func snapshotIdentityRemapsRenameButRejectsSamePathReplacement() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let original = item("before.txt")
        let renamed = item("after.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([original]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([original.id], focusedID: original.id)
        observer.emit(0)
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([renamed]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.selection.selectedIDs == [renamed.id])
        #expect(store.activeTab.selection.focusedID == renamed.id)
        #expect(store.activeTab.selection.anchorID == renamed.id)
        observer.emit(0)
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot([item("after.txt", inode: 102)]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.selection.focusedID == nil)
    }

    @Test
    func replacedDirectoryIdentityClearsSelectionEvenIfARowPathStillExists() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        let entry = item("same-name.txt")
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot([entry]))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.setSelection([entry.id], focusedID: entry.id)
        observer.emit(0, .rootChanged)
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot([entry], directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.directoryIdentity == identity(200))
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.url == root)
    }

    @Test
    func detachingAndWindowShutdownReleaseTheirObservationStreams() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, observer: observer)
        defer { stop(store, loader) }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        store.openTab(at: source)
        try await waitForReads(2, loader)
        await loader.complete(1, snapshot(directory: 200))
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let movingID = store.activeTabID
        var movedID: UUID?
        store.onDetachTab = { tab, _ in movedID = tab.id }
        store.detachTab(movingID)
        try await waitForReads(3, loader)
        await loader.complete(2, snapshot())
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing && observer.ended(1) }
        #expect(movedID == movingID)
        #expect(observer.activeCount == 1)
        #expect(observer.isWatching(root))
        store.cancelLoads()
        try await waitUntil { observer.activeCount == 0 }
        observer.emit(2)
        try await settleDebounce()
        #expect(await loader.requests.count == 3)
    }

    @Test
    func releasingTheStoreTerminatesObservationWithoutAnExplicitWindowClose() async throws {
        let observer = RecordingDirectoryObserver()
        let loader = ObservationSnapshotLoader(observer: observer)
        var store: ExplorerStore? = ExplorerStore(initialURL: root, loader: loader,
                                                  homeURL: root, observer: observer)
        defer {
            store?.cancelLoads()
            Task { await loader.cancelPending() }
        }
        try await waitForReads(1, loader)
        await loader.complete(0, snapshot())
        try await waitUntil { store?.activeTab.isLoading == false }
        #expect(observer.activeCount == 1)
        weak var weakStore = store
        store = nil
        try await waitUntil { weakStore == nil && observer.activeCount == 0 }
        #expect(observer.ended(0))
        #expect(await loader.requests.count == 1)
    }

    /// Native ancestor-link retarget integration. The core test exercises
    /// detection and manual rebind; the store must retire and reattach its own watch.
    @Test
    func nativeObservationRebindsAfterAtomicAncestorSymlinkRetarget() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory
            .appendingPathComponent("ExplorerObservedRetarget-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }

        let start = fixture.appendingPathComponent("Start", isDirectory: true)
        let firstTarget = fixture.appendingPathComponent("A", isDirectory: true)
        let secondTarget = fixture.appendingPathComponent("B", isDirectory: true)
        let firstFolder = firstTarget.appendingPathComponent("Visible", isDirectory: true)
        let secondFolder = secondTarget.appendingPathComponent("Visible", isDirectory: true)
        for folder in [start, firstFolder, secondFolder] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let sharedName = "same-name.txt"
        let firstMarker = firstFolder.appendingPathComponent("only-a.txt")
        let secondMarker = secondFolder.appendingPathComponent("only-b.txt")
        for file in [firstFolder.appendingPathComponent(sharedName), firstMarker,
                     secondFolder.appendingPathComponent(sharedName), secondMarker] {
            try Data("synthetic watch fixture".utf8).write(to: file)
        }
        let firstIdentity = try #require(try LocalFileIdentity.read(at: firstFolder, ifLocal: true))
        let secondIdentity = try #require(try LocalFileIdentity.read(at: secondFolder, ifLocal: true))
        try #require(firstIdentity != secondIdentity)

        let route = fixture.appendingPathComponent("Route")
        let stagedRoute = fixture.appendingPathComponent("Route-next")
        try manager.createSymbolicLink(at: route, withDestinationURL: firstTarget)
        try manager.createSymbolicLink(at: stagedRoute, withDestinationURL: secondTarget)
        let lexical = route.appendingPathComponent("Visible", isDirectory: true)
        let stops = NativeObservationStopCount()
        let observer = LocalDirectoryObserver(onStop: { stops.increment() })
        let store = ExplorerStore(initialURL: start, loader: LocalDirectoryLoader(), homeURL: start, observer: observer)
        defer { store.cancelLoads() }
        func isSettled(at url: URL) -> Bool {
            let tab = store.activeTab
            return tab.url == url && tab.hasLoaded && !tab.isLoading && !tab.isRefreshing && !tab.isUnavailable
        }
        try await waitUntil { isSettled(at: start) }
        let stopsBeforeNavigation = stops.value
        let tabID = store.activeTabID
        store.navigate(to: lexical)
        try await waitUntil { isSettled(at: lexical) && stops.value > stopsBeforeNavigation }
        try #require(store.activeTab.directoryIdentity == firstIdentity)
        #expect(store.activeTab.items.contains { $0.name == firstMarker.lastPathComponent })
        let history = store.activeTab.history
        #expect(history.backStack == [start])
        let original = try #require(store.activeTab.items.first { $0.name == sharedName })
        let originalIdentity = try #require(original.identity)
        store.setSelection([original.id], focusedID: original.id, anchorID: original.id)
        try #require(store.activeTab.selection.selectedIDs == [original.id])
        let settledStopCount = stops.value

        // Replace the entry atomically, keeping the original directory alive.
        let retargeted = stagedRoute.withUnsafeFileSystemRepresentation { source in
            route.withUnsafeFileSystemRepresentation { destination in Darwin.rename(source!, destination!) }
        }
        try #require(retargeted == 0, "Could not atomically retarget the owned route")
        try #require(manager.fileExists(atPath: firstMarker.path))
        try await waitUntil {
            isSettled(at: lexical) && store.activeTab.directoryIdentity == secondIdentity
                && stops.value > settledStopCount
                && store.activeTab.items.contains { $0.name == secondMarker.lastPathComponent }
        }
        let replacement = try #require(store.activeTab.items.first { $0.name == sharedName })
        let replacementIdentity = try #require(replacement.identity)
        #expect(replacement.id == original.id)
        #expect(replacementIdentity != originalIdentity)
        #expect(!store.activeTab.items.contains { $0.name == firstMarker.lastPathComponent })
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(store.activeTab.selection.focusedID == nil && store.activeTab.selection.anchorID == nil)

        // prepareObservation attaches the replacement watch before the B read.
        // No manual Refresh, activation or visibility revalidation can supply this update.
        let afterRebind = secondFolder.appendingPathComponent("after-rebind.txt")
        try Data("new target watch".utf8).write(to: afterRebind)
        try await waitUntil {
            isSettled(at: lexical) && store.activeTab.items.contains { $0.name == afterRebind.lastPathComponent }
        }
        #expect(store.activeTab.items.first { $0.name == afterRebind.lastPathComponent }?.url
                == lexical.appendingPathComponent(afterRebind.lastPathComponent))
        #expect(store.activeTab.directoryIdentity == secondIdentity)
        #expect(store.activeTabID == tabID && store.tabs.count == 1)
        #expect(store.activeTab.history == history)
        #expect(store.observationWarning == nil)
    }

    /// GAP-036 / MAC-0385–0393: use the production observer and loader without
    /// manual Refresh, activation, navigation or popup state masking a missed rmdir.
    @Test
    func nativeObservationReconcilesEmptyChildMkdirThenRmdir() async throws {
        let manager = FileManager.default
        let path = manager.temporaryDirectory.standardizedFileURL.path
        let lexicalPath = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        let fixture = URL(fileURLWithPath: lexicalPath, isDirectory: true)
            .appendingPathComponent("ExplorerObservedEmpty-\(UUID().uuidString)", isDirectory: true)
        let empty = fixture.appendingPathComponent("Empty", isDirectory: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let child = empty.appendingPathComponent("Chevron Validation Child", isDirectory: true)
        let store = ExplorerStore(initialURL: empty, loader: LocalDirectoryLoader(),
                                  homeURL: empty, observer: LocalDirectoryObserver())
        defer { store.cancelLoads() }
        try await waitUntil(timeout: 6) {
            store.activeTab.hasLoaded && !store.activeTab.isLoading && !store.activeTab.isRefreshing
        }
        #expect(store.activeTab.items.isEmpty)

        for _ in 0..<2 {
            try #require(child.withUnsafeFileSystemRepresentation { Darwin.mkdir($0!, 0o700) } == 0)
            try await waitUntil(timeout: 6) {
                !store.activeTab.isLoading && !store.activeTab.isRefreshing
                    && store.activeTab.items.map(\.name) == [child.lastPathComponent]
            }
            #expect(store.activeTab.items.first?.isDirectory == true)
            #expect(store.activeTab.url == empty)

            try #require(child.withUnsafeFileSystemRepresentation { Darwin.rmdir($0!) } == 0)
            #expect(try manager.contentsOfDirectory(atPath: empty.path).isEmpty)
            try await waitUntil(timeout: 6) {
                !store.activeTab.isLoading && !store.activeTab.isRefreshing && store.activeTab.items.isEmpty
            }
            #expect(!store.activeTab.isUnavailable)
            #expect(store.observationWarning == nil)
            #expect(store.activeTab.url == empty)
        }
    }

    /// Genuine native store integration. Mutations are test-side actions in an owned fixture;
    /// there is no app-activation/manual refresh to mask a missing observation subscription.
    @Test
    func nativeObservationReconcilesExternalRenameReplacementDeletionAndRecovery() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory
            .appendingPathComponent("ExplorerObservedStore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let originalURL = fixture.appendingPathComponent("before.txt")
        let renamedURL = fixture.appendingPathComponent("after.txt")
        let payload = Data("twenty-two-byte sample".utf8)
        try payload.write(to: originalURL)
        let store = ExplorerStore(initialURL: fixture, loader: LocalDirectoryLoader(),
                                  homeURL: fixture, observer: LocalDirectoryObserver())
        defer { store.cancelLoads() }
        try await waitUntil(timeout: 5) { store.activeTab.hasLoaded && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        let original = try #require(store.activeTab.items.first { $0.name == "before.txt" })
        let originalIdentity = try #require(original.identity, "Supported local fixture must expose identity")
        store.setSelection([original.id], focusedID: original.id)

        try manager.moveItem(at: originalURL, to: renamedURL)
        #expect(!manager.fileExists(atPath: originalURL.path))
        #expect(try Data(contentsOf: renamedURL) == payload)
        try await waitUntil(timeout: 5) {
            !store.activeTab.isLoading && !store.activeTab.isRefreshing && store.activeTab.items.contains { $0.url == renamedURL }
                && store.activeTab.selection.selectedIDs == [renamedURL.absoluteString]
        }
        #expect(store.activeTab.items.first { $0.url == renamedURL }?.identity == originalIdentity)
        #expect(store.activeTab.selection.focusedID == renamedURL.absoluteString)

        // POSIX rename replaces the directory entry atomically, with a distinct live inode.
        let stagingURL = fixture.appendingPathComponent(".replacement")
        let replacementBytes = Data("replacement bytes".utf8)
        try replacementBytes.write(to: stagingURL)
        let result = stagingURL.withUnsafeFileSystemRepresentation { source in
            renamedURL.withUnsafeFileSystemRepresentation { destination in
                Darwin.rename(source!, destination!)
            }
        }
        try #require(result == 0, "Atomic replacement failed in the isolated fixture")
        #expect(try Data(contentsOf: renamedURL) == replacementBytes)
        try await waitUntil(timeout: 5) {
            !store.activeTab.isLoading && !store.activeTab.isRefreshing && store.activeTab.selection.selectedIDs.isEmpty
                && store.activeTab.items.first { $0.url == renamedURL }?.identity != nil
                && store.activeTab.items.first { $0.url == renamedURL }?.identity != originalIdentity
        }
        #expect(store.activeTab.selection.focusedID == nil)
        #expect(store.activeTab.items.first { $0.url == renamedURL }?.size == Int64(replacementBytes.count))

        try manager.removeItem(at: fixture)
        #expect(!manager.fileExists(atPath: fixture.path))
        try await waitUntil(timeout: 5) { store.activeTab.isUnavailable && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == fixture)
        #expect(store.activeTab.hasLoaded)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)

        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        let recoveredURL = fixture.appendingPathComponent("recovered.txt")
        try Data("recovered".utf8).write(to: recoveredURL)
        try await waitUntil(timeout: 5) {
            !store.activeTab.isUnavailable && !store.activeTab.isLoading && !store.activeTab.isRefreshing
                && store.activeTab.items.map(\.name) == ["recovered.txt"]
        }
        #expect(store.activeTab.errorMessage == nil)
        #expect(store.activeTab.selection.selectedIDs.isEmpty)
        #expect(try Data(contentsOf: recoveredURL) == Data("recovered".utf8))
    }
}
