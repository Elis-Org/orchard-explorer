import Foundation
import Testing
@testable import ExplorerCore

@Suite(.serialized)
struct ArchiveWorkerTests {
    @Test func pausedArchiveAllowsUnrelatedPhysicalRenameToFinish() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("remove.txt", contents: Data("remove".utf8)),
            ZIPOperationTestEntry("keep.txt", contents: Data("keep".utf8))
        ])
        let archiveContext = try await fixture.context()
        let sourceURL = fixture.root.appendingPathComponent("physical.txt")
        let physicalBytes = Data("unrelated physical file".utf8)
        try physicalBytes.write(to: sourceURL)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let parentIdentity = try #require(snapshot.directoryIdentity)
        let item = try #require(snapshot.items.first { $0.name == "physical.txt" })
        let physicalContext = FileOperationContext(directoryURL: fixture.root, directoryIdentity: parentIdentity)
        let target = ArchiveMemberTarget(location: try fixture.location(["remove.txt"]), revision: archiveContext.revision)
        let control = TransferControl(), signals = ArchiveWorkerSignals()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in
            control.pause()
            signals.mark("archivePaused")
        }
        let operations = LocalArchiveOperations(hooks: hooks)
        let archive = Task {
            try await operations.modify([.remove(source: target)], in: archiveContext,
                                        control: control, onProgress: { _ in })
        }
        defer { control.cancel(); archive.cancel() }
        guard await waitUntil(timeout: .seconds(30), { signals.contains("archivePaused") }) else {
            control.cancel(); archive.cancel()
            _ = await archive.result
            Issue.record("The real archive operation did not reach its pre-swap pause.")
            return
        }

        let rename = Task {
            let result = try await LocalFileOperations().rename(item, to: "renamed.txt", in: physicalContext)
            signals.mark("renameFinished")
            return result
        }
        defer { rename.cancel() }
        // Sharing the sole short-mutation worker strands this rename until the
        // archive is resumed. The assertion is about the real published file.
        let finishedWhilePaused = await waitUntil { signals.contains("renameFinished") }
        let renamedURL = fixture.root.appendingPathComponent("renamed.txt")
        let publishedWhilePaused = (try? Data(contentsOf: renamedURL)) == physicalBytes
        let archiveBytesWhilePaused = try? Data(contentsOf: fixture.url)

        // Drain both tasks before any throwing assertion or fixture cleanup,
        // including the expected RED path where the rename is still queued.
        control.resume()
        let archiveResult = await archive.result
        let renameResult = await rename.result
        #expect(finishedWhilePaused && publishedWhilePaused,
                "An unrelated physical rename must finish while ZIP preparation is paused.")
        #expect(archiveBytesWhilePaused == fixture.bytes)
        _ = try archiveResult.get()
        let renamed = try renameResult.get()
        #expect(renamed.warning == nil)
        #expect(try Data(contentsOf: renamed.url) == physicalBytes)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(manifest.records.map(\.components) == [["keep.txt"]])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["fixture.zip", "renamed.txt"])
    }

    @Test func archiveJobsSerializeOnOneWorker() async throws {
        let executor = BlockingIOExecutor(), signals = ArchiveWorkerSignals(), control = TransferControl()
        control.pause()
        let first = Task {
            try await executor.run(on: .archiveMutation, onCancel: { control.cancel() }) { _ in
                signals.mark("firstStarted"); try control.checkpoint(); return 1
            }
        }
        defer { control.cancel(); first.cancel() }
        guard await waitUntil({ signals.contains("firstStarted") }) else {
            control.cancel(); first.cancel(); _ = await first.result
            Issue.record("First archive worker did not start."); return
        }
        let second = Task {
            try await executor.run(on: .archiveMutation) { _ in signals.mark("secondStarted"); return 2 }
        }
        defer { second.cancel() }
        let queued = await waitUntil { executor.pendingCount(on: .archiveMutation) == 1 }
        let startedWhileOccupied = signals.contains("secondStarted")
        control.resume()
        let firstResult = await first.result, secondResult = await second.result
        #expect(queued && !startedWhileOccupied)
        #expect(try firstResult.get() == 1)
        #expect(try secondResult.get() == 2)
    }

    @Test func cancellingPausedArchivePreservesOriginalAndCleansCandidate() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep.txt", contents: Data("keep".utf8))])
        let context = try await fixture.context()
        let target = ArchiveMemberTarget(location: try fixture.location(["keep.txt"]), revision: context.revision)
        let control = TransferControl(), signals = ArchiveWorkerSignals()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in control.pause(); signals.mark("paused") }
        let operations = LocalArchiveOperations(hooks: hooks)
        let task = Task {
            try await operations.modify([.remove(source: target)], in: context, control: control, onProgress: { _ in })
        }
        defer { control.cancel(); task.cancel() }
        let reachedPause = await waitUntil(timeout: .seconds(30)) { signals.contains("paused") }
        // Task cancellation must wake the paused control, await cleanup, and
        // return cancellation rather than leaving the archive worker occupied.
        task.cancel()
        let result = await task.result
        #expect(reachedPause)
        do { _ = try result.get(); Issue.record("Cancelled archive work succeeded.") }
        catch is CancellationError {}
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func physicalRenameOfPausedArchivePreservesRelocatedOriginal() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep.txt", contents: Data("keep".utf8))])
        let context = try await fixture.context()
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let identity = try #require(snapshot.directoryIdentity)
        let item = try #require(snapshot.items.first { $0.name == "fixture.zip" })
        let parent = FileOperationContext(directoryURL: fixture.root, directoryIdentity: identity)
        let target = ArchiveMemberTarget(location: try fixture.location(["keep.txt"]), revision: context.revision)
        let control = TransferControl(), signals = ArchiveWorkerSignals()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in control.pause(); signals.mark("paused") }
        let operations = LocalArchiveOperations(hooks: hooks)
        let archive = Task {
            try await operations.modify([.remove(source: target)], in: context, control: control, onProgress: { _ in })
        }
        defer { control.cancel(); archive.cancel() }
        guard await waitUntil(timeout: .seconds(30), { signals.contains("paused") }) else {
            control.cancel(); archive.cancel(); _ = await archive.result
            Issue.record("Archive work did not reach the race boundary."); return
        }
        let rename = Task {
            let result = try await LocalFileOperations().rename(item, to: "relocated.zip", in: parent)
            signals.mark("renamed"); return result
        }
        defer { rename.cancel() }
        let renamedWhilePaused = await waitUntil { signals.contains("renamed") }
        control.resume()
        let archiveResult = await archive.result, renameResult = await rename.result
        #expect(renamedWhilePaused)
        let relocated = try renameResult.get()
        #expect(relocated.warning == nil)
        do { _ = try archiveResult.get(); Issue.record("The archive transaction accepted a renamed source.") }
        catch ArchiveOperationError.changed {}
        #expect(try Data(contentsOf: relocated.url) == fixture.bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["relocated.zip"])
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}

private final class ArchiveWorkerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()
    func mark(_ name: String) {
        lock.lock(); values.insert(name); lock.unlock()
    }
    func contains(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains(name)
    }
}
