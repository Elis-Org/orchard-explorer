import AppKit
import Combine
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Isolated named pasteboard, as in the other store suites.
@MainActor
private func makeSearchTestPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ExplorerSearchStoreTests-\(UUID().uuidString)"))
}

/// Synchronous protocol entry with independently controlled streams. The lock also
/// protects termination callbacks, which AsyncThrowingStream may invoke off actor.
private final class ControlledFilenameSearcher: FilenameSearching, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<FilenameSearchEvent, Error>.Continuation
    private let lock = NSLock()
    private var recorded: [FilenameSearchRequest] = []
    private var streams: [Continuation] = []
    private var ended: [Int: Continuation.Termination] = [:]

    var requests: [FilenameSearchRequest] { lock.withLock { recorded } }
    func continuation(_ index: Int) -> Continuation { lock.withLock { streams[index] } }
    func termination(_ index: Int) -> Continuation.Termination? { lock.withLock { ended[index] } }

    func search(_ request: FilenameSearchRequest) -> AsyncThrowingStream<FilenameSearchEvent, Error> {
        let pair = AsyncThrowingStream<FilenameSearchEvent, Error>.makeStream()
        let index = lock.withLock {
            let index = recorded.count
            recorded.append(request)
            streams.append(pair.continuation)
            return index
        }
        pair.continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            self.lock.withLock { self.ended[index] = reason }
        }
        return pair.stream
    }

    func progress(_ index: Int, _ results: [FilenameSearchResult], coverage: SearchCoverage = SearchCoverage()) {
        continuation(index).yield(.progress(results: results, coverage: coverage))
    }
    func finish(_ index: Int, coverage: SearchCoverage = SearchCoverage()) {
        continuation(index).yield(.finished(coverage))
        continuation(index).finish()
    }
    func fail(_ index: Int, _ error: any Error) { continuation(index).finish(throwing: error) }
    func shutdown() { lock.withLock { streams }.forEach { $0.finish() } }
}

