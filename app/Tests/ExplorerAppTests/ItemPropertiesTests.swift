import Combine
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Intentionally ignores cancellation so stale result rejection is independently tested.
private actor PropertiesReader: FileMetadataReading {
    private(set) var requests: [FileItem] = []
    private var pending: [Int: CheckedContinuation<FileMetadata, Error>] = [:]
    private var closed = false

    func metadata(for item: FileItem) async throws -> FileMetadata {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requests.count] = continuation
            requests.append(item)
        }
    }
    func finish(_ index: Int, _ value: FileMetadata) {
        pending.removeValue(forKey: index)?.resume(returning: value)
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

/// FR-PREVIEW-002 / EV-0277–0279 / AT-PREVIEW-002 metadata subset. Captured-item
/// identity, asynchronous cancellation and scoped access help are native extensions;
/// these tests do not establish Properties-window appearance or Windows allocation values.
@MainActor
final class ItemPropertiesTests {
    private let folder = URL(fileURLWithPath: "/tmp/explorer-properties-model", isDirectory: true)
    private func item(_ name: String, inode: UInt64) -> FileItem {
        FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
                 isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text Document",
                 identity: LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1))
    }
    private func metadata(size: Int64? = 24, captured: TimeInterval = 500) -> FileMetadata {
        FileMetadata(size: size, allocatedSize: 4096, createdAt: Date(timeIntervalSince1970: 100),
                     modifiedAt: Date(timeIntervalSince1970: 200), accessedAt: Date(timeIntervalSince1970: 300),
                     capturedAt: Date(timeIntervalSince1970: captured))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Properties did not reach its expected state before the bounded deadline")
    }
    private func stop(_ model: ItemPropertiesModel, _ reader: PropertiesReader) {
        model.dismiss()
        Task { await reader.shutdown() }
    }

    @Test
    func initializationAndRefreshWithoutAnItemPerformNoRead() async throws {
        let reader = PropertiesReader()
        let properties = ItemPropertiesModel(reader: reader)
        defer { stop(properties, reader) }
        properties.refresh()
        properties.showAccessHelp()
        await Task.yield()
        #expect(await reader.requests.isEmpty)
        #expect(properties.item == nil && properties.metadata == nil && !properties.isLoading)
        #expect(properties.errorMessage == nil && properties.accessIssue == nil)
    }

    @Test(arguments: [false, true])
    func showingANewerItemRejectsAnOlderSuccessOrFailure(_ oldFails: Bool) async throws {
        let reader = PropertiesReader()
        let model = ItemPropertiesModel(reader: reader)
        defer { stop(model, reader) }
        let first = item("first.txt", inode: 101), second = item("second.txt", inode: 102)
        model.show(first)
        try await waitUntil { await reader.requests.count == 1 }
        model.show(second)
        try await waitUntil { await reader.requests.count == 2 }
        #expect(model.item == second && model.isLoading && model.metadata == nil)
        await reader.finish(1, metadata(size: 88, captured: 600))
        try await waitUntil { !model.isLoading && model.metadata?.size == 88 }
        if oldFails { await reader.fail(0, CocoaError(.fileReadNoPermission)) }
        else { await reader.finish(0, metadata(size: 24)) }
        await Task.yield()
        #expect(model.item == second && model.metadata?.size == 88)
        #expect(model.metadata?.capturedAt == Date(timeIntervalSince1970: 600))
        #expect(model.errorMessage == nil && model.accessIssue == nil && !model.isLoading)
        #expect(await reader.requests == [first, second])
    }

    @Test
    func dismissClearsAllStateAndLateCompletionCannotReopenTheItem() async throws {
        let reader = PropertiesReader()
        let model = ItemPropertiesModel(reader: reader)
        defer { stop(model, reader) }
        model.show(item("pending.txt", inode: 101))
        try await waitUntil { await reader.requests.count == 1 }
        model.dismiss()
        #expect(model.item == nil && model.metadata == nil && !model.isLoading)
        await reader.finish(0, metadata())
        await Task.yield()
        #expect(model.item == nil && model.metadata == nil && !model.isLoading)
        #expect(model.errorMessage == nil && model.accessIssue == nil)
    }

    @Test
    func explicitRefreshKeepsTheCapturedItemAndFailureClearsTheOldSnapshot() async throws {
        let reader = PropertiesReader()
        let model = ItemPropertiesModel(reader: reader)
        defer { stop(model, reader) }
        let original = item("captured.txt", inode: 101)
        model.show(original)
        try await waitUntil { await reader.requests.count == 1 }
        await reader.finish(0, metadata())
        try await waitUntil { !model.isLoading && model.metadata != nil }
        #expect(model.metadata?.size == 24 && model.metadata?.allocatedSize == 4096)
        #expect(model.metadata?.createdAt == Date(timeIntervalSince1970: 100))
        #expect(model.metadata?.modifiedAt == Date(timeIntervalSince1970: 200))
        #expect(model.metadata?.accessedAt == Date(timeIntervalSince1970: 300))
        model.refresh()
        try await waitUntil { await reader.requests.count == 2 }
        #expect(await reader.requests == [original, original])
        await reader.fail(1, FileMetadataError.staleSelection)
        try await waitUntil { !model.isLoading }
        #expect(model.item == original && model.metadata == nil)
        #expect(model.errorMessage != nil && model.accessIssue == nil)
        model.refresh()
        try await waitUntil { await reader.requests.count == 3 }
        await reader.finish(2, metadata(size: nil, captured: 700))
        try await waitUntil { !model.isLoading && model.metadata != nil }
        #expect(model.metadata?.size == nil && model.metadata?.capturedAt == Date(timeIntervalSince1970: 700))
        #expect(model.errorMessage == nil && model.accessIssue == nil)
    }

    @Test(arguments: [CocoaError.Code.fileReadNoPermission, .fileWriteVolumeReadOnly])
    func accessHelpUsesOnlyTheCapturedParentAndDoesNotRetry(_ code: CocoaError.Code) async throws {
        let reader = PropertiesReader()
        let model = ItemPropertiesModel(reader: reader)
        defer { stop(model, reader) }
        let selected = item("denied.txt", inode: 101)
        var shown: [FileAccessContext] = []
        model.onShowAccessHelp = { shown.append($0) }
        model.show(selected)
        try await waitUntil { await reader.requests.count == 1 }
        await reader.fail(0, CocoaError(code))
        try await waitUntil { !model.isLoading }
        let issue = try #require(model.accessIssue)
        #expect(issue.locations == [folder] && !issue.locations.contains(selected.url))
        #expect(issue.failure == (code == .fileWriteVolumeReadOnly ? .readOnlyVolume : .permissionDenied))
        let message = model.errorMessage
        model.showAccessHelp()
        #expect(shown == [issue] && model.accessIssue == issue && model.errorMessage == message)
        #expect(model.item == selected && model.metadata == nil && !model.isLoading)
        #expect(await reader.requests.count == 1)
        model.refresh()
        try await waitUntil { await reader.requests.count == 2 }
        await reader.finish(1, metadata())
        try await waitUntil { !model.isLoading && model.metadata != nil }
        #expect(model.errorMessage == nil && model.accessIssue == nil)
        model.showAccessHelp()
        #expect(shown == [issue])
    }

    @Test
    func aPendingReadDoesNotRetainTheModelOrPublishAfterItsRelease() async throws {
        let reader = PropertiesReader()
        var model: ItemPropertiesModel? = ItemPropertiesModel(reader: reader)
        weak var released = model
        var publications = 0
        let subscription = try #require(model).objectWillChange.sink { publications += 1 }
        defer { subscription.cancel(); Task { await reader.shutdown() } }
        model?.show(item("pending.txt", inode: 101))
        try await waitUntil { await reader.requests.count == 1 }
        model = nil
        try #require(released == nil, "An in-flight metadata read must not keep the Properties model alive")
        let countAtRelease = publications
        await reader.finish(0, metadata())
        await Task.yield()
        #expect(publications == countAtRelease && released == nil)
    }
}
