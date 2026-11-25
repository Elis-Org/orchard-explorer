import ExplorerCore
import Foundation

/// Display observations only; the native service retains all command authority.
@MainActor
final class OneDriveBadgeCache {
    typealias Lookup = @Sendable (TransferEntry) async throws -> OneDriveBadgeObservation
    typealias ParentRead = @Sendable () async throws -> DirectorySnapshot
    typealias SearchReader = @MainActor (TransferEntry) -> ParentRead?
    static let shared = OneDriveBadgeCache(history: .live()) { try await OneDriveRetentionService.shared.badgeObservation(for: $0) }
    struct Scope: Equatable {
        let tab: UUID
        let folder: URL
        let load: UUID?
        let searchGeneration: UUID?
    }
    private struct Row { let key: OneDriveStatusKey; let entry: TransferEntry }
    private struct Viewport {
        let scope: Scope
        let storeID: UUID
        let rows: [Row]
        let selectedIDs: Set<String>
        let changed: @MainActor (Set<String>) -> Void
        let recover: (@MainActor (TransferEntry) -> Void)?
        let searchReader: SearchReader?
        let recoveredSearchHit: (@MainActor (TransferEntry, FileItem?) -> Bool)?
        let observed: (@MainActor (TransferEntry, OneDriveBadgeObservation) -> Void)?
    }
    private enum ResidencySource { case listing, viewport, query, operation }
    private enum QueryResult {
        case success(OneDriveBadgeObservation), refused(OneDriveBadgeReadError)
    }
    private struct Record {
        var entry: TransferEntry
        var snapshot: OneDriveStatusSnapshot
        var residencySequence: UInt64
        var residencySource: ResidencySource
        var listingSequence: UInt64 = 0
        var operationSequence: UInt64 = 0
        var awaitingListingSequence: UInt64?
        var refusals = 0
        var failures = 0
        var pendingCatchUp = false
        var lastNamedHint = -TimeInterval.infinity
        var refreshAfter: TimeInterval
        var requestedAt: TimeInterval
        var retryAfter: TimeInterval = 0
        var rateClass: OneDriveBadgeDemand.RateClass = .ordinary
        var lastUse: UInt64 = 0
        var protectsRoute = false
        var hasCommittedListing = false

        func evictionOrder(at time: TimeInterval) -> (Int, UInt64, UInt64) {
            let protected = snapshot.policy != nil || protectsRoute || awaitingListingSequence != nil || retryAfter > time
            let tier = protected ? 2 : (lastUse == 0 ? 0 : 1)
            return (tier, lastUse, snapshot.generation)
        }
    }
    private struct Query {
        let token: OneDriveStatusRequestToken
        let row: Row
        let followupOwners: Set<UUID>
        let historyTicket: OneDrivePolicyHistoryStore.Ticket?
        let isCatchUp: Bool
        var needsCatchUp = false
        let task: Task<Void, Never>
    }
    private struct Followup {
        let entry: TransferEntry
        let action: OneDriveRetentionAction
        let deadline: TimeInterval
        var next: TimeInterval
        var attempts = 0
        func matches(_ candidate: TransferEntry) -> Bool {
            // New leaf identities may be queried; they inherit no policy/proof.
            entry.item.id == candidate.item.id && entry.source == candidate.source
        }
        func isSettled(_ value: OneDriveBadgeObservation) -> Bool {
            action == .keep ? value.policy == .pinned && !value.isDataless
                : value.policy != .pinned && value.isDataless
        }
    }
    private let lookup: Lookup
    private let now: () -> TimeInterval
    private let freshnessNow: () -> TimeInterval
    private let wallNow: () -> Date
    private let debounce: Duration
    private let historyLimit: Int
    private let history: OneDriveBadgeHistory?
    private var scheduler: OneDriveBadgeScheduler
    private var viewports: [UUID: Viewport] = [:]
    private var visibleKeys = Set<OneDriveStatusKey>()
    private var records: [OneDriveStatusKey: Record] = [:]
    private var recent: [OneDriveStatusKey: Record] = [:]
    private var query: Query?
    private var waitingDirectories: [OneDriveStatusKey: UUID] = [:]
    private var readingDirectories: [UUID: (start: UInt64, entries: [TransferEntry])] = [:]
    private var pendingRecovery = Set<OneDriveStatusKey>()
    private var recoveringKeys = Set<OneDriveStatusKey>()
    private var recoveryTask: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?
    private var hintWakeup: Task<Void, Never>?
    private struct Hint {
        var coarse = false
        var explicit = false
        var overflow = false
        var names = Set<String>()
        var coveredGenerations: [OneDriveStatusKey: UInt64] = [:]
    }
    private var pendingHints: [String: Hint] = [:]
    private var lastHint: [String: TimeInterval] = [:]
    private var lastExplicitRetry: [String: TimeInterval] = [:]
    private var lastOwnCompletion: [String: TimeInterval] = [:]
    private var followups: [UUID: Followup] = [:]
    private var pendingChanges = Set<OneDriveStatusKey>()
    private var notificationScheduled = false
    private var foregroundAction = false
    private var pausedUntil: TimeInterval = 0
    private struct FailureDelay {
        var count = 0
        var until: TimeInterval = 0
        mutating func record(at time: TimeInterval) {
            count = min(5, count + 1)
            until = time + OneDriveBadgeCache.retryDelay(count)
        }
    }
    private var accountDelays: [String: FailureDelay] = [:]
    private var namespaceEpochs: [String: UInt64] = [:]
    private var installationDelay = FailureDelay()

    nonisolated private static func retryDelay(_ failures: Int) -> TimeInterval {
        min(900, 60 * pow(2, Double(max(0, min(5, failures) - 1))))
    }

