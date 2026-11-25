import ExplorerCore
import Foundation

struct SidebarPresenceKnowledge {
    enum Source { case foreground, probe }

    let presence: FolderChildPresence
    let directoryIdentity: LocalFileIdentity?
    let uncertainty: FolderChildPresenceUncertainty?
    let source: Source

    init(_ result: FolderChildPresenceResult, source: Source) {
        presence = result.presence
        directoryIdentity = result.directoryIdentity
        uncertainty = result.uncertainty
        self.source = source
    }

    var isPolicyDeferred: Bool { uncertainty == .policyDeferred }

    var initialInterval: TimeInterval {
        switch uncertainty {
        case .policyDeferred: return .infinity
        case .transient: return 5
        default: return 15
        }
    }

    func shouldRetain(over incoming: Self) -> Bool {
        guard directoryIdentity == incoming.directoryIdentity else { return false }
        if presence == .present, incoming.uncertainty == .structural, directoryIdentity != nil {
            return true
        }
        return source == .foreground && incoming.source == .probe &&
            presence != .unknown && presence == incoming.presence
    }
}

@MainActor
final class SidebarPresenceCache {
    struct Key: Hashable {
        private let spelling: Data
        let showHidden: Bool

        init(_ url: URL, showHidden: Bool) {
            // Keep lexical aliases distinct. Foundation's file standardization
            // can rewrite physical /private spellings to symlinks.
            var components: [Substring] = []
            for component in url.path.split(separator: "/") {
                if component == ".." { if !components.isEmpty { components.removeLast() } }
                else if component != "." { components.append(component) }
            }
            spelling = Data(("/" + components.joined(separator: "/")).utf8)
            self.showHidden = showHidden
        }
    }

    struct Candidate: Equatable {
        let key: Key
        let url: URL
        let identity: LocalFileIdentity?
        var linkIdentity: LocalFileIdentity? = nil
    }

    private struct Record {
        let knowledge: SidebarPresenceKnowledge
        var expiresAt: TimeInterval
        var interval: TimeInterval
        var access: UInt64
        let linkIdentity: LocalFileIdentity?
        let foregroundObservedAt: TimeInterval?
    }

    private struct Work {
        let candidate: Candidate
        let task: Task<Void, Never>
        var obsolete = false
    }

    private let checker: any FolderChildPresenceChecking
    private let now: @MainActor () -> TimeInterval
    private let homeURL: URL
    private var records: [Key: Record] = [:]
    private var accessed: UInt64 = 0
    private var demand: [Candidate] = []
    private var options: SidebarBackgroundCheckOptions
    private var work: [UUID: Work] = [:]
    private var expiry: Task<Void, Never>?
    private var closed = false
    // Provenance is bounded independently of the ephemeral work queue. An
    // evicted grant only makes the checker more conservative.
    private var opened: [URL] = []
    var onResult: ((Key, SidebarPresenceKnowledge) -> Void)?

    init(homeURL: URL, checker: any FolderChildPresenceChecking, now: @escaping @MainActor () -> TimeInterval,
         options: SidebarBackgroundCheckOptions = .init()) {
        self.homeURL = homeURL
        self.checker = checker
        self.now = now
        self.options = options
    }

    func result(for candidate: Candidate) -> SidebarPresenceKnowledge? {
        guard var record = records[candidate.key], matches(record, candidate) else { return nil }
        accessed &+= 1
        record.access = accessed
        records[candidate.key] = record
        return record.knowledge
    }

    static func matches(_ observed: LocalFileIdentity?, _ candidate: Candidate) -> Bool {
        guard let expected = candidate.identity, let observed else { return true }
        return expected == observed
    }

    private func matches(_ record: Record, _ candidate: Candidate) -> Bool {
        if let previous = record.linkIdentity, let current = candidate.linkIdentity, previous != current {
            return false
        }
        return Self.matches(record.knowledge.directoryIdentity, candidate)
    }

    func setDemand(_ candidates: [Candidate]) {
        demand = closed ? [] : candidates
        for (id, running) in work where !demand.contains(running.candidate) { cancel(id) }
        schedule()
    }

    /// The model reconciles the tree before resubmitting its current visible demand.
    func setBackgroundCheckOptions(_ value: SidebarBackgroundCheckOptions) -> Bool {
        guard !closed, options != value else { return false }
        options = value
        expiry?.cancel()
        expiry = nil
        for id in Array(work.keys) { cancel(id) }
        records = records.compactMapValues { record in
            guard let observedAt = record.foregroundObservedAt else { return nil }
            var retained = record
            retained.interval = record.knowledge.initialInterval
            retained.expiresAt = observedAt + retained.interval
            return retained
        }
        return true
    }

    func invalidateDemand() {
        for candidate in demand { records[candidate.key]?.expiresAt = -.infinity }
        for id in Array(work.keys) { cancel(id) }
        schedule()
    }

    func invalidateWork(for key: Key) {
        for (id, running) in work where running.candidate.key == key { cancel(id) }
    }

