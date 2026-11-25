import Foundation
import Testing
@testable import ExplorerCore

private final class IOTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class IOTestSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func mark(_ name: String) {
        lock.lock()
        values[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[name, default: 0]
    }
}

private final class IOTestLifetime: @unchecked Sendable {
    private let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

@Suite(.serialized)
struct BlockingIOTests {
    private struct Timeout: Error {}

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        guard condition() else { throw Timeout() }
    }

    @Test
    func cancelledSidebarPresenceBodiesKeepBothSlotsWhileOrdinaryReadCompletes() async throws {
        let signals = IOTestSignals(), gate = IOTestGate()
        func request(_ name: String) -> Task<Int, Error> {
            Task {
                defer { signals.mark(name + "Returned") }
                return try await BlockingIO.run(on: .sidebarPresence) { cancellation in
                    signals.mark(name + "Started")
                    if name == "held" { gate.wait() }
                    try cancellation.checkCancellation()
                    return 1
                }
            }
        }
        let held = [request("held"), request("held")]
        defer { gate.release(); held.forEach { $0.cancel() } }
        try await waitUntil { signals.count("heldStarted") == 2 }
        held.forEach { $0.cancel() }
        let churn = (0..<20).map { _ in request("churn") }
        churn.forEach { $0.cancel() }
        for task in churn { _ = await task.result }
        let next = request("next")
        defer { next.cancel() }
        let read = Task {
            try await BlockingIO.run(on: .read) { _ in signals.mark("readDone") }
        }
        defer { read.cancel() }
        try await waitUntil { signals.count("readDone") == 1 }
        #expect(signals.count("heldReturned") == 0)
        #expect(signals.count("churnStarted") == 0 && signals.count("nextStarted") == 0)
        gate.release()
        for task in held { _ = await task.result }
        #expect(try await next.value == 1)
        #expect(signals.count("nextStarted") == 1)
    }

