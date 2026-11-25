import AppKit
@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor ControlledFolderPresence: FolderChildPresenceChecking {
    private(set) var requests: [FolderChildPresenceRequest] = []
    private var replies: [Int: CheckedContinuation<FolderChildPresenceResult, Never>] = [:]

    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        await withCheckedContinuation { continuation in
            replies[requests.count] = continuation
            requests.append(request)
        }
    }

    func reply(_ index: Int, _ presence: FolderChildPresence) {
        reply(index, result: .init(presence: presence))
    }

    func reply(_ index: Int, result: FolderChildPresenceResult) {
        replies.removeValue(forKey: index)?.resume(returning: result)
    }

    func finish() {
        for continuation in replies.values { continuation.resume(returning: .init(presence: .unknown)) }
        replies.removeAll()
    }
}

private actor RecordingFolderPresence: FolderChildPresenceChecking {
    private(set) var requests: [FolderChildPresenceRequest] = []

    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        requests.append(request)
        return FolderChildPresenceResult(presence: .unknown)
    }
}

private final class HeldSidebarProbeBodies: FolderChildPresenceChecking, @unchecked Sendable {
    // Use the real lane implementation without competing with a separate test
    // that also deliberately holds both slots of the process-wide executor.
    private let executor = BlockingIOExecutor()
    private let lock = NSLock()
    private let permits = DispatchSemaphore(value: 0)
    private var submitted: [FolderChildPresenceRequest] = []
    private var started = 0
    private var active = 0
    private var peak = 0

    var requests: [FolderChildPresenceRequest] { lock.withLock { submitted } }
    var startCount: Int { lock.withLock { started } }
    var peakCount: Int { lock.withLock { peak } }

    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        let index = lock.withLock {
            submitted.append(request)
            return submitted.count - 1
        }
        return (try? await executor.run(on: .sidebarPresence) { [self] _ in
            lock.withLock {
                started += 1
                active += 1
                peak = max(peak, active)
            }
            defer { lock.withLock { active -= 1 } }
            if index < 2 { permits.wait() }
            // Return a late result even if the task was cancelled.
            return FolderChildPresenceResult(presence: index < 2 ? .absent : .present)
        }) ?? .init(presence: .unknown)
    }

    func readNames(in directory: URL) async throws -> [String] {
        try await executor.run(on: .read) { _ in
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
    }

    func releaseOne() { permits.signal() }
    func releaseAll() { permits.signal(); permits.signal() }
}

@MainActor
struct SidebarPresenceTests {
    private let homeURL = URL(fileURLWithPath: "/tmp/sidebar-presence-test", isDirectory: true)

    @Test
    func hiddenPolicyAndReplacementOwnerKeepObsoleteCallsInTheirSlots() async throws {
        let checker = ControlledFolderPresence()
        let model = SidebarModel(homeURL: homeURL, pins: PinnedFolderStore(homeURL: homeURL), presenceChecker: checker)
        defer { model.cancelLoads(); Task { await checker.finish() } }
        let nodes = model.roots.filter { $0.key == "home" || $0.key.hasPrefix("favorite:") }
        let old = UUID(), replacement = UUID()
        model.attachPresenceOwner(old)
        model.setVisiblePresenceDemand(Array(nodes.prefix(3)), owner: old, isActive: true)
        try await waitUntil { await checker.requests.count == 2 }
        model.setShowHidden(true)
        model.attachPresenceOwner(replacement)
        model.setVisiblePresenceDemand([nodes[2]], owner: replacement, isActive: true)
        model.detachPresenceOwner(old)
        #expect(await checker.requests.count == 2)
        await checker.reply(0, .absent)
        try await waitUntil { await checker.requests.count == 3 }
        let requests = await checker.requests
        #expect(requests[0..<2].allSatisfy { !$0.showHidden })
        #expect(requests[2].showHidden && requests[2].url == nodes[2].url)
        #expect(nodes[0].isExpandable && nodes[1].isExpandable)
        await checker.reply(1, .absent)
        await checker.reply(2, .absent)
        try await waitUntil { !nodes[2].isExpandable }
        let oldNodesStillExpandable = nodes.prefix(2).allSatisfy { $0.isExpandable }
        #expect(oldNodesStillExpandable)
        model.detachPresenceOwner(replacement)
        model.invalidateVisiblePresence()
        #expect(await checker.requests.count == 3)
    }

