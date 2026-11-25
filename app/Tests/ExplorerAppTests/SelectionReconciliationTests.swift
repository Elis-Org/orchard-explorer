import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// FR-SEL-001/003/009 / EV-0213/0218, EV-0421–0424 / AT-SEL-001/003/009.
/// Refusing selection while unavailable, busy, or editing is native policy.
/// These tests use native AppKit responders with fake snapshots/services only.
@Suite(.serialized)
@MainActor
final class SelectionReconciliationTests {
    @Test
    func unavailableFolderImmediatelyRestoresKeyboardAndNativeSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let expected = fixture.store.activeTab.selection
        fixture.store.tabs[0].isUnavailable = true
        try rejectedInputs(in: fixture, expected: expected)
    }

    @Test
    func busyOperationImmediatelyRestoresKeyboardAndNativeSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let expected = fixture.store.activeTab.selection
        fixture.store.trashSelection()
        #expect(fixture.store.isPerformingOperation)
        #expect(fixture.store.nameEdit == nil)
        // The fake operation runs after this synchronous native-input sequence.
        // It refuses the request without touching any filesystem path.
        try rejectedInputs(in: fixture, expected: expected)
        try await waitUntil { !fixture.store.isPerformingOperation }
    }

    @Test
    func nameEditReconcilesSelectionWithoutReplacingOrBlurringNativeEditor() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let expected = fixture.store.activeTab.selection
        fixture.store.beginRename()
        let edit = try #require(fixture.store.nameEdit)
        let field = NameEditorTextField()
        field.frame = NSRect(x: 24, y: 70, width: 250, height: 24)
        fixture.table.addSubview(field)
        defer { field.finishSession(); fixture.store.cancelNameEdit() }
        field.beginSession(id: edit.id, name: edit.proposedName, selection: edit.initialSelection)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Typed proposal.txt"
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        try rejectedInputs(in: fixture, expected: expected)
        #expect(field.currentEditor() === editor)
        #expect(fixture.window.firstResponder === editor)
        #expect(editor.string == "Typed proposal.txt")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 4))
        #expect(fixture.store.nameEdit?.id == edit.id)
    }

    @Test
    func acceptedKeyboardAndNativeSelectionKeepIndependentFocusAndAnchor() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let ids = fixture.coordinator.items.map(\.id)
        try fixture.press(keyCode: 125)
        assertAgreement(fixture)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[2]])
        #expect(fixture.table.focusedItemID == ids[2])
        #expect(fixture.table.anchorItemID == ids[2])

        try fixture.press(keyCode: 126, modifiers: .option)
        assertAgreement(fixture)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[2]])
        #expect(fixture.table.focusedItemID == ids[1])
        #expect(fixture.table.anchorItemID == ids[2])

        try fixture.press(keyCode: 49, characters: " ")
        assertAgreement(fixture)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[1], ids[2]])
        try fixture.press(keyCode: 0, characters: "a", modifiers: .command)
        assertAgreement(fixture)
        #expect(fixture.store.activeTab.selection.selectedIDs == Set(ids))
        #expect(fixture.table.focusedItemID == ids[1])
        #expect(fixture.table.anchorItemID == ids[2])

        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assertAgreement(fixture)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[0]])
        // A native AX-style row change does not invent a keyboard focus movement.
        #expect(fixture.table.focusedItemID == ids[1])
        #expect(fixture.table.anchorItemID == ids[2])
    }

    private func rejectedInputs(in fixture: SelectionFixture, expected: SelectionState) throws {
        for (keyCode, characters, modifiers) in [
            (UInt16(125), "", NSEvent.ModifierFlags()),
            (UInt16(126), "", []),
            (UInt16(125), "", .option),
            (UInt16(49), " ", []),
            (UInt16(0), "a", .command)
        ] {
            try fixture.press(keyCode: keyCode, characters: characters, modifiers: modifiers)
            #expect(fixture.store.activeTab.selection == expected)
            assertAgreement(fixture)
        }
        // NSTableView selection APIs are also used by accessibility actions and
        // notify the delegate without the explicit keyboard-intent callback.
        fixture.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
        fixture.table.deselectAll(nil)
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
    }

    private func assertAgreement(_ fixture: SelectionFixture) {
        let authoritative = fixture.store.activeTab.selection
        let expectedRows = IndexSet(fixture.coordinator.items.indices.filter {
            authoritative.selectedIDs.contains(fixture.coordinator.items[$0].id)
        })
        #expect(fixture.table.selectedRowIndexes == expectedRows)
        #expect(fixture.table.focusedItemID == authoritative.focusedID)
        #expect(fixture.table.anchorItemID == authoritative.anchorID)
        #expect(!fixture.coordinator.isUpdating)
    }

    private func makeFixture() async throws -> SelectionFixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-selection-model-\(UUID().uuidString)", isDirectory: true)
        let loader = SelectionSnapshotLoader(root: root)
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
                                  recovery: SelectionRefusingRecovery())
        try await waitUntil { !store.activeTab.isLoading }
        let items = store.sortedItems
        try #require(items.count == 3)
        store.setSelection([items[0].id], focusedID: items[1].id, anchorID: items[2].id)
        return SelectionFixture(store: store)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor
private final class SelectionFixture {
    let store: ExplorerStore
    let window: NSWindow
    let table: ExplorerTableView
    let coordinator: DetailsTableView.Coordinator

    init(store: ExplorerStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        coordinator = DetailsTableView.Coordinator(store: store)
        coordinator.items = store.sortedItems
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.itemIDs = coordinator.items.map(\.id)
        table.reloadData()
        coordinator.isUpdating = true
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.focusedItemID = store.activeTab.selection.focusedID
        table.anchorItemID = store.activeTab.selection.anchorID
        coordinator.isUpdating = false
        table.onSelectionIntent = { [weak coordinator] in coordinator?.publishSelection() }
        window.contentView?.addSubview(table)
        #expect(window.makeFirstResponder(table))
    }

    func press(keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        table.keyDown(with: event)
    }

    func close() {
        table.delegate = nil
        table.dataSource = nil
        table.onSelectionIntent = nil
        store.cancelLoads()
        window.close()
    }
}

private struct SelectionSnapshotLoader: DirectoryListing {
    let root: URL
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let items = ["A.txt", "B.txt", "C.txt"].enumerated().map { index, name in
            FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: false,
                     isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text Document",
                     identity: LocalFileIdentity(device: 1, inode: UInt64(index + 101), birthSeconds: 1, birthNanoseconds: 0))
        }
        return DirectorySnapshot(items: items,
            directoryIdentity: LocalFileIdentity(device: 1, inode: 100, birthSeconds: 1, birthNanoseconds: 0))
    }
}

private struct SelectionRefusingRecovery: FileRecovering {
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        throw FileOperationError.unsupported("Synthetic operation; no filesystem access.")
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("Synthetic operation; no filesystem access.")
    }
}
