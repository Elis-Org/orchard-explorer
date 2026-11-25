import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Reads ignore cancellation deliberately: late completions must be rejected by the model.
private actor AccessCheckLoader: DirectoryListing {
    struct Request: Sendable { let url: URL; let showHidden: Bool }
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requests.count] = continuation
            requests.append(Request(url: url, showHidden: showHidden))
        }
    }
    func finish(_ index: Int, items: [FileItem] = []) {
        pending.removeValue(forKey: index)?.resume(returning: DirectorySnapshot(items: items))
    }
    func fail(_ index: Int, _ error: any Error) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }
    func shutdown() {
        closed = true
        let calls = Array(pending.values)
        pending.removeAll()
        for call in calls { call.resume(throwing: CancellationError()) }
    }
}

/// MAC-003 native access policy: explicit, folder-scoped read checks. These tests
/// do not establish TCC/Full Disk Access status, write permission or Windows parity.
@MainActor
final class FileAccessSetupTests {
    private let folder = URL(fileURLWithPath: "/tmp/explorer-access-check-model", isDirectory: true)

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Access check did not settle before the bounded deadline")
    }
    private func stop(_ model: FileAccessSetupModel, _ loader: AccessCheckLoader) {
        model.cancelChecks()
        Task { await loader.shutdown() }
    }

    @Test
    func initializationAndContextChangesNeverProbeLocationsOrTheAppBundle() async throws {
        let loader = AccessCheckLoader()
        let bundle = folder.appendingPathComponent("Not Installed.app")
        let context = FileAccessContext(failure: .permissionDenied, locations: [folder], action: "Rename")
        let model = FileAccessSetupModel(context: context, loader: loader, bundleURL: bundle)
        defer { stop(model, loader) }
        #expect(model.context == context && model.bundleURL == bundle)
        model.updateContext(FileAccessContext(failure: .readOnlyVolume,
            locations: [folder.appendingPathComponent("Other")], action: "Copy"))
        model.updateContext(nil)
        await Task.yield()
        #expect(await loader.requests.isEmpty)
        #expect(model.results.isEmpty && model.checkingURL == nil && model.context == nil)
    }

    @Test
    func explicitChecksUseOnlyTheChosenLocationAndNewerResultsRejectLateReads() async throws {
        let loader = AccessCheckLoader()
        let checked = FileAccessSetupModel(loader: loader)
        defer { stop(checked, loader) }
        let second = folder.appendingPathComponent("Second", isDirectory: true)
        checked.checkFolder(folder)
        try await waitUntil { await loader.requests.count == 1 }
        checked.checkFolder(second)
        try await waitUntil { await loader.requests.count == 2 }
        let requests = await loader.requests
        #expect(requests.map(\.url) == [folder, second])
        #expect(requests.allSatisfy { !$0.showHidden })
        await loader.finish(1)
        try await waitUntil { checked.checkingURL == nil && checked.results.count == 1 }
        await loader.fail(0, CocoaError(.fileReadNoPermission))
        await Task.yield()
        #expect(checked.results.count == 1 && checked.results[0].location == second)
        #expect(checked.results[0].outcome == .readable(visibleItemCount: 0))
        #expect(checked.results[0].summary == "Folder listing succeeded: 0 visible entries.")
    }

    @Test
    func changingContextCancelsPendingChecksAndClearsPriorScopedResults() async throws {
        let loader = AccessCheckLoader()
        let checked = FileAccessSetupModel(loader: loader)
        defer { stop(checked, loader) }
        checked.checkFolder(folder)
        try await waitUntil { await loader.requests.count == 1 }
        await loader.finish(0)
        try await waitUntil { checked.results.count == 1 }
        checked.checkFolder(folder.appendingPathComponent("Pending"))
        try await waitUntil { await loader.requests.count == 2 }
        let context = FileAccessContext(locations: [folder.appendingPathComponent("New")], action: "Open folder")
        checked.updateContext(context)
        #expect(checked.context == context && checked.results.isEmpty && checked.checkingURL == nil)
        await loader.finish(1)
        await Task.yield()
        #expect(checked.results.isEmpty)
        #expect(await loader.requests.count == 2)
    }

    @Test
    func cancelKeepsCompletedResultsAndARepeatedLocationReplacesItsResult() async throws {
        let loader = AccessCheckLoader()
        let model = FileAccessSetupModel(loader: loader)
        defer { stop(model, loader) }
        model.checkFolder(folder)
        try await waitUntil { await loader.requests.count == 1 }
        await loader.fail(0, CocoaError(.fileReadNoPermission))
        try await waitUntil { model.results.count == 1 }
        if case .failed(let failure, let message) = model.results[0].outcome {
            #expect(failure == .permissionDenied && !message.isEmpty)
        } else { Issue.record("A denied read must remain a scoped failure") }
        model.checkFolder(folder)
        try await waitUntil { await loader.requests.count == 2 }
        await loader.finish(1)
        try await waitUntil { model.checkingURL == nil }
        #expect(model.results.count == 1 && model.results[0].outcome == .readable(visibleItemCount: 0))
        model.checkFolder(folder.appendingPathComponent("Pending"))
        try await waitUntil { await loader.requests.count == 3 }
        model.cancelChecks()
        await loader.fail(2, CocoaError(.fileReadNoPermission))
        await Task.yield()
        #expect(model.checkingURL == nil && model.results.count == 1)
        #expect(model.results[0].location == folder)
    }

    @Test(arguments: [CocoaError.Code.fileWriteVolumeReadOnly, .fileReadNoSuchFile])
    func readOnlyAndUnrelatedFailuresRemainDistinct(_ code: CocoaError.Code) async throws {
        let loader = AccessCheckLoader()
        let model = FileAccessSetupModel(loader: loader)
        defer { stop(model, loader) }
        model.checkFolder(folder)
        try await waitUntil { await loader.requests.count == 1 }
        await loader.fail(0, CocoaError(code))
        try await waitUntil { model.results.count == 1 }
        if case .failed(let failure, _) = model.results[0].outcome {
            #expect(failure == (code == .fileWriteVolumeReadOnly ? .readOnlyVolume : nil))
        } else { Issue.record("The injected failure must not become a successful access check") }
    }

    @Test
    func aRealExplicitCheckReportsOnlyVisibleEntriesInTheOwnedFolder() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerAccessCheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("one".utf8).write(to: temporary.appendingPathComponent("one.txt"))
        try Data().write(to: temporary.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("Child"), withIntermediateDirectories: false)
        let model = FileAccessSetupModel()
        defer { model.cancelChecks() }
        #expect(model.results.isEmpty)
        model.checkFolder(temporary)
        try await waitUntil { model.checkingURL == nil && model.results.count == 1 }
        #expect(model.results[0].location == temporary.standardizedFileURL)
        #expect(model.results[0].outcome == .readable(visibleItemCount: 2))
        #expect(model.results[0].summary == "Folder listing succeeded: 2 visible entries.")
    }
}