    @Test
    func acceptedSnapshotSupersedesHeldProbeAndUnchangedResultsDoNotReload() async throws {
        let checker = ControlledFolderPresence()
        var time = 0.0
        let model = SidebarModel(homeURL: homeURL, pins: PinnedFolderStore(homeURL: homeURL), presenceChecker: checker,
                                 presenceNow: { time })
        defer { model.cancelLoads(); Task { await checker.finish() } }
        let home = try #require(model.roots.first { $0.key == "home" })
        let owner = UUID()
        model.attachPresenceOwner(owner)
        model.setVisiblePresenceDemand([home], owner: owner, isActive: true)
        try await waitUntil { await checker.requests.count == 1 }
        let absent = DirectorySnapshot(items: [], isStructureComplete: true)
        model.observePhysicalSnapshot(at: homeURL, snapshot: absent, showHidden: false, explicitlyOpened: true)
        try await waitUntil { model.presenceRevision == 1 }
        #expect(!home.isExpandable && home.children.isEmpty)
        #expect(model.takeDirtyPresenceNodes(owner: owner) == [ObjectIdentifier(home)])
        await checker.reply(0, .present)
        model.observePhysicalSnapshot(at: homeURL, snapshot: absent, showHidden: false, explicitlyOpened: false)
        #expect(!home.isExpandable && model.presenceRevision == 1)
        let childURL = homeURL.appendingPathComponent("New", isDirectory: true)
        let child = FileItem(url: childURL, name: "New", isDirectory: true, isSymbolicLink: false,
                             size: nil, modifiedAt: nil, kind: "File folder")
        model.observePhysicalSnapshot(at: homeURL, snapshot: DirectorySnapshot(items: [child]),
                                      showHidden: true, explicitlyOpened: false)
        #expect(!home.isExpandable)
        model.observePhysicalSnapshot(at: homeURL, snapshot: DirectorySnapshot(items: [child]),
                                      showHidden: false, explicitlyOpened: false)
        try await waitUntil { home.isExpandable && model.presenceRevision == 2 }
        #expect(home.children.isEmpty && !home.expanded)
        time = 14
        model.setVisiblePresenceDemand([home], owner: owner, isActive: true)
        #expect(await checker.requests.count == 1)
        time = 15
        model.setVisiblePresenceDemand([], owner: owner, isActive: false)
        #expect(await checker.requests.count == 1)
        model.setVisiblePresenceDemand([home], owner: owner, isActive: true)
        try await waitUntil { await checker.requests.count == 2 }
        await checker.reply(1, .unknown)
        try await waitUntil { home.presence == .unknown }
        #expect(home.isExpandable && model.presenceRevision == 2)
    }

