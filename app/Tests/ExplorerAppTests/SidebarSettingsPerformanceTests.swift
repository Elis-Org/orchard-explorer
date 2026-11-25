import Darwin
import Foundation
import Testing
@testable import ExplorerApp
@testable import ExplorerCore

private enum SettingsBenchmarkCategory: String, CaseIterable, Codable, Sendable {
    case ordinary, protectedLocal, cloud, network

    var enabledOptions: SidebarBackgroundCheckOptions {
        switch self {
        case .ordinary: .init(protectedLocal: true, cloud: true, network: true)
        case .protectedLocal: .init(protectedLocal: true)
        case .cloud: .init(cloud: true)
        case .network: .init(network: true)
        }
    }

    var isBounded: Bool { self == .cloud || self == .network }
}

private struct SettingsProbeSample: Codable, Sendable {
    let row: String
    let startedUptime: TimeInterval
    let finishedUptime: TimeInterval
    let milliseconds: Double
    let entriesExamined: Int
    let traversalOperations: Int
    let childSamples: Int
    let streamNextCalls: Int
    let mountInventoryOperations: Int
    let modeledDelayMilliseconds: Double
    let hasLocalIdentity: Bool
    let outcome: String
    let uncertainty: String?
}

private final class SettingsProbeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var delayed = false

    func nextRead() { lock.withLock { reads += 1 } }
    func recordDelay() { lock.withLock { delayed = true } }
    var snapshot: (reads: Int, delayed: Bool) { lock.withLock { (reads, delayed) } }
}

private struct SettingsBenchmarkFileSystem: FolderPresenceFileSystem {
    static let remoteDelaySeconds = 0.012
    let local = DarwinFolderPresenceFileSystem()
    let remote: FolderPresenceMount?
    let counters: SettingsProbeCounters

    private func modeledMount(for descriptor: Int32) throws -> FolderPresenceMount? {
        guard let remote else { return nil }
        guard let descriptorPath = ContentFileIO.path(of: descriptor) else {
            throw POSIXError(.EIO)
        }
        let descriptorScope = FolderPresencePath.policyPath(descriptorPath.path)
        let remoteScope = FolderPresencePath.policyPath(remote.path)
        return FolderPresencePath.contains(descriptorScope, under: remoteScope) ? remote : nil
    }

    func openRoot() throws -> Int32 { try local.openRoot() }
    func open(_ name: String, in parent: Int32, mode: FolderPresenceOpenMode) throws -> Int32 {
        try local.open(name, in: parent, mode: mode)
    }

    func sample(_ name: String, in parent: Int32) throws -> stat { try local.sample(name, in: parent) }
    func sampleDescriptor(_ descriptor: Int32) throws -> stat { try local.sampleDescriptor(descriptor) }
    func isLocal(_ descriptor: Int32) throws -> Bool {
        if try modeledMount(for: descriptor) != nil { return false }
        return try local.isLocal(descriptor)
    }

    func mountInventory() throws -> [FolderPresenceMount] {
        let current = try local.mountInventory()
        guard let remote else { return current }
        return current + [remote]
    }

    func mount(for descriptor: Int32) throws -> FolderPresenceMount {
        if let remote = try modeledMount(for: descriptor) { return remote }
        return try local.mount(for: descriptor)
    }

    func stream(_ descriptor: Int32) throws -> FolderPresenceStream {
        if try modeledMount(for: descriptor) != nil {
            // A synchronous delay in the actual probe worker before opening a
            // real local stream. The fixture contains no mounted network share.
            counters.recordDelay()
            Thread.sleep(forTimeInterval: Self.remoteDelaySeconds)
        }
        let native = try local.stream(descriptor)
        return FolderPresenceStream(next: {
            counters.nextRead()
            return try native.next()
        }, close: native.close)
    }

    func close(_ descriptor: Int32) { local.close(descriptor) }
}

