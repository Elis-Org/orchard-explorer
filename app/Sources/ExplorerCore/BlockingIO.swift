import Foundation

/// Native synchronous I/O belongs on dispatch workers, not Swift's cooperative
/// executor. Materializing content is bounded separately from ordinary reads,
/// so listing must not queue behind another window's decoder or filesystem call.
public enum BlockingIOLane: CaseIterable, Sendable {
    case read
    case watchAttach
    case sidebarPresence
    case copy
    case mutation
    case archiveMutation
    case content
    case hydration
    case explicitHydration

    fileprivate var width: Int? {
        switch self {
        case .copy, .content, .hydration, .sidebarPresence: return 2
        case .mutation, .archiveMutation, .explicitHydration: return 1
        case .read, .watchAttach: return nil
        }
    }

    fileprivate var abandonsRunningWorkOnCancellation: Bool {
        self == .read || self == .watchAttach || self == .hydration || self == .explicitHydration
    }
}

/// A dispatch closure has no caller Task context. Call this token at the same
/// pre-commit checkpoints that formerly used Task.checkCancellation().
public final class BlockingIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    fileprivate func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public enum BlockingIO {
    private static let executor = BlockingIOExecutor()

    /// Queued cancellation prevents execution. Read-only cancellation also
    /// releases the waiter while a native call finishes; its eventual result is
    /// discarded, including any newly attached watch's owned resources.
    /// Running copy/mutation/archiveMutation/content cancellation only signals the token/onCancel hook:
    /// the body alone supplies the result, preserving committed outcomes.
    /// Abandonment does not interrupt an OS call or bound global GCD thread use.
    public static func run<Value: Sendable>(
        on lane: BlockingIOLane,
        onCancel: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable (BlockingIOCancellation) throws -> Value
    ) async throws -> Value {
        try await executor.run(on: lane, onCancel: onCancel, operation)
    }
}

/// Internal construction isolates executor tests from the application's queues.
final class BlockingIOExecutor: @unchecked Sendable {
    private let lanes: [BlockingIOLane: BlockingIOLaneQueue]

    init() {
        lanes = Dictionary(uniqueKeysWithValues: BlockingIOLane.allCases.compactMap { lane in
            lane.width.map { (lane, BlockingIOLaneQueue(lane: lane, width: $0)) }
        })
    }

    // A deterministic test seam for cancellation after admission but before execution.
    func pendingCount(on lane: BlockingIOLane) -> Int { lanes[lane]?.pendingCount ?? 0 }

    func run<Value: Sendable>(
        on lane: BlockingIOLane,
        onCancel: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable (BlockingIOCancellation) throws -> Value
    ) async throws -> Value {
        let queue = lanes[lane]
        let job = BlockingIOJob(abandonsRunningWork: lane.abandonsRunningWorkOnCancellation,
                                operation: operation)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard job.install(continuation) else { return }
                if let queue { queue.enqueue(job) }
                else {
                    DispatchQueue.global(qos: lane == .watchAttach ? .utility : .userInitiated)
                        .async { job.execute() }
                }
            }
        }, onCancel: {
            if job.cancel() {
                queue?.removePending(job.id)
                // Never call external code while holding a job or lane lock.
                // Transfers use this hook to wake a paused TransferControl.
                onCancel()
            }
        })
    }
}

private protocol BlockingIOWork: AnyObject, Sendable {
    var id: UUID { get }
    var isQueued: Bool { get }
    func execute()
}

private final class BlockingIOJob<Value: Sendable>: BlockingIOWork, @unchecked Sendable {
    private enum State { case awaitingContinuation, queued, running, finished }
    let id = UUID()
    private let lock = NSLock()
    private let cancellation = BlockingIOCancellation()
    private let abandonsRunningWork: Bool
    private var state = State.awaitingContinuation
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: (@Sendable (BlockingIOCancellation) throws -> Value)?

    init(abandonsRunningWork: Bool,
         operation: @escaping @Sendable (BlockingIOCancellation) throws -> Value) {
        self.abandonsRunningWork = abandonsRunningWork
        self.operation = operation
    }

    var isQueued: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .queued
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if state == .finished {
            // onCancel can run before the operation closure installs its continuation.
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        precondition(state == .awaitingContinuation)
        self.continuation = continuation
        state = .queued
        lock.unlock()
        return true
    }

    /// Returns whether cancellation was newly accepted before completion.
    func cancel() -> Bool {
        lock.lock()
        guard state != .finished else { lock.unlock(); return false }
        cancellation.cancel()
        let pending: CheckedContinuation<Value, Error>?
        if state == .running && !abandonsRunningWork {
            pending = nil
        } else {
            pending = continuation
            continuation = nil
            operation = nil
            state = .finished
        }
        lock.unlock()
        pending?.resume(throwing: CancellationError())
        return true
    }

    func execute() {
        lock.lock()
        guard state == .queued, let operation else { lock.unlock(); return }
        state = .running
        self.operation = nil
        lock.unlock()

        let result = Result {
            try cancellation.checkCancellation()
            return try operation(cancellation)
        }

        lock.lock()
        if state == .finished {
            // Read-only cancellation already resumed the waiter. Release the
            // eventual value outside the lock; a discarded watch owns teardown.
            lock.unlock()
            return
        }
        precondition(state == .running)
        let completed = continuation
        continuation = nil
        state = .finished
        lock.unlock()
        // No cancellation check here: the body may already have committed a write.
        completed?.resume(with: result)
    }
}

/// At most `width` synchronous bodies can run. Waiting jobs are stored without
/// occupying threads; the next job goes to whichever fixed worker becomes free.
private final class BlockingIOLaneQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let workers: [DispatchQueue]
    private var idle: [Int]
    private var pending: [any BlockingIOWork] = []

    init(lane: BlockingIOLane, width: Int) {
        workers = (0..<width).map {
            DispatchQueue(label: "nativeExplorer.blocking.\(lane).\($0)",
                          qos: lane == .sidebarPresence ? .utility : .userInitiated,
                          autoreleaseFrequency: .workItem)
        }
        idle = Array(workers.indices)
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func enqueue(_ job: any BlockingIOWork) {
        lock.lock()
        // If cancellation beat enqueue, it has already released the body/result.
        guard job.isQueued else { lock.unlock(); return }
        guard let worker = idle.popLast() else {
            pending.append(job)
            lock.unlock()
            return
        }
        lock.unlock()
        dispatch(job, on: worker)
    }

    func removePending(_ id: UUID) {
        lock.lock()
        pending.removeAll { $0.id == id }
        lock.unlock()
    }

    private func dispatch(_ job: any BlockingIOWork, on worker: Int) {
        workers[worker].async {
            job.execute()
            self.finished(worker)
        }
    }

    private func finished(_ worker: Int) {
        lock.lock()
        var next: (any BlockingIOWork)?
        while !pending.isEmpty {
            let candidate = pending.removeFirst()
            if candidate.isQueued { next = candidate; break }
        }
        if next == nil { idle.append(worker) }
        lock.unlock()
        if let next { dispatch(next, on: worker) }
    }
}