    @Test
    func cacheEvictsTheLeastRecentlyUsedIdentityAndKeepsAliasKeysDistinct() throws {
        let cache = SidebarPresenceCache(homeURL: homeURL, checker: ControlledFolderPresence(), now: { 0 })
        defer { cache.close() }
        func candidate(_ index: Int, identity: LocalFileIdentity? = nil) -> SidebarPresenceCache.Candidate {
            let url = homeURL.appendingPathComponent(String(index), isDirectory: true)
            return .init(key: .init(url, showHidden: false), url: url, identity: identity)
        }
        let identity = LocalFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)
        let replacement = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 1, birthNanoseconds: 0)
        for index in 0..<256 {
            cache.observe(.init(presence: .absent, directoryIdentity: identity),
                          candidate: candidate(index), explicitlyOpened: false)
        }
        #expect(cache.result(for: candidate(0, identity: replacement)) == nil)
        #expect(cache.result(for: candidate(0, identity: identity))?.presence == .absent)
        cache.observe(.init(presence: .present), candidate: candidate(256), explicitlyOpened: false)
        #expect(cache.result(for: candidate(1)) == nil)
        #expect(cache.result(for: candidate(0))?.presence == .absent)
        #expect(cache.result(for: candidate(256))?.presence == .present)
        #expect(SidebarPresenceCache.Key(URL(fileURLWithPath: "/private/tmp/side", isDirectory: true), showHidden: false)
            != SidebarPresenceCache.Key(URL(fileURLWithPath: "/tmp/side", isDirectory: true), showHidden: false))
    }

    @Test
    func forgettingReplacedIdentityClearsBothHiddenPolicies() {
        let cache = SidebarPresenceCache(homeURL: homeURL, checker: ControlledFolderPresence(), now: { 0 })
        defer { cache.close() }
        let candidates = [false, true].map {
            SidebarPresenceCache.Candidate(key: .init(homeURL, showHidden: $0), url: homeURL, identity: nil)
        }
        for candidate in candidates {
            cache.observe(.init(presence: .absent), candidate: candidate, explicitlyOpened: true)
            #expect(cache.result(for: candidate)?.presence == .absent)
        }
        cache.forgetIdentity(at: homeURL)
        for candidate in candidates { #expect(cache.result(for: candidate) == nil) }
    }

    @Test
    func structuralUncertaintyKeepsAnAuthoritativePresentAndAdvancesItsBackoff() async throws {
        let checker = ControlledFolderPresence()
        var time = 0.0
        let cache = SidebarPresenceCache(homeURL: homeURL, checker: checker, now: { time })
        defer { cache.close(); Task { await checker.finish() } }
        let identity = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 0)
        let candidate = SidebarPresenceCache.Candidate(key: .init(homeURL, showHidden: false),
                                                       url: homeURL, identity: identity)
        let present = FolderChildPresenceResult(presence: .present, directoryIdentity: identity)
        let structural = FolderChildPresenceResult(presence: .unknown, directoryIdentity: identity,
                                                   uncertainty: .structural)
        var publications: [FolderChildPresence] = []
        cache.onResult = { _, result in publications.append(result.presence) }
        cache.observe(present, candidate: candidate, explicitlyOpened: true)
        time = 15
        cache.setDemand([candidate])
        try await waitUntil { await checker.requests.count == 1 }
        await checker.reply(0, result: structural)
        try await waitUntil { publications == [.present] }
        #expect(cache.result(for: candidate)?.presence == .present)
        time = 44
        cache.setDemand([candidate])
        #expect(await checker.requests.count == 1)
        time = 45
        cache.setDemand([candidate])
        try await waitUntil { await checker.requests.count == 2 }
        await checker.reply(1, result: .init(presence: .absent, directoryIdentity: identity))
        try await waitUntil { publications == [.present, .absent] }
        #expect(cache.result(for: candidate)?.presence == .absent)
    }

    @Test(arguments: [false, true])
    func policyChangeRetainsForegroundKnowledgeAfterACompatibleProbe(structural: Bool) async throws {
        let checker = ControlledFolderPresence()
        var time = 0.0
        let cache = SidebarPresenceCache(homeURL: homeURL, checker: checker, now: { time })
        defer { cache.close(); Task { await checker.finish() } }
        let identity = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 0)
        let candidate = SidebarPresenceCache.Candidate(key: .init(homeURL, showHidden: false),
                                                       url: homeURL, identity: identity)
        let present = FolderChildPresenceResult(presence: .present, directoryIdentity: identity)
        let probe = structural
            ? FolderChildPresenceResult(presence: .unknown, directoryIdentity: identity, uncertainty: .structural)
            : present
        var didPublish = false
        cache.onResult = { _, _ in didPublish = true }
        cache.observe(present, candidate: candidate, explicitlyOpened: true)
        time = 15
        cache.setDemand([candidate])
        try await waitUntil { await checker.requests.count == 1 }
        await checker.reply(0, result: probe)
        try await waitUntil { didPublish }
        #expect(cache.result(for: candidate)?.presence == .present)

        #expect(cache.setBackgroundCheckOptions(.init(network: true)))
        #expect(cache.result(for: candidate)?.presence == .present)
        cache.setDemand([candidate])
        // Its independently observed value survives. The speculative retry
        // extension expires with the old policy.
        try await waitUntil { await checker.requests.count == 2 }
        #expect(await checker.requests[1].options.network)
    }

    @Test
    func nativeOutlineGuardsLeafExpansionAndUsesOnlyIntersectingRows() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("ExplorerSidebarOutline-" + UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let model = SidebarModel(homeURL: fixture, pins: PinnedFolderStore(homeURL: fixture))
        let store = ExplorerStore(initialURL: fixture)
        defer { model.cancelLoads(); store.cancelLoads() }
        let coordinator = SidebarOutline.Coordinator(store: store, model: model)
        let outline = NavigationOutlineView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        outline.headerView = nil
        outline.rowHeight = 24
        let column = NSTableColumn(identifier: .init("destination"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 85))
        scroll.documentView = outline
        coordinator.attachViewport(scroll)
        defer { coordinator.detachViewport() }
        coordinator.update()

        let home = try #require(model.roots.first { $0.key == "home" })
        let initiallyVisible = SidebarOutline.Coordinator.visibleFolderRows(in: outline)
        try #require(initiallyVisible.contains { $0 === home })
        let last = try #require(model.roots.first { $0.key == "favorite:Movies" })
        #expect(!initiallyVisible.contains { $0 === last })
        let lastRow = outline.row(forItem: last)
        try #require(lastRow >= 0)
        outline.scrollRowToVisible(lastRow)
        #expect(!SidebarOutline.Coordinator.visibleFolderRows(in: outline).contains { $0 === home })

        outline.expandItem(home)
        try await waitUntil { home.state == .loaded }
        coordinator.update()
        #expect(!outline.isItemExpanded(home))
        #expect(!coordinator.outlineView(outline, shouldExpandItem: home))
        #expect(!coordinator.outlineView(outline, shouldShowOutlineCellForItem: home))
        outline.expandItem(home)
        #expect(!outline.isItemExpanded(home))

        let child = fixture.appendingPathComponent("Branch", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: false)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture)
        model.observePhysicalSnapshot(at: fixture, snapshot: snapshot, showHidden: false, explicitlyOpened: false)
        try await waitUntil { model.presenceRevision == 1 }
        coordinator.update()
        #expect(coordinator.outlineView(outline, shouldShowOutlineCellForItem: home))
        outline.expandItem(home)
        try await waitUntil { home.expanded && home.state == .loaded }
        #expect(home.children.map(\.title) == ["Branch"])
    }

    @Test
    func startupAndHiddenReloadDoNotGrantProtectedScopeButExplicitRefreshDoes() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("ExplorerSidebarGrant-" + UUID().uuidString)
        let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let checker = RecordingFolderPresence()
        let store = ExplorerStore(initialURL: documents, homeURL: fixture, sidebarPresenceChecker: checker)
        defer { store.cancelLoads() }
        let model = store.sidebarModel
        let node = try #require(model.roots.first { $0.key == "favorite:Documents" })
        let owner = UUID()
        model.attachPresenceOwner(owner)
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        model.setVisiblePresenceDemand([node], owner: owner, isActive: true)
        model.invalidateVisiblePresence()
        try await waitUntil { !(await checker.requests).isEmpty }
        #expect(await checker.requests.allSatisfy { $0.openedProtectedScopes.isEmpty })

        store.toggleHidden()
        try await waitUntil { model.showHidden && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        model.invalidateVisiblePresence()
        try await waitUntil { await checker.requests.contains { $0.showHidden } }
        #expect(await checker.requests.allSatisfy { $0.openedProtectedScopes.isEmpty })

        store.refresh()
        try await waitUntil { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        model.invalidateVisiblePresence()
        try await waitUntil {
            await checker.requests.contains { request in
                request.openedProtectedScopes.contains { $0.path == store.activeTab.url.path }
            }
        }
    }

    @Test
    func sharedSettingsReachLiveAndLazyStores() async throws {
        let preferences = SidebarBackgroundCheckPreferences()
        let checker = RecordingFolderPresence()
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerSharedSidebar-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func makeStore(home: String) -> ExplorerStore {
            ExplorerStore(initialURL: fixture, homeURL: fixture.appendingPathComponent(home, isDirectory: true),
                          sidebarPresenceChecker: checker, sidebarBackgroundCheckPreferences: preferences)
        }
        let first = makeStore(home: "First")
        let second = makeStore(home: "Second")
        let lazy = ExplorerStore(initialURL: fixture, homeURL: fixture,
                                 sidebarPresenceChecker: checker, sidebarBackgroundCheckPreferences: preferences)
        let liveModels = [first.sidebarModel, second.sidebarModel]
        preferences.set(.cloud, enabled: true)

        let new = makeStore(home: "New")
        let detached = ExplorerStore(tab: BrowserTab(url: fixture),
                                     homeURL: fixture.appendingPathComponent("Detached", isDirectory: true),
                                     sidebarPresenceChecker: checker, sidebarBackgroundCheckPreferences: preferences)
        defer { [first, second, lazy, new, detached].forEach { $0.cancelLoads() } }
        try await waitUntil { lazy.activeTab.hasLoaded && !lazy.activeTab.isLoading }
        let lazyModel = lazy.sidebarModel
        // The completed empty startup listing could only mark the Home node
        // absent if the preference notification had already created a model.
        #expect(lazyModel.roots.first { $0.key == "home" }?.presence == .unknown)
        let models = liveModels + [lazyModel, new.sidebarModel, detached.sidebarModel]
        var expectedPaths: Set<String> = []
        for model in models {
            let node = try #require(model.roots.first { $0.key == "home" })
            expectedPaths.insert(try #require(node.url).path)
            let owner = UUID()
            model.attachPresenceOwner(owner)
            model.setVisiblePresenceDemand([node], owner: owner, isActive: true)
        }
        try await waitUntil { await checker.requests.count >= models.count }
        let requests = await checker.requests
        #expect(Set(requests.map { $0.url.path }) == expectedPaths)
        #expect(requests.allSatisfy { $0.options == .init(cloud: true) })
    }

    @Test
    func policyChangeRestoresEvictedProbeLeafAndKeepsIdenticalForegroundLeaf() async throws {
        let manager = FileManager.default
        let homeURL = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ExplorerEvictedSidebar-" + UUID().uuidString, isDirectory: true)
        let desktop = homeURL.appendingPathComponent("Desktop", isDirectory: true)
        let desktopChild = desktop.appendingPathComponent("Child", isDirectory: true)
        try manager.createDirectory(at: desktopChild, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: homeURL) }
        let checker = ControlledFolderPresence()
        let model = SidebarModel(homeURL: homeURL, pins: PinnedFolderStore(homeURL: homeURL),
                                 presenceChecker: checker, presenceNow: { 0 })
        defer { model.cancelLoads(); Task { await checker.finish() } }
        let favorites = model.roots.filter { $0.key == "home" || $0.key.hasPrefix("favorite:") }
        let foreground = favorites[0]
        let probeOnly = favorites[1]
        let owner = UUID()
        model.attachPresenceOwner(owner)
        model.setVisiblePresenceDemand([foreground, probeOnly], owner: owner, isActive: true)
        try await waitUntil { await checker.requests.count == 2 }
        await checker.reply(0, .absent)
        await checker.reply(1, .absent)
        try await waitUntil { !foreground.isExpandable && !probeOnly.isExpandable && model.presenceRevision > 0 }
        _ = model.takeDirtyPresenceNodes(owner: owner)
        let revision = model.presenceRevision

        let empty = DirectorySnapshot(items: [], isStructureComplete: true)
        model.observePhysicalSnapshot(at: homeURL, snapshot: empty, showHidden: false, explicitlyOpened: true)
        #expect(model.presenceRevision == revision)
        #expect(model.takeDirtyPresenceNodes(owner: owner).isEmpty)
        model.setVisiblePresenceDemand([], owner: owner, isActive: false)

        // These unrelated accepted snapshots exceed the cache cap. The two
        // existing tree nodes retain their evidence source after eviction.
        for index in 0..<256 {
            let unrelated = homeURL.appendingPathComponent("offscreen-\(index)", isDirectory: true)
            model.observePhysicalSnapshot(at: unrelated, snapshot: empty, showHidden: false, explicitlyOpened: false)
        }
        model.setBackgroundCheckOptions(.init(cloud: true))
        #expect(foreground.presence == .absent && foreground.state == .loaded)
        #expect(probeOnly.presence == .unknown && probeOnly.isExpandable && probeOnly.state == .idle)
        #expect(probeOnly.children.map(\.title) == ["Loading folders…"])
        try await waitUntil { model.presenceRevision == revision + 1 }
        #expect(model.takeDirtyPresenceNodes(owner: owner) == [ObjectIdentifier(probeOnly)])
        #expect(await checker.requests.count == 2)

        model.setVisiblePresenceDemand([foreground], owner: owner, isActive: true)
        try await waitUntil { await checker.requests.count == 3 }
        let next = await checker.requests[2]
        #expect(next.options.cloud && next.openedProtectedScopes == [homeURL])
        model.expand(probeOnly)
        try await waitUntil { probeOnly.state == .loaded }
        let child = try #require(probeOnly.children.first)
        #expect(child.url?.path == desktopChild.path)
        model.setBackgroundCheckOptions(.init(network: true))
        #expect(probeOnly.expanded && probeOnly.presence == .present && probeOnly.children.first === child)
    }

    @Test
    func policyChangeReschedulesActiveDemandWithoutWakingInactiveOrClosedModels() async throws {
        let preferences = SidebarBackgroundCheckPreferences()
        let checker = RecordingFolderPresence()
        let first = ExplorerStore(initialURL: homeURL.appendingPathComponent("initial"), homeURL: homeURL,
                                  sidebarPresenceChecker: checker, sidebarBackgroundCheckPreferences: preferences)
        let second = ExplorerStore(initialURL: homeURL.appendingPathComponent("other-initial"),
                                   homeURL: homeURL.appendingPathComponent("inactive", isDirectory: true),
                                   sidebarPresenceChecker: checker, sidebarBackgroundCheckPreferences: preferences)
        defer { first.cancelLoads(); second.cancelLoads() }
        let live = first.sidebarModel, inactive = second.sidebarModel
        let liveNode = try #require(live.roots.first { $0.key == "home" })
        let inactiveNode = try #require(inactive.roots.first { $0.key == "home" })
        let liveOwner = UUID(), inactiveOwner = UUID()
        live.attachPresenceOwner(liveOwner)
        inactive.attachPresenceOwner(inactiveOwner)
        live.setVisiblePresenceDemand([liveNode], owner: liveOwner, isActive: true)
        inactive.setVisiblePresenceDemand([inactiveNode], owner: inactiveOwner, isActive: false)
        try await waitUntil { await checker.requests.count == 1 }

        preferences.set(.cloud, enabled: true)
        try await waitUntil { await checker.requests.count >= 2 }
        #expect(await checker.requests.map(\.options) == [.init(), .init(cloud: true)])
        preferences.set(.cloud, enabled: true)
        second.cancelLoads()
        preferences.set(.network, enabled: true)
        try await waitUntil { await checker.requests.count >= 3 }
        #expect(await checker.requests.map(\.options) == [.init(), .init(cloud: true), .init(cloud: true, network: true)])
        #expect(await checker.requests.allSatisfy { $0.url == liveNode.url })
    }

    @Test
    func rapidPolicyChangesKeepBothPhysicalSlotsAndIgnoreLateResults() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("ExplorerSidebarHeld-" + UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let visibleChild = fixture.appendingPathComponent("Visible", isDirectory: true)
        try manager.createDirectory(at: visibleChild, withIntermediateDirectories: false)

        let checker = HeldSidebarProbeBodies()
        let on = SidebarBackgroundCheckOptions(protectedLocal: true)
        let model = SidebarModel(homeURL: fixture, pins: PinnedFolderStore(homeURL: fixture),
                                 presenceChecker: checker, backgroundCheckOptions: on)
        defer { model.cancelLoads(); checker.releaseAll() }
        let favorites = model.roots.filter { $0.key == "home" || $0.key.hasPrefix("favorite:") }
        let ordinary = favorites[0]
        let protected = Array(favorites[1...2])
        let owner = UUID()
        model.attachPresenceOwner(owner)
        model.setVisiblePresenceDemand(protected, owner: owner, isActive: true)
        try await waitUntil { checker.startCount == 2 }
        #expect(checker.requests.map(\.options) == [on, on])

        model.setBackgroundCheckOptions(.init())
        model.setVisiblePresenceDemand([ordinary] + protected, owner: owner, isActive: true)
        let store = ExplorerStore(initialURL: fixture, loader: LocalDirectoryLoader())
        defer { store.cancelLoads() }
        var laneReadNames: [String]?
        let laneRead = Task { laneReadNames = try await checker.readNames(in: fixture) }
        defer { laneRead.cancel() }
        try await waitUntil { store.activeTab.hasLoaded && !store.activeTab.isLoading && laneReadNames != nil }
        #expect(store.activeTab.items.map(\.name) == ["Visible"])
        #expect(laneReadNames == ["Visible"])
        #expect(checker.requests.count == 2 && checker.startCount == 2)
        #expect(ordinary.presence == .unknown)

        model.setBackgroundCheckOptions(on)
        await Task.yield()
        #expect(checker.requests.count == 2 && checker.startCount == 2)
        checker.releaseOne()
        try await waitUntil { ordinary.presence == .present }
        #expect(protected.allSatisfy { $0.presence != .absent })
        #expect(checker.requests.dropFirst(2).first?.url == ordinary.url)
        #expect(checker.requests.allSatisfy { $0.options == on })
        checker.releaseAll()
        try await waitUntil { protected.allSatisfy { $0.presence == .present } }
        #expect(checker.peakCount == 2)
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let matched = await predicate()
        try #require(matched)
    }
}
