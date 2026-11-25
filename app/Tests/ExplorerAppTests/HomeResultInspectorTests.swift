import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

actor HeldInspectorReads {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<TransferEntry, Error>] = [:]
    func sample() async throws -> TransferEntry {
        let id = count
        count += 1
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func finish(_ id: Int, with entry: TransferEntry) { pending.removeValue(forKey: id)?.resume(returning: entry) }
    func stop() {
        let remaining = pending
        pending.removeAll()
        for call in remaining.values { call.resume(throwing: CancellationError()) }
    }
}

@MainActor
struct HomeResultInspectorTests {
    @Test func recentSelectionProvidesDetailsAndPreviewWithoutGrantingFolderCommands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("example.txt")
        try Data("selected text".utf8).write(to: file)
        let doc = try #require(await RecentDocument.sample(file))
        let recent = RecentDocumentStore(defaults: nil)
        recent.record([doc], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder, recentDocuments: recent)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(recent: doc)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        store.setPreviewSurfaceVisible(true)
        store.toggleDetailsPane()
        try await waitFor { store.inspectorDetails.item?.name == file.lastPathComponent }
        #expect(store.inspectorDetails.item?.size == 13)
        #expect(store.selectedOperationEntries == nil)
        #expect(store.canShowProperties)
        #expect(!store.canCreateFolder && !store.canChangeOneDriveRetention)
        store.togglePreviewPane()
        try await waitFor { if case .ready = store.preview.state { true } else { false } }
        guard case .ready(let id) = store.preview.state else { return }
        let presentation = try #require(store.preview.takePresentation(id))
        guard case .text(let value, _) = presentation.content else { Issue.record("Expected text preview"); return }
        #expect(value == "selected text")
        _ = await presentation.lease.release()
    }

    @Test func aChangedRecentCannotSupplyDetailsOrPreview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("changed.txt")
        try Data("original".utf8).write(to: file)
        let doc = try #require(await RecentDocument.sample(file))
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("held.txt"))
        try Data("replacement".utf8).write(to: file)
        let recent = RecentDocumentStore(defaults: nil)
        recent.record([doc], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder, recentDocuments: recent)
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        let row = HomeResultRow(recent: doc)
        store.replaceHomeResults([row], in: scope)
        store.selectHomeResult(row, in: scope)
        store.setPreviewSurfaceVisible(true)
        store.togglePreviewPane()
        try await waitFor { if case .unavailable = store.inspectorDetails { true } else { false } }
        #expect(store.recentOpenConfirmation == nil)
        #expect(store.previewRequest?.entry == nil)
        #expect(store.preview.state == .failed(HomeInspectorDetails.unavailableMessage))
    }

    @Test func groupedSelectionsNeedOneReadOnlyForASinglePhysicalTargetAndRejectLateResults() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        let first = try await LocalDirectoryLoader.inspectorEntry(at: a)
        let second = try await LocalDirectoryLoader.inspectorEntry(at: b)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: folder)
        let held = HeldInspectorReads()
        defer { store.cancelLoads(); Task { await held.stop() } }
        store.readHomeInspectorEntry = { _ in try await held.sample() }
        store.selectHomeSection(.tags)
        let scope = try #require(store.homeResultScope)
        let aMatch = try #require(FinderTagItem(indexedURL: a, tags: ["One", "Two"], contentTypes: []))
        let bMatch = try #require(FinderTagItem(indexedURL: b, tags: ["Two"], contentTypes: []))
        let a1 = HomeResultRow(item: aMatch, group: "One"), a2 = HomeResultRow(item: aMatch, group: "Two")
        let b2 = HomeResultRow(item: bMatch, group: "Two")
        store.replaceHomeResults([a1, a2, b2], in: scope)
        for row in [a1, a2] { store.bindHomeResultIdentity(first.item.identity, for: row, in: scope) }
        store.bindHomeResultIdentity(second.item.identity, for: b2, in: scope)
        store.selectHomeResult(a1, in: scope)
        store.selectHomeResult(a2, in: scope, toggling: true)
        #expect(await held.count == 0)
        store.setPreviewSurfaceVisible(true)
        store.toggleDetailsPane()
        try await waitFor { await held.count == 1 }
        store.selectHomeResult(b2, in: scope, toggling: true)
        #expect(store.inspectorDetails == .multiple(2))
        store.togglePreviewPane()
        #expect(store.preview.state == .multiple)
        #expect(await held.count == 1)
        store.selectHomeResult(b2, in: scope)
        try await waitFor { await held.count == 2 }
        await held.finish(1, with: second)
        try await waitFor { store.inspectorDetails.item?.id == second.item.id }
        await held.finish(0, with: first)
        await Task.yield()
        #expect(store.inspectorDetails.item?.id == second.item.id)
        store.replaceHomeResults([a1, a2], in: scope)
        #expect(store.inspectorDetails == .empty)
        #expect(store.preview.state == .empty)
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let reached = await condition()
        try #require(reached)
    }
}
