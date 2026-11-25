import Combine
import CryptoKit
import ExplorerCore
import Foundation

struct RecentDocument: Codable, Equatable, Identifiable, Sendable {
    let url: URL
    let identity: LocalFileIdentity
    var volumeUUID: UUID?
    var documentID: Int?
    var regularFile: Bool?
    var openedAt: Date
    var id: String { url.path }

    static func capture(_ url: URL, followingLinks: Bool = true) -> Self? {
        guard let sample = LocalFileIdentity.document(at: url, followingLinks: followingLinks) else { return nil }
        return Self(url: url.standardizedFileURL, identity: sample.identity, volumeUUID: sample.volumeUUID,
                    documentID: sample.documentID, regularFile: sample.regularFile, openedAt: Date())
    }

    static func sample(_ url: URL) async -> Self? {
        try? await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            return capture(url)
        }
    }

    static func validated(_ item: FileItem) async -> Self? {
        guard let identity = item.identity, !item.isDirectory, item.isSymbolicLink || item.isRegularFile != nil,
              let captured = await sample(item.url), item.isSymbolicLink || captured.identity == identity else { return nil }
        return captured
    }

    /// Kernel document IDs can survive a safe save. File numbers and birth times
    /// are the fallback when the volume supplies no persistent document ID.
    func identifies(_ current: Self) -> Bool {
        url == current.url && regularFile == current.regularFile
            && RecentIdentity(self).identifiesOnKnownVolume(RecentIdentity(current))
    }

    /// An explicit confirmation covers this physical file only. Even a later
    /// version of the same logical document must be sampled and offered again.
    func isSameCandidate(as current: Self) -> Bool {
        url == current.url && regularFile == true && current.regularFile == true
            && identity == current.identity && volumeUUID == current.volumeUUID && documentID == current.documentID
    }

    var isCurrent: Bool { Self.capture(url).map(identifies) == true }
}

private struct RecentIdentity: Codable, Equatable {
    let physical: LocalFileIdentity
    let volume: UUID?
    let documentID: Int?

    init(_ entry: RecentDocument) {
        physical = entry.identity
        volume = entry.volumeUUID
        documentID = entry.documentID
    }

    func identifiesOnKnownVolume(_ other: Self) -> Bool {
        guard let volume, volume == other.volume else { return false }
        if let documentID, let otherID = other.documentID { return documentID == otherID }
        return physical.inode == other.physical.inode && physical.birthSeconds == other.physical.birthSeconds
            && physical.birthNanoseconds == other.physical.birthNanoseconds
    }

    /// A hidden use can survive remounting the same identified volume. Without
    /// a volume UUID the exact physical sample can still suppress an old use.
    func matchesSuppression(_ other: Self) -> Bool {
        if volume != nil && other.volume != nil { return identifiesOnKnownVolume(other) }
        return physical == other.physical
    }
}

@MainActor
final class RecentDocumentStore: ObservableObject {
    typealias SystemSnapshots = (Int) -> AsyncThrowingStream<[RecentDocument], Error>
    enum SystemStatus { case idle, loading, ready, unavailable }

    private struct Suppression: Codable {
        let pathKey: String
        let identities: [RecentIdentity]
        let through: Date
    }

    private static let key = "nativeExplorer.recentDocuments.v1"
    private static let suppressionKey = "nativeExplorer.suppressedRecents.v1"
    static let limit = 100
    @Published private(set) var entries: [RecentDocument]
    @Published private(set) var systemStatus: SystemStatus = .idle
    let departedSources = PassthroughSubject<[TransferEntry], Never>()
    private var verifiedSources: [Data: (RecentDocument, TransferEntry)] = [:]
    private let defaults: UserDefaults?
    private let systemSnapshots: SystemSnapshots?
    private var accepted: [RecentDocument]
    private var indexed: [String: RecentDocument] = [:]
    private var suppressions: [String: Suppression] = [:]
    private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var queryTask: Task<Void, Never>?
    private var queryGeneration: UUID?

