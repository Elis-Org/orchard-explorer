import Combine
import ExplorerCore
import Foundation

struct PinnedFolder: Equatable, Identifiable {
    let id: String
    let title: String
    let url: URL
    let symbol: String
}

/// A single ordered list feeds the sidebar and Home. The v1 list stays available
/// to earlier builds. A present, empty v2 list means the user removed every pin.
@MainActor
final class PinnedFolderStore: ObservableObject {
    static let preferencesKey = "nativeExplorer.pinnedFolders.v1"
    private static let orderedKey = "nativeExplorer.pinnedFolders.v2"
    @Published private(set) var entries: [PinnedFolder]
    @Published private(set) var errorMessage: String?
    var urls: [URL] { entries.map(\.url) }
    private let defaults: UserDefaults?
    private let known: [PinnedFolder]

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let home = URL(fileURLWithPath: homeURL.standardizedFileURL.path, isDirectory: true)
        let known = [PinnedFolder(id: "home", title: "Home folder", url: home, symbol: "house.fill")] +
            [("Desktop", "desktopcomputer"), ("Downloads", "arrow.down.circle.fill"), ("Documents", "doc.fill"),
             ("Pictures", "photo.fill"), ("Music", "music.note"), ("Movies", "film.fill")].map { name, symbol in
                PinnedFolder(id: "favorite:" + name, title: name,
                             url: home.appendingPathComponent(name, isDirectory: true), symbol: symbol)
            }
        self.known = known
        let migrating = defaults?.object(forKey: Self.orderedKey) == nil
        let ids = migrating
            ? known.map(\.id) + (defaults?.stringArray(forKey: Self.preferencesKey) ?? []).map { "pin:" + $0 }
            : defaults?.stringArray(forKey: Self.orderedKey) ?? []
        var seen = Set<String>()
        entries = ids.compactMap { id in
            let entry: PinnedFolder
            if let folder = known.first(where: { $0.id == id }) { entry = folder }
            else {
                guard id.hasPrefix("pin:/"), !id.contains("\0"),
                      let url = Self.normalized(URL(fileURLWithPath: String(id.dropFirst(4)), isDirectory: true))
                else { return nil }
                entry = Self.descriptor(for: url, known: known)
            }
            return seen.insert(entry.url.path).inserted ? entry : nil
        }
        if migrating { persist() }
    }

    func contains(_ url: URL) -> Bool {
        guard let normalized = Self.normalized(url) else { return false }
        return entries.contains { $0.url.path == normalized.path }
    }

    @discardableResult
    func pin(_ url: URL) -> Bool {
        guard let normalized = Self.normalized(url) else {
            errorMessage = "Only local folders can be pinned to Quick access."
            return false
        }
        do {
            let values = try FileSystemPath.resolvingExisting(normalized)
                .resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true else {
                errorMessage = "Choose a folder to pin to Quick access."
                return false
            }
            if !contains(normalized) {
                entries.append(Self.descriptor(for: normalized, known: known))
                persist()
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn’t pin \(normalized.lastPathComponent). \(error.localizedDescription)"
            return false
        }
    }

    func unpin(_ url: URL) {
        guard let normalized = Self.normalized(url) else { return }
        entries.removeAll { $0.url.path == normalized.path }
        errorMessage = nil
        persist()
    }

    func dismissError() { errorMessage = nil }
    private func persist() { defaults?.set(entries.map(\.id), forKey: Self.orderedKey) }

    private static func descriptor(for url: URL, known: [PinnedFolder]) -> PinnedFolder {
        known.first { $0.url.path == url.path } ??
            PinnedFolder(id: "pin:" + url.path, title: url.path == "/" ? "File System" : url.lastPathComponent,
                         url: url, symbol: "folder.fill")
    }

    private static func normalized(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}

@MainActor
final class SidebarNode: NSObject {
    enum Kind { case page, folder, message }
    enum LoadState { case idle, loading, loaded, failed }
    let key: String
    let title: String
    let symbol: String
    let kind: Kind
    let url: URL?
    let fileIdentity: LocalFileIdentity?
    let isSymbolicLink: Bool
    var directoryIdentity: LocalFileIdentity?
    var requiresDirectoryRebind = false
    var presenceKnowledge: SidebarPresenceKnowledge?
    var presence: FolderChildPresence { presenceKnowledge?.presence ?? .unknown }
    var children: [SidebarNode] = []
    var separatorBefore = false
    var expanded = false
    var state: LoadState = .idle
    var failure: String?
    weak var retryParent: SidebarNode?
    var isExpandable: Bool {
        kind == .page ? !children.isEmpty : (kind == .folder && presence != .absent)
    }

    init(key: String, title: String, symbol: String = "folder.fill", kind: Kind = .folder, url: URL? = nil,
         fileIdentity: LocalFileIdentity? = nil, isSymbolicLink: Bool = false) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.url = url
        self.fileIdentity = fileIdentity
        self.isSymbolicLink = isSymbolicLink
        directoryIdentity = isSymbolicLink ? nil : fileIdentity
        super.init()
        if kind == .folder { children = [pendingChild()] }
    }

    func pendingChild() -> SidebarNode {
        SidebarNode(key: key + "#pending", title: "Loading folders…", kind: .message)
    }
}