    func forgetIdentity(at url: URL) {
        for showHidden in [false, true] {
            let key = Key(url, showHidden: showHidden)
            records.removeValue(forKey: key)
            invalidateWork(for: key)
        }
        opened.removeAll { $0.path.utf8.elementsEqual(url.path.utf8) }
    }

    func reopenDeferredDemand() {
        for candidate in demand where records[candidate.key]?.knowledge.isPolicyDeferred == true {
            records[candidate.key]?.expiresAt = -.infinity
        }
        schedule()
    }

    func observe(_ result: FolderChildPresenceResult, candidate: Candidate, explicitlyOpened: Bool) {
        guard !closed else { return }
        if explicitlyOpened {
            opened.removeAll { $0.path.utf8.elementsEqual(candidate.url.path.utf8) }
            opened.append(candidate.url)
            if opened.count > 256 { opened.removeFirst() }
        }
        for (id, running) in work where running.candidate.key == candidate.key { cancel(id) }
        _ = save(result, source: .foreground, for: candidate)
        schedule()
    }

    func close() {
        closed = true
        setDemand([])
    }

    private func cancel(_ id: UUID) {
        guard var running = work[id], !running.obsolete else { return }
        running.obsolete = true
        work[id] = running
        running.task.cancel()
    }

    private func schedule() {
        expiry?.cancel()
        expiry = nil
        guard !demand.isEmpty, work.count < 2 else { return }
        let time = now()
        var waiting: [Candidate] = []
        var wake = TimeInterval.infinity
        for candidate in demand where !work.values.contains(where: { $0.candidate.key == candidate.key }) {
            if let record = records[candidate.key], matches(record, candidate) {
                if record.expiresAt > time { wake = min(wake, record.expiresAt); continue }
                waiting.append(candidate)
            } else {
                submit(candidate)
                if work.count == 2 { return }
            }
        }
        for candidate in waiting {
            submit(candidate)
            if work.count == 2 { return }
        }
        guard wake.isFinite else { return }
        let interval = max(1, wake - time)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            self?.schedule()
        }
    }

    private func submit(_ candidate: Candidate) {
        let id = UUID()
        let proven = Set(opened)
        let request = FolderChildPresenceRequest(url: candidate.url, showHidden: candidate.key.showHidden,
            homeURL: homeURL, openedProtectedScopes: proven, options: options)
        let task = Task { [weak self, checker] in
            let result = Task.isCancelled ? .init(presence: .unknown) : await checker.check(request)
            self?.complete(id, result: result)
        }
        work[id] = Work(candidate: candidate, task: task)
    }

    private func complete(_ id: UUID, result: FolderChildPresenceResult) {
        guard let finished = work.removeValue(forKey: id) else { return }
        defer { schedule() }
        guard !finished.obsolete, demand.contains(finished.candidate) else { return }
        let candidate = finished.candidate
        // An old presentation cannot consume negative knowledge for the path's
        // replacement. Retry with backoff while its parent catches up.
        let current = Self.matches(result.directoryIdentity, candidate)
            ? result : FolderChildPresenceResult(presence: .unknown)
        let saved = save(current, source: .probe, for: candidate)
        onResult?(candidate.key, saved)
    }

    private func save(_ result: FolderChildPresenceResult, source: SidebarPresenceKnowledge.Source,
                      for candidate: Candidate) -> SidebarPresenceKnowledge {
        let key = candidate.key
        let incoming = SidebarPresenceKnowledge(result, source: source)
        let compatible = records[key].flatMap { matches($0, candidate) ? $0 : nil }
        let sameIdentity = compatible?.knowledge.directoryIdentity == incoming.directoryIdentity
        let retained = compatible.flatMap { $0.knowledge.shouldRetain(over: incoming) ? $0 : nil }
        let knowledge = retained?.knowledge ?? incoming
        let equivalent = sameIdentity && incoming.directoryIdentity != nil &&
            ((compatible?.knowledge.presence == .present && incoming.uncertainty == .structural)
             || (compatible?.knowledge.uncertainty == .structural && incoming.presence == .present))
        var interval = incoming.initialInterval
        if !incoming.isPolicyDeferred, incoming.uncertainty != .transient,
           let previous = compatible, sameIdentity,
           equivalent || (previous.knowledge.presence == incoming.presence &&
                          previous.knowledge.uncertainty == incoming.uncertainty) {
            interval = min(120, previous.interval * 2)
        }
        let time = now()
        let foregroundObservedAt = knowledge.source == .foreground ? retained?.foregroundObservedAt ?? time : nil
        accessed &+= 1
        records[key] = Record(knowledge: knowledge, expiresAt: time + interval, interval: interval, access: accessed,
                              linkIdentity: candidate.linkIdentity ?? records[key]?.linkIdentity,
                              foregroundObservedAt: foregroundObservedAt)
        if records.count > 256, let leastRecent = records.min(by: { $0.value.access < $1.value.access })?.key {
            records.removeValue(forKey: leastRecent)
        }
        return knowledge
    }
}
