import ExplorerCore
import Foundation

/// Bridges admitted display observations to a disposable, asynchronous history store.
@MainActor
final class OneDriveBadgeHistory {
    typealias Store = OneDrivePolicyHistoryStore
    typealias NamespaceLookup = @Sendable (URL) async -> Store.Namespace?
    private struct Slot {
        let id: UUID
        let generation: UInt64
        var ticket: Store.Ticket?
    }
    private struct Fence {
        let id: UUID
        let task: Task<Store.Ticket?, Never>
    }
    private let store: Store
    private let namespace: NamespaceLookup
    private var namespaces: [String: (id: UUID, task: Task<Store.Namespace?, Never>)] = [:]
    private var verifiedNamespaces: [String: Store.Namespace] = [:]
    var namespaceChanged: (@MainActor (String) -> Void)?

    func retainNamespaces(for accounts: Set<String>) {
        verifiedNamespaces = verifiedNamespaces.filter { accounts.contains($0.key) }
    }
    private var slots: [OneDriveStatusKey: Slot] = [:]
    private var preparingAccounts = Set<String>()
    private var fences: [String: Fence] = [:]
    private var operations: [OneDriveStatusRequestToken: Task<Store.Ticket?, Never>] = [:]
    private var retired = Set<String>()
    private var importsDisabled = false

    init(store: Store, namespace: @escaping NamespaceLookup) {
        self.store = store
        self.namespace = namespace
    }

    static func live() -> OneDriveBadgeHistory? {
        guard Bundle.main.bundleIdentifier == "dev.native-explorer.app" else { return nil }
        let manager = FileManager.default
        let directory: URL
        if let raw = ProcessInfo.processInfo.environment["MAXPLORER_ONEDRIVE_POLICY_CACHE_DIRECTORY"] {
            let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            let run = url.deletingLastPathComponent()
            guard url.path == raw, url.lastPathComponent.hasPrefix("policy-cache"),
                  run.lastPathComponent.range(of: "^zip-browsing-[a-z0-9-]+-[a-f0-9]{32}$", options: .regularExpression) != nil,
                  run.deletingLastPathComponent().path == manager.homeDirectoryForCurrentUser
                    .appendingPathComponent("repos/explorer/validation/runtime", isDirectory: true).path else { return nil }
            directory = url
        } else {
            guard let base = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
            directory = base.appendingPathComponent("dev.native-explorer.app.OneDrivePolicyHistory", isDirectory: true)
        }
        return OneDriveBadgeHistory(store: Store(directory: directory)) { root in
            guard let value = await OneDriveRetentionService.shared.policyHistoryNamespace(for: root) else { return nil }
            return Store.Namespace(rootURL: value.root.absoluteString, rootIdentity: value.identity,
                                   providerIdentifier: value.providerIdentifier, providerVersion: value.providerVersion,
                                   providerStamp: value.providerStamp)
        }
    }

    /// Warm the signed provider check and disposable index while the real directory read runs.
    /// Imports still require a freshly resolved namespace and exact committed, visible row.
    func beginListing(in folder: URL) {
        guard let root = OneDriveRetentionService.accountRoot(in: folder),
              preparingAccounts.count < 4, preparingAccounts.insert(root.absoluteString).inserted else { return }
        let lookup = namespace, store = store
        Task { [weak self] in
            if await lookup(root) != nil { _ = await store.prepare([]) }
            self?.preparingAccounts.remove(root.absoluteString)
        }
    }

    private func rootTask(_ account: String) -> Task<Store.Namespace?, Never> {
        if let pending = namespaces[account] { return pending.task }
        let lookup = namespace, id = UUID()
        let task = Task<Store.Namespace?, Never> { [weak self] in
            guard let root = URL(string: account), root.isFileURL else { return nil }
            let current = await lookup(root)
            // A retired lookup still belongs to any captured disk invalidation fence.
            // Only the latest lookup may change the current in-memory namespace.
            guard let self, self.namespaces[account]?.id == id else { return current }
            let previous = self.verifiedNamespaces[account]
            self.verifiedNamespaces[account] = current
            if let previous, previous != current { self.namespaceChanged?(account) }
            return current
        }
        namespaces[account] = (id, task)
        return task
    }