    private func trace(_ event: String, count: Int = 1) {
        guard tracesHints else { return }
        let message = "maxplorer-cloud-cache event=\(event) count=\(count) elapsed=\(now())\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var usage: UInt64 = 0
    private let tracesHints = ProcessInfo.processInfo.environment["MAXPLORER_CLOUD_STATUS_TRACE"] == "1"

    private func touch(_ record: inout Record) {
        usage &+= 1
        record.lastUse = usage
    }

    init(debounce: Duration = .milliseconds(120), historyLimit: Int = 256,
         workLimit: Int = 32, workInterval: TimeInterval = 60,
         now: (() -> TimeInterval)? = nil, freshnessNow: (() -> TimeInterval)? = nil,
         wallNow: @escaping () -> Date = Date.init, history: OneDriveBadgeHistory? = nil, lookup: @escaping Lookup) {
        self.history = history
        self.debounce = debounce; self.historyLimit = max(0, historyLimit)
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        let origin = ContinuousClock.now
        self.freshnessNow = freshnessNow ?? now ?? {
            let duration = origin.duration(to: .now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        self.wallNow = wallNow; self.lookup = lookup
        scheduler = .init(capacity: workLimit, interval: workInterval)
        history?.namespaceChanged = { [weak self] account in self?.invalidateNamespace(account) }
    }
    func snapshot(for entry: TransferEntry) -> OneDriveStatusSnapshot? {
        guard let key = OneDriveStatusKey(entry), var record = records[key] ?? recent[key] else { return nil }
        let previous = record.snapshot.freshness
        record.snapshot.reconsiderAge(at: freshnessNow(), visibleCount: visibleKeys.count)
        if records[key] != nil { records[key] = record } else { recent[key] = record }
        if previous != record.snapshot.freshness { notify([key]) }
        return record.snapshot
    }
    func observation(for entry: TransferEntry) -> OneDriveBadgeObservation? { snapshot(for: entry)?.observation }
    func beginListingSnapshot(for folder: URL) -> UInt64 {
        history?.beginListing(in: folder)
        return sequence
    }

    /// A committed directory read (unlike a search batch) also proves absence
    /// from its captured roster. Retire removed routes before another view can
    /// reuse their old confirmed policy after a rename or replacement.
    func mergeDirectoryListing(_ entries: [TransferEntry], roster: [FileItem], parent: FileOperationContext, startedAt start: UInt64) {
        _ = resolveSearchRefusals(parent: parent.directoryURL, identity: parent.directoryIdentity,
                              items: roster, startedAt: start)
        let present = Set(roster.map(\.id))
        let previous = records.merging(recent, uniquingKeysWith: { first, _ in first })
        let removed = Set(previous.compactMap { key, record -> OneDriveStatusKey? in
            guard key.parent == parent.directoryURL.absoluteString, !present.contains(key.file),
                  record.listingSequence <= start, record.operationSequence <= start,
                  record.residencySequence <= start else { return nil }
            return key
        })
        for key in removed { history?.invalidate(key) }
        invalidate(removed); notify(removed)
        mergeListing(entries, startedAt: start)
    }

    // Share one physical post-refusal sample across all search panes that still
    // display that same captured hit. A changed identity only retires the hit.
    private func resolveSearchRefusals(parent: URL, identity: LocalFileIdentity?, items: [FileItem], startedAt start: UInt64)
        -> (entries: [TransferEntry], handled: Set<OneDriveStatusKey>) {
        let owners = viewports.values.filter { $0.scope.searchGeneration != nil && $0.recoveredSearchHit != nil }
        guard !owners.isEmpty else { return ([], []) }
        var accepted: [OneDriveStatusKey: TransferEntry] = [:], handled = Set<OneDriveStatusKey>()
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for owner in owners {
            for row in owner.rows where row.entry.source.directoryURL == parent {
                guard let record = records[row.key], let refusal = record.awaitingListingSequence, start >= refusal,
                      start >= record.listingSequence, start >= record.operationSequence else { continue }
                let hit = itemsByID[row.key.file]
                guard identity != nil, hit == nil || hit?.identity != nil else {
                    failedRecovery(of: [row.entry], startedAt: start)
                    continue
                }
                let matches = identity == row.key.parentIdentity && hit?.identity == row.key.identity
                if owner.recoveredSearchHit?(row.entry, matches ? hit : nil) == true {
                    handled.insert(row.key)
                    if matches, let hit { accepted[row.key] = .init(source: row.entry.source, item: hit) }
                }
            }
        }
        return (Array(accepted.values), handled)
    }

    func beginDirectoryRecovery(store: UUID, folder: URL, load: UUID, startedAt start: UInt64) {
        let owned = waitingDirectories.filter { $0.key.parent == folder.absoluteString && viewports[$0.value]?.storeID == store }
        guard !owned.isEmpty else { return }
        let entries = owned.keys.compactMap { key -> TransferEntry? in
            waitingDirectories.removeValue(forKey: key)
            guard let record = records[key], let refusal = record.awaitingListingSequence, start >= refusal else { return nil }
            return record.entry
        }
        if !entries.isEmpty { readingDirectories[load] = (start, entries) }
    }

    func endDirectoryRecovery(_ load: UUID) {
        guard let read = readingDirectories.removeValue(forKey: load) else { return }
        // Successful accepted rows already left quarantine; only discarded or
        // unsuccessful reads enter the bounded route retry here.
        failedRecovery(of: read.entries, startedAt: read.start)
    }

    private func requestRecovery(for key: OneDriveStatusKey, entry: TransferEntry) {
        let owners = viewports.filter { $0.value.rows.contains { $0.key == key } }
        if let directory = owners.first(where: { $0.value.scope.searchGeneration == nil && $0.value.recover != nil }) {
            waitingDirectories[key] = directory.key
            directory.value.recover?(entry)
        } else if owners.contains(where: { $0.value.searchReader != nil }) {
            pendingRecovery.insert(key); scheduleSearchRecovery()
        }
    }

    // A read belongs to its physical parent and exact refused keys. Its originating
    // window may close while another search still needs the same observation.
    private func scheduleSearchRecovery() {
        guard recoveryTask == nil, let first = pendingRecovery.first else { return }
        let keys = pendingRecovery.filter { $0.parent == first.parent && $0.parentIdentity == first.parentIdentity }
        pendingRecovery.subtract(keys)
        recoveringKeys = keys
        recoveryTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            defer {
                self.recoveryTask = nil; self.recoveringKeys.removeAll()
                self.scheduleSearchRecovery()
            }
            let entries = keys.compactMap { (self.records[$0] ?? self.recent[$0])?.entry }
            guard let entry = entries.first else { return }
            let start = self.sequence
            guard !Task.isCancelled, !keys.isDisjoint(with: self.visibleKeys), let read = self.searchParentRead(for: keys) else {
                self.failedRecovery(of: entries, startedAt: start, readStarted: false); return
            }
            do {
                let snapshot = try await read()
                guard !Task.isCancelled else {
                    self.failedRecovery(of: entries, startedAt: start); return
                }
                let resolved = self.resolveSearchRefusals(parent: entry.source.directoryURL, identity: snapshot.directoryIdentity,
                                                          items: snapshot.items, startedAt: start)
                if !resolved.entries.isEmpty { self.mergeListing(resolved.entries, startedAt: start) }
                let deferred = keys.subtracting(resolved.handled).compactMap { self.records[$0]?.entry }
                self.failedRecovery(of: deferred, startedAt: start)
            } catch { self.failedRecovery(of: entries, startedAt: start) }
        }
    }

    private func searchParentRead(for keys: Set<OneDriveStatusKey>) -> ParentRead? {
        for viewport in viewports.values {
            guard let reader = viewport.searchReader else { continue }
            for row in viewport.rows where keys.contains(row.key) {
                if let read = reader(row.entry) { return read }
            }
        }
        return nil
    }

    private func failedRecovery(of entries: [TransferEntry], startedAt start: UInt64, readStarted: Bool = true) {
        for entry in entries {
            guard let key = OneDriveStatusKey(entry), var record = records[key] ?? recent[key],
                  let refusal = record.awaitingListingSequence, start >= refusal,
                  start >= record.operationSequence, start >= record.listingSequence else { continue }
            record.awaitingListingSequence = nil
            if !readStarted { record.refusals = 0 }
            record.failures = min(5, record.failures + 1)
            record.retryAfter = now() + Self.retryDelay(record.failures)
            record.snapshot.failureReason = .itemUnavailable
            record.snapshot.freshness = .unavailable
            record.rateClass = .routine; record.refreshAfter = record.retryAfter
            if records[key] != nil { records[key] = record } else { recent[key] = record }
            notify([key]); trace("unavailableRecovery")
        }
        demandChanged()
    }

    func mergeListing(_ entries: [TransferEntry], startedAt start: UInt64) {
        if let history { history.listingChanged(accounts: Set(entries.compactMap { OneDriveStatusKey($0)?.account })) }
        mergeListing(entries, startedAt: start, fromViewport: false)
        demandChanged()
    }
    private func mergeListing(_ entries: [TransferEntry], startedAt start: UInt64, fromViewport: Bool) {
        sequence &+= 1
        let admission = sequence
        let known = records.merging(recent, uniquingKeysWith: { first, _ in first })
        let byRoute = Dictionary(grouping: known.keys, by: \.file)
        for entry in entries {
            guard let key = OneDriveStatusKey(entry) else { continue }
            let previous = (byRoute[key.file] ?? []).compactMap { key in known[key].map { (key, $0) } }
            // Real listings and operations retain independent barriers even
            // after a passive confirmation changes the residency provenance.
            if previous.contains(where: { $0.1.listingSequence > start || $0.1.operationSequence > start }) { continue }
            // A current committed different key may supersede passive facts.
            // Raw versions are unequal stamps, never an ordering of file ages.
            if previous.contains(where: { oldKey, record in
                record.residencySequence > start
                    && (fromViewport || oldKey == key || record.residencySource != .query)
            }) { continue }
            let listingSequence = max(previous.map { $0.1.listingSequence }.max() ?? 0, fromViewport ? 0 : admission)
            let operationSequence = previous.map { $0.1.operationSequence }.max() ?? 0
            let obsolete = Set(previous.map(\.0).filter { $0 != key })
            if let old = obsolete.first { history?.invalidate(old) }
            if !obsolete.isEmpty { trace("replaced", count: obsolete.count) }
            invalidate(obsolete)
            if var record = records[key] ?? recent[key] {
                if !fromViewport { record.hasCommittedListing = true }
                record.listingSequence = listingSequence
                record.operationSequence = operationSequence
                let previousAvailability = fromViewport ? record.entry.item.availability : record.snapshot.availability
                // A new real sample can disprove a cached cloud even when search
                // skipped membership. Confirmed policy on this exact key establishes
                // provider membership; a raw resident bit alone cannot establish it.
                let sampledResident = !fromViewport && entry.item.isDataless == false
                var availability = entry.item.availability
                if availability == .unknown, sampledResident, record.snapshot.policy != nil { availability = .availableLocally }
                let contradictsOldCloud = sampledResident && previousAvailability == .onlineOnly
                if (availability != .unknown || contradictsOldCloud), previousAvailability != availability {
                    retireQuery(for: key); generation &+= 1
                    record.snapshot.generation = generation
                    record.snapshot.availability = availability
                    if record.snapshot.policy != nil { record.snapshot.freshness = .stale }
                    record.snapshot.source = .listing
                    record.refreshAfter = now(); record.requestedAt = now(); record.rateClass = .ordinary
                    record.residencySequence = admission
                    record.residencySource = fromViewport ? .viewport : .listing
                    notify([key])
                }
                if !fromViewport, let refusal = record.awaitingListingSequence, start >= refusal, now() >= record.retryAfter {
                    record.awaitingListingSequence = nil
                    waitingDirectories.removeValue(forKey: key)
                    if record.refusals > 1 { record.refusals = 0 }
                    record.refreshAfter = now(); record.rateClass = .ordinary
                }
                record.entry = entry
                records[key] = record; recent.removeValue(forKey: key)
            } else {
                generation &+= 1
                records[key] = Record(entry: entry,
                    snapshot: .init(availability: entry.item.availability, generation: generation),
                    residencySequence: admission, residencySource: fromViewport ? .viewport : .listing,
                    listingSequence: listingSequence, operationSequence: operationSequence,
                    refreshAfter: now(), requestedAt: now(),
                    lastUse: previous.map { $0.1.lastUse }.max() ?? 0,
                    protectsRoute: previous.contains { $0.1.lastUse != 0 || $0.1.protectsRoute },
                    hasCommittedListing: !fromViewport)
            }
            notify(obsolete)
        }
    }

    func update(_ owner: UUID, scope: Scope, entries: [TransferEntry], selectedIDs: Set<String> = [],
                storeID: UUID? = nil, mergeEntries: Bool = true, changed: @escaping @MainActor () -> Void,
                observed: (@MainActor (TransferEntry, OneDriveBadgeObservation) -> Void)? = nil) {
        update(owner, scope: scope, entries: entries, selectedIDs: selectedIDs, storeID: storeID,
            mergeEntries: mergeEntries, changedIDs: { _ in changed() }, observed: observed)
    }
    func update(_ owner: UUID, scope: Scope, entries: [TransferEntry], selectedIDs: Set<String> = [],
                storeID: UUID? = nil, mergeEntries: Bool = true, recover: (@MainActor (TransferEntry) -> Void)? = nil,
                searchReader: SearchReader? = nil, recoveredSearchHit: (@MainActor (TransferEntry, FileItem?) -> Bool)? = nil,
                changedIDs: @escaping @MainActor (Set<String>) -> Void,
                observed: (@MainActor (TransferEntry, OneDriveBadgeObservation) -> Void)? = nil) {
        if entries.isEmpty { remove(owner); return }
        let old = viewports[owner]
        var seen = Set<OneDriveStatusKey>()
        let rows = entries.compactMap { entry -> Row? in
            guard let key = OneDriveStatusKey(entry), seen.insert(key).inserted else { return nil }
            return Row(key: key, entry: entry)
        }
        viewports[owner] = Viewport(scope: scope, storeID: storeID ?? owner, rows: rows,
            selectedIDs: selectedIDs, changed: changedIDs, recover: recover, searchReader: searchReader, recoveredSearchHit: recoveredSearchHit, observed: observed)
        rebuildVisibleKeys()
        if mergeEntries { mergeListing(entries, startedAt: sequence, fromViewport: true) }
        else {
            // Listing history is bounded. A newly visible uncached row starts
            // from its captured metadata, without overriding another version at
            // a route rejected by the listing/action sequence check.
            let known = Set(records.keys).union(recent.keys)
            let routes = Set(known.map(\.file))
            let unseen = rows.filter { !known.contains($0.key) && !routes.contains($0.key.file) }.map(\.entry)
            if !unseen.isEmpty { mergeListing(unseen, startedAt: sequence, fromViewport: true) }
        }
        if !mergeEntries {
            // Production viewports use rows provided by their committed listing or search result.
            for row in rows { records[row.key]?.hasCommittedListing = true; recent[row.key]?.hasCommittedListing = true }
        }
        let priorKeys = Set(old?.rows.map(\.key) ?? [])
        for row in rows where !priorKeys.contains(row.key) {
            guard var record = records[row.key] ?? recent[row.key] else { continue }
            touch(&record)
            records[row.key] = record
            recent.removeValue(forKey: row.key)
        }
        // Selection edges request a check. Unchanged selection never adds polling.
        for row in rows where selectedIDs.contains(row.key.file) && old?.selectedIDs.contains(row.key.file) != true {
            guard var record = records[row.key] ?? recent[row.key], let confirmed = record.snapshot.confirmationElapsed,
                  freshnessNow() - confirmed >= 15 else { continue }
            // Preserve the rate class of a queued hint/periodic refresh. A new
            // selection check on an otherwise fresh record uses ordinary tokens.
            if record.refreshAfter > now(), record.snapshot.freshness == .fresh { record.rateClass = .ordinary }
            record.refreshAfter = min(record.refreshAfter, now()); record.requestedAt = now()
            records[row.key] = record; recent.removeValue(forKey: row.key)
        }
        demandChanged()
    }
    func viewportOwners(store: UUID, tab: UUID) -> [UUID] {
        viewports.compactMap { owner, viewport in
            viewport.storeID == store && viewport.scope.tab == tab ? owner : nil
        }
    }

    func remove(_ owner: UUID) {
        guard let removed = viewports.removeValue(forKey: owner) else { return }
        rebuildVisibleKeys()
        if !viewports.values.contains(where: { $0.storeID == removed.storeID }) { followups.removeValue(forKey: removed.storeID) }
        demandChanged()
    }

    func beginOperation(for entry: TransferEntry) -> OneDriveStatusRequestToken? {
        guard let key = OneDriveStatusKey(entry) else { return nil }
        if records[key] == nil && recent[key] == nil { mergeListing([entry], startedAt: sequence, fromViewport: true) }
        guard var record = records[key] ?? recent[key] else { return nil }
        touch(&record)
        record.protectsRoute = true
        generation &+= 1; record.snapshot.generation = generation
        if record.snapshot.policy != nil { record.snapshot.freshness = .stale }
        record.refreshAfter = now(); record.rateClass = .ordinary
        records[key] = record; recent.removeValue(forKey: key)
        retireQuery(for: key); notify([key])
        let token = OneDriveStatusRequestToken(key: key, generation: generation, startSequence: sequence)
        history?.begin(token)
        return token
    }
    func finishOperation(_ token: OneDriveStatusRequestToken?, verified: OneDriveVerifiedStatus?) {
        guard let token else { return }
        var confirmedHint: OneDrivePolicyHistoryStore.Hint?
        defer { history?.finish(token, hint: confirmedHint) }
        // Admission is sequenced now, not at operation start.
        sequence &+= 1
        let known = records.merging(recent, uniquingKeysWith: { first, _ in first })
        for (key, var record) in known where key.file == token.key.file {
            record.operationSequence = sequence
            if records[key] != nil { records[key] = record } else { recent[key] = record }
        }
        // A retired generation contributes ordering only, never display proof.
        guard var record = records[token.key] ?? recent[token.key],
              record.snapshot.generation == token.generation else { return }
        touch(&record)
        record.residencySequence = sequence; record.residencySource = .operation
        lastOwnCompletion[token.key.parent] = now()
        if let verified, verified.matches(record.entry), let policy = verified.policy, let dataless = verified.isDataless {
            confirm(&record, value: .init(policy: policy, isDataless: dataless), source: .operation)
            if let date = record.snapshot.confirmedAt { confirmedHint = .init(policy: policy, confirmedAt: date) }
        } else {
            if record.snapshot.policy != nil { record.snapshot.freshness = .stale }
            record.refreshAfter = now(); record.rateClass = .ordinary
        }
        records[token.key] = record; recent.removeValue(forKey: token.key)
        notify([token.key]); demandChanged()
    }
    /// Release resumes work without erasing a verified result. Native ownership
    /// still outlives a cancelled UI waiter in the existing service slot.
    func retentionChanged(target: PhysicalContentTarget, isBusy: Bool) {
        foregroundAction = isBusy
        if isBusy {
            followups = followups.filter { !PhysicalContentTarget($0.value.entry).conflicts(with: target) }
            let all = records.merging(recent, uniquingKeysWith: { first, _ in first })
            for (key, var record) in all where PhysicalContentTarget(record.entry).conflicts(with: target) {
                history?.invalidate(key)
                generation &+= 1; record.snapshot.generation = generation
                if record.snapshot.policy != nil { record.snapshot.freshness = .stale }
                record.refreshAfter = now(); record.rateClass = .ordinary
                if records[key] != nil { records[key] = record } else { recent[key] = record }
                retireQuery(for: key); notify([key])
            }
            query?.task.cancel()
        }
        if !isBusy, !pendingHints.isEmpty { scheduleHints() }
        demandChanged()
    }
    func followUp(owner: UUID, entry: TransferEntry, action: OneDriveRetentionAction) {
        let shared = followups.values.first { $0.matches(entry) && $0.action == action }
        followups[owner] = shared ?? Followup(entry: entry, action: action, deadline: now() + 30, next: now() + 2)
        demandChanged()
    }
    func cancelFollowUp(owner: UUID) { followups.removeValue(forKey: owner); demandChanged() }
    func setActive(_ active: Bool) { scheduler.isActive = active; demandChanged() }

    func hintVisibleSearch(in store: UUID) {
        let parents = Set(viewports.values.filter { $0.storeID == store }.flatMap { $0.rows.map { $0.entry.source.directoryURL } })
        for parent in parents { hint(folder: parent, reason: .explicitRefresh) }
    }

    func hint(folder: URL?, reason: OneDriveStatusRefreshReason, childNames: Set<String>? = nil) {
        let folders = folder.map { Set([$0.absoluteString]) } ?? Set(visibleKeys.map(\.parent))
        for folder in folders {
            if reason == .explicitRefresh, now() - (lastExplicitRetry[folder] ?? -.infinity) >= 30 {
                lastExplicitRetry[folder] = now()
                // The owning Store starts its real directory or search read immediately
                // after this hint. Only the committed post-refusal read lifts quarantine.
                for key in visibleKeys where key.parent == folder {
                    guard var record = records[key], record.snapshot.failureReason != nil else { continue }
                    record.retryAfter = 0
                    if record.awaitingListingSequence != nil { record.refusals = 1 }
                    record.refreshAfter = now()
                    records[key] = record
                }
            }
            var hint = pendingHints[folder] ?? Hint()
            hint.explicit = hint.explicit || reason == .explicitRefresh
            if let childNames {
                if !hint.overflow {
                    hint.names.formUnion(childNames)
                    if hint.names.count > 64 {
                        hint.names.removeAll(); hint.overflow = true
                        hint.coarse = true
                    }
                }
            } else {
                hint.coarse = true
            }
            // Snapshot the in-flight owner at delivery. The worker may finish
            // during debounce, or have started because of an earlier named hint.
            if reason == .directory, var active = query, active.row.key.parent == folder {
                let named = childNames?.contains(active.row.entry.item.name) == true
                let broad = childNames == nil && now() - (lastHint[folder] ?? -.infinity) >= 30
                    && now() - (lastOwnCompletion[folder] ?? -.infinity) >= 2
                if named || broad {
                    if !active.isCatchUp { active.needsCatchUp = true; query = active }
                    hint.coveredGenerations[active.row.key] = active.token.generation
                    if named { records[active.row.key]?.lastNamedHint = now() }
                }
            }
            pendingHints[folder] = hint
        }
        if tracesHints {
            let message = "maxplorer-cloud-cache hint=\(reason) elapsed=\(now())\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        scheduleHints()
    }

    private func scheduleHints() {
        guard hintWakeup == nil else { return }
        hintWakeup = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.admitHints()
        }
    }

    private func admitHints() {
        hintWakeup = nil
        guard !foregroundAction else { return }
        let hints = pendingHints; pendingHints.removeAll()
        let time = now()
        for (folder, hint) in hints {
            let broad = hint.coarse && time - (lastHint[folder] ?? -.infinity) >= 30
                && (hint.explicit || time - (lastOwnCompletion[folder] ?? -.infinity) >= 2)
            if broad { lastHint[folder] = time }
            else if hint.coarse { trace("suppressedHint") }
            for key in visibleKeys where key.parent == folder {
                guard var record = records[key], hint.coveredGenerations[key] != record.snapshot.generation else { continue }
                let named = hint.names.contains(record.entry.item.name) && time - record.lastNamedHint >= 30
                guard broad || named else { continue }
                if named { record.lastNamedHint = time }
                // A hint describes demand, not new file or provider evidence.
                // A request begun after the event already observes it.
                if record.refreshAfter > time { record.rateClass = .routine; record.requestedAt = time }
                record.refreshAfter = min(record.refreshAfter, time)
                records[key] = record
                trace("admittedHint")
            }
        }
        demandChanged()
    }

    func isVisible(_ entry: TransferEntry, owner: UUID) -> Bool {
        guard let key = OneDriveStatusKey(entry) else { return false }
        return viewports[owner]?.rows.contains { $0.key == key } == true
    }

    // The parent and leaf can keep the same raw version while the provider or
    // physical root changes. Retire old evidence across visible and cached rows.
    func namespaceEpoch(for entry: TransferEntry) -> UInt64 {
        guard let key = OneDriveStatusKey(entry) else { return 0 }
        return namespaceEpochs[key.account] ?? 0
    }

    func revalidateRoot(for folder: URL) { history?.revalidateRoot(for: folder) }

    private func invalidateNamespace(_ account: String) {
        let all = records.merging(recent, uniquingKeysWith: { first, _ in first })
        var changed = Set<OneDriveStatusKey>()
        sequence &+= 1
        namespaceEpochs[account] = sequence
        for (key, var record) in all where key.account == account {
            generation &+= 1
            retireQuery(for: key)
            history?.retire(key)
            record.snapshot = .init(availability: .unknown, generation: generation)
            record.listingSequence = sequence
            record.hasCommittedListing = false
            record.refusals = 0; record.failures = 0; record.retryAfter = 0
            record.awaitingListingSequence = nil
            record.refreshAfter = now(); record.rateClass = .ordinary
            if records[key] != nil { records[key] = record } else { recent[key] = record }
            changed.insert(key)
        }
        trace("namespaceChanged", count: changed.count)
        notify(changed); demandChanged()
    }

    private func rebuildVisibleKeys() {
        visibleKeys = Set(viewports.values.flatMap { $0.rows.map(\.key) })
        if !recoveringKeys.isEmpty && recoveringKeys.isDisjoint(with: visibleKeys) { recoveryTask?.cancel() }
        for (key, owner) in waitingDirectories where viewports[owner]?.rows.contains(where: { $0.key == key }) != true {
            waitingDirectories.removeValue(forKey: key)
            guard let record = records[key] ?? recent[key], record.awaitingListingSequence != nil else { continue }
            if visibleKeys.contains(key) { requestRecovery(for: key, entry: record.entry) }
            else { failedRecovery(of: [record.entry], startedAt: sequence, readStarted: false) }
        }
    }
    private func retireQuery(for key: OneDriveStatusKey) { if query?.row.key == key { query?.task.cancel() } }
    private func invalidate(_ keys: Set<OneDriveStatusKey>) {
        for key in keys {
            waitingDirectories.removeValue(forKey: key); pendingRecovery.remove(key)
            records.removeValue(forKey: key); recent.removeValue(forKey: key); retireQuery(for: key)
        }
    }
    private func notify(_ keys: Set<OneDriveStatusKey>) {
        guard !keys.isEmpty else { return }
        pendingChanges.formUnion(keys)
        guard !notificationScheduled else { return }
        notificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationScheduled = false
            let changed = self.pendingChanges; self.pendingChanges.removeAll()
            for owner in Array(self.viewports.keys) {
                guard let viewport = self.viewports[owner] else { continue }
                let ids = Set(viewport.rows.filter { changed.contains($0.key) }.map(\.key.file))
                if !ids.isEmpty { viewport.changed(ids) }
            }
        }
    }
    private func reconcile() {
        let visible = visibleKeys
        for key in records.keys where !visible.contains(key) { recent[key] = records.removeValue(forKey: key) }
        for key in recent.keys where visible.contains(key) { records[key] = recent.removeValue(forKey: key) }
        if recent.count > historyLimit {
            let time = now()
            let oldest = recent.sorted { $0.value.evictionOrder(at: time) < $1.value.evictionOrder(at: time) }
            for (key, _) in oldest.prefix(recent.count - historyLimit) {
                recent.removeValue(forKey: key)
            }
        }
        let elapsed = freshnessNow()
        for (key, var record) in records {
            let previous = record.snapshot.freshness
            record.snapshot.reconsiderAge(at: elapsed, visibleCount: visible.count)
            records[key] = record
            if previous != record.snapshot.freshness { notify([key]) }
        }
        followups = followups.filter { owner, followup in
            followup.attempts < 4 && now() < followup.deadline && viewports.values.contains { viewport in
                viewport.storeID == owner && viewport.rows.contains { row in
                    viewport.selectedIDs.contains(row.key.file) && followup.matches(row.entry)
                }
            }
        }
        let retainedAccounts = Set(records.keys.map(\.account)).union(recent.keys.map(\.account))
        history?.retainNamespaces(for: retainedAccounts)
        namespaceEpochs = namespaceEpochs.filter { retainedAccounts.contains($0.key) }
        accountDelays = accountDelays.filter { retainedAccounts.contains($0.key) || $0.value.until > now() }
        let folders = Set(records.keys.map(\.parent)).union(recent.keys.map(\.parent))
        lastHint = lastHint.filter { folders.contains($0.key) }
        lastExplicitRetry = lastExplicitRetry.filter { folders.contains($0.key) }
        lastOwnCompletion = lastOwnCompletion.filter { folders.contains($0.key) }
    }
    private func refreshDemands() {
        var demands: [OneDriveBadgeDemand] = []
        for (owner, viewport) in viewports {
            for row in viewport.rows {
                guard let record = records[row.key], record.awaitingListingSequence == nil else { continue }
                let selected = viewport.selectedIDs.contains(row.key.file)
                let followup = followups[viewport.storeID].flatMap { $0.matches(row.entry) && selected ? $0 : nil }
                let priority: OneDriveBadgeDemand.Priority = followup != nil ? .postAction
                    : selected ? .selected : record.rateClass == .ordinary ? .firstObservation : .routine
                demands.append(.init(token: .init(key: row.key, generation: record.snapshot.generation, startSequence: sequence),
                    owner: owner, priority: priority, rateClass: followup != nil ? .postAction : record.rateClass,
                    eligibleAt: max(pausedUntil, installationDelay.until, accountDelays[row.key.account]?.until ?? 0,
                                    record.retryAfter, followup?.next ?? record.refreshAfter), requestedAt: record.requestedAt))
            }
        }
        scheduler.update(demands, now: now())
    }
    private func prepareHistory() {
        guard let history else { return }
        let visible = records.compactMapValues { $0.hasCommittedListing ? $0.snapshot.generation : nil }
        history.prepare(visible) { [weak self] key, generation, hint in
            guard let self, self.visibleKeys.contains(key), var record = self.records[key], record.hasCommittedListing,
                  record.snapshot.generation == generation, record.snapshot.freshness == .unknown,
                  record.snapshot.policy == nil, record.awaitingListingSequence == nil else { return }
            record.snapshot.policy = hint.policy
            if record.snapshot.availability == .unknown, record.entry.item.isDataless == false {
                record.snapshot.availability = .availableLocally
            }
            record.snapshot.confirmedAt = hint.confirmedAt
            record.snapshot.freshness = .stale
            record.snapshot.source = .diskHistory
            self.records[key] = record
            self.notify([key])
        }
    }
    private func demandChanged() {
        reconcile(); prepareHistory(); refreshDemands()
        wakeup?.cancel(); wakeup = nil
        if viewports.isEmpty { hintWakeup?.cancel(); hintWakeup = nil; pendingHints.removeAll() }
        if let query {
            if foregroundAction || !visibleKeys.contains(query.row.key) { query.task.cancel() }
            return
        }
        guard !foregroundAction, !viewports.isEmpty else { return }
        schedule(after: debounce)
    }
    private func schedule(after delay: Duration) {
        wakeup?.cancel()
        wakeup = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.advance()
        }
    }
    private func advance() {
        wakeup = nil
        guard !foregroundAction, query == nil, !viewports.isEmpty else { return }
        reconcile(); refreshDemands()
        guard let demand = scheduler.next(now: now()) else {
            var delay = scheduler.nextWakeup(now: now()).map { max(0.05, $0 - now()) }
            if let expiry = records.values.filter({ $0.snapshot.freshness == .fresh }).compactMap(\.snapshot.staleAfter).min() {
                let ageDelay = max(0.05, expiry - freshnessNow())
                delay = delay.map { min($0, ageDelay) } ?? ageDelay
            }
            if let delay { schedule(after: .seconds(delay)) }
            return
        }
        guard let record = records[demand.token.key] else {
            scheduler.completed(demand.token, disposition: .finished, now: now())
            refreshDemands(); schedule(after: .milliseconds(10))
            return
        }
        let row = Row(key: demand.token.key, entry: record.entry)
        let isCatchUp = record.pendingCatchUp
        records[row.key]?.pendingCatchUp = false
        let followupOwners = (demand.rateClass == .postAction || demand.priority == .postAction)
            ? Set(followups.filter { $0.value.matches(row.entry) }.keys) : []
        for owner in followupOwners {
            guard var followup = followups[owner] else { continue }
            followup.attempts += 1; followup.next = now() + 2; followups[owner] = followup
        }
        trace("startAgeSeconds", count: Int(max(0, now() - demand.requestedAt)))
        let token = demand.token, lookup = lookup
        let task = Task { [weak self] in
            let result: QueryResult
            do { result = .success(try await lookup(row.entry)) }
            catch let error as OneDriveBadgeReadError { result = .refused(error) }
            catch OneDriveRetentionError.busy { result = .refused(.busy) }
            catch OneDriveRetentionError.staleTarget { result = .refused(.staleTarget) }
            catch OneDriveRetentionError.providerRejected { result = .refused(.itemRejected) }
            catch { result = .refused(.itemUnavailable) }
            self?.finished(token, row: row, result: result, cancelled: Task.isCancelled)
        }
        query = Query(token: token, row: row, followupOwners: followupOwners,
                      historyTicket: history?.ticket(for: row.key), isCatchUp: isCatchUp, task: task)
    }
    private func confirm(_ record: inout Record, value: OneDriveBadgeObservation, source: OneDriveStatusSource) {
        record.snapshot.policy = value.policy
        record.snapshot.availability = value.isDataless ? .onlineOnly : .availableLocally
        record.snapshot.freshness = .fresh; record.snapshot.confirmedAt = wallNow()
        record.snapshot.confirmationElapsed = freshnessNow()
        record.snapshot.staleAfter = freshnessNow() + OneDriveStatusSnapshot.ageLimit(visibleCount: visibleKeys.count)
        record.snapshot.source = source
        record.retryAfter = 0; record.failures = 0; record.refusals = 0
        record.snapshot.failureReason = nil; record.snapshot.repeatedTargetRefusal = false
        record.refreshAfter = now() + 300; record.requestedAt = now(); record.rateClass = .routine
    }
    private func finished(_ token: OneDriveStatusRequestToken, row: Row, result: QueryResult, cancelled: Bool) {
        guard let active = query, active.token == token else { return }
        func isCurrent() -> Bool {
            !foregroundAction && query?.task.isCancelled == false
                && records[row.key]?.snapshot.generation == token.generation && visibleKeys.contains(row.key)
        }
        if !cancelled, isCurrent(), case let .success(value) = result {
            // Equal fresh successes still emit proof. Cache reuse and operation
            // seeds never replay this event. Reentrant actions may cancel it.
            for owner in Array(viewports.keys) {
                guard isCurrent() else { break }
                guard let viewport = viewports[owner], viewport.rows.contains(where: { $0.key == row.key }) else { continue }
                viewport.observed?(row.entry, value)
            }
        }
        let accepted = !cancelled && isCurrent()
        let busy: Bool
        if case .refused(.busy) = result { busy = true } else { busy = false }
        scheduler.completed(token, disposition: busy ? .busy : .finished, now: now())
        query = nil
        if busy {
            trace("busy")
            if active.isCatchUp || active.needsCatchUp, records[row.key]?.snapshot.generation == token.generation {
                records[row.key]?.pendingCatchUp = true
            }
            pausedUntil = max(pausedUntil, now() + 2)
            for owner in active.followupOwners {
                guard var followup = followups[owner] else { continue }
                followup.attempts = max(0, followup.attempts - 1); followups[owner] = followup
            }
        } else if accepted, var record = records[row.key] {
            touch(&record)
            let previous = record.snapshot
            history?.retire(row.key)
            switch result {
            case let .success(value):
                lastOwnCompletion[row.key.parent] = now()
                sequence &+= 1; record.residencySequence = sequence
                record.residencySource = .query
                confirm(&record, value: value, source: .query)
                accountDelays.removeValue(forKey: row.key.account)
                installationDelay = FailureDelay()
                if active.needsCatchUp { record.pendingCatchUp = true; record.refreshAfter = now() }
                if let date = record.snapshot.confirmedAt {
                    history?.record(.init(policy: value.policy, confirmedAt: date), ticket: active.historyTicket)
                }
                for (owner, followup) in followups where followup.matches(row.entry) && followup.isSettled(value) {
                    followups.removeValue(forKey: owner)
                }
            case .refused(.staleTarget):
                history?.invalidate(row.key)
                sequence &+= 1; record.awaitingListingSequence = sequence
                record.refusals += 1
                record.snapshot.failureReason = .staleTarget
                record.snapshot.repeatedTargetRefusal = record.refusals > 1
                record.snapshot.freshness = record.refusals == 1 ? .stale : .unavailable
                if record.refusals > 1 {
                    record.failures = min(5, record.failures + 1)
                    record.retryAfter = now() + Self.retryDelay(record.failures)
                }
                trace(record.refusals == 1 ? "staleTarget" : "repeatedStaleTarget")
            case .refused(let error):
                lastOwnCompletion[row.key.parent] = now()
                record.snapshot.failureReason = error
                record.snapshot.freshness = .unavailable
                record.failures = min(5, record.failures + 1)
                record.retryAfter = now() + Self.retryDelay(record.failures)
                record.refreshAfter = record.retryAfter; record.requestedAt = now(); record.rateClass = .routine
                switch error {
                case .installationUntrusted: installationDelay.record(at: now())
                case .accountUnavailable: accountDelays[row.key.account, default: FailureDelay()].record(at: now())
                default: break
                }
                trace("failure-\(error)")
                trace("retrySeconds", count: Int(record.retryAfter - now()))
            }
            records[row.key] = record
            if case .refused(.staleTarget) = result, record.refusals == 1 {
                // One request for the exact key, shared by all mounted views.
                // A folder view commits a complete listing; a search view only reconciles its captured hit.
                requestRecovery(for: row.key, entry: row.entry)
            }
            if previous.failureReason != record.snapshot.failureReason || previous.repeatedTargetRefusal != record.snapshot.repeatedTargetRefusal
                || previous.policy != record.snapshot.policy || previous.availability != record.snapshot.availability
                || previous.freshness != record.snapshot.freshness
                || previous.confirmedAt != record.snapshot.confirmedAt { notify([row.key]) }
        }
        reconcile(); refreshDemands()
        if !viewports.isEmpty && !foregroundAction { schedule(after: .milliseconds(10)) }
    }
}
