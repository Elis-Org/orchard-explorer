import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor MeasuredPresence: FolderChildPresenceChecking {
    struct Sample: Codable, Sendable {
        let path: String
        let startedUptime: Double
        let milliseconds: Double
        let entries: Int
        let traversalOperations: Int
        let childSamples: Int
        let outcome: String
        let uncertainty: String?
    }

    private let checker = LocalFolderChildPresenceChecker()
    private(set) var requests: [String] = []
    private(set) var samples: [Sample] = []
    private(set) var peakSubmitted = 0
    private var pending = 0

    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        let started = ProcessInfo.processInfo.systemUptime
        requests.append(request.url.path)
        pending += 1
        peakSubmitted = max(peakSubmitted, pending)
        let result = await checker.check(request)
        pending -= 1
        samples.append(Sample(path: request.url.path, startedUptime: started, milliseconds: elapsedMS(started),
                              entries: result.entriesExamined, traversalOperations: result.traversalOperations,
                              childSamples: result.childSamples, outcome: String(describing: result.presence),
                              uncertainty: result.uncertainty.map { String(describing: $0) }))
        return result
    }
}

private func elapsedMS(_ started: TimeInterval) -> Double {
    (ProcessInfo.processInfo.systemUptime - started) * 1_000
}

@MainActor
struct SidebarPresencePerformanceTests {
    private struct Lookup: Encodable {
        let dataset: String
        let round: Int
        let candidate: MeasuredPresence.Sample
        let fullListingMilliseconds: Double
        let listingReturnedEntries: Int
        let listingTraversableFolders: Int
        let listingStructureComplete: Bool
    }

    private struct Viewport: Encodable {
        let width: Int
        let round: Int
        let coldMilliseconds: Double
        let coldProviderCalls: Int
        let warmAdditionalProviderCalls: Int
        let additionalProviderCallsAfterReturning: Int
        let uniqueColdPaths: Int
        let maximumSubmittedProviderCalls: Int
        let probeSamples: [MeasuredPresence.Sample]
        let candidateFirst: Bool
        let navigationWithoutPresence: Navigation
        let navigationWithPresence: Navigation
        let overlappingPresenceCalls: Int
        let coldViewportHeartbeatDelayMilliseconds: [Double]
    }

    private struct Navigation: Encodable {
        let startedUptime: Double
        let finishedUptime: Double
        let milliseconds: Double
        let heartbeatDelayMilliseconds: [Double]
    }

    private struct Idle: Encodable {
        let initialProviderCalls: Int
        let providerCallsAfter17Seconds: Int
        let providerCallsAfter48Seconds: Int
        let additionalInactiveProviderCalls: Int
        let activationProviderCalls: Int
        let visibleSeconds: Double
        let inactiveSeconds: Double
        let earlyVisibleRechecksPerMinute: Double
    }

    private struct SimulatedBackoff: Encodable {
        let intervalsSeconds: [Double]
        let providerCallsBeforeDeadlines: [Int]
        let providerCallsAtDeadlines: [Int]
    }

    private struct Report: Encodable {
        let host: String
        let operatingSystem: String
        let buildMode: String
        let filesystemCache = "Uncontrolled operating system cache"
        let collapsedBaseline = "Original collapsed rows issue zero child discovery calls"
        let listingComparator = "Existing full LocalDirectoryLoader snapshot for explicit discovery"
        let lookup: [Lookup]
        let viewport: [Viewport]
        let idle: Idle
        let simulatedBackoff: SimulatedBackoff
    }

    @Test
    func measureSidebarPresence() async throws {
        guard let runPath = ProcessInfo.processInfo.environment["MAXPLORER_SIDEBAR_BENCHMARK_RUN"] else { return }
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let canonical = run.resolvingSymlinksInPath().standardizedFileURL
        try #require(canonical.path == run.path && run.path.hasPrefix("/Users/")
                     && run.deletingLastPathComponent().path.hasSuffix("/validation/runtime")
                     && run.lastPathComponent.range(of: "^sidebar-leaf-benchmark-[0-9a-f]{32}$",
                                                    options: .regularExpression) != nil)
        let manager = FileManager.default
        let fixture = run.appendingPathComponent("fixture", isDirectory: true)
        let reportURL = run.appendingPathComponent("sidebar-performance.json")
        try #require(!manager.fileExists(atPath: fixture.path) && !manager.fileExists(atPath: reportURL.path))
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        let empty = try makeFolder("empty", under: fixture)
        let files = try makeFolder("file-only-128", under: fixture, files: 128)
        let large = try makeFolder("file-only-10000", under: fixture, files: 10_000)
        let mixed = try makeFolder("mixed-one-child", under: fixture)
        _ = try makeFolder("000-child", under: mixed)
        try makeFiles(2_048, in: mixed)
        let packages = try makeFolder("package-only", under: fixture)
        _ = try makeFolder("Example.app", under: packages, files: 1)
        let navigation = try makeFolder("navigation", under: fixture, files: 64)
        let loader = LocalDirectoryLoader()