/// A lazy, read-only tree. Expansion is independent from navigation and selection.
/// FR-NAV-001 / EV-9003 / AT-NAV-001; expansion timing is a native adaptation.
@MainActor
final class SidebarModel: ObservableObject {
    @Published private(set) var roots: [SidebarNode] = []
    @Published private(set) var volumes: [SidebarVolume] = []
    @Published private(set) var revision = 0
    @Published private(set) var presenceRevision = 0
    private(set) var showHidden = false
    private let loader: any DirectoryListing
    private let homeURL: URL
    private let presenceCache: SidebarPresenceCache
    private var presenceOwner: UUID?
    private var visiblePresenceNodes: [SidebarNode] = []
    private var dirtyPresenceNodes: Set<ObjectIdentifier> = []
    private var presencePublication: Task<Void, Never>?
    private var demandActive = false
    private var closed = false
    private let pins: PinnedFolderStore
    private let locations: SidebarLocationCatalog
    private var rootSubscription: AnyCancellable?
    // The same location can appear both as a pin and beneath another expanded pin.
    // Each presentation owns its read; a path-derived key would couple those nodes.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var generations: [ObjectIdentifier: UUID] = [:]
    private var rebindReads: Set<ObjectIdentifier> = []

    init(homeURL: URL, pins: PinnedFolderStore, loader: any DirectoryListing = LocalDirectoryLoader(),
         showHidden: Bool = false, presenceChecker: any FolderChildPresenceChecking = LocalFolderChildPresenceChecker(),
         presenceNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         backgroundCheckOptions: SidebarBackgroundCheckOptions = .init(), locations: SidebarLocationCatalog? = nil) {
        self.homeURL = homeURL
        self.loader = loader
        self.pins = pins
        self.locations = locations ?? SidebarLocationCatalog()
        self.showHidden = showHidden
        presenceCache = SidebarPresenceCache(homeURL: homeURL, checker: presenceChecker, now: presenceNow,
                                             options: backgroundCheckOptions)
        presenceCache.onResult = { [weak self] key, result in self?.receivePresence(result, key: key) }
        rootSubscription = pins.$entries.combineLatest(self.locations.$snapshot).sink { [weak self] pins, locations in
            self?.rebuildRoots(pins, locations: locations)
        }
    }

    func expand(_ node: SidebarNode) {
        guard node.isExpandable, !closed else { return }
        node.expanded = true
        if node.kind == .folder, node.state == .idle { read(node, explicitlyOpened: true) }
    }

    func collapse(_ node: SidebarNode) {
        if node.kind == .page {
            node.expanded = false
            for child in node.children where child.expanded { collapse(child) }
            return
        }
        guard node.kind == .folder else { return }
        invalidate(node)
        node.expanded = false
        node.state = .idle
        node.children = node.isExpandable ? [message(for: node, text: "Loading folders…")] : []
        prunePresenceDemand()
        revision += 1
    }

    func retry(_ node: SidebarNode) {
        guard node.kind == .folder, node.isExpandable, !closed else { return }
        node.expanded = true
        read(node, explicitlyOpened: true)
    }