    func revalidateRoot(for folder: URL) {
        guard let account = OneDriveRetentionService.accountRoot(in: folder)?.absoluteString else { return }
        namespaces.removeValue(forKey: account)
        _ = rootTask(account)
    }

    private static func identity(_ key: OneDriveStatusKey, in root: Store.Namespace) -> Store.Identity? {
        guard key.account == root.rootURL else { return nil }
        return .init(namespace: root, parentURL: key.parent, parentIdentity: key.parentIdentity,
                     fileURL: key.file, fileIdentity: key.identity, version: key.version)
    }

    /// An accepted new listing must discover a remounted root or updated provider.
    func listingChanged(accounts: Set<String>) {
        for account in accounts { namespaces.removeValue(forKey: account) }
        slots = slots.filter { !accounts.contains($0.key.account) }
    }

    func prepare(_ visible: [OneDriveStatusKey: UInt64],
                 receive: @escaping @MainActor (OneDriveStatusKey, UInt64, Store.Hint) -> Void) {
        slots = slots.filter { visible[$0.key] == $0.value.generation }
        let accounts = Set(visible.keys.map(\.account))
        namespaces = namespaces.filter { accounts.contains($0.key) }
        let pending = visible.filter { slots[$0.key] == nil }
        for (account, entries) in Dictionary(grouping: pending, by: { $0.key.account }) {
            let id = UUID()
            for (key, generation) in entries { slots[key] = Slot(id: id, generation: generation) }
            let root = rootTask(account), store = store
            Task { [weak self] in
                guard let value = await root.value, let self else { return }
                let batch = entries.compactMap { key, _ -> (OneDriveStatusKey, Store.Identity)? in
                    guard self.slots[key]?.id == id, let identity = Self.identity(key, in: value) else { return nil }
                    return (key, identity)
                }
                guard !batch.isEmpty else { return }
                let prepared = await store.prepare(batch.map(\.1))
                for ((key, _), result) in zip(batch, prepared) {
                    guard var slot = self.slots[key], slot.id == id, let result else { continue }
                    slot.ticket = result.ticket
                    self.slots[key] = slot
                    if let hint = result.hint, !self.importsDisabled, !self.retired.contains(key.file) {
                        receive(key, slot.generation, hint)
                    }
                }
            }
        }
    }

    func retire(_ key: OneDriveStatusKey) {
        guard !importsDisabled else { return }
        retired.insert(key.file)
        if retired.count >= 2_048 {
            retired.removeAll()
            importsDisabled = true
        }
    }

    /// Only a new native admission can acquire the latest known disk epoch.
    func ticket(for key: OneDriveStatusKey) -> Store.Ticket? {
        guard fences[key.file] == nil, let ticket = slots[key]?.ticket else { return nil }
        return store.currentTicket(for: ticket)
    }

    func record(_ hint: Store.Hint, ticket: Store.Ticket?) {
        if let ticket { store.enqueue(hint, ticket: ticket) }
    }

    @discardableResult
    func invalidate(_ key: OneDriveStatusKey) -> Task<Store.Ticket?, Never> {
        retire(key)
        let previous = fences[key.file]?.task
        let root = rootTask(key.account), store = store, id = UUID()
        let task = Task<Store.Ticket?, Never> { [weak self] in
            _ = await previous?.value
            let ticket: Store.Ticket?
            if let value = await root.value, let identity = Self.identity(key, in: value) {
                ticket = await store.invalidate(identity)
            } else { ticket = nil }
            if self?.fences[key.file]?.id == id { self?.fences.removeValue(forKey: key.file) }
            return ticket
        }
        fences[key.file] = Fence(id: id, task: task)
        return task
    }

    func begin(_ token: OneDriveStatusRequestToken) {
        operations[token] = invalidate(token.key)
    }

    func finish(_ token: OneDriveStatusRequestToken, hint: Store.Hint?) {
        guard let task = operations.removeValue(forKey: token), let hint else { return }
        let store = store
        Task {
            if let ticket = await task.value { store.enqueue(hint, ticket: ticket) }
        }
    }
}