private actor MeasuredSidebarSettingsPresence: FolderChildPresenceChecking {
    let remote: FolderPresenceMount?
    let options: SidebarBackgroundCheckOptions
    private(set) var samples: [SettingsProbeSample] = []
    private(set) var requests: [String] = []
    private(set) var peakSubmitted = 0
    private(set) var capturedExpectedOptions = true
    private var outstanding = 0

    init(remote: FolderPresenceMount?, options: SidebarBackgroundCheckOptions) {
        self.remote = remote
        self.options = options
    }

    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        let start = ProcessInfo.processInfo.systemUptime
        let row = request.url.lastPathComponent
        requests.append(row)
        capturedExpectedOptions = capturedExpectedOptions && request.options == options
        outstanding += 1
        peakSubmitted = max(peakSubmitted, outstanding)
        let counters = SettingsProbeCounters()
        let fileSystem = SettingsBenchmarkFileSystem(remote: remote, counters: counters)
        let result = await LocalFolderChildPresenceChecker(fileSystem: fileSystem).check(request)
        let finish = ProcessInfo.processInfo.systemUptime
        outstanding -= 1
        let instrumentation = counters.snapshot
        samples.append(SettingsProbeSample(
            row: row, startedUptime: start, finishedUptime: finish, milliseconds: (finish - start) * 1_000,
            entriesExamined: result.entriesExamined, traversalOperations: result.traversalOperations,
            childSamples: result.childSamples, streamNextCalls: instrumentation.reads,
            mountInventoryOperations: result.mountInventoryOperations,
            modeledDelayMilliseconds: instrumentation.delayed ? SettingsBenchmarkFileSystem.remoteDelaySeconds * 1_000 : 0,
            hasLocalIdentity: result.directoryIdentity != nil, outcome: String(describing: result.presence),
            uncertainty: result.uncertainty.map { String(describing: $0) }))
        return result
    }
}

@MainActor
struct SidebarSettingsPerformanceTests {
    private enum RowKind: Equatable { case leaf, structural, exceedsStreamBudget }

    private struct Row {
        let folder: URL
        let kind: RowKind
    }

    private struct Navigation: Encodable {
        let startedUptime: TimeInterval
        let finishedUptime: TimeInterval
        let milliseconds: Double
        let heartbeatDelayMilliseconds: [Double]
    }

    private struct Viewport: Encodable {
        let coldMilliseconds: Double
        let coldProviderCalls: Int
        let warmAdditionalProviderCalls: Int
        let secondViewportProviderCalls: Int
        let additionalProviderCallsAfterReturning: Int
        let maximumSubmittedProviderCalls: Int
        let coldViewportHeartbeatDelayMilliseconds: [Double]
        let navigation: Navigation
        let overlappingPresenceCalls: Int
        let coldProbes: [SettingsProbeSample]
    }

    private struct Pair: Encodable {
        let category: SettingsBenchmarkCategory
        let round: Int
        let first: String
        let off: Viewport
        let on: Viewport
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let host = ProcessInfo.processInfo.hostName
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let buildMode: String
        let filesystemCache = "Uncontrolled operating system cache; new application cache for each sample"
        let warmupPairsPerCategory = 2
        let measuredPairsPerCategory = 20
        let coldRows = 32
        let remoteDelayMilliseconds = SettingsBenchmarkFileSystem.remoteDelaySeconds * 1_000
        let remoteMode = "Synthetic SMB metadata plus one synchronous delay per admitted stream; real local fixture I/O"
        let pairs: [Pair]
    }