    func setShowHidden(_ value: Bool) {
        guard showHidden != value else { return }
        showHidden = value
        presenceCache.setDemand([])
        func reset(_ node: SidebarNode) {
            if node.kind == .folder {
                node.presenceKnowledge = nil
                if node.children.isEmpty, !node.expanded { node.state = .idle }
            }
            node.children.forEach(reset)
        }
        roots.forEach(reset)
        // Refresh expanded roots only. Descendant snapshots are invalidated together,
        // so a late hidden-file read cannot recreate a removed branch.
        for root in roots {
            let folders = root.kind == .page ? root.children : [root]
            for folder in folders where folder.expanded { read(folder, explicitlyOpened: false) }
        }
        updatePresenceDemand()
        revision += 1
    }

    func setBackgroundCheckOptions(_ options: SidebarBackgroundCheckOptions) {
        guard presenceCache.setBackgroundCheckOptions(options) else { return }
        // Offscreen nodes keep their source even after the bounded cache evicts it.
        func reset(_ node: SidebarNode) {
            if node.presenceKnowledge?.source == .probe {
                let wasExpandable = node.isExpandable
                node.presenceKnowledge = nil
                if !wasExpandable && node.state == .loaded && node.children.isEmpty && !node.expanded {
                    node.state = .idle
                    node.children = [node.pendingChild()]
                }
                if wasExpandable != node.isExpandable { markPresenceDirty(node) }
            }
            node.children.forEach(reset)
        }
        roots.forEach(reset)
        updatePresenceDemand()
    }

    /// Native observation policy for FR-NAV-001 / EV-9003 / AT-NAV-001.
    /// Reuse the current directory's successful snapshot without reading other
    /// folders. This does not promise observation of every expanded sidebar branch.
    func observePhysicalSnapshot(at url: URL, snapshot: DirectorySnapshot, showHidden: Bool,
                                 explicitlyOpened: Bool) {
        guard !closed, self.showHidden == showHidden, snapshot.archiveRevision == nil,
              BrowsingLocation(url: url)?.physicalURL != nil else { return }
        let key = SidebarPresenceCache.Key(url, showHidden: showHidden)
        let folders = eligibleFolders(snapshot.items, at: url)
        let result = snapshotPresence(snapshot, hasFolders: !folders.isEmpty)
        let knowledge = SidebarPresenceKnowledge(result, source: .foreground)
        let observed = SidebarPresenceCache.Candidate(key: key, url: url, identity: snapshot.directoryIdentity)
        presenceCache.observe(result, candidate: observed, explicitlyOpened: explicitlyOpened)
        var changed = false
        func visit(_ node: SidebarNode) {
            if let candidate = candidate(for: node), candidate.key == key {
                if node.requiresDirectoryRebind {
                    if rebindReads.contains(ObjectIdentifier(node)) {
                        if let identity = result.directoryIdentity, identity == candidate.identity {
                            node.requiresDirectoryRebind = false
                            changed = reconcileChildren(of: node, folders: folders, knowledge: knowledge) || changed
                        } else {
                            cancelRead(node)
                            showReadFailure(node, at: url, error: Self.changedFolderError)
                            changed = true
                        }
                    }
                } else if SidebarPresenceCache.matches(knowledge.directoryIdentity, candidate) {
                    if node.expanded {
                        changed = reconcileChildren(of: node, folders: folders, knowledge: knowledge) || changed
                    } else {
                        applyPresence(knowledge, to: node)
                    }
                } else {
                    applyPresence(nil, to: node)
                }
            }
            // Traversal only visits nodes already materialized in memory.
            for child in node.children { visit(child) }
        }
        for root in roots { visit(root) }
        if changed { prunePresenceDemand(); revision += 1 }
    }

    func attachPresenceOwner(_ owner: UUID) {
        guard !closed, presenceOwner != owner else { return }
        presenceOwner = owner
        demandActive = false
        visiblePresenceNodes = []
        presenceCache.setDemand([])
        dirtyPresenceNodes = []
    }

    func setVisiblePresenceDemand(_ nodes: [SidebarNode], owner: UUID, isActive: Bool) {
        guard !closed, presenceOwner == owner else { return }
        let resumed = isActive && !demandActive
        demandActive = isActive
        let folders = nodes.filter { $0.kind == .folder && $0.url != nil }
        if folders.count <= 128 {
            visiblePresenceNodes = isActive ? folders : []
        } else if isActive {
            let current = Set(folders.map(ObjectIdentifier.init))
            let pending = visiblePresenceNodes.filter { node in
                guard current.contains(ObjectIdentifier(node)), let candidate = candidate(for: node) else { return false }
                return presenceCache.result(for: candidate) == nil
            }
            let retained = Set(pending.map(ObjectIdentifier.init))
            let remaining = folders.filter { !retained.contains(ObjectIdentifier($0)) }
            let uncached = remaining.filter { candidate(for: $0).flatMap(presenceCache.result(for:)) == nil }
            let uncachedIDs = Set(uncached.map(ObjectIdentifier.init))
            visiblePresenceNodes = Array((pending + uncached
                + remaining.filter { !uncachedIDs.contains(ObjectIdentifier($0)) }).prefix(128))
        } else {
            visiblePresenceNodes = []
        }
        updatePresenceDemand()
        if resumed { presenceCache.reopenDeferredDemand() }
    }

