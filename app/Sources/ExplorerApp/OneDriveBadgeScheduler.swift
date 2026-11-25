import Foundation

/// Scheduling demand is display work only. It carries no authority to mutate a file.
struct OneDriveBadgeDemand {
    enum Priority: Int { case postAction, selected, firstObservation, routine }
    enum RateClass { case ordinary, routine, postAction }

    let token: OneDriveStatusRequestToken
    let owner: UUID
    let priority: Priority
    let rateClass: RateClass
    let eligibleAt: TimeInterval
    let requestedAt: TimeInterval
}

/// Pure admission policy. The cache supplies demand/cooldowns and owns wakeups;
/// the native service retains actual worker ownership after cancellation/timeout.
struct OneDriveBadgeScheduler {
    enum CompletionDisposition { case busy, finished }

    private struct Identity: Hashable {
        let key: OneDriveStatusKey
        let generation: UInt64

        init(_ token: OneDriveStatusRequestToken) {
            key = token.key
            generation = token.generation
        }
    }

    private struct Pending {
        var token: OneDriveStatusRequestToken
        var owners: Set<UUID>
        var priority: OneDriveBadgeDemand.Priority
        var rateClass: OneDriveBadgeDemand.RateClass
        var eligibleAt: TimeInterval
        var requestedAt: TimeInterval
        let ordinal: UInt64

        var isRoutine: Bool { rateClass == .routine }
        var isPostAction: Bool { rateClass == .postAction || priority == .postAction }
        var usesReserve: Bool { priority == .selected || priority == .postAction }

        func demand(owner: UUID) -> OneDriveBadgeDemand {
            .init(token: token, owner: owner, priority: priority, rateClass: rateClass,
                  eligibleAt: eligibleAt, requestedAt: requestedAt)
        }
    }

    private struct Admission {
        let demand: OneDriveBadgeDemand
        let identity: Identity
        let routineCost: Bool
        let postActionID: UInt64?
        let previousOwner: UUID?
        let previousNonroutineStarts: Int
    }

    private struct PostActionStart {
        let id: UInt64
        let time: TimeInterval
    }

    /// Recompute from the last debit/refund, rather than accumulating rounded
    /// fractions on every clock observation. Inspecting the next wakeup must
    /// not change an exact refill boundary.
    private struct Bucket {
        let capacity: Double
        let refillPerSecond: Double
        private var balance: Double
        private var recordedAt: TimeInterval?

        init(capacity: Double, refillPerSecond: Double) {
            self.capacity = capacity
            self.refillPerSecond = refillPerSecond
            balance = capacity
        }

        func available(at time: TimeInterval) -> Double {
            guard let recordedAt else { return capacity }
            return min(capacity, balance + max(0, time - recordedAt) * refillPerSecond)
        }

        mutating func consume(at time: TimeInterval) {
            balance = available(at: time) - 1
            recordedAt = time
        }

        mutating func refund(at time: TimeInterval) {
            balance = min(capacity, available(at: time) + 1)
            recordedAt = time
        }
    }

    var isActive = true
    var inFlight: OneDriveStatusRequestToken? { admission?.demand.token }

    private let reserve: Double
    private var global: Bucket
    private var routine = Bucket(capacity: 2, refillPerSecond: 8.0 / 60.0)
    private var lastTime: TimeInterval?
    private var pending: [Identity: Pending] = [:]
    private var admission: Admission?
    private var postActionStarts: [PostActionStart] = []
    private var nextOrdinal: UInt64 = 0
    private var nextAdmissionID: UInt64 = 0
    private var lastOwner: UUID?
    private var nonroutineStarts = 0

    init(capacity: Int = 32, interval: TimeInterval = 60) {
        let count = max(1, capacity)
        reserve = Double(min(4, max(0, count - 4)))
        global = Bucket(capacity: Double(count),
            refillPerSecond: Double(count) / (interval.isFinite ? max(0.01, interval) : 60))
    }

    /// Replaces current demand without releasing a previously admitted worker.
    /// Multiple viewports share a key/generation; promotion cannot evade the
    /// routine budget of an existing invalidation hint.
    mutating func update(_ demands: [OneDriveBadgeDemand], now: TimeInterval) {
        let time = advance(to: now)
        var updated: [Identity: Pending] = [:]
        for demand in demands where demand.eligibleAt.isFinite && demand.requestedAt.isFinite {
            let identity = Identity(demand.token)
            if var existing = updated[identity] {
                existing.owners.insert(demand.owner)
                if demand.token.startSequence < existing.token.startSequence { existing.token = demand.token }
                // Future periodic work is not an admitted invalidating hint.
                // A new selected check due now must not inherit its routine cost.
                let sameEligibility = (existing.eligibleAt <= time && demand.eligibleAt <= time)
                    || existing.eligibleAt == demand.eligibleAt
                if sameEligibility {
                    if demand.priority.rawValue < existing.priority.rawValue { existing.priority = demand.priority }
                    existing.rateClass = combined(existing.rateClass, demand.rateClass)
                } else if demand.eligibleAt < existing.eligibleAt {
                    existing.priority = demand.priority
                    existing.rateClass = demand.rateClass
                }
                existing.eligibleAt = min(existing.eligibleAt, demand.eligibleAt)
                existing.requestedAt = min(existing.requestedAt, demand.requestedAt)
                updated[identity] = existing
            } else {
                let ordinal: UInt64
                if let existing = pending[identity] {
                    ordinal = existing.ordinal
                } else {
                    ordinal = nextOrdinal
                    nextOrdinal &+= 1
                }
                updated[identity] = Pending(token: demand.token, owners: [demand.owner],
                    priority: demand.priority, rateClass: demand.rateClass,
                    eligibleAt: demand.eligibleAt, requestedAt: demand.requestedAt, ordinal: ordinal)
            }
        }
        pending = updated.mapValues { request in
            var result = request
            if let previous = pending[Identity(request.token)], previous.eligibleAt <= time {
                result.rateClass = combined(previous.rateClass, result.rateClass)
            }
            return result
        }
        if !pending.values.contains(where: \.isRoutine) { nonroutineStarts = 0 }
    }

