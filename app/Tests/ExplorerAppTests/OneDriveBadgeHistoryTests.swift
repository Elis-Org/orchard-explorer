import Foundation
import Testing
@testable import ExplorerCore
@testable import ExplorerApp

private actor HistoryNamespaceGate {
    let value: OneDrivePolicyHistoryStore.Namespace
    private var opened: Bool
    private var waiters: [CheckedContinuation<OneDrivePolicyHistoryStore.Namespace?, Never>] = []
    private(set) var roots: [String] = []
    init(_ value: OneDrivePolicyHistoryStore.Namespace, opened: Bool = false) {
        self.value = value; self.opened = opened
    }
    func resolve(_ root: URL) async -> OneDrivePolicyHistoryStore.Namespace? {
        roots.append(root.absoluteString)
        guard root.absoluteString == value.rootURL else { return nil }
        if opened { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }
}

private actor ChangingBadgeNamespace {
    var value: OneDrivePolicyHistoryStore.Namespace?
    init(_ value: OneDrivePolicyHistoryStore.Namespace) { self.value = value }
    func clear() { value = nil }
}

private actor HistoryBadgeReader {
    private(set) var calls: [String] = []
    private var reply: CheckedContinuation<OneDriveBadgeObservation, Error>?
    func read(_ entry: TransferEntry) async throws -> OneDriveBadgeObservation {
        calls.append(entry.item.id)
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func finish(_ value: OneDriveBadgeObservation) {
        let pending = reply; reply = nil; pending?.resume(returning: value)
    }
    func fail(_ error: OneDriveRetentionError = .providerRejected) {
        let pending = reply; reply = nil; pending?.resume(throwing: error)
    }
}

private struct BadgeHistoryFixture {
    typealias Store = OneDrivePolicyHistoryStore
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("badge-history-\(UUID().uuidString)", isDirectory: true)
    // Only synthetic URL values are used here; no provider path is created or read.
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage/OneDrive-BadgeHistory-\(UUID().uuidString)", isDirectory: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var folder: URL { root.appendingPathComponent("fixture", isDirectory: true) }
    var oldDate: Date { now.addingTimeInterval(-100) }
    var namespace: Store.Namespace {
        .init(rootURL: root.absoluteString,
              rootIdentity: .init(device: 1, inode: 7, birthSeconds: 101, birthNanoseconds: 3),
              providerIdentifier: "com.microsoft.OneDrive", providerVersion: "synthetic-1",
              providerStamp: "synthetic-provider-stamp")
    }
    func store() -> Store {
        var limits = Store.Limits(); limits.writeDelay = 0
        let time = now
        return Store(directory: directory, limits: limits, wallNow: { time })
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func entry(_ number: UInt64, availability: FileAvailability = .availableLocally,
               nanos: Int64 = 1, inode: UInt64? = nil) -> TransferEntry {
        let name = "history-\(number).txt"
        let item = FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 256, modifiedAt: nil, kind: "Text",
            identity: .init(device: 1, inode: inode ?? number, birthSeconds: 102, birthNanoseconds: 5),
            availability: availability, isRegularFile: true,
            statusVersion: .init(size: 256, modificationSeconds: 1_999_999_800, modificationNanoseconds: nanos))
        return TransferEntry(source: .init(directoryURL: folder,
            directoryIdentity: .init(device: 1, inode: 11, birthSeconds: 101, birthNanoseconds: 4)), item: item)
    }
    func identity(_ entry: TransferEntry) throws -> Store.Identity {
        let key = try #require(OneDriveStatusKey(entry))
        #expect(key.account == namespace.rootURL)
        return .init(namespace: namespace, parentURL: key.parent, parentIdentity: key.parentIdentity,
                     fileURL: key.file, fileIdentity: key.identity, version: key.version)
    }
    func seed(_ entries: [TransferEntry], policy: OneDriveRetentionPolicy = .pinned) async throws {
        let store = store()
        let identities = try entries.map(identity)
        let prepared = await store.prepare(identities)
        for value in prepared {
            let current = try #require(value)
            store.enqueue(.init(policy: policy, confirmedAt: oldDate), ticket: current.ticket)
        }
        await store.flush()
    }
}

@MainActor
struct OneDriveBadgeHistoryTests {
    private func until(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    private func scope(_ fixture: BadgeHistoryFixture) -> OneDriveBadgeCache.Scope {
        .init(tab: UUID(), folder: fixture.folder, load: UUID(), searchGeneration: nil)
    }
    private func commit(_ entries: [TransferEntry], to cache: OneDriveBadgeCache, folder: URL) {
        cache.mergeListing(entries, startedAt: cache.beginListingSnapshot(for: folder))
    }
    private func verifyOperation(_ entry: TransferEntry, cache: OneDriveBadgeCache,
                                 policy: OneDriveRetentionPolicy = .unpinned) throws {
        let tokenValue = cache.beginOperation(for: entry)
        let token = try #require(tokenValue)
        let version = try #require(entry.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: entry, sampledVersion: version,
            policy: policy, isDataless: entry.item.availability == .onlineOnly))
        cache.finishOperation(token, verified: proof)
    }

    @Test func verifiedRootLossRetiresInMemoryAndDiskEvidenceAcrossWindows() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(101), reader = HistoryBadgeReader(), root = ChangingBadgeNamespace(f.namespace)
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { _ in await root.value })
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }, history: history) { try await reader.read($0) }
        let first = UUID(), second = UUID()
        defer { cache.remove(first); cache.remove(second); Task { await reader.fail() } }
        commit([row], to: cache, folder: f.folder)
        for owner in [first, second] { cache.update(owner, scope: scope(f), entries: [row], mergeEntries: false, changed: {}) }
        try #require(await until { await reader.calls.count == 1 })
        // A completed prepare ticket proves the initial namespace was installed.
        let key = try #require(OneDriveStatusKey(row))
        try #require(await until { history.ticket(for: key) != nil })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        await root.clear()
        cache.revalidateRoot(for: f.folder)
        try #require(await until { cache.namespaceEpoch(for: row) > 0 })
        #expect(cache.snapshot(for: row)?.policy == nil)
        #expect(cache.snapshot(for: row)?.confirmedAt == nil)
        #expect(cache.snapshot(for: row)?.availability == .unknown)
        #expect(cache.snapshot(for: row)?.freshness == .unknown)
    }

    @Test func pendingListingPreparesColdStoreWithoutProofAndFirstVisibleQueryPersists() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(21), store = f.store()
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: store, namespace: { await gate.resolve($0) })
        let wall = f.now
        // Keep normal admission timing; history readiness must not become a query prerequisite.
        let cache = OneDriveBadgeCache(now: { 100 }, wallNow: { wall }, history: history) {
            try await reader.read($0)
        }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        let start = cache.beginListingSnapshot(for: f.folder)
        try #require(await until { !(await gate.roots.isEmpty) })
        #expect(cache.snapshot(for: row) == nil)
        #expect(await reader.calls.isEmpty)

        // Simulate a directory read that is still pending. Do not call store.prepare
        // from the test: the cache's listing-start path must initialize it itself.
        await gate.release()
        try #require(await until { store.diagnostic.phase == .ready })
        let identifierURL = f.directory.appendingPathComponent("store-id-v1.json")
        #expect(FileManager.default.fileExists(atPath: identifierURL.path))
        #expect(cache.snapshot(for: row) == nil)
        #expect(await reader.calls.isEmpty)
        let warmLookups = await gate.roots.count

        var proofs: [String] = []
        cache.mergeListing([row], startedAt: start)
        cache.update(owner, scope: context, entries: [row], mergeEntries: false, changed: {},
                     observed: { entry, _ in proofs.append(entry.item.id) })
        try #require(await until { await reader.calls == [row.item.id] })
        #expect(await gate.roots.count > warmLookups, "A committed row revalidates its namespace after warm-up")
        #expect(cache.snapshot(for: row)?.policy == nil)
        #expect(cache.snapshot(for: row)?.confirmedAt == nil)
        #expect(proofs.isEmpty, "Preparation creates neither a display confirmation nor observed proof")
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        #expect(proofs == [row.item.id])
        let identity = try f.identity(row)
        try #require(await until {
            await store.flush()
            let diskReader = f.store()
            let prepared = await diskReader.prepare([identity])
            let hint = (prepared.first ?? nil)?.hint
            return hint?.policy == .pinned && hint?.confirmedAt == f.now
        })
        #expect(await reader.calls == [row.item.id], "The first query persisted without a retry or a seeded row")
    }

    @Test(arguments: [true, false], [OneDriveRetentionPolicy.pinned, OneDriveRetentionPolicy.none])
    func committedListingAndViewportMayArriveInEitherOrder(_ listingFirst: Bool,
                                                           _ policy: OneDriveRetentionPolicy) async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(31, availability: .onlineOnly)
        try await f.seed([row], policy: policy)
        let gate = HistoryNamespaceGate(f.namespace, opened: true), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }, wallNow: { wall }, history: history) {
            try await reader.read($0)
        }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs = 0
        if listingFirst {
            commit([row], to: cache, folder: f.folder)
            cache.update(owner, scope: context, entries: [row], mergeEntries: false, changed: {}, observed: { _, _ in proofs += 1 })
        } else {
            cache.update(owner, scope: context, entries: [row], changed: {}, observed: { _, _ in proofs += 1 })
            // A viewport-only seed is not an accepted directory/search listing.
            for _ in 0..<5 { await Task.yield() }
            #expect(await gate.roots.isEmpty)
            #expect(cache.snapshot(for: row)?.policy == nil)
            commit([row], to: cache, folder: f.folder)
        }
        try #require(await until { cache.snapshot(for: row)?.policy == policy })
        let restored = try #require(cache.snapshot(for: row))
        #expect(restored.freshness == .stale)
        #expect(restored.confirmedAt == f.oldDate)
        #expect(restored.availability == .onlineOnly, "Disk policy never supplies residency")
        #expect(restored.confirmationElapsed == nil, "A disk date is not a new monotonic confirmation")
        #expect(proofs == 0)
        #expect(await reader.calls.isEmpty)
        let requestedRoots = await gate.roots
        #expect(requestedRoots.allSatisfy { $0 == f.root.absoluteString })
    }

    @Test func delayedDiskResultUsesCurrentCommittedResidencyWithoutPublishingProof() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let local = f.entry(32), online = f.entry(32, availability: .onlineOnly)
        try await f.seed([local])
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }, wallNow: { wall }, history: history) {
            try await reader.read($0)
        }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs = 0
        commit([local], to: cache, folder: f.folder)
        cache.update(owner, scope: context, entries: [local], mergeEntries: false, changed: {}, observed: { _, _ in proofs += 1 })
        try #require(await until { !(await gate.roots.isEmpty) })
        commit([online], to: cache, folder: f.folder)
        cache.update(owner, scope: context, entries: [online], mergeEntries: false, changed: {}, observed: { _, _ in proofs += 1 })
        await gate.release()
        try #require(await until { cache.snapshot(for: online)?.policy == .pinned })
        #expect(cache.snapshot(for: online)?.availability == .onlineOnly)
        #expect(cache.snapshot(for: online)?.freshness == .stale)
        #expect(cache.snapshot(for: online)?.confirmedAt == f.oldDate)
        #expect(proofs == 0)
    }

    @Test(arguments: [false, true])
    func acceptedLiveQueryRetiresDelayedImportsEvenAfterEviction(_ evict: Bool) async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(41), sentinel = f.entry(42), other = f.entry(43)
        try await f.seed([row, sentinel])
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .zero, historyLimit: 1, workLimit: 1,
            now: { 100 }, wallNow: { wall }, history: history) { try await reader.read($0) }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofRows: [String] = []
        func show(_ rows: [TransferEntry]) {
            cache.update(owner, scope: context, entries: rows, selectedIDs: [row.item.id], mergeEntries: false,
                         changed: {}, observed: { entry, _ in proofRows.append(entry.item.id) })
        }
        commit([row, sentinel], to: cache, folder: f.folder); show([row, sentinel])
        try #require(await until {
            let requested = !(await gate.roots.isEmpty)
            let count = await reader.calls.count
            return requested && count == 1
        })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        if evict {
            show([sentinel, other])
            try verifyOperation(other, cache: cache)
            show([sentinel])
            #expect(cache.snapshot(for: row) == nil, "Exercise a real bounded-history eviction")
            show([row, sentinel])
            commit([row, sentinel], to: cache, folder: f.folder)
        }
        await gate.release()
        // This independent route's import proves the asynchronous disk work ran.
        try #require(await until { cache.snapshot(for: sentinel)?.policy == .pinned })
        if evict {
            #expect(cache.snapshot(for: row)?.policy == nil, "Eviction must not reset the session's route retirement")
            #expect(cache.snapshot(for: row)?.confirmedAt == nil)
        } else {
            #expect(cache.snapshot(for: row)?.policy == .unpinned)
            #expect(cache.snapshot(for: row)?.confirmedAt == f.now)
            #expect(cache.snapshot(for: row)?.freshness == .fresh)
        }
        #expect(proofRows == [row.item.id])
    }

    @Test func staleOperationGenerationAndEvictionCannotRestoreAnOldDiskPolicy() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(51), online = f.entry(51, availability: .onlineOnly), sentinel = f.entry(52), other = f.entry(53)
        try await f.seed([row, sentinel])
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), historyLimit: 1,
            now: { 100 }, wallNow: { wall }, history: history) { try await reader.read($0) }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs = 0
        func show(_ rows: [TransferEntry]) {
            cache.update(owner, scope: context, entries: rows, mergeEntries: false, changed: {}, observed: { _, _ in proofs += 1 })
        }
        commit([row, sentinel], to: cache, folder: f.folder); show([row, sentinel])
        try #require(await until { !(await gate.roots.isEmpty) })
        let tokenValue = cache.beginOperation(for: row)
        let token = try #require(tokenValue)
        commit([online], to: cache, folder: f.folder); show([online, sentinel])
        let version = try #require(row.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: row, sampledVersion: version, policy: .pinned, isDataless: false))
        cache.finishOperation(token, verified: proof)
        #expect(cache.snapshot(for: online)?.policy == nil, "Retired operation generation cannot seed facts")
        show([sentinel, other]); try verifyOperation(other, cache: cache); show([sentinel])
        #expect(cache.snapshot(for: online) == nil)
        show([online, sentinel]); commit([online, sentinel], to: cache, folder: f.folder)
        await gate.release()
        try #require(await until { cache.snapshot(for: sentinel)?.policy == .pinned })
        #expect(cache.snapshot(for: online)?.policy == nil)
        #expect(cache.snapshot(for: online)?.confirmedAt == nil)
        #expect(cache.snapshot(for: online)?.availability == .onlineOnly)
        #expect(proofs == 0)
    }

    @Test func acceptedReplacementRetiresImportsEvenIfTheOldFullKeyReturns() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let original = f.entry(61), replacement = f.entry(61, nanos: 2, inode: 161), sentinel = f.entry(62)
        try await f.seed([original, sentinel])
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }, wallNow: { wall }, history: history) {
            try await reader.read($0)
        }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs = 0
        func show(_ row: TransferEntry) {
            cache.update(owner, scope: context, entries: [row, sentinel], mergeEntries: false, changed: {}, observed: { _, _ in proofs += 1 })
        }
        commit([original, sentinel], to: cache, folder: f.folder); show(original)
        try #require(await until { !(await gate.roots.isEmpty) })
        commit([replacement], to: cache, folder: f.folder); show(replacement)
        #expect(cache.snapshot(for: original) == nil)
        commit([original], to: cache, folder: f.folder); show(original)
        await gate.release()
        try #require(await until { cache.snapshot(for: sentinel)?.policy == .pinned })
        #expect(cache.snapshot(for: original)?.policy == nil, "Exact-key equality does not undo a session route retirement")
        #expect(cache.snapshot(for: original)?.confirmedAt == nil)
        #expect(cache.snapshot(for: replacement) == nil)
        #expect(proofs == 0)
    }

    @Test func activeStaleTargetQuarantineRejectsDelayedDiskImport() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let row = f.entry(71), sentinel = f.entry(72)
        try await f.seed([row, sentinel])
        let gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: f.store(), namespace: { await gate.resolve($0) })
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .zero, workLimit: 1,
            now: { 100 }, wallNow: { wall }, history: history) { try await reader.read($0) }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs = 0
        commit([row, sentinel], to: cache, folder: f.folder)
        cache.update(owner, scope: context, entries: [row, sentinel], selectedIDs: [row.item.id], mergeEntries: false,
                     changed: {}, observed: { _, _ in proofs += 1 })
        try #require(await until {
            let requested = !(await gate.roots.isEmpty)
            let count = await reader.calls.count
            return requested && count == 1
        })
        await reader.fail(.staleTarget)
        try #require(await until { cache.snapshot(for: row)?.freshness == .stale })
        await gate.release()
        try #require(await until { cache.snapshot(for: sentinel)?.policy == .pinned })
        #expect(cache.snapshot(for: row)?.policy == nil)
        #expect(cache.snapshot(for: row)?.confirmedAt == nil)
        #expect(cache.snapshot(for: row)?.freshness == .stale)
        #expect(await reader.calls == [row.item.id])
        #expect(proofs == 0)
    }

    @Test func preparedHintDoesNotPublishProofAndSubsequentNativeQueryPersistsNonePolicy() async throws {
        let f = BadgeHistoryFixture(); defer { f.clean() }
        let target = f.entry(81), blocker = f.entry(82)
        try await f.seed([target])
        let store = f.store(), gate = HistoryNamespaceGate(f.namespace), reader = HistoryBadgeReader()
        let history = OneDriveBadgeHistory(store: store, namespace: { await gate.resolve($0) })
        var clock: TimeInterval = 100
        let wall = f.now
        let cache = OneDriveBadgeCache(debounce: .zero, workLimit: 1,
            now: { clock }, wallNow: { wall }, history: history) { try await reader.read($0) }
        let owner = UUID(), context = scope(f)
        defer { cache.remove(owner); Task { await gate.release(); await reader.fail() } }
        var proofs: [String] = []
        func show(selected: TransferEntry) {
            cache.update(owner, scope: context, entries: [target, blocker], selectedIDs: [selected.item.id], mergeEntries: false,
                         changed: {}, observed: { entry, _ in proofs.append(entry.item.id) })
        }
        commit([target, blocker], to: cache, folder: f.folder); show(selected: blocker)
        try #require(await until { await reader.calls == [blocker.item.id] })
        await gate.release()
        try #require(await until { cache.snapshot(for: target)?.policy == .pinned })
        #expect(cache.snapshot(for: target)?.freshness == .stale)
        #expect(cache.snapshot(for: target)?.confirmedAt == f.oldDate)
        #expect(proofs.isEmpty)
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { proofs == [blocker.item.id] })
        clock += 61; show(selected: target)
        try #require(await until { await reader.calls == [blocker.item.id, target.item.id] })
        await reader.finish(.init(policy: .none, isDataless: false))
        try #require(await until { cache.snapshot(for: target)?.freshness == .fresh })
        #expect(cache.snapshot(for: target)?.policy == OneDriveRetentionPolicy.none)
        #expect(cache.snapshot(for: target)?.confirmedAt == f.now)
        #expect(proofs == [blocker.item.id, target.item.id])
        let identity = try f.identity(target)
        try #require(await until {
            await store.flush()
            let diskReader = f.store()
            let prepared = await diskReader.prepare([identity])
            let hint = (prepared.first ?? nil)?.hint
            return hint?.policy == OneDriveRetentionPolicy.none && hint?.confirmedAt == f.now
        })
    }
}
