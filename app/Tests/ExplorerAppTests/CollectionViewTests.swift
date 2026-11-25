import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// FR-VIEW-001/008/010, UI-VIEW-004 / EV-0306/0307, EV-0318–0329 /
/// AT-VIEW-008/010, AT-UIVIEW-004. Native policy tests, not visual-equivalence claims.
@Suite(.serialized)
@MainActor
final class CollectionViewTests {
    @Test
    func emptyCollectionReceivesPendingTableFocusAfterReplacementLayout() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-empty-collection-\(UUID().uuidString)", isDirectory: true)
        let store = ExplorerStore(initialURL: root, loader: CollectionEmptySnapshotLoader(), homeURL: root)
        try await waitUntil { !store.activeTab.isLoading }
        store.setViewMode(.largeIcons)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let oldTable = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        oldTable.focusCoordinator = store.focus
        window.contentView?.addSubview(oldTable)
        store.focus.register(.list, owner: oldTable) { [weak oldTable] in
            guard let oldTable else { return false }
            return oldTable.window?.makeFirstResponder(oldTable) == true
        }
        #expect(window.makeFirstResponder(oldTable))
        store.focus.prepareContentReplacementFocus()

        let coordinator = FileCollectionView.Coordinator(store: store)
        let scroll = coordinator.makeScrollView()
        let view = try #require(coordinator.collection)
        defer { coordinator.dismantle(); store.cancelLoads(); window.close() }
        // Match the native bridge lifecycle: attach at zero size, remove the
        // focused old content, then receive the SwiftUI container's real size.
        window.contentView?.addSubview(scroll)
        oldTable.removeFromSuperview()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(coordinator.items.isEmpty)
        #expect(view.numberOfItems(inSection: 0) == 0)
        #expect(view.bounds.width > 0)
        #expect(view.bounds.height > 0)
        #expect(window.firstResponder === view,
                "Empty collection handoff after layout: bounds \(view.bounds), responder \(String(describing: window.firstResponder))")
        // Distinguish layout/handoff failure from NSCollectionView refusing an
        // empty responder. This diagnostic must not satisfy the assertion above.
        let directlyAccepted = window.makeFirstResponder(view)
        #expect(directlyAccepted,
                "Direct empty collection focus request at bounds \(view.bounds)")
        #expect(window.firstResponder === view)
    }

    @Test
    func stackedLabelsActuallyRenderTwoLinesInsteadOfClippingAfterFirstWord() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let itemView = ExplorerCollectionItemView()
        window.contentView?.addSubview(itemView)
        let name = "color sample.png with a long filename.txt"
        let item = FileItem(url: URL(fileURLWithPath: "/synthetic/\(name)"), name: name,
                            isDirectory: false, isSymbolicLink: false, size: 24,
                            modifiedAt: nil, kind: "PNG Image")
        for mode in [FolderViewMode.extraLargeIcons, .largeIcons, .mediumIcons] {
            itemView.configure(item: item, mode: mode)
            itemView.frame = NSRect(origin: .zero, size: CollectionGeometry.metrics(for: mode).itemSize)
            itemView.layoutSubtreeIfNeeded()
            let field = itemView.nameField
            field.textColor = .black
            let font = try #require(field.font)
            let bitmap = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
            field.cacheDisplay(in: field.bounds, to: bitmap)
            var inkRows: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                let hasInk = (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.5
                        && max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.5
                }
                if hasInk { inkRows.append(y) }
            }
            let first = try #require(inkRows.first)
            let last = try #require(inkRows.last)
            let pixelsPerPoint = CGFloat(bitmap.pixelsHigh) / field.bounds.height
            let renderedInkHeight = CGFloat(last - first + 1) / pixelsPerPoint
            // A property-only check would miss the original 28pt container bug.
            // Two visible text lines must occupy more height than one font line.
            #expect(renderedInkHeight > ceil(font.ascender - font.descender))
            #expect(field.stringValue == name)
            #expect(field.frame.maxY <= itemView.bounds.maxY)
        }
    }

    @Test
    func layoutsKeepItemsWithinViewportAndListDistinctFromContent() {
        for mode in FolderViewMode.allCases where mode != .details {
            for width in [CGFloat(1), 180, 600, 1200] {
                let geometry = CollectionGeometry(count: 17, viewport: NSSize(width: width, height: 240), mode: mode)
                #expect(geometry.frames.count == 17)
                #expect(geometry.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width && $0.width > 0 })
                #expect(geometry.contentSize.height >= geometry.frames.last!.maxY)
                for index in 1..<geometry.frames.count {
                    #expect(!geometry.frames[index - 1].intersects(geometry.frames[index]))
                }
                let first = geometry.frames[0]
                #expect(geometry.indexes(intersecting: first) == [0])
            }
        }
        let list = CollectionGeometry(count: 17, viewport: NSSize(width: 600, height: 240), mode: .list)
        let content = CollectionGeometry(count: 17, viewport: NSSize(width: 600, height: 240), mode: .content)
        #expect(list.columns == 1 && content.columns == 1)
        #expect(list.itemSize.width == 240)
        #expect(content.itemSize.width > list.itemSize.width)
        #expect(list.contentSize.height > 240)
    }

    @Test
    func spatialArrowsDoNotWrapAndHandlePartialFinalRows() {
        let geometry = CollectionGeometry(count: 8, viewport: NSSize(width: 360, height: 240), mode: .largeIcons)
        #expect(geometry.columns == 3)
        #expect(geometry.neighbor(of: 0, keyCode: 123) == nil)
        #expect(geometry.neighbor(of: 2, keyCode: 124) == nil)
        #expect(geometry.neighbor(of: 1, keyCode: 125) == 4)
        #expect(geometry.neighbor(of: 5, keyCode: 125) == nil)
        #expect(geometry.neighbor(of: 7, keyCode: 126) == 4)
        #expect(geometry.neighbor(of: 7, keyCode: 124) == nil)
        let list = CollectionGeometry(count: 8, viewport: NSSize(width: 600, height: 240), mode: .list)
        #expect(list.neighbor(of: 3, keyCode: 124) == nil)
        #expect(list.neighbor(of: 3, keyCode: 125) == 4)
    }

    @Test
    func homeEndUseAuthoritativeEndpointsAndFunctionKeysDoNotTypeSelect() async throws {
        let fixture = try await makeFixture(mode: .content)
        defer { fixture.close() }
        let ids = fixture.coordinator.items.map(\.id)
        fixture.view.selectItem(at: 3, extending: false, toggling: false)
        try fixture.press(119, characters: "\u{F72B}", modifiers: .function)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids.last!])
        #expect(fixture.view.focusedItemID == ids.last && fixture.view.anchorItemID == ids.last)
        try fixture.press(115, characters: "\u{F729}", modifiers: [.function, .shift])
        #expect(fixture.store.activeTab.selection.selectedIDs == Set(ids))
        #expect(fixture.view.focusedItemID == ids.first && fixture.view.anchorItemID == ids.last)
        fixture.view.selectItem(at: 3, extending: false, toggling: false)
        try fixture.press(115, characters: "\u{F729}", modifiers: [.function, .option])
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[3]])
        #expect(fixture.view.focusedItemID == ids.first && fixture.view.anchorItemID == ids[3])
        assertAgreement(fixture)

        // A synthetic filename starting with an AppKit private-use function
        // character exposes accidental type-selection by a real F3 event.
        let specialName = "\u{F706} function sentinel.txt"
        fixture.store.tabs[0].items.append(FileItem(
            url: fixture.store.activeTab.url.appendingPathComponent(specialName), name: specialName,
            isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text Document"))
        fixture.coordinator.update()
        fixture.view.selectItem(at: 3, extending: false, toggling: false)
        let expected = fixture.store.activeTab.selection
        try fixture.press(99, characters: "\u{F706}", modifiers: .function)
        #expect(fixture.store.activeTab.selection == expected)
        try fixture.press(99, characters: "\u{F706}")
        #expect(fixture.store.activeTab.selection == expected)
        // Function-key input must not pollute the next typed prefix either.
        try fixture.press(11, characters: "b")
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[2]])
        assertAgreement(fixture)
    }

    @Test
    func pageKeysScrollWithoutChangingSelectionAndNavigationResetsScrollbar() async throws {
        let fixture = try await makeFixture(mode: .content)
        defer { fixture.close() }
        fixture.view.selectItem(at: 2, extending: false, toggling: false)
        let expected = fixture.store.activeTab.selection
        try fixture.press(121, characters: "\u{F72D}", modifiers: .function)
        try await waitUntil { fixture.scroll.contentView.bounds.minY > 0 }
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
        try fixture.press(116, characters: "\u{F72C}", modifiers: .function)
        try await waitUntil { fixture.scroll.contentView.bounds.minY == 0 }
        #expect(fixture.store.activeTab.selection == expected)
        fixture.store.tabs[0].isUnavailable = true
        try fixture.press(121, characters: "\u{F72D}", modifiers: .function)
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
        fixture.store.tabs[0].isUnavailable = false
        fixture.store.navigate(to: fixture.coordinator.items[0].url)
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.coordinator.update()
        fixture.layout()
        #expect(fixture.scroll.contentView.bounds.minY == 0)
        #expect(fixture.scroll.verticalScroller?.doubleValue == 0)
    }

    @Test
    func nativeCommandArrowBindingsKeepTheirFinalSelectionFocusAndAnchorTogether() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for (code, character) in [(UInt16(123), "\u{F702}"), (UInt16(125), "\u{F701}")] {
            fixture.view.selectItem(at: 3, extending: false, toggling: false)
            try fixture.press(code, characters: character, modifiers: [.command, .function])
            assertAgreement(fixture)
            let state = fixture.store.activeTab.selection
            if state.selectedIDs.count == 1 {
                let focusedID = try #require(state.focusedID)
                #expect(state.selectedIDs.contains(focusedID))
                #expect(state.anchorID == state.focusedID)
            }
        }
        fixture.store.tabs[0].isUnavailable = true
        let expected = fixture.store.activeTab.selection
        try fixture.press(123, characters: "\u{F702}", modifiers: [.command, .function])
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
    }

    @Test
    func selectionAccessibilityAnnouncementsFollowCommittedChangesOnly() async throws {
        var notifications: [(NSView, NSAccessibility.Notification)] = []
        let fixture = try await makeFixture(onAccessibilityNotification: { notifications.append(($0, $1)) })
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        #expect(notifications.count == 1)
        #expect(notifications[0].0 === fixture.view)
        #expect(notifications[0].1 == .selectedChildrenChanged)
        fixture.coordinator.update()
        try fixture.press(124, modifiers: .option)
        #expect(notifications.count == 1)
        fixture.store.tabs[0].isUnavailable = true
        try rejectInputs(fixture, expected: fixture.store.activeTab.selection)
        #expect(notifications.count == 1)
        fixture.store.tabs[0].isUnavailable = false
        fixture.view.selectItem(at: 3, extending: false, toggling: false)
        #expect(notifications.count == 2)
        let id = fixture.coordinator.items[0].id
        fixture.store.setSelection([id], focusedID: id, anchorID: id)
        fixture.coordinator.update()
        #expect(notifications.count == 3)
        #expect(notifications.allSatisfy { $0.0 === fixture.view && $0.1 == .selectedChildrenChanged })
    }

    @Test
    func pointerKeyboardRangeAndFocusUseTheSameSelectionAuthority() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let ids = fixture.coordinator.items.map(\.id)
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        fixture.view.selectItem(at: 3, extending: true, toggling: false)
        #expect(fixture.store.activeTab.selection.selectedIDs == Set(ids[1...3]))
        fixture.view.selectItem(at: 2, extending: false, toggling: true)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[1], ids[3]])
        assertAgreement(fixture)

        fixture.view.selectItem(at: 0, extending: false, toggling: false)
        try fixture.press(124, modifiers: .option)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[0]])
        #expect(fixture.view.focusedItemID == ids[1])
        #expect(fixture.view.anchorItemID == ids[0])
        try fixture.press(49, characters: " ")
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[0], ids[1]])
        try fixture.press(0, characters: "a", modifiers: .command)
        #expect(fixture.store.activeTab.selection.selectedIDs == Set(ids))
        #expect(fixture.view.focusedItemID == ids[1] && fixture.view.anchorItemID == ids[0])
        assertAgreement(fixture)

        fixture.view.typeSelect("b", at: 2)
        fixture.view.typeSelect("r", at: 2.1)
        #expect(fixture.store.activeTab.selection.selectedIDs == [ids[2]])
        assertAgreement(fixture)
    }

    @Test
    func unavailableAndEditingStatesImmediatelyRejectKeyboardAndNativeSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        let expected = fixture.store.activeTab.selection
        fixture.store.tabs[0].isUnavailable = true
        try rejectInputs(fixture, expected: expected)
        fixture.store.tabs[0].isUnavailable = false
        fixture.store.beginRename()
        try #require(fixture.store.nameEdit != nil)
        // Exercise the native event refusal without mounting the text editor.
        try rejectInputs(fixture, expected: expected)
        fixture.store.cancelNameEdit()
    }

    @Test
    func layoutChangePreservesIdentityAndDoesNotTakeAddressFocus() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 3, extending: false, toggling: false)
        let expected = fixture.store.activeTab.selection
        let address = NSTextField(string: "An address draft")
        address.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        fixture.window.contentView?.addSubview(address)
        #expect(fixture.window.makeFirstResponder(address))
        let editor = try #require(address.currentEditor())
        fixture.store.setViewMode(.tiles)
        fixture.coordinator.update()
        fixture.layout()
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
        #expect(fixture.window.firstResponder === editor)
        #expect(editor.string == "An address draft")
    }

    @Test
    func returnNavigatesFolderAndContextClickSelectsBeforeBuildingMenu() async throws {
        let fixture = try await makeFixture(mode: .smallIcons)
        defer { fixture.close() }
        fixture.view.selectItem(at: 0, extending: false, toggling: false)
        let folder = fixture.coordinator.items[0].url
        try fixture.press(36)
        try await waitUntil { !fixture.store.activeTab.isLoading }
        #expect(fixture.store.activeTab.url == folder)
        #expect(fixture.store.activeTab.viewMode == .smallIcons)
        fixture.coordinator.update()
        fixture.layout()
        let path = IndexPath(item: 2, section: 0)
        let rect = try #require(fixture.view.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame)
        let point = fixture.view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(fixture.view.menu(for: event) != nil)
        #expect(fixture.store.activeTab.selection.selectedIDs == [fixture.coordinator.items[2].id])
        assertAgreement(fixture)
    }

    @Test
    func renameKeepsCurrentLayoutCaretAndSessionAndEscapeCancels() async throws {
        let fixture = try await makeFixture(mode: .tiles)
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        try fixture.press(120)
        let session = try #require(fixture.store.nameEdit)
        fixture.coordinator.update()
        let field = try await fixture.editor(for: session.rowID)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == session.initialSelection)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "Alpha")
        editor.string = "Alpha revised.txt"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        field.onProposalChange?(editor.string)
        fixture.coordinator.update()
        #expect(field.currentEditor() === editor)
        #expect(editor.string == "Alpha revised.txt" && editor.selectedRange().location == 5)
        #expect(fixture.store.activeTab.viewMode == .tiles)
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        fixture.coordinator.update()
        #expect(fixture.store.nameEdit == nil)
        #expect(fixture.window.firstResponder === fixture.view)
        #expect(await fixture.operations.requestCount == 0)
    }

    @Test
    func offscreenNewFolderMountsFromDisplayAndOldCallbackCannotCancelReplacement() async throws {
        let fixture = try await makeFixture(mode: .content)
        defer { fixture.close() }
        fixture.store.beginCreateFolder()
        let first = try #require(fixture.store.nameEdit)
        fixture.coordinator.update()
        let field = try await fixture.editor(for: first.rowID)
        let oldCancel = field.onCancel
        #expect(field.currentEditor() != nil)
        #expect(fixture.store.activeTab.viewMode == .content)
        #expect(fixture.coordinator.items.last?.id == first.rowID)
        #expect(await fixture.operations.requestCount == 0)
        fixture.store.cancelNameEdit()
        fixture.coordinator.update()
        fixture.store.beginCreateFolder()
        let replacement = try #require(fixture.store.nameEdit)
        fixture.coordinator.update()
        oldCancel?()
        #expect(fixture.store.nameEdit?.id == replacement.id)
        _ = try await fixture.editor(for: replacement.rowID)
        #expect(await fixture.operations.requestCount == 0)
    }

    @Test
    func returnSubmitsOnceReturnsFocusAndFailureKeepsEditableDraft() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        fixture.store.beginRename()
        let session = try #require(fixture.store.nameEdit)
        fixture.coordinator.update()
        let field = try await fixture.editor(for: session.rowID)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Collision.txt"
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        fixture.coordinator.update()
        #expect(field.isSubmitting)
        #expect(fixture.window.firstResponder === fixture.view)
        let expected = fixture.store.activeTab.selection
        try rejectInputs(fixture, expected: expected)
        try await waitUntil { !fixture.store.isPerformingOperation }
        fixture.coordinator.update()
        #expect(await fixture.operations.requestCount == 1)
        #expect(fixture.store.nameEdit?.id == session.id)
        #expect(fixture.store.nameEdit?.proposedName == "Collision.txt")
        #expect(fixture.store.nameEdit?.errorMessage != nil)
        #expect(field.isEditable && !field.isSubmitting)
    }

    @Test
    func nativeCommandsRequireFileFocusAndTextUndoKeepsItsOwnTitle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        let copy = NSMenuItem(title: "Copy", action: #selector(ExplorerFileCollectionView.copy(_:)), keyEquivalent: "c")
        #expect(fixture.view.validateUserInterfaceItem(copy))
        fixture.view.copy(copy)
        let payload = try #require(fixture.store.clipboard.payload)
        #expect(payload.kind == .copy)
        #expect(payload.items.map(\.id) == [fixture.coordinator.items[1].id])
        let field = NameEditorTextField()
        field.frame = NSRect(x: 10, y: 10, width: 260, height: 24)
        fixture.window.contentView?.addSubview(field)
        defer { field.finishSession() }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!fixture.view.validateUserInterfaceItem(copy))
        fixture.view.cut(nil)
        fixture.view.moveToTrash(nil)
        #expect(fixture.store.clipboard.payload?.id == payload.id)
        #expect(!fixture.store.isPerformingOperation)
        #expect(await fixture.operations.requestCount == 0)
        for action in [#selector(ExplorerFileCollectionView.copy(_:)), #selector(ExplorerFileCollectionView.paste(_:))] {
            #expect((NSApp.target(forAction: action, to: editor, from: nil) as AnyObject?) === editor)
        }
        let manager = try #require(editor.undoManager)
        editor.allowsUndo = true
        manager.removeAllActions()
        manager.beginUndoGrouping()
        editor.insertText("Edited", replacementRange: NSRange(location: 0, length: 8))
        manager.endUndoGrouping()
        let undo = NSMenuItem(title: "Undo Rename", action: #selector(ExplorerFileCollectionView.undo(_:)), keyEquivalent: "z")
        #expect(fixture.view.validateUserInterfaceItem(undo))
        #expect(undo.title == manager.undoMenuItemTitle && undo.title != "Undo Rename")
        fixture.view.undo(undo)
        #expect(editor.string == "Original.txt")
        #expect(fixture.store.clipboard.payload?.id == payload.id)
    }

    @Test(arguments: [false, true])
    func staleExplicitClipboardTargetsRequireFileFocus(textEditing: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.view.selectItem(at: 1, extending: false, toggling: false)
        fixture.view.copy(nil)
        let original = try #require(fixture.store.clipboard.payload)
        try #require(fixture.store.canCopySelection && fixture.store.canCutSelection && fixture.store.canPaste)
        let field = NameEditorTextField()
        field.frame = NSRect(x: 10, y: 10, width: 260, height: 24)
        fixture.window.contentView?.addSubview(field)
        defer { field.finishSession() }
        if textEditing {
            field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(fixture.window.firstResponder === editor)
        } else {
            try #require(fixture.window.makeFirstResponder(nil))
        }
        try #require(fixture.window.firstResponder !== fixture.view)
        for selector in [#selector(ExplorerFileCollectionView.copy(_:)),
                         #selector(ExplorerFileCollectionView.cut(_:)),
                         #selector(ExplorerFileCollectionView.paste(_:))] {
            let item = NSMenuItem(title: "Clipboard action", action: selector, keyEquivalent: "")
            #expect(!fixture.view.validateUserInterfaceItem(item))
        }
        fixture.view.copy(nil)
        fixture.view.cut(nil)
        fixture.view.paste(nil)
        #expect(fixture.store.clipboard.payload?.id == original.id)
        #expect(!fixture.store.isPerformingOperation)
        #expect(await fixture.operations.requestCount == 0)
    }

    private func rejectInputs(_ fixture: CollectionFixture, expected: SelectionState) throws {
        for (code, chars, modifiers) in [(UInt16(124), "", NSEvent.ModifierFlags()),
                                       (UInt16(125), "", .option), (UInt16(49), " ", []),
                                       (UInt16(0), "a", .command),
                                       (UInt16(115), "\u{F729}", .function),
                                       (UInt16(119), "\u{F72B}", [.function, .shift]),
                                       (UInt16(119), "\u{F72B}", [.function, .option])] {
            try fixture.press(code, characters: chars, modifiers: modifiers)
            #expect(fixture.store.activeTab.selection == expected)
            assertAgreement(fixture)
        }
        fixture.view.selectionIndexPaths = [IndexPath(item: 3, section: 0)]
        #expect(fixture.store.activeTab.selection == expected)
        assertAgreement(fixture)
    }

    private func assertAgreement(_ fixture: CollectionFixture) {
        let state = fixture.store.activeTab.selection
        let nativeIDs = Set(fixture.view.selectionIndexPaths.map { fixture.coordinator.items[$0.item].id })
        #expect(nativeIDs == state.selectedIDs)
        #expect(fixture.view.focusedItemID == state.focusedID)
        #expect(fixture.view.anchorItemID == state.anchorID)
    }

    private func makeFixture(mode: FolderViewMode = .largeIcons,
                             onAccessibilityNotification: ((NSView, NSAccessibility.Notification) -> Void)? = nil) async throws -> CollectionFixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-collection-model-\(UUID().uuidString)", isDirectory: true)
        let board = NSPasteboard(name: NSPasteboard.Name("collection-tests-\(UUID().uuidString)"))
        let operations = CollectionRefusingOperations()
        let store = ExplorerStore(initialURL: root, loader: CollectionSnapshotLoader(), homeURL: root,
                                  operations: operations, clipboard: TransferClipboard(pasteboard: board), recovery: operations)
        try await waitUntil { !store.activeTab.isLoading }
        store.setViewMode(mode)
        return CollectionFixture(store: store, operations: operations, pasteboard: board,
                                 onAccessibilityNotification: onAccessibilityNotification)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor
