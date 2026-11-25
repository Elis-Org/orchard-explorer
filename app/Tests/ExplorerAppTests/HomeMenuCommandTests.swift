import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

@MainActor
struct HomeMenuCommandTests {
    @MainActor private struct Fixture {
        let root: URL
        let store: ExplorerStore
        let rows: [HomeResultRow]
        let scope: HomeResultScope
        let router = P18Router()

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let folder = root.appendingPathComponent("Subfolder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = [root.appendingPathComponent("One.txt"), root.appendingPathComponent("Two.txt"), folder.appendingPathComponent("Three.txt")]
            for url in files { try Data(url.lastPathComponent.utf8).write(to: url) }
            let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, recentDocuments: RecentDocumentStore(defaults: nil))
            store.selectHomeSection(.tags)
            let scope = try #require(store.homeResultScope)
            let rows = try (files + [folder]).map { url in
                let types = url == folder ? ["public.directory"] : ["public.text"]
                let item = try #require(FinderTagItem(indexedURL: url, tags: ["Group"], contentTypes: types))
                return HomeResultRow(item: item, group: "Group")
            }
            store.replaceHomeResults(rows, in: scope)
            self.root = root
            self.store = store
            self.rows = rows
            self.scope = scope
            store.applications = router
        }

        func select(_ indices: [Int]) async throws {
            for (offset, index) in indices.enumerated() {
                store.selectHomeResult(rows[index], in: scope, toggling: offset > 0)
            }
            let origin = try #require(store.homeOperationOrigin)
            await store.finishHomeSelectionPreparation(for: origin)
            try #require(store.homeOperationEntries?.count == indices.count)
        }

        func close() {
            store.cancelLoads()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func archiveAndAliasesUseSharedParentAndKeepHomeSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        try await fixture.select([0, 1])
        let selection = store.activeTab.homeResults.selection.selectedIDs
        #expect(store.canCompressSelection && store.canMakeAliases && store.canShareSelection)
        #expect(store.openWithTarget == nil)
        store.compressSelection(.zip)
        try await waitFor { store.operationNotice?.contains(fixture.root.path) == true && !store.isPerformingOperation }
        let children = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        let archive = try #require(children.first { $0.pathExtension == "zip" })
        #expect(store.operationNotice?.contains(archive.lastPathComponent) == true)
        #expect(try Data(contentsOf: archive).starts(with: [0x50, 0x4b]))
        store.makeAliasesForSelection()
        try await waitFor { store.operationNotice?.contains("2 aliases") == true && !store.isPerformingOperation }
        #expect(store.operationNotice?.contains(fixture.root.path) == true)
        let after = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: [.isAliasFileKey])
        let aliases = try after.filter { try $0.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true }
        #expect(aliases.count == 2)
        #expect(store.activeTab.url == BrowserPage.home.url)
        #expect(store.activeTab.homeResults.selection.selectedIDs == selection)
        #expect(store.recentDocuments.entries.isEmpty)
        try await fixture.select([0, 2])
        #expect(!store.canCompressSelection && !store.canMakeAliases && store.canShareSelection)
        store.compressSelection(.tar)
        store.makeAliasesForSelection()
        #expect(!store.isPerformingOperation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == after.count)
    }

    @Test func verifiedFolderOpensInTerminalAndVerifiedFileOpensWithChosenApplication() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        try await fixture.select([3])
        let folder = try #require(store.homeOperationEntries?.first?.item)
        #expect(!store.canShareSelection && store.openWithTarget == nil)
        try #require(store.canOpenInTerminal(folder))
        store.openInTerminal(folder)
        try await waitFor { fixture.router.terminals == [folder.url] }
        try await fixture.select([0])
        let file = try #require(store.openWithTarget)
        #expect(!store.canOpenInTerminal(folder) && store.canShareSelection)
        fixture.router.chosen = .init(applicationURL: fixture.router.choices[0].url, scope: .file)
        store.chooseApplicationAndOpen(file)
        try await waitFor { fixture.router.opens.count == 1 && store.recentDocuments.entries.count == 1 }
        #expect(fixture.router.chooserAllowsAssociation == [true])
        #expect(fixture.router.associations.map(\.file) == [file.url])
        #expect(fixture.router.opens.first?.0 == [file.url])
    }

    @Test func returningToSameHomeRowDuringPickerCannotAuthorizeAssociation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.select([0])
        let store = fixture.store
        let file = try #require(store.openWithTarget)
        fixture.router.chosen = .init(applicationURL: fixture.router.choices[0].url, scope: .file)
        fixture.router.onChoose = {
            store.selectHomeResult(fixture.rows[1], in: fixture.scope)
            store.selectHomeResult(fixture.rows[0], in: fixture.scope)
        }
        defer { fixture.router.onChoose = nil }
        store.chooseApplicationAndOpen(file)
        try await waitFor { store.operationNotice != nil }
        #expect(fixture.router.associations.isEmpty && fixture.router.opens.isEmpty)
    }

    @Test func replacementDuringDefaultChangeDoesNotOpenOrEnterHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.select([0])
        let store = fixture.store
        let file = try #require(store.openWithTarget)
        let gate = P18Gate()
        defer { gate.release(false) }
        fixture.router.associationGate = gate
        fixture.router.chosen = .init(applicationURL: fixture.router.choices[0].url, scope: .file)
        store.chooseApplicationAndOpen(file)
        try await waitFor { gate.pending == 1 }
        try FileManager.default.moveItem(at: file.url, to: fixture.root.appendingPathComponent("Original.txt"))
        try Data("Different document".utf8).write(to: file.url)
        gate.release(true)
        try await waitFor { store.operationNotice?.contains("already set") == true }
        #expect(fixture.router.associations.count == 1)
        #expect(fixture.router.openAttempts.isEmpty && store.recentDocuments.entries.isEmpty)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }
}