    func detachPresenceOwner(_ owner: UUID) {
        guard presenceOwner == owner else { return }
        presenceOwner = nil
        demandActive = false
        visiblePresenceNodes = []
        dirtyPresenceNodes = []
        presenceCache.setDemand([])
    }

    func invalidateVisiblePresence() { presenceCache.invalidateDemand() }

    func takeDirtyPresenceNodes(owner: UUID) -> Set<ObjectIdentifier> {
        guard presenceOwner == owner else { return [] }
        defer { dirtyPresenceNodes = [] }
        return dirtyPresenceNodes
    }

    func cancelLoads() {
        closed = true
        presenceCache.close()
        visiblePresenceNodes = []
        dirtyPresenceNodes = []
        presencePublication?.cancel()
        rootSubscription?.cancel()
        roots.forEach(invalidate)
    }

    private func rebuildRoots(_ pinned: [PinnedFolder], locations: SidebarLocationCatalog.Snapshot) {
        let old = roots + (roots.last { $0.key == "this-mac" }?.children ?? [])
        let existing = Dictionary(uniqueKeysWithValues: old.map { ($0.key, $0) })
        func row(_ key: String, _ title: String, _ url: URL, _ symbol: String,
                 kind: SidebarNode.Kind = .folder) -> SidebarNode {
            if let node = existing[key], node.kind == kind, node.title == title, node.url == url, node.symbol == symbol {
                node.separatorBefore = false
                return node
            }
            return SidebarNode(key: key, title: title, symbol: symbol, kind: kind, url: url)
        }
        let home = row("page:home", "Home", BrowserPage.home.url, "house.fill", kind: .page)
        let accounts = locations.accounts.map {
            row("account:" + $0.id, $0.sidebarTitle(isOnlyAccount: locations.accounts.count == 1), $0.url, "cloud.fill")
        }
        let folders = pinned.map { row($0.id, $0.title, $0.url, $0.symbol) }
        folders.first?.separatorBefore = true
        let mac = row("this-mac", "This Mac", BrowserPage.thisMac.url, "desktopcomputer", kind: .page)
        mac.separatorBefore = true
        let drives = locations.volumes.map { row("volume:" + $0.id, $0.title, $0.url, $0.symbol) }
        let top = [home] + accounts + folders + [mac]
        let retained = Set((top + drives).map(ObjectIdentifier.init))
        for node in old where !retained.contains(ObjectIdentifier(node)) { invalidate(node) }
        mac.children = drives
        if drives.isEmpty { mac.expanded = false }
        if volumes != locations.volumes { volumes = locations.volumes }
        roots = top
        revision += 1
        prunePresenceDemand()
    }