    @Test
    func twoPausedCopiesLeaveReadWatchAndMutationWorkersAvailable() async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals()
        let first = TransferControl(), second = TransferControl()
        first.pause(); second.pause()
        let copies = [first, second].map { control in
            Task {
                try await executor.run(on: .copy, onCancel: { control.cancel() }) { _ in
                    signals.mark("copyStarted")
                    try control.checkpoint()
                    return 1
                }
            }
        }
        defer { first.cancel(); second.cancel(); copies.forEach { $0.cancel() } }
        try await waitUntil { signals.count("copyStarted") == 2 }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerBlockingIO-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("entry.txt"))
        let reads = Task {
            let names = try await executor.run(on: .read) { cancellation in
                try cancellation.checkCancellation()
                return try FileManager().contentsOfDirectory(atPath: root.path)
            }
            #expect(names == ["entry.txt"])
            signals.mark("readDone")
        }
        let watch = Task {
            let stream = try await executor.run(on: .watchAttach) { _ in
                try LocalDirectoryObserver().events(for: root)
            }
            withExtendedLifetime(stream) { signals.mark("watchDone") }
        }
        let mutation = Task {
            let outsideTask = try await executor.run(on: .mutation) { _ in
                withUnsafeCurrentTask { $0 == nil }
            }
            #expect(outsideTask)
            signals.mark("mutationDone")
        }
        let heartbeat = Task { signals.mark("taskRan") }
        defer { reads.cancel(); watch.cancel(); mutation.cancel(); heartbeat.cancel() }
        try await waitUntil {
            signals.count("readDone") == 1 && signals.count("watchDone") == 1
                && signals.count("mutationDone") == 1 && signals.count("taskRan") == 1
        }
        try await reads.value
        try await watch.value
        try await mutation.value
        first.resume(); second.resume()
        for copy in copies { #expect(try await copy.value == 1) }
    }

    @Test
    func waitingCopyUsesTheNextFreeWorkerAndWidthStaysBounded() async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals()
        let firstGate = IOTestGate(), secondGate = IOTestGate()
        let first = Task {
            try await executor.run(on: .copy) { _ in
                signals.mark("firstStarted"); firstGate.wait(); return 1
            }
        }
        let second = Task {
            try await executor.run(on: .copy) { _ in
                signals.mark("secondStarted"); secondGate.wait(); return 2
            }
        }
        defer { firstGate.release(); secondGate.release(); first.cancel(); second.cancel() }
        try await waitUntil { signals.count("firstStarted") == 1 && signals.count("secondStarted") == 1 }
        let third = Task {
            try await executor.run(on: .copy) { _ in signals.mark("thirdStarted"); return 3 }
        }
        defer { third.cancel() }
        try await waitUntil { executor.pendingCount(on: .copy) == 1 }
        #expect(signals.count("thirdStarted") == 0)
        secondGate.release()
        try await waitUntil { signals.count("thirdStarted") == 1 }
        #expect(try await third.value == 3)
        // The first copy remains blocked; no round-robin queue can strand the third behind it.
        firstGate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }

    @Test(arguments: [BlockingIOLane.mutation, .archiveMutation])
    func queuedCancellationCompletesBeforeOccupiedWorkerAndNeverRunsBody(_ lane: BlockingIOLane) async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals(), gate = IOTestGate()
        let occupying = Task {
            try await executor.run(on: lane) { _ in
                signals.mark("occupied"); gate.wait(); return 1
            }
        }
        defer { gate.release(); occupying.cancel() }
        try await waitUntil { signals.count("occupied") == 1 }
        let queued = Task {
            do {
                _ = try await executor.run(on: lane, onCancel: { signals.mark("cancelHook") }) { _ in
                    signals.mark("forbiddenBody"); return 2
                }
                signals.mark("unexpectedSuccess")
            } catch is CancellationError { signals.mark("cancelled") }
            catch { signals.mark("unexpectedError") }
        }
        defer { queued.cancel() }
        try await waitUntil { executor.pendingCount(on: lane) == 1 }
        queued.cancel()
        try await waitUntil { signals.count("cancelled") == 1 }
        #expect(signals.count("cancelHook") == 1)
        #expect(signals.count("forbiddenBody") == 0)
        gate.release()
        _ = try await occupying.value
        // Enqueue after the cancellation and drain the same lane.
        _ = try await executor.run(on: lane) { _ in true }
        await queued.value
        #expect(signals.count("forbiddenBody") == 0)
        #expect(signals.count("unexpectedSuccess") == 0)
        #expect(signals.count("unexpectedError") == 0)
    }

    @Test
    func alreadyCancelledTaskNeverInvokesOperation() async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run(on: .read, onCancel: { signals.mark("cancelHook") }) { _ in
                signals.mark("forbiddenBody"); return 1
            }
        }
        do { _ = try await task.value; Issue.record("Already-cancelled work succeeded") }
        catch is CancellationError {}
        #expect(signals.count("cancelHook") == 1)
        #expect(signals.count("forbiddenBody") == 0)
    }

    @Test(arguments: [BlockingIOLane.mutation, .archiveMutation])
    func runningCancellationIsObservedBeforeCommitCheckpoint(_ lane: BlockingIOLane) async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals(), gate = IOTestGate()
        let task = Task {
            try await executor.run(on: lane, onCancel: { signals.mark("cancelHook") }) { token in
                signals.mark("started")
                gate.wait()
                try token.checkCancellation()
                signals.mark("committed")
                return 1
            }
        }
        defer { gate.release(); task.cancel() }
        try await waitUntil { signals.count("started") == 1 }
        task.cancel()
        try await waitUntil { signals.count("cancelHook") == 1 }
        gate.release()
        do { _ = try await task.value; Issue.record("Cancelled pre-commit work succeeded") }
        catch is CancellationError {}
        #expect(signals.count("committed") == 0)
    }

    @Test(arguments: [BlockingIOLane.mutation, .archiveMutation])
    func cancellationDuringCommittedWorkWaitsForItsSuccessfulResult(_ lane: BlockingIOLane) async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals(), gate = IOTestGate()
        let task = Task {
            let value = try await executor.run(on: lane, onCancel: { signals.mark("cancelHook") }) { token in
                try token.checkCancellation()
                signals.mark("committed")
                gate.wait()
                return 42
            }
            signals.mark("returned")
            return value
        }
        defer { gate.release(); task.cancel() }
        try await waitUntil { signals.count("committed") == 1 }
        task.cancel()
        try await waitUntil { signals.count("cancelHook") == 1 }
        #expect(signals.count("returned") == 0)
        gate.release()
        #expect(try await task.value == 42)
        #expect(signals.count("returned") == 1)
    }

    @Test(arguments: [BlockingIOLane.mutation, .archiveMutation])
    func cancellationRacingWorkerCompletionCannotReplaceCommittedSuccess(_ lane: BlockingIOLane) async throws {
        let executor = BlockingIOExecutor()
        for _ in 0..<30 {
            let signals = IOTestSignals(), gate = IOTestGate()
            let task = Task {
                try await executor.run(on: lane) { token in
                    try token.checkCancellation()
                    signals.mark("committed")
                    gate.wait()
                    return 42
                }
            }
            defer { gate.release(); task.cancel() }
            try await waitUntil { signals.count("committed") == 1 }
            gate.release()
            task.cancel()
            #expect(try await task.value == 42)
        }
    }

    @Test
    func cancellationHookCanReleaseRunningWorkWhileCompletionRacesTheHook() async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals(), gate = IOTestGate()
        let task = Task {
            try await executor.run(on: .mutation, onCancel: {
                gate.release()
                signals.mark("cancelHook")
            }) { token in
                try token.checkCancellation()
                signals.mark("committed")
                gate.wait()
                return 42
            }
        }
        defer { gate.release(); task.cancel() }
        try await waitUntil { signals.count("committed") == 1 }
        task.cancel()
        #expect(try await task.value == 42)
        #expect(signals.count("cancelHook") == 1)
    }

    @Test(arguments: [BlockingIOLane.read, .watchAttach])
    func blockedReadOnlyCallsDoNotQueueOtherLocationsAndCancellationReleasesWaiters(
        _ lane: BlockingIOLane
    ) async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals()
        let gates = (0..<3).map { _ in IOTestGate() }
        let blocked = gates.map { gate in
            Task {
                do {
                    _ = try await executor.run(on: lane) { _ in
                        signals.mark("started")
                        gate.wait()
                        signals.mark("bodyFinished")
                        return 1
                    }
                    signals.mark("unexpectedSuccess")
                } catch is CancellationError { signals.mark("cancelled") }
                catch { signals.mark("unexpectedError") }
            }
        }
        defer { blocked.forEach { $0.cancel() }; gates.forEach { $0.release() } }
        // Three held calls exceed both former read/watch lane widths.
        try await waitUntil { signals.count("started") == 3 }
        let later = Task {
            _ = try await executor.run(on: lane) { _ in signals.mark("laterFinished"); return 2 }
        }
        defer { later.cancel() }
        try await waitUntil { signals.count("laterFinished") == 1 }
        try await later.value
        blocked.forEach { $0.cancel() }
        try await waitUntil { signals.count("cancelled") == 3 }
        #expect(signals.count("bodyFinished") == 0)
        #expect(signals.count("unexpectedSuccess") == 0)
        #expect(signals.count("unexpectedError") == 0)
        gates.forEach { $0.release() }
        try await waitUntil { signals.count("bodyFinished") == 3 }
        for task in blocked { await task.value }
    }

    @Test
    func abandonedWatchResultReleasesItsNativeStreamAfterWorkerReturns() async throws {
        let executor = BlockingIOExecutor(), signals = IOTestSignals(), gate = IOTestGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerBlockingIO-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        let task = Task {
            do {
                let stream = try await executor.run(on: .watchAttach) { _ in
                    let stream = try LocalDirectoryObserver(onStop: { signals.mark("stopped") }).events(for: root)
                    signals.mark("attached")
                    gate.wait()
                    return stream
                }
                withExtendedLifetime(stream) { signals.mark("unexpectedSuccess") }
            } catch is CancellationError { signals.mark("cancelled") }
            catch { signals.mark("unexpectedError") }
        }
        defer { task.cancel() }
        try await waitUntil { signals.count("attached") == 1 }
        task.cancel()
        try await waitUntil { signals.count("cancelled") == 1 }
        #expect(signals.count("stopped") == 0)
        gate.release()
        try await waitUntil { signals.count("stopped") == 1 }
        await task.value
        #expect(signals.count("unexpectedSuccess") == 0)
        #expect(signals.count("unexpectedError") == 0)
    }

    @Test
    func readCancellationRacingCompletionResumesOnceAndReleasesItsResult() async throws {
        let executor = BlockingIOExecutor()
        for _ in 0..<20 {
            let signals = IOTestSignals(), gate = IOTestGate()
            let task = Task {
                do {
                    let value = try await executor.run(on: .read) { _ in
                        let value = IOTestLifetime(onRelease: { signals.mark("released") })
                        signals.mark("started")
                        gate.wait()
                        return value
                    }
                    withExtendedLifetime(value) { signals.mark("success") }
                } catch is CancellationError { signals.mark("cancelled") }
                catch { signals.mark("unexpectedError") }
                signals.mark("returned")
            }
            defer { gate.release(); task.cancel() }
            try await waitUntil { signals.count("started") == 1 }
            gate.release()
            task.cancel()
            try await waitUntil { signals.count("returned") == 1 && signals.count("released") == 1 }
            await task.value
            #expect(signals.count("success") + signals.count("cancelled") == 1)
            #expect(signals.count("unexpectedError") == 0)
        }
    }
}
