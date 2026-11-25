import Foundation
import Testing
@testable import ExplorerCore

@Suite(.serialized) struct ContentWorkerTests {
    @Test func twoContentWorkersBoundAdmissionAndQueuedCancellationSkipsBody() async throws {
        let executor = BlockingIOExecutor(), signals = ContentWorkerSignals()
        let first = TransferControl(), second = TransferControl()
        first.pause(); second.pause()
        let running = [first, second].map { control in
            Task {
                try await executor.run(on: .content, onCancel: { control.cancel() }) { _ in
                    signals.mark(); try control.checkpoint(); return 1
                }
            }
        }
        defer { first.cancel(); second.cancel(); running.forEach { $0.cancel() } }
        try await waitUntil { signals.count == 2 }
        let queued = Task {
            try await executor.run(on: .content) { _ in signals.mark(); return 2 }
        }
        defer { queued.cancel() }
        try await waitUntil { executor.pendingCount(on: .content) == 1 }
        #expect(signals.count == 2)
        queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(signals.count == 2)
        first.resume(); second.resume()
        for task in running { #expect(try await task.value == 1) }
    }

    @Test func runningContentCancellationWaitsForOwnedCleanupResult() async throws {
        let executor = BlockingIOExecutor(), entered = ContentWorkerSignals(), finished = ContentWorkerSignals()
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            let result = try await executor.run(on: .content) { cancellation in
                entered.mark(); gate.wait()
                #expect(cancellation.isCancelled)
                // Represents a verified owned cleanup outcome after cancellation.
                return "cleaned"
            }
            finished.mark(); return result
        }
        defer { gate.signal(); task.cancel() }
        try await waitUntil { entered.count == 1 }
        task.cancel()
        // A FIFO mutation worker supplies a deterministic scheduling turn while
        // the content body remains blocked; cancellation cannot return early.
        _ = try await executor.run(on: .mutation) { _ in 1 }
        #expect(finished.count == 0)
        gate.signal()
        #expect(try await task.value == "cleaned")
        #expect(finished.count == 1)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
        if !condition() { throw ItemContentError.deadlineExceeded }
    }
}

private final class ContentWorkerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value += 1; lock.unlock() }
}