    init(defaults: UserDefaults? = nil, systemSnapshots: SystemSnapshots? = nil) {
        self.defaults = defaults
        self.systemSnapshots = systemSnapshots
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RecentDocument].self, from: $0) } ?? []
        var seen = Set<String>()
        accepted = Array(saved.filter { $0.url.isFileURL && !HomeFileLocations.isInTrash($0.url) && seen.insert($0.id).inserted }.prefix(Self.limit))
        entries = accepted
        let removed = defaults?.data(forKey: Self.suppressionKey).flatMap {
            try? JSONDecoder().decode([Suppression].self, from: $0)
        } ?? []
        for item in removed.sorted(by: { $0.through > $1.through }).prefix(Self.limit) where suppressions[item.pathKey] == nil {
            suppressions[item.pathKey] = item
        }
    }

    nonisolated static func pathKey(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func contains(_ document: RecentDocument) -> Bool {
        entries.contains { $0.id == document.id && RecentIdentity($0) == RecentIdentity(document) }
    }

    func record(_ captured: [RecentDocument], excluding failures: [URL]) {
        let failed = Set(failures.map { $0.standardizedFileURL.path })
        var seen = Set<String>()
        let successful = captured.reversed().filter { !failed.contains($0.id) && !HomeFileLocations.isInTrash($0.url) && seen.insert($0.id).inserted }
        guard !successful.isEmpty else { return }
        let now = Date()
        let newest = successful.map { document in
            var entry = document
            entry.openedAt = now
            return entry
        }
        accepted = Array((newest + accepted.filter { !seen.contains($0.id) }).prefix(Self.limit))
        let oldCount = suppressions.count
        for entry in newest { suppressions.removeValue(forKey: Self.pathKey(entry.id)) }
        persistAccepted()
        if oldCount != suppressions.count { persistSuppressions(); startQueryIfObserved() }
        rebuild()
    }

    func remove(_ document: RecentDocument) {
        guard contains(document), let shown = entries.first(where: { $0.id == document.id }) else { return }
        suppress(document, shown: shown, includingIndexedIdentity: true)
        commitRemovals()
    }

    /// A filesystem command retires only the source that actually left. A
    /// separate indexed replacement at the same path keeps its own identity.
    func retireDeparted(_ entries: [TransferEntry], represented: [Data: RecentDocument]) {
        guard !entries.isEmpty, let byPath = HomeFileOperationSampler.indexedEntries(entries) else { return }
        var changed = false
        for (path, entry) in byPath {
            let recorded = verifiedSources[path]
            let sameSource = recorded.map { contains($0.0) && HomeFileOperationSampler.agrees($0.1, entry) } == true
            guard let shown = self.entries.first(where: { HomeFileLocations.pathKey($0.url) == path }),
                  shown.identity == entry.item.identity || sameSource || represented[path].map(contains) == true else { continue }
            suppress(shown, shown: shown, includingIndexedIdentity: false)
            changed = true
        }
        if changed { commitRemovals() }
        departedSources.send(entries)
    }

    func rememberSourceEntries(_ files: [TransferEntry], represented: [Data: RecentDocument]) {
        guard !represented.isEmpty else { return }
        verifiedSources = verifiedSources.filter { contains($0.value.0) }
        for file in files {
            let key = HomeFileLocations.pathKey(file.item.url)
            if let row = represented[key], contains(row) { verifiedSources[key] = (row, file) }
        }
    }

    private func suppress(_ document: RecentDocument, shown: RecentDocument, includingIndexedIdentity: Bool) {
        let pathKey = Self.pathKey(document.id)
        let observed = indexed[document.id]
        let cutoff = max(Date(), shown.openedAt, observed?.openedAt ?? .distantPast)
        var identities = [RecentIdentity(document)]
        if includingIndexedIdentity, let observed, !identities.contains(RecentIdentity(observed)) { identities.append(RecentIdentity(observed)) }
        suppressions[pathKey] = Suppression(pathKey: pathKey, identities: identities, through: cutoff)
        if suppressions.count > Self.limit,
           let oldest = suppressions.values.min(by: { ($0.through, $0.pathKey) < ($1.through, $1.pathKey) }) {
            suppressions.removeValue(forKey: oldest.pathKey)
        }
        accepted.removeAll { $0.id == document.id }
    }

    private func commitRemovals() {
        persistAccepted()
        persistSuppressions()
        rebuild()
        startQueryIfObserved()
    }

    func replaceSystemRecents(_ snapshot: [RecentDocument]) {
        var latest: [String: RecentDocument] = [:]
        for entry in snapshot where entry.url.isFileURL && !HomeFileLocations.isInTrash(entry.url) {
            if let existing = latest[entry.id], existing.openedAt >= entry.openedAt { continue }
            // A repeated indexing notification is not an additional open. Keep
            // the identity already presented for the same recorded use.
            if let previous = indexed[entry.id], previous.openedAt == entry.openedAt, !isSuppressed(previous) {
                latest[entry.id] = previous
            } else { latest[entry.id] = entry }
        }
        indexed = latest
        rebuild()
    }

    private func isSuppressed(_ entry: RecentDocument) -> Bool {
        guard !suppressions.isEmpty, let removed = suppressions[Self.pathKey(entry.id)] else { return false }
        let identity = RecentIdentity(entry)
        return entry.openedAt <= removed.through && removed.identities.contains { $0.matchesSuppression(identity) }
    }

    private func rebuild() {
        var combined = Dictionary(uniqueKeysWithValues: accepted.map { ($0.id, $0) })
        let rank = Dictionary(uniqueKeysWithValues: accepted.enumerated().map { ($0.element.id, $0.offset) })
        for entry in indexed.values {
            if isSuppressed(entry) { continue }
            if var saved = combined[entry.id] {
                saved.openedAt = max(saved.openedAt, entry.openedAt)
                combined[entry.id] = saved
            } else { combined[entry.id] = entry }
        }
        let sorted = combined.values.sorted { lhs, rhs in
            if lhs.openedAt != rhs.openedAt { return lhs.openedAt > rhs.openedAt }
            let left = rank[lhs.id] ?? .max, right = rank[rhs.id] ?? .max
            return left == right ? lhs.id < rhs.id : left < right
        }
        let visible = Array(sorted.prefix(Self.limit))
        if visible != entries { entries = visible }
    }

    private func persistAccepted() {
        if let data = try? JSONEncoder().encode(accepted) { defaults?.set(data, forKey: Self.key) }
    }

    private func persistSuppressions() {
        if let data = try? JSONEncoder().encode(Array(suppressions.values)) { defaults?.set(data, forKey: Self.suppressionKey) }
    }

    func observeSystemRecents() async {
        guard systemSnapshots != nil, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                observers[id] = continuation
                if observers.count == 1 { startQueryIfObserved() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopObserving(id) }
        }
    }

    private func startQueryIfObserved() {
        guard !observers.isEmpty, let systemSnapshots else { return }
        queryTask?.cancel()
        let generation = UUID()
        queryGeneration = generation
        systemStatus = .loading
        let stream = systemSnapshots(suppressions.count)
        queryTask = Task { [weak self] in
            do {
                for try await values in stream {
                    guard !Task.isCancelled, let self, queryGeneration == generation else { return }
                    replaceSystemRecents(values)
                    systemStatus = .ready
                }
            } catch {
                guard !Task.isCancelled, let self, queryGeneration == generation else { return }
                replaceSystemRecents([])
                systemStatus = .unavailable
            }
        }
    }

    private func stopObserving(_ id: UUID) {
        guard let continuation = observers.removeValue(forKey: id) else { return }
        if observers.isEmpty {
            queryGeneration = nil
            queryTask?.cancel()
            queryTask = nil
            systemStatus = .idle
            replaceSystemRecents([])
        }
        continuation.resume()
    }
}