        var lookup: [Lookup] = []
        for folder in [empty, files, large, mixed, packages] {
            for round in -2..<20 {
                let provider = MeasuredPresence()
                let request = FolderChildPresenceRequest(url: folder, showHidden: false, homeURL: fixture)
                let candidate: FolderChildPresenceResult
                let listing: (milliseconds: Double, entries: Int, traversableFolders: Int, isStructureComplete: Bool)
                if round.isMultiple(of: 2) {
                    candidate = await provider.check(request)
                    listing = try await measureListing(loader, at: folder)
                } else {
                    listing = try await measureListing(loader, at: folder)
                    candidate = await provider.check(request)
                }
                let structurallyUnknown = folder == mixed || folder == packages
                try #require(candidate.presence == (structurallyUnknown ? .unknown : .absent))
                try #require(candidate.uncertainty == (structurallyUnknown ? .structural : nil))
                try #require(candidate.traversalOperations > 0 && (!structurallyUnknown || candidate.childSamples > 0))
                try #require(listing.isStructureComplete && listing.traversableFolders == (folder == mixed ? 1 : 0))
                let samples = await provider.samples
                if round >= 0 {
                    lookup.append(Lookup(dataset: folder.lastPathComponent, round: round,
                                         candidate: try #require(samples.first), fullListingMilliseconds: listing.milliseconds,
                                         listingReturnedEntries: listing.entries, listingTraversableFolders: listing.traversableFolders,
                                         listingStructureComplete: listing.isStructureComplete))
                }
            }
        }