private final class CollectionFixture {
    let store: ExplorerStore
    let operations: CollectionRefusingOperations
    let pasteboard: NSPasteboard
    let window: CollectionUndoWindow
    let coordinator: FileCollectionView.Coordinator
    let scroll: ExplorerCollectionScrollView
    var view: ExplorerFileCollectionView { scroll.documentView as! ExplorerFileCollectionView }

    init(store: ExplorerStore, operations: CollectionRefusingOperations, pasteboard: NSPasteboard,
         onAccessibilityNotification: ((NSView, NSAccessibility.Notification) -> Void)? = nil) {
        self.store = store
        self.operations = operations
        self.pasteboard = pasteboard
        window = CollectionUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let onAccessibilityNotification {
            coordinator = FileCollectionView.Coordinator(store: store,
                postAccessibilityNotification: onAccessibilityNotification)
        } else {
            coordinator = FileCollectionView.Coordinator(store: store)
        }
        scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        window.contentView = scroll
        layout()
        #expect(window.makeFirstResponder(view))
    }

    func layout() {
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func editor(for id: String) async throws -> NameEditorTextField {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            layout()
            if let index = coordinator.items.firstIndex(where: { $0.id == id }),
               let cell = view.item(at: IndexPath(item: index, section: 0)) as? ExplorerCollectionItem,
               cell.itemView.nameField.sessionID != nil {
                return cell.itemView.nameField
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CollectionFixtureError.missingEditor
    }

    func press(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        view.keyDown(with: event)
    }

    func close() {
        store.cancelNameEdit()
        coordinator.dismantle()
        store.cancelLoads()
        window.close()
        pasteboard.releaseGlobally()
    }
}

private enum CollectionFixtureError: Error { case missingEditor }
@MainActor
private final class CollectionUndoWindow: NSWindow {
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }
}

private struct CollectionSnapshotLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let names = ["Folder", "Alpha.txt", "Bravo.txt", "Charlie.txt"] + (1...20).map { "Z\($0).txt" }
        let items = names.enumerated().map { index, name in
            FileItem(url: url.appendingPathComponent(name), name: name, isDirectory: index == 0,
                     isSymbolicLink: false, size: index == 0 ? nil : 24, modifiedAt: nil,
                     kind: index == 0 ? "Folder" : "Text Document",
                     identity: LocalFileIdentity(device: 1, inode: UInt64(index + 101), birthSeconds: 1, birthNanoseconds: 0))
        }
        return DirectorySnapshot(items: items,
            directoryIdentity: LocalFileIdentity(device: 1, inode: 100, birthSeconds: 1, birthNanoseconds: 0))
    }
}

private struct CollectionEmptySnapshotLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        DirectorySnapshot(items: [],
            directoryIdentity: LocalFileIdentity(device: 1, inode: 100, birthSeconds: 1, birthNanoseconds: 0))
    }
}

private actor CollectionRefusingOperations: FileOperating, FileRecovering {
    private(set) var requestCount = 0
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        requestCount += 1
        throw FileOperationError.collision(name)
    }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        requestCount += 1
        throw FileOperationError.collision(name)
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        requestCount += 1
        throw FileOperationError.unsupported("Synthetic test; no filesystem mutation.")
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        requestCount += 1
        throw FileOperationError.unsupported("Synthetic test; no filesystem mutation.")
    }
}
