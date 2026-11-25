import AppKit
import Combine
import ExplorerCore

/// The sidebar and drives view share one mount snapshot across all application windows.
@MainActor
final class SidebarLocationCatalog: ObservableObject {
    struct Snapshot: Equatable {
        var volumes: [SidebarVolume] = []
        var accounts: [SidebarAccount] = []
    }

    static let shared: SidebarLocationCatalog = {
        let catalog = SidebarLocationCatalog()
        catalog.startObserving()
        return catalog
    }()

    @Published private(set) var snapshot = Snapshot()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshPending = false
    private var volumeWorker: Task<Void, Never>?
    private var accountWorker: Task<Void, Never>?
    private var accountsPending = false
    private var accountGeneration: UInt64 = 0
    private var lastRefresh = Date.distantPast

    private let readVolumes: @Sendable () async -> [SidebarVolume]
    private let readAccounts: @Sendable ([SidebarVolume]) async -> [SidebarAccount]

    init(readVolumes: @escaping @Sendable () async -> [SidebarVolume] = {
        await Task.detached(priority: .utility) { SidebarVolume.mounted() }.value
    }, readAccounts: @escaping @Sendable ([SidebarVolume]) async -> [SidebarAccount] = { volumes in
        await SidebarAccount.discover(homeURL: FileManager.default.homeDirectoryForCurrentUser, volumes: volumes)
    }) {
        self.readVolumes = readVolumes
        self.readAccounts = readAccounts
    }

    func update(volumes: [SidebarVolume], accounts: [SidebarAccount]) {
        var seen = Set<String>()
        let next = Snapshot(volumes: volumes.filter { seen.insert($0.id).inserted }, accounts: accounts)
        if snapshot != next { snapshot = next }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refresh()
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastRefresh) >= 30 else { return }
            self.refresh()
        }.store(in: &subscriptions)
        refresh()
    }

    func refresh() {
        refreshPending = true
        accountGeneration &+= 1
        guard volumeWorker == nil else { return }
        volumeWorker = Task { [weak self] in
            guard let self else { return }
            while refreshPending {
                refreshPending = false
                lastRefresh = Date()
                let volumes = await readVolumes()
                guard !refreshPending else { continue }
                let removed = snapshot.volumes.filter { previous in
                    !volumes.contains { $0.id == previous.id && $0.url == previous.url }
                }
                let accounts = snapshot.accounts.filter { account in
                    !removed.contains { account.url.pathComponents.starts(with: $0.url.pathComponents) }
                }
                update(volumes: volumes, accounts: accounts)
                refreshAccounts()
            }
            volumeWorker = nil
        }
    }

    private func refreshAccounts() {
        accountsPending = true
        guard accountWorker == nil else { return }
        accountWorker = Task { [weak self] in
            guard let self else { return }
            while accountsPending {
                accountsPending = false
                let generation = accountGeneration
                let accounts = await readAccounts(snapshot.volumes)
                if generation == accountGeneration { update(volumes: snapshot.volumes, accounts: accounts) }
            }
            accountWorker = nil
        }
    }
}
