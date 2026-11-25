import Foundation
import Testing
@testable import ExplorerCore
@testable import ExplorerApp

private actor StatusIntegrationReader {
    private(set) var calls = 0
    var fails = false
    func failNextReads() { fails = true }
    func read(_ entry: TransferEntry) throws -> OneDriveBadgeObservation {
        calls += 1
        if fails { throw OneDriveRetentionError.providerRejected }
        return .init(policy: .pinned, isDataless: true)
    }
}

@MainActor
struct OneDriveStatusIntegrationTests {
    private let folder = URL(fileURLWithPath: "/synthetic/status-integration", isDirectory: true)
    private func row(_ id: Int) -> TransferEntry {
        let name = "file-\(id).txt"
        return TransferEntry(source: .init(directoryURL: folder,
            directoryIdentity: .init(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)),
            item: FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
                isSymbolicLink: false, size: 4, modifiedAt: nil, kind: "Text",
                identity: .init(device: 1, inode: UInt64(id + 10), birthSeconds: 1, birthNanoseconds: 0),
                availability: .onlineOnly, isRegularFile: true,
                statusVersion: .init(size: 4, modificationSeconds: 1, modificationNanoseconds: 7)))
    }
    private func until(_ check: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await check()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    @Test func verifiedSeedSurvivesReservationReleaseAndBatchesOnlyChangedIDs() async throws {
        let reader = StatusIntegrationReader(), owner = UUID(), a = row(1), b = row(2)
        let cache = OneDriveBadgeCache(debounce: .seconds(3600), now: { 100 }) { try await reader.read($0) }
        var batches: [Set<String>] = [], proofEvents = 0
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
            entries: [a, b], changedIDs: { batches.append($0) }, observed: { _, _ in proofEvents += 1 })
        cache.retentionChanged(target: .init(a), isBusy: true)
        let token = try #require(cache.beginOperation(for: a))
        let version = try #require(a.item.statusVersion)
        let proof = try #require(OneDriveVerifiedStatus(entry: a,
            sampledVersion: version, policy: .pinned, isDataless: true))
        cache.finishOperation(token, verified: proof)
        cache.retentionChanged(target: .init(a), isBusy: false)
        try #require(await until { batches.count == 1 })
        #expect(batches == [[a.item.id]])
        #expect(cache.snapshot(for: a)?.freshness == .fresh)
        #expect(cache.snapshot(for: b)?.policy == nil)
        #expect(await reader.calls == 0)
        #expect(proofEvents == 0)
        cache.remove(owner)
    }

    @Test func followupStopsAfterFourReadsAndSelectionCancelsItsDemand() async throws {
        let reader = StatusIntegrationReader(), owner = UUID(), a = row(3), tab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        func demand(selected: Bool = true) {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: nil, searchGeneration: nil),
                entries: [a], selectedIDs: selected ? [a.item.id] : [], changed: {})
        }
        demand()
        try #require(await until { cache.snapshot(for: a)?.freshness == .fresh })
        cache.followUp(owner: owner, entry: a, action: .keep)
        for count in 2...5 {
            clock += 2; demand()
            try #require(await until { await reader.calls == count })
            try #require(await until { cache.snapshot(for: a)?.confirmedAt != nil })
            try await Task.sleep(for: .milliseconds(20))
        }
        clock += 2; demand()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls == 5, "One initial read plus at most four follow-ups")
        cache.followUp(owner: owner, entry: a, action: .keep)
        demand(selected: false); clock += 3; demand(selected: false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls == 5)
        cache.remove(owner)
    }

    @Test func routineHintAcrossWindowsStillCountsAndSpacesFollowups() async throws {
        let reader = StatusIntegrationReader(), owner = UUID(), otherOwner = UUID()
        let a = row(6), tab = UUID(), otherTab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); cache.remove(otherOwner) }
        func demand() {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: nil, searchGeneration: nil),
                entries: [a], selectedIDs: [a.item.id], changed: {})
            cache.update(otherOwner, scope: .init(tab: otherTab, folder: folder, load: nil, searchGeneration: nil),
                entries: [a], selectedIDs: [], changed: {})
        }
        demand()
        try #require(await until { cache.snapshot(for: a)?.freshness == .fresh })
        #expect(await reader.calls == 1)
        cache.followUp(owner: owner, entry: a, action: .keep)
        // Let the initial wakeup see a future follow-up before advancing the
        // fake clock. The folder hint, rather than another viewport update,
        // then admits the next shared request.
        try await Task.sleep(for: .milliseconds(50))
        clock += 2
        cache.hint(folder: folder, reason: .directory)
        try #require(await until {
            cache.snapshot(for: a)?.freshness == .fresh
                && cache.snapshot(for: a)?.confirmationElapsed == clock
        })
        try await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls == 2,
                "The due routine hint shares the follow-up: it cannot trigger another read at the same clock time")
        for expected in 3...5 {
            clock += 2
            demand()
            try #require(await until { await reader.calls >= expected })
            try await Task.sleep(for: .milliseconds(40))
            #expect(await reader.calls == expected)
        }
        clock += 2
        demand()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await reader.calls == 5,
                "One initial read plus four follow-ups includes the coalesced routine/post-action admission")
    }


    @Test func followupAndReselectionCannotBypassFailedReadCooldown() async throws {
        let reader = StatusIntegrationReader(), owner = UUID(), a = row(4), tab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        func demand(_ selected: Bool) {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: nil, searchGeneration: nil),
                entries: [a], selectedIDs: selected ? [a.item.id] : [], changed: {})
        }
        demand(true)
        try #require(await until { cache.snapshot(for: a)?.freshness == .fresh })
        await reader.failNextReads()
        cache.followUp(owner: owner, entry: a, action: .keep)
        clock += 2; demand(true)
        try #require(await until { cache.snapshot(for: a)?.freshness == .unavailable })
        clock += 16; demand(false); demand(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reader.calls == 2, "Neither urgent follow-up nor selection bypasses 60-second retry")
        clock += 45; demand(true)
        try #require(await until { await reader.calls == 3 })
        cache.remove(owner)
    }

    @Test func hintsCoalesceRespectOwnCompletionSuppressionAndFolderGate() async throws {
        let reader = StatusIntegrationReader(), owner = UUID(), a = row(5)
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        cache.update(owner, scope: .init(tab: UUID(), folder: folder, load: nil, searchGeneration: nil),
            entries: [a], selectedIDs: [a.item.id], changed: {})
        try #require(await until { cache.snapshot(for: a)?.freshness == .fresh })
        for _ in 0..<20 { cache.hint(folder: folder, reason: .directory) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await reader.calls == 1)
        clock += 3
        for _ in 0..<20 { cache.hint(folder: folder, reason: .directory) }
        try #require(await until { await reader.calls == 2 })
        clock += 3
        cache.hint(folder: folder, reason: .activation)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await reader.calls == 2, "Selection must not bypass the unchanged-folder 30-second gate")
        cache.remove(owner)
    }
}