/// Reads and recovery calls do no filesystem work. Explicit completions allow
/// assertions before and after navigation commits and each Trash receipt.
private actor SearchStoreDriver: DirectoryListing, FileRecovering, FileOperating {
    struct Read: Sendable { let url: URL; let showHidden: Bool }
    struct TrashCall: Sendable { let item: FileItem; let context: FileOperationContext }
    private(set) var reads: [Read] = []
    private(set) var trashCalls: [TrashCall] = []
    private(set) var writeCalls = 0
    private var pendingReads: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var pendingTrash: [Int: CheckedContinuation<TrashResult, Error>] = [:]
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[reads.count] = continuation
            reads.append(Read(url: url, showHidden: showHidden))
        }
    }
    func succeed(_ index: Int, items: [FileItem] = [], identity: LocalFileIdentity? = searchTestIdentity(100)) {
        pendingReads.removeValue(forKey: index)?.resume(returning:
            DirectorySnapshot(items: items, directoryIdentity: identity))
    }
    func fail(_ index: Int) {
        pendingReads.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoSuchFile))
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingTrash[trashCalls.count] = continuation
            trashCalls.append(TrashCall(item: item, context: context))
        }
    }
    func trashed(_ index: Int, receipt: TrashReceipt) {
        pendingTrash.removeValue(forKey: index)?.resume(returning: TrashResult(receipt: receipt, warning: nil))
    }
    private var restoreResult: FileOperationResult?
    func setRestoreResult(_ result: FileOperationResult) { restoreResult = result }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        guard let restoreResult else { throw FileOperationError.unsupported("Restore is outside this search test") }
        return restoreResult
    }
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writeCalls += 1
        throw FileOperationError.unsupported("Search must not create folders")
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writeCalls += 1
        throw FileOperationError.unsupported("Search must not rename")
    }
    func shutdown() {
        closed = true
        let reads = Array(pendingReads.values), trash = Array(pendingTrash.values)
        pendingReads.removeAll()
        pendingTrash.removeAll()
        reads.forEach { $0.resume(throwing: CancellationError()) }
        trash.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private func searchTestIdentity(_ inode: UInt64) -> LocalFileIdentity {
    LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
}

@MainActor
private final class SearchStoreHarness {
    // Synthetic URLs are unique and never read by the controlled drivers.
    let root: URL
    let driver = SearchStoreDriver()
    let searcher = ControlledFilenameSearcher()
    let board = makeSearchTestPasteboard()
    let store: ExplorerStore

    init(withForwardHistory: Bool = false,
         validator: (@Sendable (FilenameSearchResult) async throws -> Bool)? = nil) {
        let validate = validator ?? FilenameSearchValidation.isCurrent
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let clipboard = TransferClipboard(pasteboard: board)
        if withForwardHistory {
            var tab = BrowserTab(url: root)
            tab.history.navigate(to: root.appendingPathComponent("Forward", isDirectory: true))
            _ = tab.history.goBack()
            store = ExplorerStore(tab: tab, loader: driver, homeURL: root, operations: driver,
                                  clipboard: clipboard, recovery: driver, searcher: searcher,
                                  validateSearchResult: validate)
        } else {
            store = ExplorerStore(initialURL: root, loader: driver, homeURL: root, operations: driver,
                                  clipboard: clipboard, recovery: driver, searcher: searcher,
                                  validateSearchResult: validate)
        }
    }
    func stop() {
        store.cancelTrash()
        store.cancelLoads()
        searcher.shutdown()
        Task { await driver.shutdown() }
        board.releaseGlobally()
    }
    func result(_ name: String, inode: UInt64 = 1000, parent: URL? = nil,
                hasIdentity: Bool = true, hasParent: Bool = true, size: Int64 = 22) -> FilenameSearchResult {
        let directory = parent ?? root
        let item = FileItem(url: directory.appendingPathComponent(name), name: name, isDirectory: false,
                            isSymbolicLink: false, size: size, modifiedAt: nil, kind: "Text Document",
                            identity: hasIdentity ? searchTestIdentity(inode) : nil)
        return FilenameSearchResult(item: item, parent: hasParent
            ? FileOperationContext(directoryURL: directory, directoryIdentity: searchTestIdentity(inode + 100)) : nil)
    }
}

/// Real lstat validation uses only owned disposable files, never desktop actions.
private final class SearchStoreFiles {
    let root: URL
    let parent: URL
    let file: URL
    let sibling: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ExplorerTests-\(UUID().uuidString)", isDirectory: true)
        parent = root.appendingPathComponent("Nested", isDirectory: true)
        file = parent.appendingPathComponent("needle.txt")
        sibling = parent.appendingPathComponent("unselected.txt")
        folder = parent.appendingPathComponent("needle-folder", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("owned search fixture".utf8).write(to: file)
            try Data("other row".utf8).write(to: sibling)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

/// NATIVE-P14 store/model evidence only. Requirement mappings:
/// FR-SEARCH-001 / EV-0343/0344/0351/9001 / AT-SEARCH-001;
/// FR-SEARCH-002/003 / EV-0345–0351/9004 / AT-SEARCH-002/003;
/// FR-SEARCH-004 / EV-0349–0351 / AT-SEARCH-004; native contract MAC-062–065.
/// These subsets establish neither actual UI execution, visual comparison nor
/// Windows fidelity, and do not by themselves close the Phase 14 milestone.
@MainActor
final class SearchStoreTests {
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await predicate(), "Search store did not reach the expected state within five seconds")
    }
    private func ready(_ harness: SearchStoreHarness, items: [FileItem] = [],
                       identity: LocalFileIdentity? = searchTestIdentity(100)) async throws {
        try await waitUntil { await harness.driver.reads.count == 1 }
        await harness.driver.succeed(0, items: items, identity: identity)
        try await waitUntil { !harness.store.activeTab.isLoading }
        try #require(harness.store.activeTab.hasLoaded)
    }
    private func begin(_ harness: SearchStoreHarness, results: [FilenameSearchResult] = []) async throws {
        harness.store.submitSearch("needle")
        try #require(harness.searcher.requests.count == 1)
        harness.searcher.progress(0, results)
        try await waitUntil { harness.store.displayedItems.count == results.count }
    }
    private func expectFolder(_ store: ExplorerStore, items: [FileItem], selection: SelectionState,
                              history: NavigationHistory) {
        #expect(store.activeTab.items == items)
        #expect(store.activeTab.selection == selection)
        #expect(store.activeTab.history == history)
    }
    private func expectCancelled(_ searcher: ControlledFilenameSearcher, _ index: Int) async throws {
        try await waitUntil { searcher.termination(index) != nil }
        if case .cancelled? = searcher.termination(index) {} else {
            Issue.record("Search stream \(index) did not observe cancellation")
        }
    }
    private func expectLateEventsIgnored(_ harness: SearchStoreHarness, stream: Int) async throws {
        let before = try #require(harness.store.activeSearch)
        try await confirmation("Obsolete search events must publish no changes", expectedCount: 0) { changed in
            let observation = harness.store.objectWillChange.sink { changed() }
            harness.searcher.progress(stream, [harness.result("late.txt", inode: 9999)])
            harness.searcher.finish(stream)
            // A bounded observation window catches incorrectly accepted async events.
            try await Task.sleep(for: .milliseconds(40))
            withExtendedLifetime(observation) {}
        }
        let after = try #require(harness.store.activeSearch)
        #expect(after.id == before.id)
        #expect(after.generation == before.generation)
        #expect(after.query == before.query)
        #expect(after.phase == before.phase)
        #expect(after.results == before.results)
        #expect(after.coverage == before.coverage)
        #expect(after.selection == before.selection)
    }

    /// NATIVE-P14 / FR-SEARCH-001/002 / MAC-062/064: incremental search overlays
    /// the folder without modifying its snapshot, selection or navigation history.
    @Test
    func submitProgressAndCompletionPreserveFolderState() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id, anchorID: original.id)
        let selection = h.store.activeTab.selection, history = h.store.activeTab.history
        h.store.submitSearch("  needle  ")
        let session = try #require(h.store.activeSearch)
        #expect(session.phase == .searching)
        #expect(session.title == "needle - Search Results")
        #expect(h.store.activeTab.title == session.title)
        #expect(session.locationTitle == "Search Results in \(h.root.lastPathComponent)")
        #expect(session.rootURL == h.root)
        #expect(h.store.displayedItems.isEmpty)
        #expect(h.store.currentSelection.selectedIDs.isEmpty)
        let request = try #require(h.searcher.requests.first)
        #expect(request.root == h.root)
        #expect(request.rootIdentity == searchTestIdentity(100))
        #expect(request.query.text == "needle")
        #expect(request.query.scope == .allSubfolders)
        #expect(request.query.filters.isEmpty)
        #expect(!request.showHidden)
        expectFolder(h.store, items: [original], selection: selection, history: history)

        let first = h.result("needle-a.txt", inode: 2000), second = h.result("needle-b.txt", inode: 2001)
        var coverage = SearchCoverage()
        coverage.foldersSearched = 1
        h.searcher.progress(0, [first], coverage: coverage)
        try await waitUntil { h.store.displayedItems == [first.item] }
        #expect(h.store.activeSearch?.phase == .searching)
        #expect(h.store.activeSearch?.coverage == coverage)
        expectFolder(h.store, items: [original], selection: selection, history: history)
        h.store.setSelection([first.id], focusedID: first.id)
        #expect(h.store.currentSelection.selectedIDs == [first.id])
        coverage.foldersSearched = 2
        h.searcher.progress(0, [second], coverage: coverage)
        try await waitUntil { h.store.displayedItems == [first.item, second.item] }
        #expect(h.store.activeSearch?.results == [first, second])
        expectFolder(h.store, items: [original], selection: selection, history: history)
        h.searcher.finish(0, coverage: coverage)
        try await waitUntil { h.store.activeSearch?.phase == .complete }
        #expect(h.store.activeSearch?.coverageSummary == "Search complete.")
        #expect(h.store.activeSearch?.statusText == nil)
        #expect(h.store.currentSelection.selectedIDs == [first.id])
        expectFolder(h.store, items: [original], selection: selection, history: history)
        #expect(await h.driver.reads.count == 1)
    }

    /// NATIVE-P14 / FR-SEARCH-001/003 / MAC-064: replaced submissions and scope
    /// generations reject queued and late events; the old producer is cancelled.
    @Test(arguments: ["submit", "scope"])
    func replacementRejectsStaleStream(_ replacement: String) async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        try await begin(h, results: [h.result("old-needle.txt")])
        let generation = try #require(h.store.activeSearch?.generation)
        // Queue an old event before cancellation, in addition to late yields below.
        h.searcher.progress(0, [h.result("queued.txt", inode: 9000)])
        if replacement == "submit" { h.store.submitSearch("latest") }
        else { h.store.setSearchScope(.currentFolder) }
        try #require(h.searcher.requests.count == 2)
        #expect(h.store.activeSearch?.generation != generation)
        #expect(h.store.displayedItems.isEmpty)
        #expect(h.searcher.requests[1].query.text == (replacement == "submit" ? "latest" : "needle"))
        #expect(h.searcher.requests[1].query.scope == (replacement == "scope" ? .currentFolder : .allSubfolders))
        try await expectCancelled(h.searcher, 0)
        let newest = h.result("latest-needle.txt", inode: 3000)
        h.searcher.progress(1, [newest])
        try await waitUntil { h.store.displayedItems == [newest.item] }
        try await expectLateEventsIgnored(h, stream: 0)
        h.searcher.finish(1)
        try await waitUntil { h.store.activeSearch?.phase == .complete }
        #expect(h.store.displayedItems == [newest.item])
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-064: Stop retains found results and their
    /// selection, reports cancellation, and ignores later producer events.
    @Test
    func stopRetainsResultsAndRejectsLateEvents() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let result = h.result("needle.txt")
        try await begin(h, results: [result])
        h.store.setSelection([result.id], focusedID: result.id)
        h.store.stopSearch()
        #expect(h.store.activeSearch?.phase == .cancelled)
        #expect(h.store.displayedItems == [result.item])
        #expect(h.store.currentSelection.selectedIDs == [result.id])
        #expect(h.store.activeSearch?.statusText == "Search stopped")
        try await expectCancelled(h.searcher, 0)
        try await expectLateEventsIgnored(h, stream: 0)
    }

    /// NATIVE-P14 / FR-SEARCH-001/003 / MAC-062/063: Close and Back restore all
    /// folder selection fields without a read/history change; next search is fresh.
    @Test(arguments: ["close", "back"])
    func closeAndBackRestoreFolderAndResetQuery(_ action: String) async throws {
        let h = SearchStoreHarness(withForwardHistory: true)
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id, anchorID: original.id)
        let selection = h.store.activeTab.selection, history = h.store.activeTab.history
        try await begin(h)
        h.store.setSearchScope(.currentFolder)
        h.store.setSearchKind(.document)
        h.store.setSearchDate(.today)
        h.store.setSearchSize(.tiny)
        let stream = h.searcher.requests.count - 1
        h.searcher.progress(stream, [h.result("needle.txt", inode: 2000)])
        try await waitUntil { h.store.displayedItems.count == 1 }
        if action == "close" { h.store.closeSearch() } else { h.store.back() }
        #expect(h.store.activeSearch == nil)
        #expect(!h.store.isSearching)
        #expect(h.store.activeTab.title == h.root.lastPathComponent)
        #expect(h.store.displayedItems == [original])
        #expect(h.store.currentSelection == selection)
        expectFolder(h.store, items: [original], selection: selection, history: history)
        try await expectCancelled(h.searcher, stream)
        #expect(await h.driver.reads.count == 1)
        h.store.submitSearch("next")
        let query = try #require(h.searcher.requests.last?.query)
        #expect(query.scope == .allSubfolders)
        #expect(query.filters.isEmpty)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-062: pending and failed navigation keep
    /// results, while a successful destination read commits and ends search.
    @Test
    func navigationKeepsSearchUntilSuccessfulCommit() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let result = h.result("needle.txt")
        try await begin(h, results: [result])
        let id = h.store.activeSearch?.id, history = h.store.activeTab.history
        let destination = h.root.appendingPathComponent("Destination", isDirectory: true)
        h.store.navigate(to: destination)
        try await waitUntil { await h.driver.reads.count == 2 }
        #expect(h.store.activeTab.isLoading)
        #expect(h.store.activeSearch?.id == id)
        #expect(h.store.displayedItems == [result.item])
        #expect(h.store.activeTab.history == history)
        await h.driver.fail(1)
        try await waitUntil { !h.store.activeTab.isLoading }
        #expect(h.store.activeSearch?.id == id)
        #expect(h.store.displayedItems == [result.item])
        #expect(h.store.activeTab.history == history)
        #expect(h.store.activeTab.errorMessage != nil)
        h.store.navigate(to: destination)
        try await waitUntil { await h.driver.reads.count == 3 }
        #expect(h.store.activeSearch?.id == id)
        let row = h.result("destination.txt", inode: 2000, parent: destination).item
        await h.driver.succeed(2, items: [row], identity: searchTestIdentity(200))
        try await waitUntil { !h.store.activeTab.isLoading }
        #expect(h.store.activeSearch == nil)
        #expect(h.store.activeTab.url == destination)
        #expect(h.store.displayedItems == [row])
        #expect(h.store.activeTab.history.backStack == [h.root])
        try await expectCancelled(h.searcher, 0)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-062: Forward and address submission
    /// preserve search while pending/failed and end it only on successful commit.
    @Test(arguments: ["forward", "address"])
    func forwardAndAddressEndSearchOnCommit(_ action: String) async throws {
        let h = SearchStoreHarness(withForwardHistory: true)
        defer { h.stop() }
        try await ready(h)
        let result = h.result("needle.txt")
        try await begin(h, results: [result])
        let history = h.store.activeTab.history, sessionID = h.store.activeSearch?.id
        let destination = h.root.appendingPathComponent(action == "forward" ? "Forward" : "Address", isDirectory: true)
        if action == "forward" { h.store.forward() } else { h.store.submitAddress(destination) }
        try await waitUntil { await h.driver.reads.count == 2 }
        #expect(await h.driver.reads[1].url == destination)
        #expect(h.store.activeSearch?.id == sessionID)
        #expect(h.store.displayedItems == [result.item])
        #expect(h.store.activeTab.history == history)
        await h.driver.fail(1)
        try await waitUntil { !h.store.activeTab.isLoading }
        #expect(h.store.activeSearch?.id == sessionID)
        #expect(h.store.displayedItems == [result.item])
        #expect(h.store.activeTab.history == history)
        if action == "forward" { h.store.forward() } else { h.store.submitAddress(destination) }
        try await waitUntil { await h.driver.reads.count == 3 }
        #expect(h.store.activeSearch != nil)
        await h.driver.succeed(2, identity: searchTestIdentity(200))
        try await waitUntil { !h.store.activeTab.isLoading }
        #expect(h.store.activeSearch == nil)
        #expect(h.store.activeTab.url == destination)
        #expect(h.store.activeTab.history.backStack == [h.root])
        try await expectCancelled(h.searcher, 0)
    }

    /// NATIVE-P14 / FR-SEARCH-001 / MAC-062: empty and whitespace submissions
    /// close the overlay without issuing another traversal or read.
    @Test(arguments: ["", " \n\t "])
    func emptySubmissionClosesSearch(_ text: String) async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id)
        let selection = h.store.activeTab.selection, history = h.store.activeTab.history
        try await begin(h, results: [h.result("needle.txt", inode: 2000)])
        h.store.submitSearch(text)
        #expect(h.store.activeSearch == nil)
        #expect(h.searcher.requests.count == 1)
        #expect(h.store.displayedItems == [original])
        expectFolder(h.store, items: [original], selection: selection, history: history)
        try await expectCancelled(h.searcher, 0)
        #expect(await h.driver.reads.count == 1)
    }

    /// NATIVE-P14 / FR-SEARCH-001 / MAC-062/064: identity-less snapshots are
    /// unavailable for local search; no searcher request is dispatched.
    @Test
    func snapshotWithoutIdentityMakesSearchUnavailable() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h, identity: nil)
        h.store.submitSearch("needle")
        #expect(h.store.activeSearch?.phase == .unavailable("Search is available only for local folders."))
        #expect(h.store.activeSearch?.statusText == "Search unavailable")
        #expect(h.searcher.requests.isEmpty)
    }

    /// NATIVE-P14 / FR-SEARCH-002/004 / MAC-064: root-change and permission
    /// failures report unavailable, preserving found results and access context.
    @Test(arguments: ["rootChanged", "permission"])
    func searchErrorsReportUnavailable(_ errorKind: String) async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let result = h.result("needle.txt")
        try await begin(h, results: [result])
        if errorKind == "rootChanged" { h.searcher.fail(0, FilenameSearchError.rootChanged) }
        else { h.searcher.fail(0, CocoaError(.fileReadNoPermission)) }
        try await waitUntil { h.store.activeSearch?.isRunning == false }
        let session = try #require(h.store.activeSearch)
        guard case .unavailable(let message) = session.phase else {
            Issue.record("A search failure must become unavailable")
            return
        }
        if errorKind == "rootChanged" {
            #expect(message == FilenameSearchError.rootChanged.errorDescription)
            #expect(session.accessIssue == nil)
        } else {
            #expect(message.contains(h.root.path))
            #expect(session.accessIssue?.failure == .permissionDenied)
            #expect(session.accessIssue?.locations == [h.root])
            #expect(session.accessIssue?.action == "Search")
        }
        #expect(h.store.displayedItems == [result.item])
        #expect(session.statusText == "Search unavailable")
    }

    /// NATIVE-P14 / FR-SEARCH-002/004 / MAC-064: denied subfolders make finished
    /// coverage partial, name the count, and expose the sample for access help.
    @Test
    func partialCoverageReportsUnreadableFolderAndAccessIssue() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        try await begin(h)
        let unreadable = h.root.appendingPathComponent("Denied", isDirectory: true)
        var coverage = SearchCoverage()
        coverage.foldersSearched = 2
        coverage.unreadableFolders = 1
        coverage.accessFailure = .permissionDenied
        coverage.unreadableSamples = [unreadable]
        h.searcher.finish(0, coverage: coverage)
        try await waitUntil { h.store.activeSearch?.phase == .partial }
        let session = try #require(h.store.activeSearch)
        #expect(session.coverage == coverage)
        #expect(session.coverageSummary == "Some locations weren’t searched: 1 folder couldn’t be read.")
        #expect(session.accessIssue?.failure == .permissionDenied)
        #expect(session.accessIssue?.locations == [unreadable])
        #expect(session.accessIssue?.action == "Search")
        #expect(session.emptyMessage == "No items match your search in the locations that were searched.")
        #expect(session.statusText == "Search incomplete")
    }

    /// NATIVE-P14 / FR-SEARCH-004 / MAC-064: only complete empty coverage uses
    /// the exact observed empty-results wording (AT-SEARCH-004 model subset).
    @Test
    func emptyCompleteSearchUsesRequiredMessage() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        try await begin(h)
        #expect(h.store.activeSearch?.emptyMessage == "Searching…")
        h.searcher.finish(0)
        try await waitUntil { h.store.activeSearch?.phase == .complete }
        #expect(h.store.activeSearch?.emptyMessage == "No items match your search.")
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065: results disable folder writes and
    /// drags; unrelated destinations retain a valid, identity-bound drop binding.
    @Test
    func searchGatesFolderOperationsAndOwnFolderDrop() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id)
        h.store.copySelection()
        #expect(h.store.clipboard.hasTransferCandidate)
        #expect(h.store.canPaste)
        #expect(h.store.canRenameSelection)
        let result = h.result("needle.txt", inode: 2000)
        try await begin(h, results: [result])
        h.store.setSelection([result.id], focusedID: result.id)
        #expect(!h.store.canCreateFolder)
        #expect(!h.store.canPaste)
        #expect(!h.store.canRenameSelection)
        #expect(h.store.fileDragEntries(itemIDs: [result.id]) == nil)
        #expect(h.store.fileDragEntries(itemIDs: [original.id]) == nil)
        #expect(h.store.fileDropBinding(destinationURL: h.root) == nil)
        let other = h.root.appendingPathComponent("Other", isDirectory: true)
        let identity = searchTestIdentity(300)
        let binding = try #require(h.store.fileDropBinding(destinationURL: other, expectedDestinationIdentity: identity))
        #expect(binding.destinationURL == other)
        #expect(binding.tabID == h.store.activeTabID)
        #expect(binding.expectedDestinationIdentity == identity)
        #expect(h.store.isCurrentFileDropBinding(binding))
        h.store.beginCreateFolder()
        h.store.beginRename()
        h.store.pasteSelection()
        h.store.moveHere()
        #expect(h.store.nameEdit == nil)
        #expect(!h.store.isPerformingOperation)
        #expect(await h.driver.writeCalls == 0)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065: Copy and Trash require identity and
    /// parent for every selected result, including mixed safe/unsafe selections.
    @Test
    func copyAndTrashRequireEverySelectedResultsIdentityAndParent() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let valid = h.result("a-needle.txt"), other = h.result("b-needle.txt", inode: 2000)
        let noIdentity = h.result("c-needle.txt", inode: 3000, hasIdentity: false)
        let noParent = h.result("d-needle.txt", inode: 4000, hasParent: false)
        try await begin(h, results: [valid, other, noIdentity, noParent])
        for ids: Set<String> in [[], [valid.id], [valid.id, other.id], [noIdentity.id], [noParent.id],
                                 [valid.id, noIdentity.id], [valid.id, noParent.id]] {
            h.store.setSelection(ids, focusedID: ids.first)
            let allowed = !ids.isEmpty && ids.isSubset(of: [valid.id, other.id])
            #expect(h.store.canCopySelection == allowed)
            #expect(h.store.canTrashSelection == allowed)
            if !allowed {
                h.store.copySelection()
                h.store.cutSelection()
                h.store.trashSelection()
                #expect(h.store.clipboard.payload == nil)
                #expect(!h.store.isPerformingOperation)
            }
        }
        #expect(await h.driver.trashCalls.isEmpty)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065 (FR-FILE-003/004): Copy and Cut
    /// capture each selected result's own parent, in displayed order.
    @Test(arguments: [TransferKind.copy, .move])
    func copyAndCutCaptureDistinctResultParents(_ kind: TransferKind) async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let first = h.result("a-needle.txt", parent: h.root.appendingPathComponent("One", isDirectory: true))
        let second = h.result("b-needle.txt", inode: 2000, parent: h.root.appendingPathComponent("Two", isDirectory: true))
        try await begin(h, results: [second, first])
        h.store.setSelection([first.id, second.id], focusedID: second.id)
        if kind == .copy { h.store.copySelection() } else { h.store.cutSelection() }
        let payload = try #require(h.store.clipboard.payload)
        #expect(payload.kind == kind)
        #expect(payload.entries.map(\.item) == [first.item, second.item])
        #expect(payload.entries.map(\.source) == [first.parent!, second.parent!])
        #expect(payload.entries.allSatisfy { $0.source.directoryURL != h.root })
        #expect(h.store.activeSearch != nil)
        #expect(h.store.currentSelection.selectedIDs == [first.id, second.id])
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065 (FR-FILE-005): Trash passes each
    /// result's own context, records receipts, reruns search and passively reloads
    /// the original folder while retaining the open search session.
    @Test
    func trashUsesEachParentRecordsReceiptsAndRerunsOpenSearch() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id)
        let folderSelection = h.store.activeTab.selection, history = h.store.activeTab.history
        let first = h.result("a-needle.txt", inode: 2000, parent: h.root.appendingPathComponent("One", isDirectory: true))
        let second = h.result("b-needle.txt", inode: 3000, parent: h.root.appendingPathComponent("Two", isDirectory: true))
        try await begin(h, results: [second, first])
        h.store.setSelection([first.id, second.id], focusedID: first.id)
        let sessionID = h.store.activeSearch?.id, generation = h.store.activeSearch?.generation
        h.store.trashSelection()
        #expect(h.store.isPerformingOperation)
        try await waitUntil { await h.driver.trashCalls.count == 1 }
        let trashContext = FileOperationContext(directoryURL: h.root.appendingPathComponent("FakeTrash", isDirectory: true),
                                                directoryIdentity: searchTestIdentity(900))
        var receipts: [TrashReceipt] = []
        for (index, result) in [first, second].enumerated() {
            try await waitUntil { await h.driver.trashCalls.count == index + 1 }
            let call = await h.driver.trashCalls[index]
            #expect(call.item == result.item)
            #expect(call.context == result.parent)
            let receipt = TrashReceipt(original: result.item, originalContext: try #require(result.parent),
                trashed: h.result(result.item.name, inode: UInt64(9000 + index), parent: trashContext.directoryURL).item,
                trashContext: trashContext)
            receipts.append(receipt)
            await h.driver.trashed(index, receipt: receipt)
        }
        try await waitUntil { !h.store.isPerformingOperation && h.searcher.requests.count == 2 }
        #expect(Set(h.store.recoveryHistory.entries.map(\.id)) == Set(receipts.map(\.id)))
        #expect(h.store.recoveryHistory.entries.map(\.originalContext) == [second.parent!, first.parent!])
        #expect(h.store.operationNotice == "Moved 2 of 2 selected items to Trash.")
        #expect(h.store.activeSearch?.id == sessionID)
        #expect(h.store.activeSearch?.generation != generation)
        #expect(h.store.activeSearch?.phase == .searching)
        #expect(h.searcher.requests[1].query == h.searcher.requests[0].query)
        #expect(h.searcher.requests[1].root == h.root)
        try await waitUntil { await h.driver.reads.count == 2 }
        #expect(await h.driver.reads[1].url == h.root)
        #expect(h.store.activeTab.isRefreshing)
        #expect(!h.store.activeTab.isLoading)
        expectFolder(h.store, items: [original], selection: folderSelection, history: history)
        await h.driver.succeed(1, items: [original])
        try await waitUntil { !h.store.activeTab.isRefreshing }
        h.searcher.finish(1)
        try await waitUntil { h.store.activeSearch?.phase == .complete }
        #expect(h.store.activeSearch?.id == sessionID)
        #expect(h.store.displayedItems.isEmpty)
        expectFolder(h.store, items: [original], selection: folderSelection, history: history)
        try await expectCancelled(h.searcher, 0)
    }

    /// NATIVE-P14 / FR-SEARCH-002/003 / MAC-063/064: Refresh, hidden visibility
    /// and every scope/filter setter create runs with the updated query; no-op
    /// setters do not restart. Search Refresh alone does not reload the folder.
    @Test
    func refreshHiddenScopeAndFiltersRestartWithUpdatedRequests() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        try await ready(h)
        let result = h.result("needle.txt")
        try await begin(h, results: [result])
        h.store.setSelection([result.id], focusedID: result.id)
        let sessionID = h.store.activeSearch?.id, firstQuery = h.searcher.requests[0].query
        h.store.refresh()
        try #require(h.searcher.requests.count == 2)
        #expect(h.searcher.requests[1].query == firstQuery)
        #expect(h.store.displayedItems.isEmpty)
        #expect(h.store.currentSelection.selectedIDs.isEmpty)
        #expect(await h.driver.reads.count == 1)
        h.store.toggleHidden()
        try #require(h.searcher.requests.count == 3)
        #expect(h.store.showHidden)
        #expect(h.searcher.requests[2].showHidden)
        try await waitUntil { await h.driver.reads.count == 2 }
        #expect(await h.driver.reads[1].showHidden)
        await h.driver.succeed(1)
        try await waitUntil { !h.store.activeTab.isRefreshing }
        var query = firstQuery
        let changes: [(String, () -> Void, (inout FilenameSearchQuery) -> Void)] = [
            ("scope", { h.store.setSearchScope(.currentFolder) }, { $0.scope = .currentFolder }),
            ("kind", { h.store.setSearchKind(.document) }, { $0.filters.kind = .document }),
            ("date", { h.store.setSearchDate(.today) }, { $0.filters.dateModified = .today }),
            ("size", { h.store.setSearchSize(.tiny) }, { $0.filters.size = .tiny }),
            ("clear kind", { h.store.setSearchKind(nil) }, { $0.filters.kind = nil }),
            ("clear date", { h.store.setSearchDate(nil) }, { $0.filters.dateModified = nil }),
            ("clear size", { h.store.setSearchSize(nil) }, { $0.filters.size = nil })
        ]
        for (name, change, update) in changes {
            let count = h.searcher.requests.count
            let generation = h.store.activeSearch?.generation
            change()
            update(&query)
            try #require(h.searcher.requests.count == count + 1, "Missing rerun for \(name)")
            #expect(h.searcher.requests[count].query == query)
            #expect(h.searcher.requests[count].showHidden)
            #expect(h.store.activeSearch?.generation != generation)
            #expect(h.store.activeSearch?.id == sessionID)
            change()
            #expect(h.searcher.requests.count == count + 1, "No-op \(name) must not rerun")
        }
        let last = h.searcher.requests.count - 1
        h.searcher.finish(last)
        try await waitUntil { h.store.activeSearch?.phase == .complete }
        for index in 0..<last { try await expectCancelled(h.searcher, index) }
        #expect(await h.driver.reads.count == 2)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-062/064: sort reranks result rows and
    /// retains result/folder selections without running another search.
    @Test
    func sortResortsDisplayedResultsWithoutChangingSelections() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id)
        let folderSelection = h.store.activeTab.selection
        let first = h.result("a-needle.txt", inode: 2000, size: 90)
        let second = h.result("b-needle.txt", inode: 3000, size: 10)
        try await begin(h, results: [second, first])
        h.store.setSelection([first.id], focusedID: first.id, anchorID: first.id)
        let selection = h.store.currentSelection
        #expect(h.store.displayedItems == [first.item, second.item])
        h.store.sort(by: .name)
        #expect(h.store.displayedItems == [second.item, first.item])
        h.store.sort(by: .size)
        #expect(h.store.displayedItems == [second.item, first.item])
        h.store.setSortAscending(false)
        #expect(h.store.displayedItems == [first.item, second.item])
        #expect(h.store.currentSelection == selection)
        #expect(h.store.activeTab.selection == folderSelection)
        #expect(h.store.activeTab.items == [original])
        #expect(h.searcher.requests.count == 1)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-062/065: selected result metadata and
    /// selection fields never use the underlying folder's selection or invalid IDs.
    @Test
    func selectionAndDetailsUseOnlySelectedSearchResults() async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        h.store.setSelection([original.id], focusedID: original.id, anchorID: original.id)
        let folderSelection = h.store.activeTab.selection
        let first = h.result("a-needle.txt", inode: 2000), second = h.result("b-needle.txt", inode: 3000)
        try await begin(h, results: [second, first])
        #expect(h.store.detailSelection.isEmpty)
        h.store.setSelection([first.id, original.id, "invalid"], focusedID: second.id, anchorID: first.id)
        #expect(h.store.currentSelection.selectedIDs == [first.id])
        #expect(h.store.currentSelection.focusedID == second.id)
        #expect(h.store.currentSelection.anchorID == first.id)
        #expect(h.store.detailSelection == [first.item])
        #expect(h.store.activeTab.selection == folderSelection)
        h.store.setSelection([first.id, second.id], focusedID: second.id)
        #expect(h.store.detailSelection == [first.item, second.item])
        h.store.setSelection([], focusedID: nil)
        #expect(h.store.currentSelection == SelectionState())
        #expect(h.store.detailSelection.isEmpty)
        #expect(h.store.activeTab.selection == folderSelection)
    }

    /// NATIVE-P14 / FR-SEARCH-001/002 / MAC-062/064: closing a search tab
    /// cancels traversal; detaching transfers only committed folder state.
    @Test(arguments: ["close", "detach"])
    func closingAndDetachingSearchingTabTerminateStream(_ action: String) async throws {
        let h = SearchStoreHarness()
        defer { h.stop() }
        let original = h.result("original.txt").item
        try await ready(h, items: [original])
        let searchingID = h.store.activeTabID
        h.store.setSelection([original.id], focusedID: original.id)
        let folderSelection = h.store.activeTab.selection, history = h.store.activeTab.history
        try await begin(h, results: [h.result("needle.txt", inode: 2000)])
        h.store.openTab(at: h.root)
        let otherID = h.store.activeTabID
        try await waitUntil { await h.driver.reads.count == 2 }
        await h.driver.succeed(1)
        try await waitUntil { !h.store.activeTab.isLoading }
        h.store.activateTab(searchingID)
        var detached: BrowserTab?
        let point = NSPoint(x: 12, y: 34)
        h.store.onDetachTab = { tab, actualPoint in
            detached = tab
            #expect(actualPoint == point)
        }
        if action == "close" { h.store.closeTab(searchingID) }
        else { h.store.detachTab(searchingID, at: point) }
        #expect(h.store.tabs.map(\.id) == [otherID])
        #expect(h.store.activeTabID == otherID)
        #expect(h.store.activeSearch == nil)
        try await expectCancelled(h.searcher, 0)
        h.searcher.progress(0, [h.result("late.txt", inode: 9000)])
        h.searcher.finish(0)
        #expect(h.store.displayedItems.isEmpty)
        if action == "detach" {
            let tab = try #require(detached)
            #expect(tab.id == searchingID)
            #expect(tab.search == nil)
            #expect(tab.items == [original])
            #expect(tab.selection == folderSelection)
            #expect(tab.history == history)
            #expect(!tab.isLoading && !tab.isRefreshing)
        } else { #expect(detached == nil) }
        #expect(await h.driver.reads.count == 2)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065: real parent/entry validation, then
    /// select exactly the URL + identity row after Open file location commits;
    /// Back returns to the original root (AT-SEARCH-002 filesystem/store subset).
    /// Sandbox run 3: the nested file was absent from complete search results;
    /// directory metadata is unavailable when Launch Services fails. Re-enable
    /// and run outside the sandbox; this is not a production BUG verdict.
    @Test
    func realOpenResultLocationSelectsExactRowAndBackReturnsToRoot() async throws {
        let files = try SearchStoreFiles()
        let board = makeSearchTestPasteboard()
        defer { board.releaseGlobally(); withExtendedLifetime(files) {} }
        let store = ExplorerStore(initialURL: files.root, loader: LocalDirectoryLoader(), homeURL: files.root,
                                  clipboard: TransferClipboard(pasteboard: board), searcher: LocalFilenameSearcher())
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        try #require(store.activeTab.directoryIdentity != nil)
        store.submitSearch("needle")
        try await waitUntil { store.activeSearch?.phase == .complete }
        let result = try #require(store.activeSearch?.results.first { $0.item.url == files.file })
        #expect(result.parent?.directoryURL == files.parent)
        try #require(result.item.identity != nil)
        store.setSelection([result.id], focusedID: result.id)
        #expect(store.canOpenSearchResultLocation)
        store.openSelectedSearchResultLocation()
        try await waitUntil { store.activeTab.url == files.parent && !store.activeTab.isLoading }
        #expect(store.activeSearch == nil)
        let row = try #require(store.activeTab.items.first { $0.url == files.file && $0.identity == result.item.identity })
        #expect(store.currentSelection.selectedIDs == [row.id])
        #expect(store.currentSelection.focusedID == row.id)
        #expect(store.currentSelection.anchorID == row.id)
        #expect(store.activeTab.items.contains { $0.url == files.sibling })
        #expect(store.activeTab.history.backStack == [files.root])
        store.back()
        try await waitUntil { store.activeTab.url == files.root && !store.activeTab.isLoading }
        #expect(store.activeSearch == nil)
        #expect(store.activeTab.history.forwardStack == [files.parent])
        #expect(store.operationNotice == nil)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065: activating a real folder result
    /// validates it and navigates into the folder without opening an external app.
    /// Sandbox run 3: recursive search returned no folder result because nested
    /// directory metadata was unavailable. Re-enable outside the sandbox.
    @Test
    func realFolderResultActivationNavigatesIntoFolder() async throws {
        let files = try SearchStoreFiles()
        let board = makeSearchTestPasteboard()
        defer { board.releaseGlobally(); withExtendedLifetime(files) {} }
        let store = ExplorerStore(initialURL: files.root, loader: LocalDirectoryLoader(), homeURL: files.root,
                                  clipboard: TransferClipboard(pasteboard: board), searcher: LocalFilenameSearcher())
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        store.submitSearch("needle")
        try await waitUntil { store.activeSearch?.phase == .complete }
        let result = try #require(store.activeSearch?.results.first { $0.item.url == files.folder })
        try #require(result.item.isDirectory && result.supportsOperations)
        store.activate(result.item)
        try await waitUntil { store.activeTab.url == files.folder && !store.activeTab.isLoading }
        #expect(store.activeSearch == nil)
        #expect(store.displayedItems.isEmpty)
        #expect(store.activeTab.history.backStack == [files.root])
        #expect(store.operationNotice == nil)
    }

    /// NATIVE-P14 / FR-SEARCH-002 / MAC-065: a renamed entry or replacement at
    /// the same URL fails real lstat revalidation and cannot navigate from search.
    @Test(arguments: ["rename", "replace"])
    func realChangedResultIsRefusedWithoutNavigation(_ mutation: String) async throws {
        let files = try SearchStoreFiles()
        // This case needs entry identity, not recursive traversal. Keeping the
        // target in the root lets real lstat checks run even when Launch Services
        // cannot supply directory-kind metadata for recursive search.
        let target = files.root.appendingPathComponent("needle-root.txt")
        try Data("original root entry".utf8).write(to: target)
        let board = makeSearchTestPasteboard()
        defer { board.releaseGlobally(); withExtendedLifetime(files) {} }
        let store = ExplorerStore(initialURL: files.root, loader: LocalDirectoryLoader(), homeURL: files.root,
                                  clipboard: TransferClipboard(pasteboard: board), searcher: LocalFilenameSearcher())
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        store.submitSearch("needle")
        try await waitUntil { store.activeSearch?.phase == .complete }
        let result = try #require(store.activeSearch?.results.first { $0.item.url == target })
        let history = store.activeTab.history, sessionID = store.activeSearch?.id
        store.setSelection([result.id], focusedID: result.id)
        let renamed = files.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: target, to: renamed)
        if mutation == "replace" {
            // Keep the original alive under another name to rule out inode reuse.
            try Data("replacement".utf8).write(to: target)
            let snapshot = try await LocalDirectoryLoader().snapshot(of: files.root, showHidden: false)
            let replacement = try #require(snapshot.items.first { $0.url == target })
            #expect(replacement.identity != result.item.identity)
        } else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        store.openSelectedSearchResultLocation()
        try await waitUntil { store.operationNotice != nil }
        #expect(store.operationNotice?.contains("changed or moved since the search") == true)
        #expect(store.activeTab.url == files.root)
        #expect(store.activeTab.history == history)
        #expect(!store.activeTab.isLoading)
        #expect(store.activeSearch?.id == sessionID)
        #expect(store.currentSelection.selectedIDs == [result.id])
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }
}


/// Holds every validation until the test releases it, so activation can be
/// observed while its revalidation is still in flight.
private final class GatedSearchValidator: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    var pending: Int { lock.withLock { waiters.count } }

    func validate(_ result: FilenameSearchResult) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }

    func release(_ value: Bool) {
        let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            defer { waiters.removeAll() }
            return waiters
        }
        ready.forEach { $0.resume(returning: value) }
    }
}