    @Test
    func measurePairedSidebarSettings() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAXPLORER_SIDEBAR_SETTINGS_BENCHMARK_RUN"] else { return }
        let run = URL(fileURLWithPath: path, isDirectory: true)
        let resolved = run.resolvingSymlinksInPath().standardizedFileURL
        try #require(resolved.path == path && run.path.hasPrefix("/Users/")
                     && run.deletingLastPathComponent().path.hasSuffix("/validation/runtime")
                     && run.lastPathComponent.range(of: "^sidebar-settings-benchmark-[0-9a-f]{32}$",
                                                    options: .regularExpression) != nil)
        let fixture = run.appendingPathComponent("fixture", isDirectory: true)
        let output = run.appendingPathComponent("sidebar-settings-performance.json")
        let manager = FileManager.default
        try #require(!manager.fileExists(atPath: fixture.path) && !manager.fileExists(atPath: output.path))
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        let home = fixture.appendingPathComponent("synthetic-home", isDirectory: true)
        let navigation = fixture.appendingPathComponent("main-pane-navigation", isDirectory: true)
        try makeFolder(navigation, files: 64)
        var pairs: [Pair] = []

        for category in SettingsBenchmarkCategory.allCases {
            let parent = switch category {
            case .ordinary: fixture.appendingPathComponent("ordinary", isDirectory: true)
            case .protectedLocal: home.appendingPathComponent("Documents", isDirectory: true)
            case .cloud: home.appendingPathComponent("Library/CloudStorage/SyntheticProvider", isDirectory: true)
            case .network: fixture.appendingPathComponent("modeled-share", isDirectory: true)
            }
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            let rows = try (0..<64).map { index in
                let kind: RowKind = switch index % 16 {
                case 0: .structural
                case 1: .exceedsStreamBudget
                default: .leaf
                }
                let folder = parent.appendingPathComponent(String(format: "row-%03d", index), isDirectory: true)
                try makeFolder(folder, files: kind == .exceedsStreamBudget ? 270 : 32)
                if kind == .structural {
                    try makeFolder(folder.appendingPathComponent("000-child", isDirectory: true), files: 0)
                }
                return Row(folder: folder, kind: kind)
            }
            let remote = category == .network
                ? FolderPresenceMount(path: parent.path, type: "smbfs", fsid: SIMD2(193, 317), flags: 0) : nil
            for round in -2..<20 {
                let offFirst = round.isMultiple(of: 2)
                let first = try await measure(category: category, enabled: !offFirst, rows: rows, fixture: fixture,
                                              home: home, navigation: navigation, remote: remote)
                let second = try await measure(category: category, enabled: offFirst, rows: rows, fixture: fixture,
                                               home: home, navigation: navigation, remote: remote)
                if round >= 0 {
                    pairs.append(Pair(category: category, round: round, first: offFirst ? "off" : "on",
                                      off: offFirst ? first : second, on: offFirst ? second : first))
                }
            }
        }

        #if DEBUG
        let buildMode = "debug"
        #else
        let buildMode = "release"
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(buildMode: buildMode, pairs: pairs)).write(to: output, options: .withoutOverwriting)
    }

    private func makeFolder(_ folder: URL, files: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<files {
            try Data().write(to: folder.appendingPathComponent("entry-\(index).txt"), options: .withoutOverwriting)
        }
    }

    private func wait(_ description: String, until ready: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !(await ready()) {
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(description)")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func expected(_ row: Row, in category: SettingsBenchmarkCategory, enabled: Bool)
        -> (presence: FolderChildPresence, uncertainty: FolderChildPresenceUncertainty?) {
        if category != .ordinary && !enabled { return (.unknown, .policyDeferred) }
        switch row.kind {
        case .structural: return (.unknown, .structural)
        case .exceedsStreamBudget where category.isBounded: return (.unknown, .policyDeferred)
        case .leaf, .exceedsStreamBudget: return (.absent, nil)
        }
    }

    private func measure(category: SettingsBenchmarkCategory, enabled: Bool, rows: [Row], fixture: URL,
                         home: URL, navigation: URL, remote: FolderPresenceMount?) async throws -> Viewport {
        let options: SidebarBackgroundCheckOptions = enabled ? category.enabledOptions : .init()
        let checker = MeasuredSidebarSettingsPresence(remote: remote, options: options)
        let pins = PinnedFolderStore(homeURL: home)
        for row in rows { try #require(pins.pin(row.folder)) }
        let loader = LocalDirectoryLoader()
        let model = SidebarModel(homeURL: home, pins: pins, loader: loader, presenceChecker: checker,
                                 backgroundCheckOptions: options)
        let store = ExplorerStore(initialURL: fixture, loader: loader, homeURL: home)
        defer { model.cancelLoads(); store.cancelLoads() }
        try await wait("initial main-pane listing") { loaded(store, at: fixture) }

        let owner = UUID()
        model.attachPresenceOwner(owner)
        let nodes = model.roots.filter { $0.key.hasPrefix("pin:") }
        try #require(nodes.compactMap(\.url) == rows.map(\.folder))
        let coldRows = Array(rows.prefix(32)), coldNodes = Array(nodes.prefix(32))
        let secondRows = Array(rows.dropFirst(32)), secondNodes = Array(nodes.dropFirst(32))
        let coldPulse = SettingsBenchmarkHeartbeat()
        let heartbeat = coldPulse.start()
        defer { heartbeat.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        model.setVisiblePresenceDemand(coldNodes, owner: owner, isActive: true)
        let navigate = Task { @MainActor in
            try await wait("first sidebar submission") { await !checker.requests.isEmpty }
            return try await measureNavigation(store, to: navigation)
        }
        defer { navigate.cancel() }
        try await settle(coldRows, nodes: coldNodes, total: 32, checker: checker, category: category, enabled: enabled)
        let coldMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        heartbeat.cancel()
        await heartbeat.value
        let coldSamples = await checker.samples
        try validate(coldSamples, rows: coldRows, category: category, enabled: enabled)
        let mainPane = try await navigate.value

        model.setVisiblePresenceDemand(coldNodes, owner: owner, isActive: true)
        try await Task.sleep(for: .milliseconds(20))
        let warmCalls = await checker.requests.count - coldRows.count
        try #require(warmCalls == 0)
        model.setVisiblePresenceDemand(secondNodes, owner: owner, isActive: true)
        try await settle(secondRows, nodes: secondNodes, total: 64, checker: checker, category: category, enabled: enabled)
        let beforeReturn = await checker.requests.count
        let allSamples = await checker.samples
        try #require(beforeReturn == rows.count)
        try validate(Array(allSamples.dropFirst(coldRows.count)), rows: secondRows, category: category, enabled: enabled)
        model.setVisiblePresenceDemand(coldNodes, owner: owner, isActive: true)
        try await Task.sleep(for: .milliseconds(20))
        let returnCalls = await checker.requests.count - beforeReturn
        let peak = await checker.peakSubmitted
        let captured = await checker.capturedExpectedOptions
        try #require(returnCalls == 0 && peak <= 2 && captured)
        let overlaps = coldSamples.filter {
            $0.startedUptime < mainPane.finishedUptime && $0.finishedUptime > mainPane.startedUptime
        }.count
        return Viewport(coldMilliseconds: coldMilliseconds, coldProviderCalls: coldSamples.count,
                        warmAdditionalProviderCalls: warmCalls, secondViewportProviderCalls: beforeReturn - coldRows.count,
                        additionalProviderCallsAfterReturning: returnCalls, maximumSubmittedProviderCalls: peak,
                        coldViewportHeartbeatDelayMilliseconds: coldPulse.samples, navigation: mainPane,
                        overlappingPresenceCalls: overlaps, coldProbes: coldSamples)
    }

    private func settle(_ rows: [Row], nodes: [SidebarNode], total: Int, checker: MeasuredSidebarSettingsPresence,
                        category: SettingsBenchmarkCategory, enabled: Bool) async throws {
        try await wait("viewport settlement \(category.rawValue)/\(enabled)") {
            guard await checker.samples.count == total else { return false }
            return zip(rows, nodes).allSatisfy { row, node in
                let outcome = expected(row, in: category, enabled: enabled)
                guard let knowledge = node.presenceKnowledge, knowledge.source == .probe else { return false }
                return knowledge.presence == outcome.presence && knowledge.uncertainty == outcome.uncertainty
            }
        }
    }

    private func validate(_ samples: [SettingsProbeSample], rows: [Row],
                          category: SettingsBenchmarkCategory, enabled: Bool) throws {
        let rowsByName = Dictionary(uniqueKeysWithValues: rows.map { ($0.folder.lastPathComponent, $0) })
        try #require(samples.count == rowsByName.count && Set(samples.map(\.row)) == Set(rowsByName.keys))
        let inventoryExpected = enabled && category.enabledOptions.network ? 1 : 0
        let localDeferral = !enabled && (category == .protectedLocal || category == .cloud)
        for sample in samples {
            let row = try #require(rowsByName[sample.row])
            let outcome = expected(row, in: category, enabled: enabled)
            let uncertainty = outcome.uncertainty.map { String(describing: $0) }
            try #require(sample.outcome == String(describing: outcome.presence) && sample.uncertainty == uncertainty)
            try #require(sample.mountInventoryOperations == inventoryExpected)
            if localDeferral {
                try #require(sample.traversalOperations == 0 && sample.streamNextCalls == 0)
                continue
            }
            try #require(sample.traversalOperations > 0)
            if category == .network && !enabled {
                try #require(sample.streamNextCalls == 0 && !sample.hasLocalIdentity && sample.modeledDelayMilliseconds == 0)
                continue
            }
            try #require(sample.streamNextCalls > 0)
            if category.isBounded {
                try #require(sample.streamNextCalls <= 256 && sample.childSamples <= 32)
                if row.kind == .exceedsStreamBudget { try #require(sample.streamNextCalls == 256) }
            } else if row.kind == .exceedsStreamBudget {
                try #require(sample.entriesExamined == 270 && sample.streamNextCalls > 256)
            }
            if row.kind == .structural { try #require(sample.childSamples > 0) }
            let delayExpected = category == .network ? SettingsBenchmarkFileSystem.remoteDelaySeconds * 1_000 : 0
            try #require(sample.modeledDelayMilliseconds == delayExpected)
            try #require(sample.hasLocalIdentity == (category != .network && outcome.uncertainty != .policyDeferred))
        }
    }

    private func loaded(_ store: ExplorerStore, at folder: URL) -> Bool {
        store.activeTab.url == folder && store.activeTab.hasLoaded && !store.activeTab.isLoading
            && !store.activeTab.isUnavailable
    }

    private func measureNavigation(_ store: ExplorerStore, to target: URL) async throws -> Navigation {
        let heartbeat = SettingsBenchmarkHeartbeat()
        let pulse = heartbeat.start()
        defer { pulse.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        store.navigate(to: target)
        try await wait("main-pane navigation") { loaded(store, at: target) }
        let finish = ProcessInfo.processInfo.systemUptime
        pulse.cancel()
        await pulse.value
        return Navigation(startedUptime: start, finishedUptime: finish, milliseconds: (finish - start) * 1_000,
                          heartbeatDelayMilliseconds: heartbeat.samples)
    }
}

@MainActor
private final class SettingsBenchmarkHeartbeat {
    private(set) var samples: [Double] = []

    func start() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { break }
                samples.append(max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000 - 5))
            }
        }
    }
}