    private func read(_ node: SidebarNode, explicitlyOpened: Bool) {
        guard let url = node.url else { return }
        invalidate(node)
        node.expanded = true
        let nodeID = ObjectIdentifier(node)
        let generation = UUID()
        generations[nodeID] = generation
        if explicitlyOpened && node.requiresDirectoryRebind { rebindReads.insert(nodeID) }
        node.state = .loading
        node.failure = nil
        node.children = [message(for: node, text: "Loading folders…")]
        prunePresenceDemand()
        revision += 1
        let hidden = showHidden
        let loader = self.loader
        tasks[nodeID] = Task { [weak self, weak node] in
            do {
                let snapshot = try await loader.snapshot(of: url, showHidden: hidden)
                guard !Task.isCancelled, let self, let node, node.expanded,
                      self.generations[nodeID] == generation else { return }
                self.tasks.removeValue(forKey: nodeID)
                let folders = self.eligibleFolders(snapshot.items, at: url)
                let result = self.snapshotPresence(snapshot, hasFolders: !folders.isEmpty)
                let knowledge = SidebarPresenceKnowledge(result, source: .foreground)
                if let candidate = self.candidate(for: node) {
                    if self.rebindReads.contains(nodeID), snapshot.archiveRevision == nil {
                        // The listing identifies the traversed directory. It
                        // does not identify the entry (which may now be a link).
                        node.directoryIdentity = result.directoryIdentity
                        node.requiresDirectoryRebind = false
                    } else if node.requiresDirectoryRebind || !SidebarPresenceCache.matches(knowledge.directoryIdentity, candidate) {
                        if !node.requiresDirectoryRebind {
                            node.requiresDirectoryRebind = true
                            node.presenceKnowledge = nil
                            self.presenceCache.forgetIdentity(at: url)
                        }
                        throw Self.changedFolderError
                    }
                    let bound = self.candidate(for: node) ?? candidate
                    self.presenceCache.observe(result, candidate: bound, explicitlyOpened: explicitlyOpened)
                    self.receivePresence(knowledge, key: candidate.key, skipping: node)
                }
                self.reconcileChildren(of: node, folders: folders, knowledge: knowledge)
                self.prunePresenceDemand()
                self.revision += 1
            } catch {
                guard !Task.isCancelled, let self, let node, node.expanded,
                      self.generations[nodeID] == generation else { return }
                self.cancelRead(node)
                self.showReadFailure(node, at: url, error: error)
                self.revision += 1
            }
        }
    }

    @discardableResult
    private func reconcileChildren(of node: SidebarNode, folders: [FileItem],
                                   knowledge: SidebarPresenceKnowledge) -> Bool {
        let wasLoaded = node.state == .loaded && node.failure == nil
        let oldChildren = node.children
        var existing: [String: SidebarNode] = [:]
        for child in oldChildren {
            if let path = child.url?.standardizedFileURL.path { existing[path] = child }
        }
        var seen: Set<String> = []
        let children = FileSort().sorted(folders).compactMap { item -> SidebarNode? in
            let path = item.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            let symbol = item.isSymbolicLink ? "folder.badge.questionmark" : "folder.fill"
            if let child = existing[path], child.title == item.name, child.symbol == symbol,
               child.fileIdentity == item.identity,
               child.isSymbolicLink || child.directoryIdentity == item.identity {
                return child
            }
            let child = SidebarNode(key: node.key + "/" + item.name, title: item.name, symbol: symbol,
                                    url: item.url, fileIdentity: item.identity, isSymbolicLink: item.isSymbolicLink)
            return child
        }
        let retained = Set(children.map(ObjectIdentifier.init))
        for child in oldChildren where !retained.contains(ObjectIdentifier(child)) { invalidate(child) }
        // Supersede this presentation's pending read only. Retained descendants
        // retain their snapshots, expansion state, and independent in-flight reads.
        cancelRead(node)
        let previousPresence = node.presence
        node.presenceKnowledge = knowledge
        if knowledge.presence == .absent { node.expanded = false }
        node.children = children
        node.state = .loaded
        node.failure = nil
        return !wasLoaded || previousPresence != knowledge.presence
            || oldChildren.map(ObjectIdentifier.init) != node.children.map(ObjectIdentifier.init)
    }

    private func eligibleFolders(_ items: [FileItem], at url: URL) -> [FileItem] {
        let parent = SidebarPresenceCache.Key(url, showHidden: showHidden)
        return items.filter {
            $0.isDirectory && SidebarPresenceCache.Key($0.url.deletingLastPathComponent(),
                                                       showHidden: showHidden) == parent
        }
    }

    private func snapshotPresence(_ snapshot: DirectorySnapshot, hasFolders: Bool) -> FolderChildPresenceResult {
        let presence: FolderChildPresence = hasFolders ? .present : snapshot.isStructureComplete ? .absent : .unknown
        return FolderChildPresenceResult(presence: presence, directoryIdentity: snapshot.directoryIdentity)
    }

    private func candidate(for node: SidebarNode) -> SidebarPresenceCache.Candidate? {
        guard node.kind == .folder, let url = node.url else { return nil }
        let key = SidebarPresenceCache.Key(url, showHidden: showHidden)
        // A link's FileItem identity belongs to its lexical entry. The probe
        // and full directory snapshot both report the resolved directory.
        return SidebarPresenceCache.Candidate(key: key, url: url,
                                              identity: node.directoryIdentity,
                                              linkIdentity: node.isSymbolicLink ? node.fileIdentity : nil)
    }

