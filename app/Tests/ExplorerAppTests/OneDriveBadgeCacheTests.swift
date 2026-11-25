@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor BadgeReader {
    private(set) var calls: [String] = []
    private var reply: CheckedContinuation<OneDriveBadgeObservation, Error>?
    func read(_ entry: TransferEntry) async throws -> OneDriveBadgeObservation {
        calls.append(entry.item.id)
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func finish(_ value: OneDriveBadgeObservation) {
        let next = reply
        reply = nil
        next?.resume(returning: value)
    }
    func fail(_ error: OneDriveRetentionError = .providerRejected) { failRead(error) }
    func failRead(_ error: any Error) {
        let next = reply
        reply = nil
        next?.resume(throwing: error)
    }
}

private actor RecoveryParentGate {
    private var reply: CheckedContinuation<DirectorySnapshot, Never>?
    private(set) var reads = 0
    func sample() async -> DirectorySnapshot {
        reads += 1
        return await withCheckedContinuation { reply = $0 }
    }
    func finish(_ result: DirectorySnapshot) {
        let pending = reply; reply = nil; pending?.resume(returning: result)
    }
}

private actor ImmediateBadgeReader {
    private(set) var calls: [String] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func read(_ entry: TransferEntry) throws -> OneDriveBadgeObservation {
        calls.append(entry.item.id)
        if fails { throw OneDriveRetentionError.providerRejected }
        return .init(policy: .pinned, isDataless: false)
    }
}

@MainActor
struct OneDriveBadgeCacheTests {
    private let folder = URL(fileURLWithPath: "/Test/OneDrive/")
    private func entry(_ n: Int, inode: Int? = nil, availability: FileAvailability = .availableLocally,
                       modificationNanoseconds: Int64 = 1) -> TransferEntry {
        let name = "file-\(n)"
        let parent = LocalFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 1)
        let item = FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 200, modifiedAt: nil, kind: "Text",
            identity: .init(device: 1, inode: UInt64(inode ?? n), birthSeconds: 1, birthNanoseconds: 1),
            availability: availability, isRegularFile: true,
            statusVersion: .init(size: 200, modificationSeconds: 1, modificationNanoseconds: modificationNanoseconds))
        return TransferEntry(source: .init(directoryURL: folder, directoryIdentity: parent), item: item)
    }
    private func until(_ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func confirmPinned(_ row: TransferEntry, in cache: OneDriveBadgeCache) throws {
        let tokenValue = cache.beginOperation(for: row)
        let token = try #require(tokenValue)
        let versionValue = row.item.statusVersion
        let version = try #require(versionValue)
        let proofValue = OneDriveVerifiedStatus(entry: row, sampledVersion: version,
                                                policy: .pinned, isDataless: false)
        let proof = try #require(proofValue)
        cache.finishOperation(token, verified: proof)
    }

    @Test func successfulObservationEventsIncludeEqualRefreshButExcludeFailedRefresh() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(801), tab = UUID()
        var clock: TimeInterval = 100
        var checkedAt = Date(timeIntervalSince1970: 1_000)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }, wallNow: { checkedAt }) { try await reader.read($0) }
        let value = OneDriveBadgeObservation(policy: .unpinned, isDataless: true)
        var events: [OneDriveBadgeObservation] = []
        var metadataUpdates: [Set<String>] = []
        func demand() {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                entries: [row], changedIDs: { metadataUpdates.append($0) }, observed: { received, result in
                    #expect(received.item.identity == row.item.identity)
                    events.append(result)
                })
        }
        demand()
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(value)
        try #require(await until { events.count == 1 })
        try #require(await until { metadataUpdates.count == 1 })
        clock += 301; checkedAt.addTimeInterval(301); demand()
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(value)
        try #require(await until { events.count == 2 })
        try await Task.sleep(for: .milliseconds(40))
        #expect(metadataUpdates == [[row.item.id], [row.item.id]],
                "Equal successful confirmation must refresh only this row's check-time help; callbacks are not repaint measurements")
        #expect(cache.snapshot(for: row)?.confirmedAt == checkedAt)
        clock += 301; demand()
        try #require(await until { await reader.calls.count == 3 })
        await reader.fail()
        try await Task.sleep(for: .milliseconds(40))
        #expect(events == [value, value])
        #expect(cache.observation(for: row) == value, "Failure may preserve display but cannot emit proof")
        cache.remove(owner)
    }

    @Test func successfulObservationUsesCurrentViewportAndRejectsPreActionQuery() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(802)
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        var oldEvents = 0, currentEvents = 0
        cache.update(owner, scope: scope, entries: [row], changed: {}, observed: { _, _ in oldEvents += 1 })
        try #require(await until { await reader.calls.count == 1 })
        cache.retentionChanged(target: .init(row), isBusy: true)
        cache.update(owner, scope: .init(tab: scope.tab, folder: folder, load: UUID(), searchGeneration: nil),
            entries: [row], changed: {}, observed: { _, _ in currentEvents += 1 })
        await reader.finish(.init(policy: .unpinned, isDataless: true))
        cache.retentionChanged(target: .init(row), isBusy: false)
        try #require(await until { await reader.calls.count == 2 })
        #expect(oldEvents == 0 && currentEvents == 0)
        await reader.finish(.init(policy: .unpinned, isDataless: true))
        try #require(await until { currentEvents == 1 })
        #expect(oldEvents == 0)
        cache.remove(owner)
    }
    @Test func currentCallbackOwnsFreshEventAndReentrantActionPreventsCacheMerge() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(803)
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        var oldEvents = 0, newEvents = 0
        cache.update(owner, scope: scope, entries: [row], changed: {}, observed: { _, _ in oldEvents += 1 })
        try #require(await until { await reader.calls.count == 1 })
        // Re-registering unchanged demand still transfers callback ownership.
        cache.update(owner, scope: scope, entries: [row], changed: {}, observed: { _, _ in
            newEvents += 1
            #expect(cache.observation(for: row) == nil, "The event precedes the display merge")
            cache.retentionChanged(target: .init(row), isBusy: true)
        })
        await reader.finish(.init(policy: .unpinned, isDataless: true))
        try #require(await until { newEvents == 1 })
        #expect(oldEvents == 0 && cache.observation(for: row) == nil)
        cache.remove(owner)
    }
    @Test func sharedDemandReadsOnceAndDropsReplacedIdentity() async throws {
        let reader = BadgeReader(), first = UUID(), second = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let a = entry(3), replacement = entry(3, inode: 30)
        var updates = 0
        cache.update(first, scope: scope, entries: [a, a], changed: {})
        cache.update(second, scope: scope, entries: [a], changed: { updates += 1 })
        try #require(await until { await reader.calls.count == 1 })
        cache.remove(first)
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: a) == pinned })
        #expect(updates == 1)
        #expect(cache.observation(for: replacement) == nil)
        cache.update(second, scope: scope, entries: [replacement], changed: {})
        try #require(await until { await reader.calls.count == 2 })
        cache.remove(second)
        await reader.finish(pinned)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(cache.observation(for: replacement) == nil)
    }
    @Test func foregroundMutationDropsLateReadAndPrioritizesFreshPolicy() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let row = entry(10)
        let many = (10..<90).map { entry($0) }
        cache.update(mount, scope: scope, entries: many, changed: {})
        try #require(await until { await reader.calls.count == 1 })
        let target = PhysicalContentTarget(row)
        cache.retentionChanged(target: target, isBusy: true)
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls == [row.item.id])
        #expect(cache.observation(for: row) == nil)
        cache.update(mount, scope: scope, entries: [row], changed: {})
        cache.retentionChanged(target: target, isBusy: false)
        try #require(await until { await reader.calls.count == 2 })
        let unpinned = OneDriveBadgeObservation(policy: .unpinned, isDataless: false)
        await reader.finish(unpinned)
        try #require(await until { cache.observation(for: row) == unpinned })
        cache.remove(mount)
    }
    @Test func viewportChangesBeforeDebounceOnlyQueryTheFinalVisibleRows() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .milliseconds(30)) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let folderRows = (2..<10_002).map { entry($0) }
        for offset in stride(from: 0, to: 10_000, by: 100) {
            cache.update(mount, scope: scope, entries: Array(folderRows[offset..<(offset + 20)]), changed: {})
        }
        #expect(await reader.calls.isEmpty)
        try #require(await until { await reader.calls.count == 1 })
        #expect(await reader.calls == [folderRows[9_900].item.id])
        cache.remove(mount)
        await reader.finish(.init(policy: .unpinned, isDataless: false))
    }

    @Test func reloadAndExpiryKeepLastBadgeWhileRefreshing() async throws {
        let reader = BadgeReader(), mount = UUID(), tab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }, freshnessNow: { clock }) { try await reader.read($0) }
        let row = entry(5), pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        func refresh() {
            cache.update(mount, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                         entries: [row], changed: {})
        }
        refresh()
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: row) == pinned })
        let confirmedAt = try #require(cache.snapshot(for: row)?.confirmedAt)
        #expect(cache.snapshot(for: row)?.freshness == .fresh)
        refresh()
        #expect(cache.observation(for: row) == pinned)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls.count == 1)
        clock += 301
        #expect(cache.observation(for: row) == pinned)
        refresh()
        try #require(await until { await reader.calls.count == 2 })
        #expect(cache.observation(for: row) == pinned)
        #expect(cache.snapshot(for: row)?.freshness == .fresh,
            "The 300-second recheck eligibility is not the age-staleness deadline")
        #expect(cache.snapshot(for: row)?.confirmedAt == confirmedAt)
        await reader.fail()
        try #require(await until { cache.snapshot(for: row)?.freshness == .unavailable })
        #expect(cache.observation(for: row) == pinned)
        #expect(cache.snapshot(for: row)?.confirmedAt == confirmedAt,
            "Failure preserves the last confirmation time rather than inventing a new confirmation")
        cache.remove(mount)
        await reader.finish(pinned)
    }

    @Test func refreshingOneWindowDoesNotInvalidateAnotherWindowsBadge() async throws {
        let reader = BadgeReader(), first = UUID(), second = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let row = entry(11), pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        var secondUpdates = 0
        cache.update(first, scope: scope, entries: [row], changed: {})
        cache.update(second, scope: scope, entries: [row], changed: { secondUpdates += 1 })
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: row) == pinned })
        cache.update(first, scope: .init(tab: scope.tab, folder: folder, load: UUID(), searchGeneration: nil), entries: [], changed: {})
        #expect(cache.observation(for: row) == pinned)
        #expect(secondUpdates == 1)
        cache.update(first, scope: .init(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil), entries: [row], changed: {})
        #expect(cache.observation(for: row) == pinned)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls.count == 1)
        cache.remove(first); cache.remove(second)
        await reader.finish(pinned)
    }

    @Test func observedResidencyRoundTripRetainsPolicyOnlyAsStale() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let local = entry(12), online = entry(12, availability: .onlineOnly)
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        cache.update(mount, scope: scope, entries: [local], changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: local) == pinned })
        let confirmedAt = try #require(cache.snapshot(for: local)?.confirmedAt)
        cache.update(mount, scope: scope, entries: [online], changed: {})
        #expect(cache.observation(for: online) == .init(policy: .pinned, isDataless: true))
        #expect(cache.snapshot(for: online)?.freshness == .stale)
        #expect(cache.snapshot(for: online)?.confirmedAt == confirmedAt)
        cache.update(mount, scope: scope, entries: [local], changed: {})
        #expect(cache.observation(for: local) == pinned)
        #expect(cache.snapshot(for: local)?.freshness == .stale,
            "Returning to the old residency must not resurrect its old fresh-policy verdict")
        #expect(cache.snapshot(for: local)?.confirmedAt == confirmedAt)
        cache.remove(mount)
        await reader.finish(pinned)
    }

    @Test func hiddenActionInvalidatesOnlyTheMatchingHistory() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let target = entry(13), other = entry(14), pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        cache.update(mount, scope: scope, entries: [target, other], changed: {})
        for (index, row) in [target, other].enumerated() {
            try #require(await until { await reader.calls.count == index + 1 })
            await reader.finish(pinned)
            try #require(await until { cache.observation(for: row) == pinned })
        }
        cache.remove(mount)
        cache.retentionChanged(target: PhysicalContentTarget(target), isBusy: true)
        #expect(cache.observation(for: target) == pinned)
        #expect(cache.snapshot(for: target)?.freshness == .stale)
        #expect(cache.observation(for: other) == pinned)
        #expect(cache.snapshot(for: other)?.freshness == .fresh)
        cache.retentionChanged(target: PhysicalContentTarget(target), isBusy: false)
        #expect(cache.observation(for: other) == pinned)
    }

    @Test func nativeQueryBudgetSurvivesReloadAndScrolling() async throws {
        let reader = ImmediateBadgeReader(), mount = UUID(), tab = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        let rows = (20..<220).map { entry($0) }
        func demand(_ items: [TransferEntry]) {
            cache.update(mount, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil), entries: items, changed: {})
        }
        demand(rows)
        try #require(await until { await reader.calls.count >= 28 })
        demand(Array(rows.reversed()))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await reader.calls.count == 28, "Ordinary work preserves four tokens across reload/scroll churn")
        cache.remove(mount)
    }

    @Test func repeatedItemRejectionsLeaveOtherFilesEligible() async throws {
        let reader = BadgeReader(), owner = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let rejected = entry(30), healthy = entry(31)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(owner); Task { await reader.fail() } }
        func show(_ rows: [TransferEntry]) { cache.update(owner, scope: scope, entries: rows, changed: {}) }
        show([rejected])
        // Each retry has an exponential route-local floor (60 s, 120 s, 240 s...)
        // and only this target pays its failure delay.
        for (index, wait) in [60, 120, 240, 480, 900, 900].enumerated() {
            try #require(await until { await reader.calls.count == index + 1 })
            await reader.failRead(OneDriveBadgeReadError.itemRejected)
            try #require(await until { cache.snapshot(for: rejected)?.failureReason == .itemRejected })
            try await Task.sleep(for: .milliseconds(30))
            clock += Double(wait - 1); show([rejected])
            try await Task.sleep(for: .milliseconds(30))
            #expect(await reader.calls.count == index + 1)
            clock += 1; show([rejected])
        }
        try #require(await until { await reader.calls.count == 7 })
        show([rejected, healthy])
        await reader.failRead(OneDriveBadgeReadError.itemRejected)
        try #require(await until { await reader.calls.last == healthy.item.id })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: healthy)?.freshness == .fresh })
    }

    @Test func queryBudgetRotatesFairlyAcrossWindowsAndRows() async throws {
        let reader = ImmediateBadgeReader(), first = UUID(), second = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, workLimit: 4, now: { clock }) { try await reader.read($0) }
        let firstRows = (300..<310).map { entry($0) }, secondRows = (400..<410).map { entry($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        cache.update(first, scope: scope, entries: firstRows, changed: {})
        cache.update(second, scope: scope, entries: secondRows, changed: {})
        try #require(await until { await reader.calls.count == 4 })
        let firstPass = await reader.calls
        #expect(firstPass.filter { firstRows.map(\.item.id).contains($0) }.count == 2)
        #expect(firstPass.filter { secondRows.map(\.item.id).contains($0) }.count == 2)
        clock += 61
        cache.update(first, scope: .init(tab: scope.tab, folder: folder, load: UUID(), searchGeneration: nil),
                     entries: firstRows, changed: {})
        try #require(await until { await reader.calls.count == 8 })
        try? await Task.sleep(for: .milliseconds(40))
        let calls = await reader.calls
        #expect(calls.count == 8 && Set(calls).count == 8)
        #expect(calls.filter { firstRows.map(\.item.id).contains($0) }.count == 4)
        #expect(calls.filter { secondRows.map(\.item.id).contains($0) }.count == 4)
        cache.remove(first); cache.remove(second)
    }

    @Test func accountAndInstallationFailuresHaveDifferentScopes() async throws {
        let reader = BadgeReader(), owner = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let a = entry(510), sibling = entry(511), other = entry(512)
        let otherFolder = URL(fileURLWithPath: "/synthetic/another-account", isDirectory: true)
        let b = TransferEntry(source: .init(directoryURL: otherFolder, directoryIdentity: other.source.directoryIdentity),
                              item: other.item)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(owner); Task { await reader.fail() } }
        func show(_ rows: [TransferEntry]) { cache.update(owner, scope: scope, entries: rows, changed: {}) }
        show([a])
        try #require(await until { await reader.calls.count == 1 })
        await reader.failRead(OneDriveBadgeReadError.accountUnavailable)
        try #require(await until { cache.snapshot(for: a)?.failureReason == .accountUnavailable })
        show([a, sibling, b])
        try #require(await until { await reader.calls.count == 2 })
        #expect(await reader.calls.last == b.item.id)
        await reader.failRead(OneDriveBadgeReadError.installationUntrusted)
        try #require(await until { cache.snapshot(for: b)?.failureReason == .installationUntrusted })
        clock += 59; show([a, sibling, b])
        try await Task.sleep(for: .milliseconds(60))
        #expect(await reader.calls.count == 2)
        clock += 1; show([a, sibling, b])
        try #require(await until { await reader.calls.count == 3 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { await reader.calls.count == 4 })
    }

    @Test func latePreTransitionQueryCannotReinstateRetiredPolicy() async throws {
        let reader = BadgeReader(), mount = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let local = entry(600), online = entry(600, availability: .onlineOnly)
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [local], changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: local) == pinned })
        clock += 301
        cache.update(mount, scope: .init(tab: scope.tab, folder: folder, load: UUID(), searchGeneration: nil),
                     entries: [local], changed: {})
        try #require(await until { await reader.calls.count == 2 })
        cache.update(mount, scope: scope, entries: [online], changed: {})
        cache.update(mount, scope: scope, entries: [local], changed: {})
        await reader.finish(pinned)
        try #require(await until { await reader.calls.count == 3 })
        #expect(cache.observation(for: local) == pinned)
        #expect(cache.snapshot(for: local)?.freshness == .stale,
            "A cancelled pre-transition completion cannot renew the retained policy")
        let fresh = OneDriveBadgeObservation(policy: .unpinned, isDataless: false)
        await reader.finish(fresh)
        try #require(await until { cache.observation(for: local) == fresh })
        #expect(cache.snapshot(for: local)?.freshness == .fresh)
        cache.remove(mount)
    }

    @Test func staleBadgeSurvivesUnmountAndNewWindowWhileFreshReadRuns() async throws {
        let reader = BadgeReader(), first = UUID(), second = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let row = entry(700), pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        cache.update(first, scope: scope, entries: [row], changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.observation(for: row) == pinned })
        cache.remove(first); clock += 301
        cache.update(second, scope: .init(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil),
                     entries: [row], changed: {})
        #expect(cache.observation(for: row) == pinned)
        try #require(await until { await reader.calls.count == 2 })
        #expect(cache.observation(for: row) == pinned)
        cache.remove(second)
        await reader.finish(pinned)
    }

    @Test func sleepAgesPolicyAtThirtyMinutesWithoutAdvancingDispatchTime() async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(710), tab = UUID()
        var elapsed: TimeInterval = 100
        let confirmedAt = Date(timeIntervalSince1970: 1_000)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }, freshnessNow: { elapsed },
            wallNow: { confirmedAt }) { try await reader.read($0) }
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        func demand() {
            cache.update(mount, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                entries: [row], changed: {})
        }
        demand()
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        #expect(cache.snapshot(for: row)?.confirmedAt == confirmedAt)
        #expect(cache.snapshot(for: row)?.staleAfter == 1_900)

        elapsed = 1_899
        demand()
        #expect(cache.snapshot(for: row)?.freshness == .fresh,
            "Refresh eligibility and time spent asleep must not shorten the 30-minute age threshold")
        elapsed = 1_900
        demand()
        #expect(cache.snapshot(for: row)?.freshness == .stale)
        #expect(cache.observation(for: row) == pinned)
        #expect(cache.snapshot(for: row)?.confirmedAt == confirmedAt)
        #expect(await reader.calls.count == 1, "Continuous age advances independently of provider dispatch uptime")
        cache.remove(mount)
    }

    @Test func increasedVisibleDemandExtendsAgeDeadlineWithoutShorteningOrRevival() async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(720), tab = UUID()
        var elapsed: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }, freshnessNow: { elapsed }) {
            try await reader.read($0)
        }
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        func demand(_ rows: [TransferEntry]) {
            cache.update(mount, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                entries: rows, changed: {})
        }
        demand([row])
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(pinned)
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        let confirmedAt = cache.snapshot(for: row)?.confirmedAt
        #expect(cache.snapshot(for: row)?.staleAfter == 1_900)

        // 401 visible files require 51 routine-budget minutes plus five minutes.
        demand([row] + (1_000..<1_400).map { entry($0) })
        #expect(cache.snapshot(for: row)?.staleAfter == 3_460)
        demand([row])
        #expect(cache.snapshot(for: row)?.staleAfter == 3_460,
            "Reducing demand cannot shorten this confirmation's retained deadline")
        elapsed = 3_460
        demand([row])
        #expect(cache.snapshot(for: row)?.freshness == .stale)
        demand([row] + (2_000..<2_800).map { entry($0) })
        #expect(cache.snapshot(for: row)?.freshness == .stale,
            "A larger allowance cannot make already stale evidence fresh again")
        #expect(cache.snapshot(for: row)?.confirmedAt == confirmedAt)
        cache.remove(mount)
    }

    @Test func sameInodeNanosecondVersionChangeCannotInheritPolicy() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let original = entry(730, modificationNanoseconds: 1)
        let changed = entry(730, modificationNanoseconds: 2)
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        #expect(original.item.identity == changed.item.identity && original.item.id == changed.item.id)
        #expect(original.item.modifiedAt == changed.item.modifiedAt,
            "This fixture changes only the raw stamp, not a rounded Foundation date")
        cache.update(mount, scope: scope, entries: [original], changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: original)?.freshness == .fresh })
        cache.update(mount, scope: scope, entries: [changed], changed: {})
        #expect(cache.observation(for: changed) == nil)
        #expect(cache.snapshot(for: changed)?.policy == nil)
        #expect(cache.snapshot(for: changed)?.confirmedAt == nil)
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: changed)?.freshness == .fresh })
        #expect(cache.snapshot(for: changed)?.policy == .unpinned)
        #expect(cache.observation(for: original) == nil)
        cache.remove(mount)
    }

    @Test func olderListingAndQueryCannotReplaceNewerVerifiedActionResidency() async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(740)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        var freshEvents = 0
        cache.update(mount, scope: scope, entries: [row], changed: {}, observed: { _, _ in freshEvents += 1 })
        try #require(await until { await reader.calls.count == 1 })
        let oldListing = cache.beginListingSnapshot(for: folder)
        let optionalToken: OneDriveStatusRequestToken? = cache.beginOperation(for: row)
        let token = try #require(optionalToken)
        let version = try #require(row.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: row,
            sampledVersion: version, policy: .unpinned, isDataless: true))
        cache.finishOperation(token, verified: proof)

        #expect(cache.snapshot(for: row)?.availability == .onlineOnly)
        #expect(cache.snapshot(for: row)?.policy == .unpinned)
        #expect(cache.snapshot(for: row)?.freshness == .fresh)
        #expect(freshEvents == 0, "Admitting a command result is not a new passive-proof event")
        cache.mergeListing([row], startedAt: oldListing)
        #expect(cache.snapshot(for: row)?.availability == .onlineOnly,
            "A directory read started before action admission cannot restore its old resident sample")

        await reader.finish(.init(policy: .pinned, isDataless: false))
        try await Task.sleep(for: .milliseconds(40))
        #expect(cache.snapshot(for: row)?.availability == .onlineOnly)
        #expect(cache.snapshot(for: row)?.policy == .unpinned)
        #expect(cache.snapshot(for: row)?.freshness == .fresh)
        #expect(freshEvents == 0, "The cancelled pre-action read cannot certify deferred completion")
        #expect(await reader.calls.count == 1, "Verified action display needs no redundant provider read")

        let newListing = cache.beginListingSnapshot(for: folder)
        cache.mergeListing([row], startedAt: newListing)
        #expect(cache.snapshot(for: row)?.availability == .availableLocally,
            "A genuinely later listing still reconciles a new residency change")
        #expect(cache.snapshot(for: row)?.policy == .unpinned)
        #expect(cache.snapshot(for: row)?.freshness == .stale)
        cache.remove(mount)
        await reader.finish(.init(policy: .unpinned, isDataless: false))
    }

    @Test func unchangedFolderHintsPreserveConfirmedSiblingsWhileInactive() async throws {
        let reader = ImmediateBadgeReader(), owner = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner) }
        let rows = (750..<766).map { entry($0) }
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                     entries: rows, changed: {})
        try #require(await until { rows.allSatisfy { cache.snapshot(for: $0)?.freshness == .fresh } })
        let confirmed = rows.map { cache.snapshot(for: $0) }
        cache.setActive(false)
        for _ in 0..<3 {
            clock += 31
            cache.hint(folder: folder, reason: .directory)
            cache.hint(folder: folder, reason: .activation)
            try await Task.sleep(for: .milliseconds(200))
            #expect(rows.map { cache.snapshot(for: $0) } == confirmed)
        }
        #expect(await reader.calls.count == rows.count)
    }

    @Test func namedPolicyHintCoalescesOneCatchUpWithoutCancellingAValidRead() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(755)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        var events = 0
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                     entries: [row], changed: {}, observed: { _, _ in events += 1 })
        try #require(await until { await reader.calls.count == 1 })
        let generation = cache.snapshot(for: row)?.generation
        for _ in 0..<12 { cache.hint(folder: folder, reason: .directory, childNames: [row.item.name]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(cache.snapshot(for: row)?.generation == generation)
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { await reader.calls.count == 2 })
        #expect(events == 1)
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.policy == .pinned })
        #expect(events == 2)
        #expect(await reader.calls.count == 2)
    }

    @Test func eventDuringHintStartedReadSurvivesGateAndOnlySchedulesOneCatchUp() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(759)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                     entries: [row], changed: {})
        try #require(await until { await reader.calls.count == 1 })
        let result = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        await reader.finish(result)
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        clock += 3
        cache.hint(folder: folder, reason: .directory, childNames: [row.item.name])
        try #require(await until { await reader.calls.count == 2 })
        // The second event arrives within the named gate. Complete the native read
        // before the 150 ms coalescer wakes, then send another event during its catch-up.
        clock += 1
        cache.hint(folder: folder, reason: .directory, childNames: [row.item.name])
        await reader.finish(result)
        try #require(await until { await reader.calls.count == 3 })
        cache.hint(folder: folder, reason: .activation)
        cache.hint(folder: folder, reason: .directory, childNames: [row.item.name])
        await reader.finish(result)
        try await Task.sleep(for: .milliseconds(230))
        #expect(await reader.calls.count == 3)
        #expect(cache.snapshot(for: row)?.freshness == .fresh)
    }

    @Test func activationSuppressionDoesNotDiscardCoalescedNamedChange() async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(758), neighbor = entry(759)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                     entries: [row, neighbor], changed: {})
        let result = OneDriveBadgeObservation(policy: .unpinned, isDataless: false)
        for count in 1...2 {
            try #require(await until { await reader.calls.count == count })
            await reader.finish(result)
        }
        try #require(await until { cache.snapshot(for: neighbor)?.freshness == .fresh })
        clock += 1
        cache.hint(folder: folder, reason: .activation)
        cache.hint(folder: folder, reason: .directory, childNames: [row.item.name])
        try #require(await until { await reader.calls.count == 3 })
        #expect(await reader.calls.last == row.item.id)
        #expect(cache.snapshot(for: neighbor)?.freshness == .fresh)
    }

    @Test func failedQueryCannotRejectAnOlderStartedListingResidencySample() async throws {
        let reader = BadgeReader(), mount = UUID(), local = entry(760)
        let online = entry(760, availability: .onlineOnly)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [local], changed: {})
        let listingStarted = cache.beginListingSnapshot(for: folder)
        try #require(await until { await reader.calls.count == 1 })
        await reader.fail()
        try #require(await until { cache.snapshot(for: local)?.freshness == .unavailable })

        cache.mergeListing([online], startedAt: listingStarted)
        #expect(cache.snapshot(for: online)?.availability == .onlineOnly,
            "Failed provider work supplies no newer residency evidence that can veto a directory sample")
        #expect(cache.snapshot(for: online)?.policy == nil)
        #expect(cache.snapshot(for: online)?.confirmedAt == nil)
        #expect(cache.observation(for: online) == nil, "A listing still cannot invent pin policy")
    }

    @Test func staleTargetsDoNotTripTheProviderBreakerForUnrelatedFiles() async throws {
        let reader = BadgeReader(), mount = UUID(), healthy = entry(770), next = entry(774)
        let stale = (771...773).map { entry($0) }
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        var proofs = 0
        cache.update(mount, scope: scope, entries: [healthy], changed: {}, observed: { _, _ in proofs += 1 })
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: healthy)?.freshness == .fresh })
        let checkedAt = cache.snapshot(for: healthy)?.confirmedAt
        cache.update(mount, scope: scope, entries: stale + [healthy, next], changed: {}, observed: { _, _ in proofs += 1 })
        for (index, row) in stale.enumerated() {
            try #require(await until { await reader.calls.count == index + 2 })
            await reader.fail(.staleTarget)
            try #require(await until { cache.snapshot(for: row)?.freshness != .unknown })
            #expect(cache.snapshot(for: row)?.freshness == .stale)
            #expect(cache.snapshot(for: row)?.confirmedAt == nil)
        }
        #expect(cache.snapshot(for: healthy)?.freshness == .fresh,
                "Three stale captured targets are not evidence that the provider is unavailable")
        #expect(cache.snapshot(for: healthy)?.confirmedAt == checkedAt)
        #expect(proofs == 1, "Stale-target refusals never supply a successful observation")
        let continued = await until { await reader.calls.count == 5 }
        #expect(continued, "Unrelated healthy work must not enter the provider failure pause")
        if continued {
            await reader.finish(.init(policy: .unpinned, isDataless: false))
            try #require(await until { cache.snapshot(for: next)?.freshness == .fresh })
        }
    }

    @Test func closingDirectoryBeforeItsRelistHandsTheUnusedRequestToTheOtherWindow() async throws {
        let reader = BadgeReader(), a = UUID(), b = UUID(), row = entry(773)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        var assigned: [UUID] = []
        defer { cache.remove(a); cache.remove(b); Task { await reader.fail() } }
        for owner in [a, b] {
            cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                         entries: [row], recover: { _ in assigned.append(owner) }, changedIDs: { _ in })
        }
        try #require(await until { await reader.calls.count == 1 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { assigned.count == 1 })
        let original = try #require(assigned.first)
        cache.remove(original)
        #expect(assigned.count == 2)
        let remaining = original == a ? b : a
        #expect(assigned.last == remaining)
        let load = UUID()
        let start = cache.beginListingSnapshot(for: folder)
        cache.beginDirectoryRecovery(store: remaining, folder: folder, load: load, startedAt: start)
        cache.mergeDirectoryListing([row], roster: [row.item], parent: row.source, startedAt: start)
        cache.endDirectoryRecovery(load)
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        #expect(assigned.count == 2)
    }

    @Test func oneDirectoryRecoverySharesAnAcceptedSearchSampleButNeverAdoptsAReplacement() async throws {
        let reader = BadgeReader(), folderOwner = UUID(), searchOwner = UUID()
        let old = entry(772), replacement = entry(772, inode: 9772)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(folderOwner); cache.remove(searchOwner); Task { await reader.fail() } }
        let directory = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        let search = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: UUID())
        var folderReads = 0, searchReads = 0, received: [FileItem?] = []
        cache.update(folderOwner, scope: directory, entries: [old], recover: { _ in folderReads += 1 }, changedIDs: { _ in })
        cache.update(searchOwner, scope: search, entries: [old], recover: { _ in searchReads += 1 },
                     recoveredSearchHit: { _, item in received.append(item); return true }, changedIDs: { _ in })
        try #require(await until { await reader.calls.count == 1 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { folderReads == 1 })
        let listing = cache.beginListingSnapshot(for: folder)
        cache.mergeDirectoryListing([replacement], roster: [replacement.item], parent: old.source, startedAt: listing)
        #expect(searchReads == 0)
        #expect(received.count == 1 && received[0] == nil)
        #expect(cache.snapshot(for: old) == nil)
        #expect(cache.snapshot(for: replacement)?.policy == nil)
    }

    @Test func rejectedSearchRecoveryRetriesAfterCooldownAndSurvivesLossOfIssuingWindow() async throws {
        let reader = BadgeReader(), parent = RecoveryParentGate(), first = UUID(), second = UUID(), row = entry(779)
        var clock: TimeInterval = 100, blocked = true, firstAccepted = 0, secondAccepted = 0
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: UUID())
        defer { cache.remove(first); cache.remove(second); Task { await reader.fail() } }
        func mount(_ owner: UUID) {
            cache.update(owner, scope: scope, entries: [row], mergeEntries: false, searchReader: { _ in
                if blocked { return nil }
                return { await parent.sample() }
            }, recoveredSearchHit: { _, item in
                guard item?.identity == row.item.identity else { return false }
                if owner == first { firstAccepted += 1 } else { secondAccepted += 1 }
                return true
            }, changedIDs: { _ in })
        }
        mount(first)
        try #require(await until { await reader.calls.count == 1 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { cache.snapshot(for: row)?.failureReason == .itemUnavailable })
        #expect(await parent.reads == 0)
        blocked = false
        clock += 59; mount(first)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.calls.count == 1)
        clock += 1; mount(first)
        try #require(await until { await reader.calls.count == 2 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { await parent.reads == 1 })
        mount(second); cache.remove(first)
        await parent.finish(.init(items: [row.item], directoryIdentity: row.source.directoryIdentity))
        try #require(await until { await reader.calls.count == 3 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        #expect(firstAccepted == 0 && secondAccepted == 1)
        #expect(await parent.reads == 1)
    }

    @Test func sameKeyRecoveryListsOnceAcrossWindowsAndRequiresAnExternalReadAfterBackoff() async throws {
        let reader = BadgeReader(), first = UUID(), second = UUID(), row = entry(776)
        var clock: TimeInterval = 100, recoveries = 0
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(first); cache.remove(second); Task { await reader.fail() } }
        for owner in [first, second] {
            cache.update(owner, scope: scope, entries: [row], recover: { _ in recoveries += 1 }, changedIDs: { _ in })
        }
        let older = cache.beginListingSnapshot(for: folder)
        try #require(await until { await reader.calls.count == 1 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { recoveries == 1 })
        cache.mergeListing([row], startedAt: older)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls.count == 1)
        cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        try #require(await until { await reader.calls.count == 2 })
        await reader.failRead(OneDriveBadgeReadError.staleTarget)
        try #require(await until { cache.snapshot(for: row)?.repeatedTargetRefusal == true })
        clock += 59
        cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls.count == 2)
        clock += 1
        cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        try #require(await until { await reader.calls.count == 3 })
        await reader.finish(.init(policy: .none, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        #expect(recoveries == 1)
    }

    @Test func staleTargetWaitsForAQualifyingRealListingWithoutLosingKnownPolicy() async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(780)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        func demand(_ selected: Bool = false) {
            cache.update(mount, scope: scope, entries: [row], selectedIDs: selected ? [row.item.id] : [],
                         mergeEntries: false, changed: {})
        }
        demand()
        try #require(await until { await reader.calls.count == 1 })
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        await reader.finish(pinned)
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        let checkedAt = cache.snapshot(for: row)?.confirmedAt
        clock += 301; demand()
        try #require(await until { await reader.calls.count == 2 })
        let oldListing = cache.beginListingSnapshot(for: folder)
        await reader.fail(.staleTarget)
        try #require(await until { cache.snapshot(for: row)?.freshness != .fresh })
        #expect(cache.snapshot(for: row)?.freshness == .stale)
        #expect(cache.observation(for: row) == pinned)
        #expect(cache.snapshot(for: row)?.confirmedAt == checkedAt)
        clock += 901
        demand(true)
        cache.hint(folder: folder, reason: .directory)
        cache.mergeListing([row], startedAt: oldListing)
        try await Task.sleep(for: .milliseconds(220))
        #expect(await reader.calls.count == 2,
                "Viewport reports, selection, hints and an older same-key listing cannot reopen quarantined work")
        // Only a real listing begun after the refusal clears same-key quarantine.
        cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        let resumed = await until { await reader.calls.count >= 3 }
        #expect(resumed)
        if resumed {
            await reader.finish(pinned)
            try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        }
    }

    @Test func verifiedOperationProofDoesNotReopenAQuarantinedFollowupBeforeReload() async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(781, availability: .onlineOnly)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        func demand() {
            cache.update(mount, scope: scope, entries: [row], selectedIDs: [row.item.id],
                         mergeEntries: false, changed: {})
        }
        demand()
        try #require(await until { await reader.calls.count == 1 })
        await reader.fail(.staleTarget)
        try #require(await until { cache.snapshot(for: row)?.freshness != .unknown })
        let tokenValue = cache.beginOperation(for: row)
        let token = try #require(tokenValue)
        let version = try #require(row.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: row, sampledVersion: version,
                                                      policy: .pinned, isDataless: true))
        cache.finishOperation(token, verified: proof)
        cache.followUp(owner: mount, entry: row, action: .keep)
        clock += 3; demand()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls.count == 1, "Verified operation display does not clear captured-target quarantine")
        #expect(cache.snapshot(for: row)?.policy == .pinned)
        cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        let resumed = await until { await reader.calls.count >= 2 }
        #expect(resumed, "The command's real reload can release the bounded post-action read")
        if resumed {
            await reader.finish(.init(policy: .pinned, isDataless: false))
            try #require(await until { cache.snapshot(for: row)?.availability == .availableLocally })
        }
    }

    @Test(arguments: [Int64(0), Int64(2)])
    func differentCommittedRawVersionCanCrossAnOlderPassiveResult(_ nanoseconds: Int64) async throws {
        let reader = BadgeReader(), mount = UUID(), old = entry(790)
        let replacement = entry(790, modificationNanoseconds: nanoseconds)
        let cache = OneDriveBadgeCache(debounce: .zero, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [old], mergeEntries: false, changed: {})
        let listing = cache.beginListingSnapshot(for: folder)
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: old)?.freshness == .fresh })
        cache.mergeListing([replacement], startedAt: listing)
        cache.update(mount, scope: scope, entries: [replacement], mergeEntries: false, changed: {})
        #expect(cache.snapshot(for: replacement) != nil)
        #expect(cache.snapshot(for: replacement)?.policy == nil)
        #expect(cache.snapshot(for: replacement)?.confirmedAt == nil)
        #expect(cache.snapshot(for: old) == nil, "A committed different key inherits no policy, irrespective of mtime direction")
        let requested = await until { await reader.calls.count == 2 }
        #expect(requested)
        if requested {
            await reader.finish(.init(policy: .unpinned, isDataless: false))
            try #require(await until { cache.snapshot(for: replacement)?.freshness == .fresh })
        }
    }

    @Test func realListingBarrierSurvivesALaterPassiveConfirmation() async throws {
        let reader = BadgeReader(), mount = UUID(), current = entry(791), older = entry(791, modificationNanoseconds: 0)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [current], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: current)?.freshness == .fresh })
        let oldListing = cache.beginListingSnapshot(for: folder)
        cache.mergeListing([current], startedAt: cache.beginListingSnapshot(for: folder))
        clock += 301
        cache.update(mount, scope: scope, entries: [current], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: current)?.policy == .unpinned })
        cache.mergeListing([older], startedAt: oldListing)
        #expect(cache.snapshot(for: older) == nil)
        #expect(cache.snapshot(for: current)?.policy == .unpinned,
                "A later query cannot erase the newer committed listing's ordering barrier")
    }

    @Test func operationBarrierSurvivesALaterPassiveConfirmation() async throws {
        let reader = BadgeReader(), mount = UUID(), current = entry(792), older = entry(792, modificationNanoseconds: 0)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [current], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: current)?.freshness == .fresh })
        let oldListing = cache.beginListingSnapshot(for: folder)
        let tokenValue = cache.beginOperation(for: current)
        let token = try #require(tokenValue)
        let version = try #require(current.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: current, sampledVersion: version,
                                                      policy: .unpinned, isDataless: false))
        cache.finishOperation(token, verified: proof)
        clock += 301
        cache.update(mount, scope: scope, entries: [current], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: current)?.confirmationElapsed == clock })
        cache.mergeListing([older], startedAt: oldListing)
        #expect(cache.snapshot(for: older) == nil)
        #expect(cache.snapshot(for: current)?.policy == .unpinned,
                "A later passive result cannot erase the operation's independent barrier")
    }

    @Test func staleOperationGenerationStillRaisesOnlyAnOrderingBarrier() throws {
        let reader = BadgeReader(), mount = UUID(), local = entry(793), online = entry(793, availability: .onlineOnly)
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(mount) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [local], changed: {})
        let tokenValue = cache.beginOperation(for: local)
        let token = try #require(tokenValue)
        cache.update(mount, scope: scope, entries: [online], changed: {})
        let beforeCompletion = cache.beginListingSnapshot(for: folder)
        let version = try #require(local.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: local, sampledVersion: version,
                                                      policy: .pinned, isDataless: false))
        cache.finishOperation(token, verified: proof)
        #expect(cache.snapshot(for: online)?.policy == nil, "A stale generation still cannot seed operation facts")
        cache.mergeListing([local], startedAt: beforeCompletion)
        #expect(cache.snapshot(for: online)?.availability == .onlineOnly,
                "The completed operation orders later admission even if its proof generation was retired")
        #expect(cache.snapshot(for: online)?.confirmedAt == nil)
    }

    @Test func viewportResidencyCannotBeCrossedByAnOlderDifferentKeyListing() {
        let reader = BadgeReader(), mount = UUID(), current = entry(794), older = entry(794, modificationNanoseconds: 0)
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(mount) }
        let oldListing = cache.beginListingSnapshot(for: folder)
        cache.update(mount, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
                     entries: [current], changed: {})
        cache.mergeListing([older], startedAt: oldListing)
        #expect(cache.snapshot(for: older) == nil)
        #expect(cache.snapshot(for: current) != nil, "Viewport provenance is not a passive-query fence exception")
    }

    @Test(arguments: [TimeInterval(10), TimeInterval(16)])
    func selectingARestoredHistoryRowHonorsTheFifteenSecondGate(_ elapsed: TimeInterval) async throws {
        let reader = BadgeReader(), mount = UUID(), row = entry(795)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [row], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 1 })
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
        cache.remove(mount)
        clock += elapsed
        cache.update(mount, scope: scope, entries: [row], selectedIDs: [row.item.id], mergeEntries: false, changed: {})
        if elapsed >= 15 {
            let requested = await until { await reader.calls.count == 2 }
            #expect(requested, "A qualifying selection edge must reach the restored history record")
            if requested { await reader.finish(.init(policy: .pinned, isDataless: false)) }
        } else {
            try await Task.sleep(for: .milliseconds(50))
            #expect(await reader.calls.count == 1)
        }
    }

    @Test func unchangedSelectionAcrossOffscreenHistoryDoesNotCreateANewEdge() async throws {
        let reader = BadgeReader(), mount = UUID(), selected = entry(796), other = entry(797)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(mount); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        cache.update(mount, scope: scope, entries: [selected, other], selectedIDs: [selected.item.id], mergeEntries: false, changed: {})
        for count in 1...2 {
            try #require(await until { await reader.calls.count == count })
            await reader.finish(.init(policy: .pinned, isDataless: false))
        }
        try #require(await until { cache.snapshot(for: other)?.freshness == .fresh })
        cache.update(mount, scope: scope, entries: [other], selectedIDs: [selected.item.id], mergeEntries: false, changed: {})
        clock += 16
        cache.update(mount, scope: scope, entries: [selected], selectedIDs: [selected.item.id], mergeEntries: false, changed: {})
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls.count == 2, "Scrolling an unchanged selection does not generate a reselection event")
    }

    @Test func fullListingChurnRetainsConfirmedViewportHistoryWithoutNewProof() async throws {
        let reader = BadgeReader(), owner = UUID()
        var clock: TimeInterval = 100
        var proofs = 0
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }, freshnessNow: { clock },
            wallNow: { Date(timeIntervalSince1970: 10_000 + clock) }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        let listing = (1...512).map { entry($0) }
        let upper = Array(listing.prefix(16)), lower = Array(listing[32..<49])
        func show(_ rows: [TransferEntry]) {
            cache.update(owner, scope: scope, entries: rows, mergeEntries: false,
                         changed: {}, observed: { _, _ in proofs += 1 })
        }
        cache.mergeListing(listing, startedAt: cache.beginListingSnapshot(for: folder))
        show(upper)
        for count in 1...16 {
            try #require(await until { await reader.calls.count == count })
            clock += 1 // Refill the existing budget as the controlled observations complete.
            await reader.finish(.init(policy: .pinned, isDataless: false))
        }
        try #require(await until { upper.allSatisfy { cache.snapshot(for: $0)?.freshness == .fresh } })
        var dates: [String: Date] = [:]
        for row in upper {
            let date = cache.snapshot(for: row)?.confirmedAt
            dates[row.item.id] = try #require(date)
        }
        show(lower)
        for count in 17...33 {
            try #require(await until { await reader.calls.count == count })
            clock += 1
            await reader.finish(.init(policy: .pinned, isDataless: false))
        }
        try #require(await until { lower.allSatisfy { cache.snapshot(for: $0)?.freshness == .fresh } })
        show(upper)
        cache.remove(owner)
        // A later full listing precedes the new viewport, as in the actual store.
        // It stays below the original 300-second refresh interval and introduces
        // no activation, operation or directory hint into this regression.
        clock = 200
        cache.mergeListing(listing, startedAt: cache.beginListingSnapshot(for: folder))
        show(upper)
        for row in upper {
            let snapshot = cache.snapshot(for: row)
            #expect(snapshot?.policy == .pinned && snapshot?.freshness == .fresh
                    && snapshot?.confirmedAt == dates[row.item.id],
                    "An unqueried full listing must not displace this row's existing confirmation")
            #expect(snapshot?.availability == .availableLocally)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await reader.calls.count == 33, "Reopening unchanged rows before eligibility must not add native work")
        #expect(proofs == 33, "Retained display history must not replay native-success proof callbacks")
    }

    @Test func historyPrunesUnusedThenViewedUnknownBeforeConfirmedRows() throws {
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), historyLimit: 2,
            now: { 100 }, wallNow: { Date(timeIntervalSince1970: 1_000) }) { _ in
                Issue.record("This deterministic history test must not start a lookup")
                return .init(policy: .unpinned, isDataless: false)
            }
        let owner = UUID(), scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(owner) }
        let a = entry(1101), b = entry(1102), c = entry(1103), d = entry(1104), e = entry(1105), f = entry(1106)
        func show(_ row: TransferEntry) { cache.update(owner, scope: scope, entries: [row], changed: {}) }
        show(a); try confirmPinned(a, in: cache)
        show(b); cache.remove(owner)
        cache.mergeListing([c, d], startedAt: cache.beginListingSnapshot(for: folder))
        #expect(cache.snapshot(for: a)?.policy == .pinned)
        #expect(cache.snapshot(for: b) != nil)
        #expect(cache.snapshot(for: c) == nil && cache.snapshot(for: d) == nil,
                "Unused listing candidates must leave before an actually viewed unknown row")
        show(c); cache.remove(owner)
        #expect(cache.snapshot(for: a)?.policy == .pinned)
        #expect(cache.snapshot(for: c) != nil && cache.snapshot(for: b) == nil,
                "A brief view may replace older unknown history, but not confirmed policy")
        show(e); try confirmPinned(e, in: cache); cache.remove(owner)
        #expect(cache.snapshot(for: c) == nil)
        #expect(cache.snapshot(for: a)?.policy == .pinned && cache.snapshot(for: e)?.policy == .pinned)
        show(f); try confirmPinned(f, in: cache); cache.remove(owner)
        #expect(cache.snapshot(for: a) == nil, "Protected history is still bounded; the oldest protected row expires")
        #expect(cache.snapshot(for: e)?.policy == .pinned && cache.snapshot(for: f)?.policy == .pinned)
    }

    @Test(arguments: [false, true])
    func historyUsesOwnerVisibilityEdgesWithoutPromotingIdenticalPublications(_ mergeEntries: Bool) throws {
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), historyLimit: 2,
            now: { 100 }, wallNow: { Date(timeIntervalSince1970: 1_000) }) { _ in
                Issue.record("Verified seeds are not permission for additional history-test lookups")
                return .init(policy: .unpinned, isDataless: false)
            }
        let first = UUID(), second = UUID()
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(first); cache.remove(second) }
        let a = entry(1111), b = entry(1112), c = entry(1113)
        func publish(_ owner: UUID, _ rows: [TransferEntry]) {
            cache.update(owner, scope: scope, entries: rows, mergeEntries: mergeEntries, changed: {})
        }
        publish(first, [a, b]); try confirmPinned(a, in: cache); try confirmPinned(b, in: cache)
        publish(second, [c]); try confirmPinned(c, in: cache)
        publish(first, [b])
        publish(first, [a, b]) // A re-enters this owner's demand; B did not leave it.
        for _ in 0..<3 {
            _ = cache.snapshot(for: b)
            publish(first, [a, b])
            cache.mergeListing([b], startedAt: cache.beginListingSnapshot(for: folder))
        }
        cache.remove(first); cache.remove(second)
        #expect(cache.snapshot(for: a)?.policy == .pinned && cache.snapshot(for: c)?.policy == .pinned,
                "At a fixed clock, returning A and later-used C must survive the two-entry cap")
        #expect(cache.snapshot(for: b) == nil,
                "Reads, identical viewport publication and listing-only merges must not promote B")
    }

    @Test func unusedHistoryUsesGenerationTiesWithoutPromotionByListingOrSnapshotReads() {
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), historyLimit: 2, now: { 100 }) { _ in
            Issue.record("Listing-only history has no viewport demand")
            return .init(policy: .unpinned, isDataless: false)
        }
        let a = entry(1121), b = entry(1122), c = entry(1123), d = entry(1124)
        cache.mergeListing([a, b, c], startedAt: cache.beginListingSnapshot(for: folder))
        #expect(cache.snapshot(for: a) == nil)
        #expect(cache.snapshot(for: b) != nil && cache.snapshot(for: c) != nil)
        for _ in 0..<3 {
            _ = cache.snapshot(for: b)
            cache.mergeListing([b], startedAt: cache.beginListingSnapshot(for: folder))
        }
        cache.mergeListing([d], startedAt: cache.beginListingSnapshot(for: folder))
        #expect(cache.snapshot(for: b) == nil)
        #expect(cache.snapshot(for: c) != nil && cache.snapshot(for: d) != nil,
                "Equally unused, fixed-clock records must prune deterministically by unique generation")
    }

    @Test func retainedReplacementKeepsRouteRankAndOperationBarrierWithoutPolicy() throws {
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), historyLimit: 2, now: { 100 }) { _ in
            Issue.record("This retained replacement test has no admitted native lookup")
            return .init(policy: .unpinned, isDataless: false)
        }
        let owner = UUID(), scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        defer { cache.remove(owner) }
        let original = entry(1131), other = entry(1132), viewed = entry(1133)
        let replacement = entry(1131, inode: 9_131, availability: .onlineOnly, modificationNanoseconds: 2)
        cache.update(owner, scope: scope, entries: [original, other], changed: {})
        let oldListing = cache.beginListingSnapshot(for: folder)
        try confirmPinned(original, in: cache); try confirmPinned(other, in: cache)
        cache.remove(owner)
        cache.mergeListing([replacement], startedAt: cache.beginListingSnapshot(for: folder))
        cache.update(owner, scope: scope, entries: [viewed], changed: {})
        cache.remove(owner)
        #expect(cache.snapshot(for: viewed) == nil)
        #expect(cache.snapshot(for: original) == nil)
        #expect(cache.snapshot(for: replacement)?.availability == .onlineOnly)
        #expect(cache.snapshot(for: replacement)?.policy == nil && cache.snapshot(for: replacement)?.confirmedAt == nil,
                "Retaining the route's importance must not transfer an old object's policy or date")
        cache.mergeListing([original], startedAt: oldListing)
        #expect(cache.snapshot(for: original) == nil)
        #expect(cache.snapshot(for: replacement)?.availability == .onlineOnly,
                "A retained replacement must still reject a listing older than its operation barrier")
        let resident = entry(1131, inode: 9_131, availability: .availableLocally, modificationNanoseconds: 2)
        cache.mergeListing([resident], startedAt: cache.beginListingSnapshot(for: folder))
        #expect(cache.snapshot(for: resident)?.availability == .availableLocally)
        #expect(cache.snapshot(for: resident)?.policy == nil && cache.snapshot(for: resident)?.confirmedAt == nil)
    }

    @Test func retainedReplacementRejectsDelayedOldInodeQueryAfterListingChurn() async throws {
        let reader = BadgeReader(), owner = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero, historyLimit: 1, now: { 100 }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        let original = entry(1141), replacement = entry(1141, inode: 9_141, availability: .onlineOnly)
        var proofs = 0
        cache.update(owner, scope: scope, entries: [original], changed: {}, observed: { _, _ in proofs += 1 })
        try #require(await until { await reader.calls.count == 1 })
        cache.mergeListing([replacement], startedAt: cache.beginListingSnapshot(for: folder))
        cache.remove(owner)
        cache.mergeListing((1142...1145).map { entry($0) }, startedAt: cache.beginListingSnapshot(for: folder))
        #expect(cache.snapshot(for: replacement) != nil)
        await reader.finish(.init(policy: .pinned, isDataless: false))
        try await Task.sleep(for: .milliseconds(40))
        #expect(cache.snapshot(for: original) == nil)
        #expect(cache.snapshot(for: replacement)?.policy == nil && cache.snapshot(for: replacement)?.availability == .onlineOnly)
        #expect(proofs == 0, "The evicted old inode's delayed completion cannot become replacement proof")
        cache.update(owner, scope: scope, entries: [replacement], mergeEntries: false,
                     changed: {}, observed: { _, _ in proofs += 1 })
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: true))
        try #require(await until { cache.snapshot(for: replacement)?.freshness == .fresh })
        #expect(cache.snapshot(for: replacement)?.policy == .unpinned && proofs == 1)
    }

    @Test(arguments: [false, true])
    func historyProtectsCooldownAndQuarantineWithoutAdmittingScrollRetries(_ staleTarget: Bool) async throws {
        let reader = BadgeReader(), owner = UUID(), row = entry(1151)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, historyLimit: 1, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.fail() } }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: nil)
        func show(_ rows: [TransferEntry]) {
            cache.update(owner, scope: scope, entries: rows, mergeEntries: false, changed: {})
        }
        show([row])
        try #require(await until { await reader.calls.count == 1 })
        let beforeRefusal = cache.beginListingSnapshot(for: folder)
        await reader.fail(staleTarget ? .staleTarget : .providerRejected)
        try #require(await until { cache.snapshot(for: row)?.freshness != .unknown })
        cache.setActive(false); cache.remove(owner)
        clock = 101
        cache.mergeListing((1152...1155).map { entry($0) }, startedAt: cache.beginListingSnapshot(for: folder))
        show([entry(1156)]); cache.remove(owner)
        #expect(cache.snapshot(for: row)?.freshness == (staleTarget ? .stale : .unavailable))
        #expect(cache.snapshot(for: row)?.policy == nil)
        show([row]); cache.setActive(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls.count == 1, "Scrolling a protected record back into view cannot erase its retry fence")
        if staleTarget {
            clock = 200
            cache.mergeListing([row], startedAt: beforeRefusal)
            show([row])
            try await Task.sleep(for: .milliseconds(50))
            #expect(await reader.calls.count == 1, "An older-started real listing must not clear quarantine")
            cache.mergeListing([row], startedAt: cache.beginListingSnapshot(for: folder))
        } else {
            clock = 161
            show([row])
        }
        try #require(await until { await reader.calls.count == 2 })
        await reader.finish(.init(policy: .unpinned, isDataless: false))
        try #require(await until { cache.snapshot(for: row)?.freshness == .fresh })
    }

    @Test func visibleRowsCanExceedHistoryLimitAndLastWindowEvictsHistory() async throws {
        let reader = BadgeReader(), mount = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero, historyLimit: 2) { try await reader.read($0) }
        let scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: UUID(), searchGeneration: nil)
        let rows = (3...8).map { entry($0) }
        cache.update(mount, scope: scope, entries: rows, changed: {})
        for (index, row) in rows.enumerated() {
            try #require(await until { await reader.calls.count == index + 1 })
            await reader.finish(.init(policy: .pinned, isDataless: false))
            try #require(await until { cache.observation(for: row) != nil })
        }
        #expect(rows.allSatisfy { cache.observation(for: $0) != nil })
        cache.remove(mount)
        #expect(rows.filter { cache.observation(for: $0) != nil }.count == 2)
    }
}
