import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct ShortcutDraftTests {
    @Test(arguments: [false, true])
    func cancellingDuringNextDiscardsLateTarget(_ teardown: Bool) async throws {
        let fixture = try await P18Fixture.make()
        defer { fixture.close() }
        let folder = try shortcutTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = try await LocalDirectoryLoader().snapshot(of: folder)
        let destination = FileOperationContext(directoryURL: folder, directoryIdentity: try #require(snapshot.directoryIdentity))
        let prepared = try await LocalAliasCreator().prepareShortcut(to: folder, in: destination)
        let aliases = DelayedShortcutTarget(prepared: prepared)
        let store = fixture.store
        store.aliasCreator = aliases
        store.runNewCommand(.shortcut)
        let draft = try #require(store.shortcutDraft)
        #expect(!draft.canAdvance && !draft.canFinish)
        store.updateShortcutTarget(folder.path, draftID: draft.id)
        store.advanceShortcutDraft()
        try await p18Wait { aliases.gate.pending == 1 }
        defer { aliases.gate.release(true) }
        #expect(store.shortcutDraft?.canFinish == false)
        #expect(!store.canCreateFolder && !store.canAcceptOpenRequest && !store.canUseAddress)
        store.beginCreateFolder()
        store.addTab()
        store.navigate(to: folder)
        #expect(store.nameEdit == nil && store.tabs.count == 1 && store.activeTab.url == fixture.root)
        store.finishShortcutDraft()
        if teardown { store.cancelLoads() }
        else { store.cancelShortcutDraft() }
        store.runNewCommand(.shortcut)
        let replacement = try #require(store.shortcutDraft)
        aliases.gate.release(true)
        // The synthetic validator deliberately returns a result despite cancellation.
        try await p18Wait { aliases.returned }
        #expect(store.shortcutDraft?.id == replacement.id)
        #expect(store.shortcutDraft?.target == nil)
        #expect(aliases.writes == 0)
    }

    @Test(arguments: [false, true])
    func suggestedAliasNameUsesDestinationFilesystemOccupancy(_ hidden: Bool) async throws {
        _ = NSApplication.shared
        let source = try shortcutTestFolder(), destination = try shortcutTestFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let leaf = hidden ? ".Hidden.txt" : "report.txt"
        let target = source.appendingPathComponent(leaf)
        try Data().write(to: target)
        let occupied = destination.appendingPathComponent(hidden ? leaf : "Report.txt")
        if hidden {
            // No displayed row and no live target, but the name is occupied.
            try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: source.appendingPathComponent("missing"))
        } else {
            try Data("occupied".utf8).write(to: occupied)
        }
        let store = ExplorerStore(initialURL: destination, homeURL: destination)
        defer { store.cancelLoads() }
        try await p18Wait { store.canCreateFolder }
        #expect(!store.activeTab.items.contains { $0.name == leaf })
        store.runNewCommand(.shortcut)
        let draft = try #require(store.shortcutDraft)
        store.updateShortcutTarget(target.path, draftID: draft.id)
        store.advanceShortcutDraft()
        try await p18Wait { store.shortcutDraft?.canFinish == true }
        let aliasesLeaf = hidden || FileManager.default.fileExists(atPath: destination.appendingPathComponent(leaf).path)
        #expect(store.shortcutDraft?.name == (aliasesLeaf ? leaf + " alias" : leaf))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [occupied.lastPathComponent])
    }

    @Test func shortcutDraftRejectsDirectAddressEditing() async throws {
        let fixture = try await P18Fixture.make()
        defer { fixture.close() }
        let store = fixture.store
        store.runNewCommand(.shortcut)
        let draft = try #require(store.shortcutDraft)
        store.requestAddressEditing()
        #expect(!store.address.isEditing)
        #expect(store.shortcutDraft?.id == draft.id)
    }

    @Test(arguments: [false, true])
    func shortcutDraftBlocksTerminalAlreadyAwaitingValidation(_ background: Bool) async throws {
        let fixture = try await P18Fixture.make()
        defer { fixture.close() }
        let store = fixture.store
        let router = P18Router()
        store.applications = router
        let folder = fixture.items[0]
        let gate = P18Gate()
        defer { gate.release(true) }
        if background {
            store.validateRoutingFolder = { _, _ in await gate.wait() }
            store.openCurrentFolderInTerminal(store.currentFolderItem)
        } else {
            store.validateRoutingTarget = { _ in await gate.wait() }
            store.openInTerminal(folder)
        }
        try await p18Wait { gate.pending == 1 }
        store.runNewCommand(.shortcut)
        _ = try #require(store.shortcutDraft)
        #expect(!store.canOpenInTerminal(folder) && !store.canOpenCurrentFolderInTerminal)
        gate.release(true)
        try await p18Wait { !router.terminals.isEmpty || store.operationNotice != nil }
        #expect(router.terminals.isEmpty)
    }

    @Test func backCollisionAndSuccessfulFinishKeepOneExactAlias() async throws {
        _ = NSApplication.shared
        let folder = try shortcutTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Document.txt")
        let existingAliasName = target.lastPathComponent + " alias"
        try Data("document".utf8).write(to: target)
        try Data("occupied".utf8).write(to: folder.appendingPathComponent(existingAliasName))
        let loader = ShortcutRefreshLoader()
        let store = ExplorerStore(initialURL: folder, loader: loader, homeURL: folder)
        defer { store.cancelLoads() }
        try await p18Wait { store.canCreateFolder }
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: nil).item(withTitle: "New")?.submenu)
        let item = try #require(menu.item(withTitle: "Shortcut"))
        menu.performActionForItem(at: menu.index(of: item))
        let draft = try #require(store.shortcutDraft)
        store.updateShortcutTarget(target.absoluteString, draftID: draft.id)
        store.advanceShortcutDraft()
        try await p18Wait { store.shortcutDraft?.canFinish == true }
        #expect(store.shortcutDraft?.name == existingAliasName + " 2")
        store.backShortcutDraft()
        #expect(store.shortcutDraft?.target == nil && store.shortcutDraft?.targetText == target.absoluteString)
        store.advanceShortcutDraft()
        try await p18Wait { store.shortcutDraft?.canFinish == true }
        store.updateShortcutName(existingAliasName, draftID: draft.id)
        store.finishShortcutDraft()
        try await p18Wait { store.shortcutDraft?.errorMessage != nil }
        #expect(store.shortcutDraft?.name == existingAliasName)
        #expect(try Data(contentsOf: folder.appendingPathComponent(existingAliasName)) == Data("occupied".utf8))
        let exactName = "My Shortcut"
        await loader.failNextSnapshot()
        store.updateShortcutName(exactName, draftID: draft.id)
        store.finishShortcutDraft()
        try await p18Wait { !store.isPerformingOperation && store.activeTab.errorMessage != nil }
        #expect(store.shortcutDraft == nil)
        store.retry()
        try await p18Wait { !store.activeTab.isLoading && store.activeTab.errorMessage == nil }
        let alias = folder.appendingPathComponent(exactName)
        #expect(try URL(resolvingAliasFileAt: alias).resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [target.lastPathComponent, existingAliasName, exactName])
    }
}

private func shortcutTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MaxplorerShortcut-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

@MainActor private final class DelayedShortcutTarget: AliasCreating {
    let gate = P18Gate()
    let prepared: ShortcutPreparation
    private(set) var returned = false
    private(set) var writes = 0

    init(prepared: ShortcutPreparation) { self.prepared = prepared }

    func makeAliases(for items: [FileItem], in context: FileOperationContext) async throws -> [FileOperationResult] { [] }

    func prepareShortcut(to url: URL, in destination: FileOperationContext) async throws -> ShortcutPreparation {
        _ = await gate.wait()
        returned = true
        return prepared
    }

    func createAlias(to target: ShortcutTarget, named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        writes += 1
        throw FileOperationError.unsupported("Unexpected shortcut publication")
    }
}

private actor ShortcutRefreshLoader: DirectoryListing {
    private var shouldFail = false

    func failNextSnapshot() { shouldFail = true }

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }

    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        if shouldFail {
            shouldFail = false
            throw FileOperationError.unsupported("Synthetic refresh failure")
        }
        return try await LocalDirectoryLoader().snapshot(of: url, showHidden: showHidden)
    }
}