    mutating func next(now: TimeInterval) -> OneDriveBadgeDemand? {
        let time = advance(to: now)
        guard admission == nil else { return nil }
        let eligible = pending.values.filter { ready($0, at: time) }
        guard !eligible.isEmpty else { return nil }

        let chosen: Pending
        let owner: UUID
        if nonroutineStarts >= 7, global.available(at: time) > reserve,
           let oldest = eligible.filter(\.isRoutine).min(by: older) {
            chosen = oldest
            owner = nextOwner(in: oldest.owners)
        } else {
            let priority = eligible.map(\.priority.rawValue).min()!
            let peers = eligible.filter { $0.priority.rawValue == priority }
            owner = nextOwner(in: Set(peers.flatMap(\.owners)))
            chosen = peers.filter { $0.owners.contains(owner) }.min(by: older)!
        }

        let result = chosen.demand(owner: owner)
        let previousOwner = lastOwner
        let previousNonroutineStarts = nonroutineStarts
        global.consume(at: time)
        if chosen.isRoutine {
            routine.consume(at: time)
            nonroutineStarts = 0
        } else if pending.values.contains(where: \.isRoutine) {
            nonroutineStarts = min(7, nonroutineStarts + 1)
        } else {
            nonroutineStarts = 0
        }
        var postActionID: UInt64?
        if chosen.isPostAction {
            postActionID = nextAdmissionID
            postActionStarts.append(.init(id: nextAdmissionID, time: time))
        }
        nextAdmissionID &+= 1
        lastOwner = owner
        admission = .init(demand: result, identity: Identity(result.token), routineCost: chosen.isRoutine,
            postActionID: postActionID, previousOwner: previousOwner,
            previousNonroutineStarts: previousNonroutineStarts)
        return result
    }

    /// Only a typed pre-native-admission busy result refunds cost. Every other
    /// outcome, including an ambiguous timeout, uses finished and consumes it.
    mutating func completed(_ token: OneDriveStatusRequestToken, disposition: CompletionDisposition,
                            now: TimeInterval) {
        let time = advance(to: now)
        guard let active = admission, active.demand.token == token else { return }
        admission = nil
        switch disposition {
        case .busy:
            global.refund(at: time)
            if active.routineCost { routine.refund(at: time) }
            if let id = active.postActionID { postActionStarts.removeAll { $0.id == id } }
            lastOwner = active.previousOwner
            nonroutineStarts = pending.values.contains(where: \.isRoutine) ? active.previousNonroutineStarts : 0
        case .finished:
            pending.removeValue(forKey: active.identity)
            if !pending.values.contains(where: \.isRoutine) { nonroutineStarts = 0 }
        }
    }

    /// Absolute monotonic time. A running native owner has no scheduler wakeup;
    /// completion or a new demand/activation event is responsible for reconsidering.
    mutating func nextWakeup(now: TimeInterval) -> TimeInterval? {
        let time = advance(to: now)
        guard admission == nil else { return nil }
        let tokens = global.available(at: time)
        let routineTokens = routine.available(at: time)
        return pending.values.compactMap { request -> TimeInterval? in
            guard !request.isRoutine || isActive else { return nil }
            var earliest = max(time, request.eligibleAt)
            let minimum = request.usesReserve ? 1 : max(1, reserve.nextUp)
            if tokens < minimum {
                earliest = max(earliest, time + (minimum - tokens) / global.refillPerSecond)
            }
            if request.isRoutine && routineTokens < 1 {
                earliest = max(earliest, time + (1 - routineTokens) / routine.refillPerSecond)
            }
            if request.isPostAction && postActionStarts.count >= 8 {
                earliest = max(earliest, postActionStarts[0].time + 60)
            }
            if earliest <= time && !ready(request, at: time) { return time.nextUp }
            return earliest
        }.min()
    }

    private func ready(_ request: Pending, at time: TimeInterval) -> Bool {
        let tokens = global.available(at: time)
        return request.eligibleAt <= time && tokens >= 1
            && (request.usesReserve || tokens > reserve)
            && (!request.isRoutine || (isActive && routine.available(at: time) >= 1))
            && (!request.isPostAction || postActionStarts.count < 8)
    }

    private func combined(_ first: OneDriveBadgeDemand.RateClass,
                          _ second: OneDriveBadgeDemand.RateClass) -> OneDriveBadgeDemand.RateClass {
        if first == .routine || second == .routine { return .routine }
        if first == .postAction || second == .postAction { return .postAction }
        return .ordinary
    }

    private func older(_ first: Pending, _ second: Pending) -> Bool {
        first.requestedAt == second.requestedAt ? first.ordinal < second.ordinal : first.requestedAt < second.requestedAt
    }

    private func nextOwner(in owners: Set<UUID>) -> UUID {
        let ordered = owners.sorted { $0.uuidString < $1.uuidString }
        if let lastOwner, let next = ordered.first(where: { $0.uuidString > lastOwner.uuidString }) { return next }
        return ordered[0]
    }

    @discardableResult
    private mutating func advance(to proposed: TimeInterval) -> TimeInterval {
        let finite = proposed.isFinite ? proposed : (lastTime ?? 0)
        let time = max(lastTime ?? finite, finite)
        lastTime = time
        postActionStarts.removeAll { $0.time <= time - 60 }
        return time
    }
}