    private func updatePresenceDemand() {
        var candidates: [SidebarPresenceCache.Candidate] = []
        for node in visiblePresenceNodes {
            guard !node.requiresDirectoryRebind, let candidate = candidate(for: node) else { continue }
            if let result = presenceCache.result(for: candidate) {
                applyPresence(result, to: node)
            }
            if node.state != .loading, node.state != .failed, !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        presenceCache.setDemand(candidates)
    }

    private func prunePresenceDemand() {
        guard !visiblePresenceNodes.isEmpty || !dirtyPresenceNodes.isEmpty else { return }
        var retained: Set<ObjectIdentifier> = []
        func visit(_ node: SidebarNode) {
            retained.insert(ObjectIdentifier(node))
            node.children.forEach(visit)
        }
        roots.forEach(visit)
        for node in visiblePresenceNodes where !retained.contains(ObjectIdentifier(node)) {
            if let candidate = candidate(for: node) { presenceCache.invalidateWork(for: candidate.key) }
        }
        visiblePresenceNodes.removeAll { !retained.contains(ObjectIdentifier($0)) }
        dirtyPresenceNodes.formIntersection(retained)
        updatePresenceDemand()
    }

    private func receivePresence(_ result: SidebarPresenceKnowledge, key: SidebarPresenceCache.Key,
                                 skipping source: SidebarNode? = nil) {
        // Cache records are shared by compatible presentations. Expansion
        // reads still own their independent generations and children.
        let before = revision
        for node in visiblePresenceNodes where node !== source {
            guard !node.requiresDirectoryRebind, let candidate = candidate(for: node), candidate.key == key,
                  SidebarPresenceCache.matches(result.directoryIdentity, candidate),
                  presenceCache.result(for: candidate) != nil else { continue }
            applyPresence(result, to: node)
        }
        if revision != before { prunePresenceDemand() }
    }

    private func applyPresence(_ knowledge: SidebarPresenceKnowledge?, to node: SidebarNode) {
        guard node.state != .loading, node.state != .failed else { return }
        if let knowledge, node.presenceKnowledge?.shouldRetain(over: knowledge) == true { return }
        let previousPresence = node.presence
        let wasExpandable = node.isExpandable
        // An equal answer can still establish foreground provenance.
        node.presenceKnowledge = knowledge
        guard previousPresence != node.presence else { return }
        if node.presence == .absent {
            let structural = node.expanded && !node.children.isEmpty
            node.expanded = false
            node.children.forEach(invalidate)
            node.children = []
            node.state = .loaded
            if structural {
                revision += 1
                // The post-layout outline pass will replace descendant demand.
            }
        } else if !wasExpandable {
            node.state = .idle
        }
        if wasExpandable != node.isExpandable { markPresenceDirty(node) }
    }

    private func markPresenceDirty(_ node: SidebarNode) {
        guard presenceOwner != nil else { return }
        dirtyPresenceNodes.insert(ObjectIdentifier(node))
        guard presencePublication == nil else { return }
        presencePublication = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.presencePublication = nil
            if !self.dirtyPresenceNodes.isEmpty { self.presenceRevision += 1 }
        }
    }

    private func invalidate(_ node: SidebarNode) {
        cancelRead(node)
        for child in node.children { invalidate(child) }
        if node.state == .loading {
            node.state = .idle
            node.expanded = false
        }
    }

    private func cancelRead(_ node: SidebarNode) {
        let nodeID = ObjectIdentifier(node)
        generations.removeValue(forKey: nodeID)
        rebindReads.remove(nodeID)
        tasks.removeValue(forKey: nodeID)?.cancel()
    }

    private static var changedFolderError: CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [
            NSLocalizedDescriptionKey: "The folder changed while it was being read. Retry to open the current folder."
        ])
    }

    private func showReadFailure(_ node: SidebarNode, at url: URL, error: Error) {
        node.failure = "Couldn’t read \(url.path). \(error.localizedDescription)"
        node.state = .failed
        let row = message(for: node, text: "Couldn’t read folders. Retry")
        row.retryParent = node
        node.children = [row]
    }

    private func message(for node: SidebarNode, text: String) -> SidebarNode {
        SidebarNode(key: node.key + "#message", title: text, kind: .message)
    }
}