        var viewport: [Viewport] = []
        for width in [64, 256] {
            let parent = try makeFolder("viewport-\(width)", under: fixture)
            var folders: [URL] = []
            for index in 0..<width {
                folders.append(try makeFolder("row-\(index)", under: parent, files: index < 64 ? 128 : 0))
            }
            for round in -2..<20 {
                let sample = try await measureViewport(fixture: fixture, folders: folders, navigation: navigation,
                                                       loader: loader, round: round)
                if round >= 0 { viewport.append(sample) }
            }
        }
        let idle = try await measureIdle(fixture: fixture, folder: empty, loader: loader)
        let simulatedBackoff = try await checkBackoffCap(fixture: fixture, folder: empty, loader: loader)
        #if DEBUG
        let buildMode = "debug"
        #else
        let buildMode = "release"
        #endif
        let report = Report(host: ProcessInfo.processInfo.hostName,
                            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            buildMode: buildMode, lookup: lookup, viewport: viewport, idle: idle,
                            simulatedBackoff: simulatedBackoff)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .withoutOverwriting)
    }

    private func makeFolder(_ name: String, under parent: URL, files: Int = 0) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try makeFiles(files, in: folder)
        return folder
    }

    private func makeFiles(_ count: Int, in folder: URL) throws {
        for index in 0..<count {
            try Data().write(to: folder.appendingPathComponent("item-\(index).txt"), options: .withoutOverwriting)
        }
    }

    private func measureListing(_ loader: LocalDirectoryLoader, at folder: URL) async throws ->
        (milliseconds: Double, entries: Int, traversableFolders: Int, isStructureComplete: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try await loader.snapshot(of: folder, showHidden: false)
        return (elapsedMS(start), snapshot.items.count, snapshot.items.filter(\.isDirectory).count,
                snapshot.isStructureComplete)
    }

    private func waitFor(_ description: String, until ready: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !(await ready()) {
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(description)")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeModel(_ folders: [URL], fixture: URL, loader: LocalDirectoryLoader,
                           checker: MeasuredPresence,
                           now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws -> (SidebarModel, [SidebarNode]) {
        let pins = PinnedFolderStore(homeURL: fixture)
        for folder in folders { try #require(pins.pin(folder)) }
        let model = SidebarModel(homeURL: fixture, pins: pins, loader: loader, presenceChecker: checker, presenceNow: now)
        let nodes = model.roots.filter { $0.key.hasPrefix("pin:") }
        try #require(nodes.count == folders.count)
        return (model, nodes)
    }

    private func loaded(_ store: ExplorerStore, at folder: URL) -> Bool {
        store.activeTab.url == folder && store.activeTab.hasLoaded && !store.activeTab.isLoading
            && !store.activeTab.isUnavailable
    }

    private func measureNavigation(_ store: ExplorerStore, to folder: URL) async throws -> Navigation {
        let heartbeat = Heartbeat()
        let pulse = heartbeat.start()
        defer { pulse.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        store.navigate(to: folder)
        try await waitFor("main-pane navigation") { loaded(store, at: folder) }
        let finish = ProcessInfo.processInfo.systemUptime
        pulse.cancel()
        await pulse.value
        return Navigation(startedUptime: start, finishedUptime: finish, milliseconds: (finish - start) * 1_000,
                          heartbeatDelayMilliseconds: heartbeat.samples)
    }

    private func measureNavigationWithoutPresence(fixture: URL, folder: URL, loader: LocalDirectoryLoader) async throws -> Navigation {
        let store = ExplorerStore(initialURL: fixture, loader: loader, homeURL: fixture)
        defer { store.cancelLoads() }
        try await waitFor("uncontended store initial listing") { loaded(store, at: fixture) }
        return try await measureNavigation(store, to: folder)
    }

    private func measureColdViewport(model: SidebarModel, rows: [SidebarNode], owner: UUID, fixture: URL,
                                     navigation: URL, loader: LocalDirectoryLoader,
                                     checker: MeasuredPresence) async throws -> (Double, [Double], Navigation) {
        let store = ExplorerStore(initialURL: fixture, loader: loader, homeURL: fixture)
        defer { store.cancelLoads() }
        try await waitFor("contended store initial listing") { loaded(store, at: fixture) }
        let heartbeat = Heartbeat()
        let pulse = heartbeat.start()
        defer { pulse.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        model.setVisiblePresenceDemand(rows + Array(rows.prefix(2)), owner: owner, isActive: true)
        let settle = Task { @MainActor in
            try await waitFor("application-cache-cold viewport") { rows.allSatisfy { !$0.isExpandable } }
            let milliseconds = elapsedMS(start)
            pulse.cancel()
            await pulse.value
            return (milliseconds, heartbeat.samples)
        }
        defer { settle.cancel() }
        try await waitFor("candidate presence work to start") { await !checker.requests.isEmpty }
        let sample = try await measureNavigation(store, to: navigation)
        let (milliseconds, coldHeartbeat) = try await settle.value
        return (milliseconds, coldHeartbeat, sample)
    }

    private func measureViewport(fixture: URL, folders: [URL], navigation: URL,
                                 loader: LocalDirectoryLoader, round: Int) async throws -> Viewport {
        let checker = MeasuredPresence()
        let (model, nodes) = try makeModel(folders, fixture: fixture, loader: loader, checker: checker)
        defer { model.cancelLoads() }
        let owner = UUID()
        model.attachPresenceOwner(owner)
        let rows = Array(nodes.prefix(32))
        let offscreen = Array(nodes.dropFirst(32).prefix(32))
        let candidateFirst = round.isMultiple(of: 2)
        let withoutPresence: Navigation
        let cold: (Double, [Double], Navigation)
        if candidateFirst {
            cold = try await measureColdViewport(model: model, rows: rows, owner: owner, fixture: fixture,
                                                 navigation: navigation, loader: loader, checker: checker)
            withoutPresence = try await measureNavigationWithoutPresence(fixture: fixture, folder: navigation, loader: loader)
        } else {
            withoutPresence = try await measureNavigationWithoutPresence(fixture: fixture, folder: navigation, loader: loader)
            cold = try await measureColdViewport(model: model, rows: rows, owner: owner, fixture: fixture,
                                                 navigation: navigation, loader: loader, checker: checker)
        }
        return try await finishViewport(model: model, rows: rows, offscreen: offscreen, owner: owner,
                                        folders: folders, checker: checker, round: round,
                                        cold: cold, withoutPresence: withoutPresence)
    }

    private func finishViewport(model: SidebarModel, rows: [SidebarNode], offscreen: [SidebarNode], owner: UUID,
                                folders: [URL], checker: MeasuredPresence, round: Int,
                                cold: (Double, [Double], Navigation), withoutPresence: Navigation) async throws -> Viewport {
        let (coldTime, coldHeartbeat, withPresence) = cold
        let coldPaths = await checker.requests
        try #require(coldPaths.count == 32 && Set(coldPaths) == Set(folders.prefix(32).map(\.path)))
        let offscreenStillUnprobed = offscreen.allSatisfy { $0.isExpandable }
        try #require(offscreenStillUnprobed)
        let coldSamples = await checker.samples
        let overlaps = coldSamples.count { probe in
            probe.startedUptime < withPresence.finishedUptime &&
                probe.startedUptime + probe.milliseconds / 1_000 > withPresence.startedUptime
        }

        model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
        try await Task.sleep(for: .milliseconds(20))
        let warmCalls = await checker.requests.count - coldPaths.count
        try #require(warmCalls == 0)
        model.setVisiblePresenceDemand(offscreen, owner: owner, isActive: true)
        try await waitFor("second viewport") { offscreen.allSatisfy { !$0.isExpandable } }
        let beforeReturn = await checker.requests.count
        try #require(beforeReturn == 64)
        model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
        try await Task.sleep(for: .milliseconds(20))
        let returnCalls = await checker.requests.count - beforeReturn
        try #require(returnCalls == 0)
        let samples = await checker.samples
        let peak = await checker.peakSubmitted
        try #require(peak <= 2)
        return Viewport(width: folders.count, round: round, coldMilliseconds: coldTime, coldProviderCalls: coldPaths.count,
                        warmAdditionalProviderCalls: warmCalls, additionalProviderCallsAfterReturning: returnCalls,
                        uniqueColdPaths: Set(coldPaths).count, maximumSubmittedProviderCalls: peak, probeSamples: samples,
                        candidateFirst: round.isMultiple(of: 2), navigationWithoutPresence: withoutPresence,
                        navigationWithPresence: withPresence, overlappingPresenceCalls: overlaps,
                        coldViewportHeartbeatDelayMilliseconds: coldHeartbeat)
    }

    private func measureIdle(fixture: URL, folder: URL, loader: LocalDirectoryLoader) async throws -> Idle {
        let checker = MeasuredPresence()
        let (model, rows) = try makeModel([folder], fixture: fixture, loader: loader, checker: checker)
        defer { model.cancelLoads() }
        let owner = UUID()
        model.attachPresenceOwner(owner)
        model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
        try await waitFor("first idle result") { rows.allSatisfy { !$0.isExpandable } }
        let first = await checker.requests.count
        let visibleStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(17))
        let second = await checker.requests.count
        try await Task.sleep(for: .seconds(31))
        let third = await checker.requests.count
        let visibleSeconds = elapsedMS(visibleStart) / 1_000
        try #require(first == 1 && second == 2 && third == 3)
        model.setVisiblePresenceDemand(rows, owner: owner, isActive: false)
        let inactiveStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(61))
        let inactiveCalls = await checker.requests.count - third
        let inactiveSeconds = elapsedMS(inactiveStart) / 1_000
        try #require(inactiveCalls == 0)
        model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
        try await waitFor("expiry recheck on activation") { await checker.samples.count == third + 1 }
        return Idle(initialProviderCalls: first, providerCallsAfter17Seconds: second, providerCallsAfter48Seconds: third,
                    additionalInactiveProviderCalls: inactiveCalls, activationProviderCalls: 1, visibleSeconds: visibleSeconds,
                    inactiveSeconds: inactiveSeconds, earlyVisibleRechecksPerMinute: Double(third - first) * 60 / visibleSeconds)
    }

    private func checkBackoffCap(fixture: URL, folder: URL, loader: LocalDirectoryLoader) async throws -> SimulatedBackoff {
        let checker = MeasuredPresence()
        var time: TimeInterval = 0
        let (model, rows) = try makeModel([folder], fixture: fixture, loader: loader, checker: checker, now: { time })
        defer { model.cancelLoads() }
        let owner = UUID()
        model.attachPresenceOwner(owner)
        model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
        try await waitFor("simulated first result") { rows.allSatisfy { !$0.isExpandable } }
        let intervals: [Double] = [15, 30, 60, 120, 120]
        var readsBefore: [Int] = []
        var readsAt: [Int] = []
        for (index, interval) in intervals.enumerated() {
            time += interval - 0.01
            model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
            try await Task.sleep(for: .milliseconds(20))
            let before = await checker.requests.count
            try #require(before == index + 1)
            readsBefore.append(before)
            time += 0.011
            model.setVisiblePresenceDemand(rows, owner: owner, isActive: true)
            try await waitFor("simulated expiry \(index)") { await checker.samples.count == index + 2 }
            // Let the model consume the provider result before advancing the simulated clock.
            try await Task.sleep(for: .milliseconds(20))
            readsAt.append(await checker.requests.count)
        }
        return SimulatedBackoff(intervalsSeconds: intervals, providerCallsBeforeDeadlines: readsBefore,
                                providerCallsAtDeadlines: readsAt)
    }
}

@MainActor
private final class Heartbeat {
    private(set) var samples: [Double] = []

    func start() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { break }
                samples.append(max(0, elapsedMS(start) - 5))
            }
        }
    }
}