/// GPT-6 Astra review `7af5c5e7-e9a6-4e3b-a0bc-1ab9a991a30e` regressions:
/// findings 1–3 (MAC-062/064/065) and 4 (FR-SEARCH-003 wording).
@MainActor
final class SearchReviewRegressionTests {
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await predicate(), "Expected state was not reached")
    }

    /// Lets queued main-actor work run without asserting a positive outcome.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    private func loaded(_ harness: SearchStoreHarness) async throws {
        try await waitUntil { await harness.driver.reads.count == 1 }
        await harness.driver.succeed(0)
        try await waitUntil { harness.store.activeTab.hasLoaded && !harness.store.activeTab.isLoading }
    }

    private func folderResult(_ harness: SearchStoreHarness) -> FilenameSearchResult {
        let url = harness.root.appendingPathComponent("needle-folder", isDirectory: true)
        let item = FileItem(url: url, name: "needle-folder", isDirectory: true, isSymbolicLink: false,
                            size: nil, modifiedAt: nil, kind: "File folder", identity: searchTestIdentity(700))
        return FilenameSearchResult(item: item, parent: FileOperationContext(
            directoryURL: harness.root, directoryIdentity: searchTestIdentity(100)))
    }

    private func completeSearch(_ harness: SearchStoreHarness, _ results: [FilenameSearchResult]) async throws {
        harness.store.submitSearch("needle")
        try await waitUntil { harness.searcher.requests.count == 1 }
        harness.searcher.progress(0, results)
        harness.searcher.finish(0)
        try await waitUntil { harness.store.activeSearch?.phase == .complete }
    }

    /// Finding 1: a Refresh that replaces the presented run invalidates an
    /// activation that was still revalidating.
    @Test
    func delayedActivationIsDiscardedWhenRefreshReplacesTheRun() async throws {
        let gate = GatedSearchValidator()
        let harness = SearchStoreHarness(validator: { await gate.validate($0) })
        defer { harness.stop() }
        try await loaded(harness)
        let folder = folderResult(harness)
        try await completeSearch(harness, [folder])

        harness.store.activate(folder.item)
        try await waitUntil { gate.pending == 1 }
        harness.store.refresh()
        try await waitUntil { harness.searcher.requests.count == 2 }
        gate.release(true)
        try await settle()
        #expect(await harness.driver.reads.count == 1, "The stale activation must not navigate")
        #expect(harness.store.activeSearch != nil)
        #expect(harness.store.activeTab.url == harness.root)
    }

    /// Finding 1: a newer user navigation supersedes a pending activation.
    @Test
    func delayedActivationDoesNotOverrideANewerNavigation() async throws {
        let gate = GatedSearchValidator()
        let harness = SearchStoreHarness(validator: { await gate.validate($0) })
        defer { harness.stop() }
        try await loaded(harness)
        let folder = folderResult(harness)
        try await completeSearch(harness, [folder])
        let other = harness.root.appendingPathComponent("Other", isDirectory: true)

        harness.store.activate(folder.item)
        try await waitUntil { gate.pending == 1 }
        harness.store.navigate(to: other)
        try await waitUntil { await harness.driver.reads.count == 2 }
        gate.release(true)
        try await settle()
        let reads = await harness.driver.reads
        #expect(reads.count == 2)
        #expect(reads.last?.url.path == other.path)
        await harness.driver.succeed(1)
        try await waitUntil { harness.store.activeTab.url.path == other.path }
        #expect(harness.store.activeSearch == nil)
    }

    /// Follow-up `3b64e33f` finding 1: a newer activation supersedes an older
    /// activation whose folder read is still pending; the older read cannot commit.
    @Test
    func newerActivationSupersedesOlderPendingResultNavigation() async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let first = folderResult(harness)
        let secondURL = harness.root.appendingPathComponent("second-folder", isDirectory: true)
        let second = FilenameSearchResult(
            item: FileItem(url: secondURL, name: "second-folder", isDirectory: true, isSymbolicLink: false,
                           size: nil, modifiedAt: nil, kind: "File folder", identity: searchTestIdentity(701)),
            parent: FileOperationContext(directoryURL: harness.root, directoryIdentity: searchTestIdentity(100)))
        try await completeSearch(harness, [first, second])

        harness.store.activate(first.item)
        try await waitUntil { await harness.driver.reads.count == 2 }
        #expect(harness.store.activeSearch != nil, "Results stay presented while the first read is pending")
        harness.store.activate(second.item)
        // Read 3 is the passive reload replacing the abandoned first read; read 4 is B.
        try await waitUntil { await harness.driver.reads.count == 4 }
        let reads = await harness.driver.reads
        #expect(reads[2].url.path == harness.root.path)
        #expect(reads[3].url.path == secondURL.path)

        await harness.driver.succeed(1)
        await harness.driver.succeed(2)
        try await settle()
        #expect(harness.store.activeTab.url == harness.root, "The superseded read must not commit")
        await harness.driver.succeed(3)
        try await waitUntil { harness.store.activeTab.url.path == secondURL.path }
        #expect(harness.store.activeSearch == nil)
        #expect(harness.store.activeTab.history.backStack.map(\.path) == [harness.root.path])
    }

    /// Follow-up `2716f5db` finding 1: while a newer activation revalidates, an
    /// older result's pending folder read is abandoned and cannot commit first.
    @Test
    func olderPendingNavigationCannotCommitWhileNewerActivationRevalidates() async throws {
        let gate = GatedSearchValidator()
        let harness = SearchStoreHarness(validator: { result in
            result.item.name == "second-folder" ? await gate.validate(result) : true
        })
        defer { harness.stop() }
        try await loaded(harness)
        let first = folderResult(harness)
        let secondFolder = harness.root.appendingPathComponent("second-folder", isDirectory: true)
        let second = FilenameSearchResult(
            item: FileItem(url: secondFolder, name: "second-folder", isDirectory: true, isSymbolicLink: false,
                           size: nil, modifiedAt: nil, kind: "File folder", identity: searchTestIdentity(702)),
            parent: FileOperationContext(directoryURL: harness.root, directoryIdentity: searchTestIdentity(100)))
        try await completeSearch(harness, [first, second])

        harness.store.activate(first.item)
        try await waitUntil { await harness.driver.reads.count == 2 }
        harness.store.activate(second.item)
        try await waitUntil { gate.pending == 1 }
        try await waitUntil { await harness.driver.reads.count == 3 }
        #expect(await harness.driver.reads.last?.url.path == harness.root.path,
                "The older search-exit read is replaced by a passive reload")
        await harness.driver.succeed(1)
        await harness.driver.succeed(2)
        try await settle()
        #expect(harness.store.activeTab.url == harness.root)
        #expect(harness.store.activeSearch != nil, "The abandoned read must not end search")

        gate.release(true)
        try await waitUntil { await harness.driver.reads.count == 4 }
        #expect(await harness.driver.reads.last?.url.path == secondFolder.path)
        await harness.driver.succeed(3)
        try await waitUntil { harness.store.activeTab.url.path == secondFolder.path }
        #expect(harness.store.activeSearch == nil)
    }

    /// Follow-up `2716f5db` finding 2: Restore (which navigates without
    /// prepareForNavigation) invalidates a pending activation, so a failed
    /// post-Restore read keeps its Retry target.
    @Test
    func restoreInvalidatesPendingActivationAndKeepsRetryTarget() async throws {
        let gate = GatedSearchValidator()
        let harness = SearchStoreHarness(validator: { await gate.validate($0) })
        defer { harness.stop() }
        try await loaded(harness)
        let folder = folderResult(harness)
        try await completeSearch(harness, [folder])
        let originalFolder = harness.root.appendingPathComponent("Original", isDirectory: true)
        let originalContext = FileOperationContext(directoryURL: originalFolder, directoryIdentity: searchTestIdentity(800))
        let trashContext = FileOperationContext(
            directoryURL: harness.root.appendingPathComponent(".Trash", isDirectory: true),
            directoryIdentity: searchTestIdentity(801))
        let original = harness.result("restored.txt", inode: 802, parent: originalFolder).item
        let receipt = TrashReceipt(original: original, originalContext: originalContext,
            trashed: harness.result("restored.txt", inode: 802, parent: trashContext.directoryURL).item,
            trashContext: trashContext)
        harness.store.recoveryHistory.record(receipt)
        await harness.driver.setRestoreResult(FileOperationResult(url: original.url, identity: original.identity, warning: nil))

        harness.store.activate(folder.item)
        try await waitUntil { gate.pending == 1 }
        harness.store.showRecovery()
        harness.store.restore(receipt.id, as: "restored.txt")
        try await waitUntil { await harness.driver.reads.count == 2 }
        #expect(await harness.driver.reads.last?.url.path == originalFolder.path)
        await harness.driver.fail(1)
        try await waitUntil { !harness.store.isPerformingOperation }

        gate.release(true)
        try await settle()
        #expect(await harness.driver.reads.count == 2, "The superseded activation must not navigate")
        harness.store.retry()
        try await waitUntil { await harness.driver.reads.count == 3 }
        #expect(await harness.driver.reads.last?.url.path == originalFolder.path, "Retry still targets the Restore location")
    }

    /// Follow-up `91db4337`: a pending passive folder reload does not stop
    /// Refresh from restarting search and invalidating a held activation.
    @Test
    func refreshDuringPassiveReloadRestartsSearchAndRejectsHeldActivation() async throws {
        let gate = GatedSearchValidator()
        let harness = SearchStoreHarness(validator: { await gate.validate($0) })
        defer { harness.stop() }
        try await loaded(harness)
        let folder = folderResult(harness)
        try await completeSearch(harness, [folder])

        harness.store.refreshAfterActivation()
        try await waitUntil { await harness.driver.reads.count == 2 }
        harness.store.activate(folder.item)
        try await waitUntil { gate.pending == 1 }
        harness.store.refresh()
        try await waitUntil { harness.searcher.requests.count == 2 }
        #expect(await harness.driver.reads.count == 2, "Refresh restarts search, not the passive read")
        gate.release(true)
        await harness.driver.succeed(1)
        try await settle()
        #expect(await harness.driver.reads.count == 2, "The held activation must not navigate")
        #expect(harness.store.activeTab.url == harness.root)
        #expect(harness.store.activeSearch?.isRunning == true)
    }

    /// Follow-up `cde7c941` finding 1: Trash from results waits while an Open
    /// file location read is pending, as folder writes wait during navigation.
    @Test
    func trashFromResultsIsUnavailableWhileSearchExitNavigationLoads() async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let parent = harness.root.appendingPathComponent("Nested", isDirectory: true)
        let result = harness.result("needle.txt", inode: 303, parent: parent)
        try await completeSearch(harness, [result])
        harness.store.setSelection([result.id], focusedID: result.id)
        #expect(harness.store.canTrashSelection)

        harness.store.openSelectedSearchResultLocation()
        try await waitUntil { await harness.driver.reads.count == 2 }
        #expect(!harness.store.canTrashSelection)
        #expect(!harness.store.canCopySelection)
        harness.store.trashSelection()
        try await settle()
        #expect(await harness.driver.trashCalls.isEmpty)
        #expect(!harness.store.isPerformingOperation)

        await harness.driver.fail(1)
        try await waitUntil { !harness.store.activeTab.isLoading }
        #expect(harness.store.canTrashSelection, "A refused navigation re-enables result operations")
    }

    /// Follow-up `cde7c941` finding 2: closing search cannot take over a
    /// Restore's post-write read; Restore keeps its navigation and selection.
    @Test
    func closeSearchCannotHijackRestoreNavigation() async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        try await completeSearch(harness, [folderResult(harness)])
        let originalFolder = harness.root.appendingPathComponent("Original", isDirectory: true)
        let originalContext = FileOperationContext(directoryURL: originalFolder, directoryIdentity: searchTestIdentity(810))
        let trashContext = FileOperationContext(
            directoryURL: harness.root.appendingPathComponent(".Trash", isDirectory: true),
            directoryIdentity: searchTestIdentity(811))
        let original = harness.result("restored.txt", inode: 812, parent: originalFolder).item
        let receipt = TrashReceipt(original: original, originalContext: originalContext,
            trashed: harness.result("restored.txt", inode: 812, parent: trashContext.directoryURL).item,
            trashContext: trashContext)
        harness.store.recoveryHistory.record(receipt)
        await harness.driver.setRestoreResult(FileOperationResult(url: original.url, identity: original.identity, warning: nil))

        harness.store.showRecovery()
        harness.store.restore(receipt.id, as: "restored.txt")
        try await waitUntil { await harness.driver.reads.count == 2 }
        #expect(harness.store.isPerformingOperation)
        #expect(!harness.store.canSearch)
        harness.store.closeSearch()
        try await settle()
        #expect(await harness.driver.reads.count == 2, "Close search must not replace the Restore read")
        #expect(harness.store.activeSearch != nil)

        await harness.driver.succeed(1, items: [original], identity: originalContext.directoryIdentity)
        try await waitUntil { !harness.store.isPerformingOperation }
        #expect(harness.store.activeTab.url.path == originalFolder.path)
        #expect(harness.store.activeSearch == nil)
        #expect(harness.store.activeTab.selection.selectedIDs == [original.id])
    }

    /// A new submission or option change while an Open file location read is
    /// pending is the newest intent: the older search exit cannot end search.
    @Test(arguments: ["submit", "scope"])
    func newerSearchIntentAbandonsPendingSearchExit(change: String) async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let parent = harness.root.appendingPathComponent("Nested", isDirectory: true)
        let result = harness.result("needle.txt", inode: 304, parent: parent)
        try await completeSearch(harness, [result])
        harness.store.setSelection([result.id], focusedID: result.id)
        harness.store.openSelectedSearchResultLocation()
        try await waitUntil { await harness.driver.reads.count == 2 }

        if change == "submit" { harness.store.submitSearch("needle") }
        else { harness.store.setSearchScope(.currentFolder) }
        try await waitUntil { harness.searcher.requests.count == 2 }
        try await waitUntil { await harness.driver.reads.count == 3 }
        #expect(await harness.driver.reads.last?.url.path == harness.root.path)
        await harness.driver.succeed(1, items: [result.item], identity: result.parent?.directoryIdentity)
        await harness.driver.succeed(2)
        try await settle()
        #expect(harness.store.activeTab.url == harness.root)
        #expect(harness.store.activeSearch?.isRunning == true, "The newer search run survives")
    }

    /// Follow-up `b08a421f`: Back carries search-exit intent. A search started
    /// while Back is pending wins; a failed Back's Retry ends that search.
    @Test(arguments: ["pending", "retry"])
    func backCarriesSearchExitIntent(order: String) async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let other = harness.root.appendingPathComponent("Other", isDirectory: true)
        harness.store.navigate(to: other)
        try await waitUntil { await harness.driver.reads.count == 2 }
        await harness.driver.succeed(1)
        try await waitUntil { harness.store.activeTab.url.path == other.path && !harness.store.activeTab.isLoading }

        harness.store.back()
        try await waitUntil { await harness.driver.reads.count == 3 }
        if order == "pending" {
            harness.store.submitSearch("needle")
            try await waitUntil { harness.searcher.requests.count == 1 }
            try await waitUntil { await harness.driver.reads.count == 4 }
            #expect(await harness.driver.reads.last?.url.path == other.path, "Back is abandoned for a passive reload")
            await harness.driver.succeed(2)
            await harness.driver.succeed(3)
            try await settle()
            #expect(harness.store.activeTab.url.path == other.path)
            #expect(harness.store.activeSearch?.rootURL.path == other.path)
        } else {
            await harness.driver.fail(2)
            try await waitUntil { harness.store.activeTab.errorMessage != nil }
            harness.store.submitSearch("needle")
            try await waitUntil { harness.searcher.requests.count == 1 }
            harness.store.retry()
            try await waitUntil { await harness.driver.reads.count == 4 }
            await harness.driver.succeed(3)
            try await waitUntil { harness.store.activeTab.url == harness.root }
            #expect(harness.store.activeSearch == nil, "The search over Other must not survive over the root")
        }
    }

    /// Finding 2: Retry after a failed Open file location still ends search and
    /// selects the exact result, for a nested and an immediate-child parent.
    @Test(arguments: [true, false])
    func retryReplaysOpenFileLocationIntent(nested: Bool) async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let parent = nested ? harness.root.appendingPathComponent("Nested", isDirectory: true) : harness.root
        let result = harness.result("needle.txt", inode: 300, parent: parent)
        try await completeSearch(harness, [result])
        harness.store.setSelection([result.id], focusedID: result.id)

        harness.store.openSelectedSearchResultLocation()
        try await waitUntil { await harness.driver.reads.count == 2 }
        await harness.driver.fail(1)
        try await waitUntil { harness.store.activeTab.errorMessage != nil }
        #expect(harness.store.activeSearch != nil, "A refused navigation keeps the results")

        harness.store.retry()
        try await waitUntil { await harness.driver.reads.count == 3 }
        await harness.driver.succeed(2, items: [result.item], identity: result.parent?.directoryIdentity)
        try await waitUntil { harness.store.activeSearch == nil && !harness.store.activeTab.isLoading }
        #expect(harness.store.activeTab.url.path == parent.path)
        #expect(harness.store.activeTab.selection.selectedIDs == [result.item.id])
        #expect(harness.store.activeTab.selection.focusedID == result.item.id)
    }

    /// Finding 3: Close search, Back or Escape abandons a still-loading
    /// Open file location navigation; its late success cannot navigate.
    @Test(arguments: ["close", "back"])
    func closingSearchAbandonsPendingSearchExitNavigation(action: String) async throws {
        let harness = SearchStoreHarness(validator: { _ in true })
        defer { harness.stop() }
        try await loaded(harness)
        let parent = harness.root.appendingPathComponent("Nested", isDirectory: true)
        let result = harness.result("needle.txt", inode: 301, parent: parent)
        try await completeSearch(harness, [result])
        harness.store.setSelection([result.id], focusedID: result.id)
        harness.store.openSelectedSearchResultLocation()
        try await waitUntil { await harness.driver.reads.count == 2 }

        if action == "close" { harness.store.closeSearch() } else { harness.store.back() }
        #expect(harness.store.activeSearch == nil)
        try await waitUntil { await harness.driver.reads.count == 3 }
        #expect(await harness.driver.reads.last?.url.path == harness.root.path,
                "The committed folder is passively reloaded instead")
        await harness.driver.succeed(1, items: [result.item], identity: result.parent?.directoryIdentity)
        await harness.driver.succeed(2)
        try await settle()
        #expect(harness.store.activeTab.url.path == harness.root.path)
        #expect(!harness.store.activeTab.history.canGoBack, "The abandoned navigation left no history entry")
        #expect(!harness.store.activeTab.isLoading)
    }

    /// Finding 4 / FR-SEARCH-003: progress wording follows the scope.
    @Test
    func progressWordingFollowsScope() throws {
        let root = URL(fileURLWithPath: "/tmp/fixture", isDirectory: true)
        let recursive = try #require(FilenameSearchQuery(text: "needle"))
        var session = SearchSession(query: recursive, rootURL: root, rootTitle: "fixture")
        #expect(session.progressText.hasPrefix("Searching fixture and its subfolders…"))
        session.query.scope = .currentFolder
        #expect(session.progressText == "Searching fixture…")
    }
}
