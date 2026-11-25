import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct TagEditingTests {
    @Test func physicalFileFolderAndMixedSelectionOfferTagsButTheBackgroundDoesNot() async throws {
        let fixture = try await P18Fixture.make()
        defer { fixture.close() }
        let controller = FileContextMenuController(store: fixture.store)
        for items in [[fixture.items[0]], [fixture.items[1]], Array(fixture.items.prefix(2))] {
            fixture.select(items)
            let menu = controller.menu(for: items[0])
            let command = try #require(menu.item(withTitle: "Tags…"))
            #expect(command.identifier?.rawValue == "context-editTags")
            #expect(command.isEnabled)
            #expect(command.target != nil && command.action != nil)
        }
        #expect(controller.menu(for: nil).item(withTitle: "Tags…") == nil)
    }

    @Test func editorStagesMixedChoicesAndCancelDoesNotTouchEitherItem() async throws {
        let fixture = try await TagEditorFixture.make()
        defer { fixture.close() }
        let store = fixture.store
        let clicked = try #require(store.activeTab.items.first)
        let menu = FileContextMenuController(store: store)
        let commands = try #require(menu.menu(for: clicked) as? ContextCommandMenu)
        let command = try #require(commands.item(withTitle: "Tags…"))
        let action = try #require(command.action)
        #expect(NSApplication.shared.sendAction(action, to: command.target, from: command))
        try await p18Wait { store.finderTagEditor?.isLoading == false }
        let editor = try #require(store.finderTagEditor)
        #expect(editor.state(for: "Shared") == .all)
        #expect(editor.state(for: "Partial") == .some)
        #expect(editor.state(for: "New") == .none)
        editor.toggle("Partial")
        editor.toggle("Shared")
        editor.toggle("New")
        #expect(editor.state(for: "Partial") == .all)
        #expect(editor.state(for: "Shared") == .none)
        #expect(editor.state(for: "New") == .all)
        store.cancelFinderTagEditing()
        #expect(store.finderTagEditor == nil)
        #expect(try fixture.names(fixture.first) == ["Shared", "Partial"])
        #expect(try fixture.names(fixture.second) == ["Shared"])
    }

    @Test func failureNamesChangedFileAndRetryLeavesPreviouslySuccessfulFilesAlone() async throws {
        let fixture = try await TagEditorFixture.make()
        defer { fixture.close() }
        let store = fixture.store
        store.beginSelectionTagEditing()
        try await p18Wait { store.finderTagEditor?.isLoading == false }
        let editor = try #require(store.finderTagEditor)
        editor.toggle("New")
        let parked = fixture.root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: fixture.second, to: parked)
        try Data().write(to: fixture.second)
        store.applyFinderTagEdits()
        try await p18Wait { !editor.isApplying && !editor.failures.isEmpty }
        #expect(editor.failures[fixture.second] != nil)
        #expect(try fixture.names(fixture.first) == ["Shared", "Partial", "New"])
        #expect(try fixture.names(fixture.second).isEmpty)
        try fixture.setNames(["Changed after success"], at: fixture.first)
        try FileManager.default.removeItem(at: fixture.second)
        try FileManager.default.moveItem(at: parked, to: fixture.second)
        store.applyFinderTagEdits()
        try await p18Wait { store.finderTagEditor == nil }
        #expect(try fixture.names(fixture.first) == ["Changed after success"])
        #expect(try fixture.names(fixture.second) == ["Shared", "New"])
    }

    @Test func homeEditsRefuseReplacedPinAndVolumeRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tagged-pin-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let original = try await FinderTagFile.identity(at: folder)
        let store = ExplorerStore(initialURL: BrowserPage.home.url)
        defer { store.cancelLoads() }
        store.pins.pin(folder)
        let pin = try #require(store.pins.entries.first { $0.url == folder })
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("parked"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        store.performPageAction(.editTags, url: folder, folder: true, pinKey: pin.id, representedIdentity: original)
        try await p18Wait { store.finderTagEditor?.failures.count == 1 || store.operationNotice != nil }
        #expect(store.finderTagEditor?.canApply != true)
        store.cancelFinderTagEditing()
        store.navigate(to: BrowserPage.thisMac.url)
        let current = try await FinderTagFile.identity(at: folder)
        store.performPageAction(.editTags, url: folder, folder: true, representedIdentity: current)
        #expect(store.finderTagEditor == nil)
    }
}

@MainActor private struct TagEditorFixture {
    let root: URL
    let first: URL
    let second: URL
    let store: ExplorerStore

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maxplorer-edit-tags-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        let store = ExplorerStore(initialURL: root)
        let fixture = Self(root: root, first: first, second: second, store: store)
        try fixture.setNames(["Shared", "Partial"], at: first)
        try fixture.setNames(["Shared"], at: second)
        try await p18Wait { store.activeTab.hasLoaded }
        let ids = store.activeTab.items.map(\.id)
        store.setSelection(Set(ids), focusedID: ids.last, anchorID: ids.first)
        return fixture
    }

    func names(_ source: URL) throws -> Set<String> {
        Set(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    func setNames(_ names: [String], at source: URL) throws {
        var url = URL(fileURLWithPath: source.path)
        var values = URLResourceValues()
        values.tagNames = names
        try url.setResourceValues(values)
    }

    func close() {
        store.cancelLoads()
        try? FileManager.default.removeItem(at: root)
    }
}
