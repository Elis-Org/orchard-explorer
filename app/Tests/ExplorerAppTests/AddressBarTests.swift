import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// NATIVE-P11; FR-NAV-005/007/009 and UI-NAV-002; AT-NAV-005/007/009,
/// AT-UINAV-002. These are native responder/control assertions, separate from
/// desktop keyboard replay, spoken VoiceOver and Windows visual fidelity.
@Suite(.serialized)
@MainActor
final class AddressBarTests {
    @Test
    func longUnicodeDraftPreservesNonemptySelectionAcrossResizes() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.window.animationBehavior = .none
        fixture.window.makeKeyAndOrderFront(nil)
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let selection = fixture.store.activeTab.selection
        let history = fixture.store.activeTab.history
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + String(repeating: "/Draft cafe\u{301} 日本語 🗂", count: 8) + "/Leaf"
        try typeNativeAddress(draft, in: fixture, text: text)
        let unicodeSelection = (draft as NSString).range(of: "cafe\u{301} 日本語 🗂")
        try #require(unicodeSelection.location != NSNotFound)

        text.setSelectedRange(unicodeSelection)
        let widths: [CGFloat] = [260, 650, 340]
        for width in widths {
            fixture.view.frame.size.width = width
            fixture.view.needsLayout = true
            fixture.view.layoutSubtreeIfNeeded()
            #expect(text.selectedRange() == unicodeSelection)
            #expect(fixture.view.editor.currentEditor() === text && fixture.window.firstResponder === text)
            #expect(text.string == draft && fixture.store.address.text == draft)
            try await expectSingleAddressLineAndVisibleSelection(fixture, text: text, selection: unicodeSelection)
            #expect(fixture.store.activeTab.selection == selection && fixture.store.activeTab.history == history)
        }

        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(fixture.view.editor.stringValue == fixture.root.path)
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.activeTab.selection == selection && fixture.store.activeTab.history == history)
    }

    @Test
    func longEndCaretRemainsVisibleAcrossWindowResizesWithoutAssistance() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.view.autoresizingMask = [.width]
        fixture.window.setContentSize(NSSize(width: 640, height: 320))
        fixture.window.animationBehavior = .none
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + String(repeating: "/Draft cafe\u{301} 日本語 🗂", count: 12) + "/TAIL"
        try typeNativeAddress(draft, in: fixture, text: text)
        let end = NSRange(location: (draft as NSString).length, length: 0)
        try #require(text.selectedRange() == end)
        // Establish initial visibility once. Window resizing must preserve it
        // without any later test-side selection or scroll command.
        text.scrollRangeToVisible(end)
        try await expectSingleAddressLineAndVisibleSelection(fixture, text: text, requiresOverflow: true)
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        for width in [CGFloat(1200), 640, 900, 640] {
            fixture.window.setContentSize(NSSize(width: width, height: 320))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            #expect(fixture.window.contentView?.bounds.width == width)
            #expect(fixture.view.frame.width == width - 50)
            #expect(text.string == draft && fixture.store.address.text == draft)
            #expect(text.selectedRange() == end)
            #expect(fixture.view.editor.currentEditor() === text && fixture.window.firstResponder === text)
            try await expectSingleAddressLineAndVisibleSelection(fixture, text: text, requiresOverflow: true)
            #expect(fixture.store.activeTab.history == history && fixture.store.activeTab.selection == selection)
        }
    }

    @Test
    func windowResizePreservesNativeMarkedTextAndStoredDraft() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.view.autoresizingMask = [.width]
        fixture.window.setContentSize(NSSize(width: 640, height: 320))
        let text = try fixture.beginEditing()
        try typeNativeAddress(fixture.root.path + String(repeating: "/Draft 日本語 🗂", count: 12),
                              in: fixture, text: text)
        text.setMarkedText("仮の入力", selectedRange: NSRange(location: 1, length: 1),
                           replacementRange: text.selectedRange())
        defer { text.unmarkText() }
        // This synthetic composition seed is not an IME event replay; deliver
        // its normal native text-change notification before checking the model.
        text.didChangeText()
        try #require(text.hasMarkedText())
        let string = text.string
        let marked = text.markedRange()
        let selected = text.selectedRange()
        let storedDraft = fixture.store.address.text
        #expect(storedDraft == string)
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        for width in [CGFloat(1200), 640] {
            fixture.window.setContentSize(NSSize(width: width, height: 320))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            #expect(text.hasMarkedText() && text.markedRange() == marked)
            #expect(text.selectedRange() == selected && text.string == string)
            #expect(fixture.view.editor.currentEditor() === text && fixture.window.firstResponder === text)
            #expect(fixture.store.address.text == storedDraft && fixture.store.address.text == text.string
                    && fixture.store.address.isEditing)
            #expect(fixture.store.activeTab.history == history && fixture.store.activeTab.selection == selection)
        }
    }

    @Test
    func longCompletionShowsItsEndCaretWithoutAnExtraScroll() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.window.animationBehavior = .none
        fixture.window.makeKeyAndOrderFront(nil)
        let child = fixture.root.appendingPathComponent("Child-" + String(repeating: "Café 日本語 🗂 ", count: 4) + "Leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        fixture.view.frame.size.width = 260
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()
        let selection = fixture.store.activeTab.selection
        let history = fixture.store.activeTab.history
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + String(repeating: "/Earlier long draft 🗂", count: 8)
        try typeNativeAddress(draft, in: fixture, text: text)
        let oldEnd = NSRange(location: (draft as NSString).length, length: 0)
        text.setSelectedRange(oldEnd); text.scrollRangeToVisible(oldEnd)
        try typeNativeAddress(fixture.root.path + "/Child-", in: fixture, text: text)
        let prefixEnd = NSRange(location: (text.string as NSString).length, length: 0)
        text.setSelectedRange(prefixEnd); text.scrollRangeToVisible(prefixEnd)
        try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.suggestions == [child] }
        fixture.view.synchronize()
        fixture.store.address.moveHighlight(by: 1)
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.insertTab(_:))))

        // Inspect after native display delivery, without test-side scrolling:
        // the production replacement must reveal the newly selected end.
        #expect(text.string == child.path + "/")
        #expect(fixture.store.address.text == text.string)
        try await expectSingleAddressLineAndVisibleSelection(fixture, text: text)
        #expect(fixture.window.firstResponder === text)
        #expect(fixture.store.activeTab.selection == selection && fixture.store.activeTab.history == history)
    }

    @Test
    func longHistoryRecallNavigatesOnceAndReopensAReadableEditor() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.window.animationBehavior = .none
        fixture.window.makeKeyAndOrderFront(nil)
        let remembered = fixture.root.appendingPathComponent("History-" + String(repeating: "Café 日本語 🗂 ", count: 4) + "Leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: remembered, withIntermediateDirectories: false)
        fixture.store.address.recordSuccessfulSubmission(remembered)
        fixture.view.frame.size.width = 260
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let oldEditor = try fixture.beginEditing()
        let draft = fixture.root.path + String(repeating: "/Unsubmitted long draft 🗂", count: 8)
        try typeNativeAddress(draft, in: fixture, text: oldEditor)
        let oldEnd = NSRange(location: (draft as NSString).length, length: 0)
        oldEditor.setSelectedRange(oldEnd); oldEditor.scrollRangeToVisible(oldEnd)
        fixture.store.address.showHistory()
        fixture.view.synchronize()
        let generation = fixture.store.address.requestID
        fixture.view.activateSuggestion(index: 0, generation: generation)
        try await waitUntil { !fixture.store.activeTab.isLoading && fixture.store.activeTab.url == remembered }
        #expect(!fixture.store.address.isEditing && fixture.view.editor.currentEditor() == nil)
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.activeTab.history.backStack == [fixture.root])
        let history = fixture.store.activeTab.history
        fixture.view.activateSuggestion(index: 0, generation: generation)
        #expect(fixture.store.activeTab.history == history)

        // History activation navigates and closes the editor. Cmd-L reopens the
        // committed location; it does not insert a history choice into a draft.
        let text = try fixture.beginEditing()
        #expect(text.string == remembered.path)
        #expect(text.selectedRange() == NSRange(location: 0, length: (remembered.path as NSString).length))
        text.moveRight(nil)
        try await expectSingleAddressLineAndVisibleSelection(fixture, text: text)
        #expect(fixture.store.activeTab.history == history && fixture.window.firstResponder === text)
    }

    @Test
    func editingSelectsFullUTF16PathAndEscapeRestoresCommittedTextAndResponder() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let selection = fixture.store.activeTab.selection
        let text = try fixture.beginEditing()
        #expect(text.selectedRange() == NSRange(location: 0, length: (fixture.root.path as NSString).length))
        fixture.type(fixture.root.path + "/unsubmitted")
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!fixture.store.address.isEditing)
        #expect(fixture.view.editor.stringValue == fixture.root.path)
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(!fixture.store.activeTab.history.canGoBack)
    }

    @Test
    func repeatedAddressShortcutReplacesDraftWithCommittedPathBeforeSelectingIt() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let text = try fixture.beginEditing()
        fixture.type("/different/draft")
        fixture.store.requestAddressEditing()
        fixture.view.synchronize()
        #expect(fixture.view.editor.currentEditor() === text)
        #expect(text.string == fixture.root.path)
        #expect(text.selectedRange() == NSRange(location: 0, length: (fixture.root.path as NSString).length))
        #expect(fixture.store.address.text == fixture.root.path)
    }

    @Test
    func asynchronousSuggestionsRetainEditorInsertionPointAndFileSelection() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection
        let history = fixture.store.activeTab.history
        let text = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/Ch")
        text.setSelectedRange(NSRange(location: 3, length: 0))
        try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.suggestions.count == 2 }
        fixture.view.synchronize()
        #expect(fixture.view.editor.currentEditor() === text)
        #expect(fixture.window.firstResponder === text)
        #expect(text.selectedRange() == NSRange(location: 3, length: 0))
        #expect(fixture.store.address.highlightedIndex == nil)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(fixture.store.activeTab.history == history)
        let panel = try #require(fixture.view.suggestionPanel)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.table.acceptsFirstResponder)
    }

    @Test
    func arrowsHighlightAndTabCompletesWithSlashWithoutNavigation() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection
        let history = fixture.store.activeTab.history
        let text = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/Ch")
        try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.suggestions.count == 2 }
        fixture.view.synchronize()
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.moveDown(_:))))
        let chosen = try #require(fixture.store.address.suggestions.first)
        #expect(fixture.view.suggestionPanel?.table.selectedRow == 0)
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(text.string == chosen.path + "/")
        #expect(fixture.store.address.text == chosen.path + "/")
        #expect(text.selectedRange() == NSRange(location: (text.string as NSString).length, length: 0))
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(fixture.window.firstResponder === text)
    }

    @Test
    func enterAcceptsHighlightedFolderOnceAndRestoresPriorResponder() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let text = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/Ch")
        try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.suggestions.count == 2 }
        fixture.view.synchronize()
        fixture.store.address.moveHighlight(by: 1)
        let chosen = try #require(fixture.store.address.suggestions.first)
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitUntil { !fixture.store.activeTab.isLoading && fixture.store.activeTab.url == chosen }
        #expect(!fixture.store.address.isEditing)
        #expect(fixture.store.address.recentAddresses == [chosen])
        #expect(fixture.store.activeTab.history.backStack == [fixture.root])
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    @Test
    func markedTextAndOrdinaryTextCommandsStayInNativeFieldEditor() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let text = try fixture.beginEditing()
        for selector in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
                         #selector(NSText.selectAll(_:)), NSSelectorFromString("undo:")] {
            #expect(!fixture.view.control(fixture.view.editor, textView: text, doCommandBy: selector))
        }
        text.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)),
                         #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!fixture.view.control(fixture.view.editor, textView: text, doCommandBy: selector))
        }
        #expect(fixture.store.address.isEditing)
        #expect(fixture.store.activeTab.url == fixture.root)
        text.unmarkText()
    }

    @Test
    func nativeSuggestionSelectionUpdatesHighlightWithoutNavigationOrFocusChange() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let text = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/Ch")
        try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.suggestions.count == 2 }
        fixture.view.synchronize()
        let panel = try #require(fixture.view.suggestionPanel)
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        panel.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntil { fixture.store.address.highlightedIndex == 1 }
        #expect(fixture.window.firstResponder === text)
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
    }

    @Test
    func stalePopupCannotNavigateAfterCancellationOrReplacementResults() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.store.address.recordSuccessfulSubmission(fixture.root.appendingPathComponent("ChildOne"))
        fixture.store.address.showHistory()
        fixture.view.synchronize()
        let stale = fixture.store.address.requestID
        fixture.store.address.cancel()
        fixture.store.address.recordSuccessfulSubmission(fixture.root.appendingPathComponent("ChildTwo"))
        fixture.store.address.showHistory()
        fixture.view.synchronize()
        fixture.view.activateSuggestion(index: 0, generation: stale)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(!fixture.store.activeTab.history.canGoBack)
        #expect(fixture.store.address.presentation == .history)
    }

    @Test
    func focusLossAndLaterHistoryActivationNeverRestoreStaleResponder() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        _ = try fixture.beginEditing()
        let newDestination = AddressTestFocusView(frame: NSRect(x: 10, y: 80, width: 100, height: 20))
        fixture.window.contentView?.addSubview(newDestination)
        #expect(fixture.window.makeFirstResponder(newDestination))
        #expect(!fixture.store.address.isEditing)
        fixture.store.address.recordSuccessfulSubmission(fixture.root.appendingPathComponent("ChildOne"))
        fixture.store.address.showHistory()
        fixture.view.synchronize()
        fixture.view.activateSuggestion(index: 0, generation: fixture.store.address.requestID)
        #expect(fixture.window.firstResponder === newDestination)
    }

    @Test
    func buildingAddressCommandsLeavesCurrentSuggestionsAndNavigationAlone() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection
        let history = fixture.store.activeTab.history
        fixture.store.address.showChildren(of: fixture.root, showHidden: false)
        fixture.view.synchronize()
        let menu = fixture.view.addressContextMenu()
        #expect(menu.items.map(\.title) == ["Copy Address", "Copy Address as Text", "Edit Address", "Delete History"])
        #expect(menu.items.allSatisfy { $0.image == nil && $0.target === fixture.view && $0.action != nil })
        #expect(fixture.store.address.presentation == .children(fixture.root))
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
    }

    @Test
    func addressMenuDispatchFocusesNativeEditorAndRejectsAStaleLocation() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let menu = fixture.view.addressContextMenu()
        let edit = try #require(menu.item(withTitle: "Edit Address"))
        menu.performActionForItem(at: menu.index(of: edit))
        let text = try #require(fixture.view.editor.currentEditor() as? NSTextView)
        #expect(fixture.window.firstResponder === text)
        #expect(fixture.store.address.isEditing)
        #expect(fixture.view.handlePopupCommand(#selector(NSResponder.cancelOperation(_:))))
        fixture.store.openTab(at: fixture.root.appendingPathComponent("ChildOne", isDirectory: true))
        menu.performActionForItem(at: menu.index(of: edit))
        #expect(!fixture.store.address.isEditing, "An old address command cannot start an editor on the new tab")
    }

    @Test
    func addressHistoryAndBreadcrumbButtonsForwardSecondaryAndControlClicks() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let history = try fixture.button(named: "Recent addresses")
        let crumb = try fixture.button(named: BrowsingPresentation.title(fixture.root))
        for button in [history, crumb] {
            var received: [NSEvent.EventType] = []
            button.onContextMenu = { received.append($0.type) }
            let invocations: [(NSEvent.EventType, NSEvent.ModifierFlags)] = [
                (.rightMouseDown, []), (.leftMouseDown, .control)
            ]
            for (type, modifiers) in invocations {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                    timestamp: 1, windowNumber: fixture.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .rightMouseDown { button.rightMouseDown(with: event) }
                else { button.mouseDown(with: event) }
            }
            #expect(received == [.rightMouseDown, .leftMouseDown])
        }
        #expect(!fixture.store.address.isEditing)
        #expect(fixture.store.address.presentation == nil)
    }

    @Test(arguments: ["escape", "copy", "outside"])
    func addressContextMenuPreservesAnActiveDraft(_ dismissal: String) async throws {
        let fixture = try AddressBarFixture(simulateContextMenu: true)
        defer { fixture.close() }
        let panel = try #require(fixture.contextMenuPanel)
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + "/Draft cafe\u{301} \u{65E5}\u{672C}\u{8A9E} \u{1F5C2}"
        try typeNativeAddress(draft, in: fixture, text: text)
        fixture.store.address.dismissPopup()
        fixture.view.synchronize()
        let request = fixture.store.address.requestID
        let selection = (draft as NSString).range(of: "cafe\u{301} \u{65E5}\u{672C}\u{8A9E}")
        try #require(selection.location != NSNotFound)
        text.setSelectedRange(selection)

        let history = try fixture.button(named: "Recent addresses")
        let point = history.convert(NSPoint(x: history.bounds.midX, y: history.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 1, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        history.rightMouseDown(with: event)
        try #require(panel.isVisible)
        #expect(fixture.store.address.isEditing)
        #expect(fixture.view.editor.currentEditor() === text)
        #expect(fixture.store.address.requestID == request)

        switch dismissal {
        case "escape":
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
            #expect(panel.performKeyEquivalent(with: escape))
        case "copy":
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let content = try #require(panel.contentView)
            let copy = try #require(descendants(content).compactMap { $0 as? ContextActionButton }
                .first { $0.identifier?.rawValue == "context-address-copy-text" })
            #expect(copy.accessibilityPerformPress())
            #expect(fixture.pasteboard.string(forType: .string) == fixture.root.path)
        default:
            // Simulate a panel losing key. The address click monitor separately
            // decides whether a real click stays inside the address field.
            panel.resignContextMenuKey()
            try await waitUntil { !panel.isVisible }
        }
        #expect(!panel.isVisible)
        #expect(fixture.store.address.isEditing)
        #expect(fixture.view.editor.currentEditor() === text && fixture.window.firstResponder === text)
        #expect(text.string == draft && fixture.store.address.text == draft)
        #expect(text.selectedRange() == selection)
        #expect(fixture.store.address.requestID == request)
    }

    @Test(arguments: ["panel-first", "application-first", "normal-cancel-first"])
    func addressDraftCancellationSurvivesApplicationDeactivationOrder(_ order: String) async throws {
        let fixture = try AddressBarFixture(simulateContextMenu: true)
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        let item = try #require(fixture.store.activeTab.items.first)
        fixture.store.setSelection([item.id], focusedID: item.id)
        let model = fixture.store.address
        model.recordSuccessfulSubmission(fixture.root.appendingPathComponent("ChildTwo", isDirectory: true))
        let history = fixture.store.activeTab.history
        let recent = model.recentAddresses
        let selection = fixture.store.currentSelection
        let tab = fixture.store.activeTabID
        let text = try fixture.beginEditing()
        let draft = fixture.root.appendingPathComponent("ChildOne", isDirectory: true).path
        try typeNativeAddress(draft, in: fixture, text: text)

        let panel = try #require(fixture.contextMenuPanel)
        if order == "normal-cancel-first" {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
            try #require(!model.isEditing && fixture.view.editor.isHidden)
            #expect(fixture.view.editor.currentEditor() == nil && model.presentation == nil)
        } else {
            let button = try fixture.button(named: "Recent addresses")
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: 1, windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            button.rightMouseDown(with: click)
            try #require(panel.isVisible)
            if order == "panel-first" {
                panel.resignContextMenuKey()
                try await waitUntil { !panel.isVisible }
                try #require(model.isEditing && model.text == draft)
            }
        }

        let requestBeforeDeactivation = model.requestID
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        #expect(!model.isEditing)
        #expect(fixture.view.editor.isHidden && fixture.view.editor.currentEditor() == nil)
        #expect(model.presentation == nil && !panel.isVisible)
        #expect(fixture.store.activeTabID == tab && fixture.store.activeTab.history == history)
        #expect(fixture.store.currentSelection == selection && model.recentAddresses == recent)
        if order == "normal-cancel-first" {
            #expect(model.requestID == requestBeforeDeactivation)
        }
        let canceledRequest = model.requestID
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        #expect(model.requestID == canceledRequest)
    }

    @Test
    func breadcrumbOverflowThresholdsRetainRootAndFullUnicodeURLs() {
        let url = URL(fileURLWithPath: "/one/two/Café 🗂/four/five/six", isDirectory: true)
        let crumbs = NativeAddressBar.breadcrumbURLs(for: url)
        #expect(crumbs.first?.path == "/")
        #expect(crumbs.last == url)
        #expect(crumbs.contains { $0.lastPathComponent == "Café 🗂" })
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 560) == 5)
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 559) == 3)
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 350) == 3)
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 349) == 1)
    }

    @Test
    func teardownsCancelQueriesAndDismissPanelsWithoutTakingOtherFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        _ = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/Ch")
        try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        fixture.view.synchronize()
        #expect(fixture.view.suggestionPanel != nil)
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        fixture.view.tearDown()
        #expect(fixture.view.suggestionPanel == nil)
        #expect(fixture.store.address.presentation == nil)
        #expect(!fixture.store.address.isEditing)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    @Test
    func pencilControlAndEscapeReturnToContentResponder() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let button = try fixture.button(named: "Edit address")
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        let text = try #require(fixture.view.editor.currentEditor() as? NSTextView)
        fixture.type(fixture.root.path + "/draft")
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.view.editor.stringValue == fixture.root.path)
    }

    @Test
    func childrenPopupControlKeepsContentFocusAndFirstRowEventNavigatesOnce() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        // The CLI replay completes with an ordered parent and direct button
        // actions. Actual desktop evidence separately covers physical clicks.
        fixture.window.orderFront(nil)
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let dropdown = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        #expect(NSApp.sendAction(try #require(dropdown.action), to: dropdown.target, from: dropdown))
        try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        fixture.view.synchronize()
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.view.handlePopupCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(!fixture.store.activeTab.history.canGoBack, "Enter without a highlighted choice cannot activate the content list")
        let firstPanel = try #require(fixture.view.suggestionPanel)
        #expect(fixture.view.handlePopupCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.view.suggestionPanel == nil)
        #expect(firstPanel.parent == nil)
        #expect(NSApp.sendAction(try #require(dropdown.action), to: dropdown.target, from: dropdown))
        try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        fixture.view.synchronize()
        let panel = try #require(fixture.view.suggestionPanel)
        let chosen = try #require(fixture.store.address.suggestions.first)
        let rect = panel.table.rect(ofRow: 0)
        let point = panel.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(panel.table.acceptsFirstMouse(for: click))
        panel.table.mouseDown(with: click)
        try await waitUntil { !fixture.store.activeTab.isLoading && fixture.store.activeTab.url == chosen }
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.activeTab.history.backStack == [fixture.root])
        #expect(fixture.store.address.recentAddresses.isEmpty, "A breadcrumb child is not an address-entry recent")
    }

    @Test
    func hiddenAddressRequestFocusesOnReattachmentAndStoreCancellationReturnsToContent() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.window.orderFront(nil)
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        fixture.view.removeFromSuperview()
        // The old view's deferred teardown must not cancel this newer request.
        fixture.store.requestAddressEditing()
        let replacement = NativeAddressBar(store: fixture.store)
        replacement.frame = NSRect(x: 10, y: 260, width: 650, height: 32)
        fixture.window.contentView?.addSubview(replacement)
        replacement.layoutSubtreeIfNeeded()
        defer { replacement.tearDown() }
        try await waitUntil { replacement.editor.currentEditor() != nil }
        let text = try #require(replacement.editor.currentEditor() as? NSTextView)
        #expect(fixture.store.address.isEditing)
        #expect(fixture.window.firstResponder === text)
        #expect(text.selectedRange() == NSRange(location: 0, length: (fixture.root.path as NSString).length))
        fixture.store.address.cancel()
        replacement.synchronize()
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(replacement.editor.stringValue == fixture.root.path)
    }

    @Test
    func paddingClickRetainsDraftAndInsertionPoint() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let text = try fixture.beginEditing()
        fixture.type(fixture.root.path + "/unsubmitted")
        let selection = NSRange(location: 4, length: 0)
        text.setSelectedRange(selection)
        let focusRequest = fixture.store.addressFocusRequest
        let point = fixture.view.convert(NSPoint(x: 40, y: 1), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        fixture.view.mouseDown(with: click)
        #expect(text.string == fixture.root.path + "/unsubmitted")
        #expect(fixture.store.address.text == text.string)
        #expect(text.selectedRange() == selection)
        #expect(fixture.store.addressFocusRequest == focusRequest)
        #expect(fixture.window.firstResponder === text)
    }

    @Test
    func trailingChevronFollowsCommittedChildAvailabilityAcrossRefreshes() async throws {
        let loader = AddressBarChangingLoader()
        let fixture = try AddressBarFixture(loader: loader)
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let label = "Subfolders of \(fixture.root.lastPathComponent)"
        #expect(fixture.findButton(named: label) == nil, "Empty folders have no trailing chevron")
        #expect(fixture.findButton(named: "Subfolders of \(fixture.root.deletingLastPathComponent().lastPathComponent)") != nil,
                "The visible ancestor still contains the current route")
        for hasChild in [false, true, false] {
            await loader.setHasChild(hasChild)
            fixture.store.refresh()
            try await waitUntil { !fixture.store.activeTab.isLoading && !fixture.store.activeTab.isRefreshing }
            fixture.view.synchronize()
            #expect((fixture.findButton(named: label) != nil) == hasChild,
                    "A successful same-location snapshot adds/removes the current chevron")
            #expect(fixture.store.activeTab.url == fixture.root)
            #expect(!fixture.store.activeTab.history.canGoBack)
        }
    }

    // HV-OBS-001: the supplied Windows frames show one breadcrumb boundary with
    // separate label/arrow emphasis. These native integration checks cover state,
    // actions and lifecycle; physical pointer routing and visual fidelity remain
    // separate Mac UI acceptance work.
    @Test
    func breadcrumbLabelAndDisclosureShareOnlyTheirSegment() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let disclosure = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        let segment = try #require(label.superview)
        #expect(disclosure.superview === segment)
        let buttons = segment.subviews.compactMap { $0 as? AddressActionButton }
        #expect(buttons.count == 2, "A breadcrumb boundary must not include neighboring segments or overflow")
        #expect(buttons.contains { $0 === label })
        #expect(buttons.contains { $0 === disclosure })
        #expect(label.representedURL == fixture.root)
        #expect(disclosure.representedURL == fixture.root)
        #expect(label.action != disclosure.action, "The label navigates; the arrow presents children")
    }

    @Test
    func roomyBreadcrumbLayoutKeepsLabelPaddingWithoutAmbiguityAfterResize() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        // Opus M1: the segment and its native label must not compete at equal
        // priority for the 12pt inset. Use the actual address-bar stack so its
        // trailing spacer, neighboring segments and rebuild path participate.
        for width in [2000.pt, 2200.pt] {
            fixture.view.frame.size.width = width
            fixture.view.needsLayout = true
            fixture.view.layoutSubtreeIfNeeded()
            let label = try fixture.button(named: fixture.root.lastPathComponent)
            let segment = try #require(label.superview as? BreadcrumbSegmentView)
            let disclosure = try #require(segment.disclosureButton)
            #expect(abs(label.frame.width - (label.intrinsicContentSize.width + 12.pt)) < 0.5,
                    "A roomy breadcrumb must retain its intended horizontal label padding")
            #expect(!segment.hasAmbiguousLayout)
            #expect(!label.hasAmbiguousLayout)
            #expect(!disclosure.hasAmbiguousLayout)
        }
    }

    @Test
    func breadcrumbWithoutChildrenKeepsItsLabelInASingleSegment() async throws {
        let fixture = try AddressBarFixture(loader: AddressBarChangingLoader())
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        #expect(segment.labelButton === label)
        #expect(segment.disclosureButton == nil)
        #expect(segment.subviews.compactMap { $0 as? AddressActionButton }.count == 1)
        #expect(label.representedURL == fixture.root)
        #expect(label.action != nil && label.target != nil)
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        #expect(segment.hoveredButton === label)
        label.mouseExited(with: try fixture.hoverEvent(.mouseExited, in: label))
        #expect(segment.hoveredButton == nil)
    }

    @Test
    func breadcrumbHoverTransfersWithoutNavigationSelectionOrFocusChanges() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let disclosure = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        #expect(label.isPointerInside)
        #expect(segment.hoveredButton === label)
        disclosure.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: disclosure))
        #expect(disclosure.isPointerInside)
        #expect(segment.hoveredButton === disclosure)
        // A queued exit from the former part must not clear its new neighbor.
        label.mouseExited(with: try fixture.hoverEvent(.mouseExited, in: label))
        #expect(!label.isPointerInside)
        #expect(segment.hoveredButton === disclosure)
        disclosure.mouseExited(with: try fixture.hoverEvent(.mouseExited, in: disclosure))
        #expect(!disclosure.isPointerInside)
        #expect(segment.hoveredButton == nil)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(fixture.store.address.presentation == nil)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    // MAC-HOVER-DEF-003 recovery boundary: a delivered move must reconcile
    // current pointer geometry even if the corresponding entry was missed.
    // The window supplies a controlled live-pointer read; native OS delivery
    // remains a separate actual-cursor probe, not an assertion of this test.
    @Test
    func mouseMovedRecoversStaleBreadcrumbSiblingWithoutChangingTextFocusOrNavigation() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let search = ExplorerSearchTextField(frame: NSRect(x: 150, y: 20, width: 200, height: 24))
        fixture.window.contentView?.addSubview(search)
        #expect(fixture.window.makeFirstResponder(search))
        let text = try #require(search.currentEditor() as? NSTextView)
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let arrow = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        _ = try fixture.customTrackingArea(of: arrow)
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        try #require(label.isPointerInside && !arrow.isPointerInside && segment.hoveredButton === label)

        // No arrow entry or label exit is sent. A real mouse-move event type
        // must recover the stale sibling from the independent current pointer.
        let moved = try fixture.mouseMovedEvent(in: arrow)
        arrow.mouseMoved(with: moved)
        #expect(!label.isPointerInside)
        #expect(arrow.isPointerInside)
        #expect(segment.hoveredButton === arrow)
        #expect(fixture.window.firstResponder === text)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(fixture.store.address.presentation == nil)
        #expect(!fixture.window.acceptsMouseMovedEvents,
                "Per-control recovery must not enable window-wide mouse movement")
    }

    @Test
    func mouseMovedRecoveryUsesLivePointerInsteadOfQueuedEventCoordinates() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let arrow = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        _ = try fixture.customTrackingArea(of: arrow)
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        let queuedInside = try fixture.mouseMovedEvent(in: arrow)
        let blank = fixture.prior.convert(NSPoint(x: 20, y: 10), to: nil)
        fixture.window.pointerForHoverTesting = blank
        arrow.mouseMoved(with: queuedInside)
        #expect(!arrow.isPointerInside, "Old inside coordinates must not create hover after the pointer left")

        let queuedOutside = try fixture.mouseMovedEvent(in: arrow, point: blank)
        fixture.window.pointerForHoverTesting = arrow.convert(
            NSPoint(x: arrow.bounds.midX, y: arrow.bounds.midY), to: nil)
        arrow.mouseMoved(with: queuedOutside)
        #expect(arrow.isPointerInside, "A current inside pointer must recover despite old outside coordinates")
        #expect(!label.isPointerInside)
        #expect(segment.hoveredButton === arrow)
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.address.presentation == nil)
    }

    @Test(arguments: ["other-window", "disabled", "hidden", "hidden-ancestor", "detached"])
    func mouseMovedRecoveryCannotHoverAnIneligibleBreadcrumb(_ condition: String) async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let arrow = try fixture.button(named: "Subfolders of \(fixture.root.lastPathComponent)")
        let segment = try #require(arrow.superview as? BreadcrumbSegmentView)
        _ = try fixture.customTrackingArea(of: arrow)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let event = try fixture.mouseMovedEvent(in: arrow,
            eventWindow: condition == "other-window" ? otherWindow : nil)
        switch condition {
        case "disabled": arrow.isEnabled = false
        case "hidden": arrow.isHidden = true
        case "hidden-ancestor": segment.isHidden = true
        case "detached": fixture.view.removeFromSuperview()
        default: break
        }
        arrow.mouseMoved(with: event)
        #expect(!arrow.isPointerInside)
        #expect(segment.hoveredButton !== arrow)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.address.presentation == nil)
    }

    @Test
    func disablingBreadcrumbClearsHoverAndPreventsBothActions() async throws {
        // A real temporary-directory snapshot supplies the identity required
        // to open a draft. Mock DirectoryListing snapshots intentionally omit it.
        let fixture = try AddressBarFixture(loader: LocalDirectoryLoader())
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let ancestor = fixture.root.deletingLastPathComponent()
        let label = try fixture.button(named: ancestor.lastPathComponent)
        let disclosure = try fixture.button(named: "Subfolders of \(ancestor.lastPathComponent)")
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        #expect(segment.hoveredButton === label)
        // A new-folder draft disables the address without committing disk writes.
        fixture.store.beginCreateFolder()
        try #require(fixture.store.nameEdit != nil)
        fixture.view.synchronize()
        #expect(!fixture.store.canUseAddress)
        #expect(!label.isEnabled && !disclosure.isEnabled)
        #expect(!label.isPointerInside && !disclosure.isPointerInside)
        #expect(segment.hoveredButton == nil)
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        disclosure.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: disclosure))
        #expect(!label.isPointerInside && !disclosure.isPointerInside)
        #expect(segment.hoveredButton == nil)
        // Direct target/action dispatch also exercises the model guard, beyond
        // the native disabled-button gate that physical clicks normally use.
        #expect(NSApp.sendAction(try #require(label.action), to: label.target, from: label))
        #expect(NSApp.sendAction(try #require(disclosure.action), to: disclosure.target, from: disclosure))
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(!fixture.store.activeTab.history.canGoBack)
        #expect(fixture.store.address.presentation == nil)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    @Test
    func rebuiltAndDetachedBreadcrumbsCannotRetainOrReenterHover() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let oldLabel = try fixture.button(named: fixture.root.lastPathComponent)
        let oldSegment = try #require(oldLabel.superview as? BreadcrumbSegmentView)
        let staleEntry = try fixture.hoverEvent(.mouseEntered, in: oldLabel)
        oldLabel.mouseEntered(with: staleEntry)
        #expect(oldSegment.hoveredButton === oldLabel)
        fixture.view.frame.size.width = 340
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()
        let replacement = try fixture.button(named: fixture.root.lastPathComponent)
        let newSegment = try #require(replacement.superview as? BreadcrumbSegmentView)
        #expect(replacement !== oldLabel)
        #expect(oldLabel.window == nil)
        #expect(!oldLabel.isPointerInside && oldSegment.hoveredButton == nil)
        #expect(!replacement.isPointerInside && newSegment.hoveredButton == nil)
        oldLabel.mouseEntered(with: staleEntry)
        #expect(!oldLabel.isPointerInside && oldSegment.hoveredButton == nil)
        #expect(newSegment.hoveredButton == nil)
        replacement.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: replacement))
        #expect(newSegment.hoveredButton === replacement)
        fixture.view.removeFromSuperview()
        #expect(!replacement.isPointerInside && newSegment.hoveredButton == nil)
        #expect(fixture.store.activeTab.url == fixture.root)
    }

    @Test
    func windowResignationClearsOnlyItsOwnBreadcrumbHover() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let label = try fixture.button(named: fixture.root.lastPathComponent)
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        label.mouseEntered(with: try fixture.hoverEvent(.mouseEntered, in: label))
        #expect(segment.hoveredButton === label)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: otherWindow)
        #expect(label.isPointerInside && segment.hoveredButton === label)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(!label.isPointerInside && segment.hoveredButton == nil)
        #expect(fixture.window.firstResponder === fixture.prior)
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.address.presentation == nil)
    }

    @Test
    func groupedBreadcrumbLabelNavigatesOnceAndPreservesContentFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let ancestor = fixture.root.deletingLastPathComponent()
        let label = try fixture.button(named: ancestor.lastPathComponent)
        let segment = try #require(label.superview as? BreadcrumbSegmentView)
        #expect(segment.labelButton === label)
        #expect(segment.disclosureButton != nil)
        #expect(NSApp.sendAction(try #require(label.action), to: label.target, from: label))
        try await waitUntil { !fixture.store.activeTab.isLoading && fixture.store.activeTab.url == ancestor }
        #expect(fixture.store.activeTab.history.backStack == [fixture.root])
        #expect(fixture.store.address.presentation == nil)
        #expect(fixture.store.address.recentAddresses.isEmpty)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    // MAC-HOVER-DEF-001: NSButton also receives native/tooltip tracking events.
    // Only the app's current tracking area may change its custom hover state.
    @Test
    func foreignTrackingAreasCannotSetOrClearCustomAddressHover() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let history = fixture.store.activeTab.history
        let selection = fixture.store.activeTab.selection
        for title in [fixture.root.lastPathComponent, "Edit address", "Recent addresses"] {
            let button = try fixture.button(named: title)
            let own = try fixture.customTrackingArea(of: button)
            let foreign = NSTrackingArea(rect: button.bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                         owner: button, userInfo: nil)
            button.addTrackingArea(foreign)
            defer { button.removeTrackingArea(foreign) }
            button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: foreign))
            #expect(!button.isPointerInside, "A native/tooltip tracking area must not create custom hover")
            button.clearPointerHover()
            button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: own))
            #expect(button.isPointerInside)
            button.mouseExited(with: try fixture.trackingEvent(.mouseExited, in: button, area: foreign))
            #expect(button.isPointerInside, "An unrelated exit must not clear the app's active tracking area")
            button.mouseExited(with: try fixture.trackingEvent(.mouseExited, in: button, area: own))
            #expect(!button.isPointerInside)
        }
        #expect(fixture.store.activeTab.history == history)
        #expect(fixture.store.activeTab.selection == selection)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    @Test
    func outOfBoundsOrOtherWindowTrackingEntryCannotCreateAddressHover() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let button = try fixture.button(named: "Edit address")
        let own = try fixture.customTrackingArea(of: button)
        let outside = fixture.prior.convert(NSPoint(x: 20, y: 10), to: nil)
        button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: own, point: outside))
        #expect(!button.isPointerInside, "A delayed entry with coordinates outside the current control must not highlight it")
        button.clearPointerHover()
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: own,
                                                            eventWindow: otherWindow))
        #expect(!button.isPointerInside, "Tracking input from a different window must not affect this control")
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.address.presentation == nil)
    }

    @Test
    func replacedTrackingAreaCannotResurrectOrClearCurrentHover() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let button = try fixture.button(named: fixture.root.lastPathComponent)
        let obsolete = try fixture.customTrackingArea(of: button)
        let oldEntry = try fixture.trackingEvent(.mouseEntered, in: button, area: obsolete)
        let oldExit = try fixture.trackingEvent(.mouseExited, in: button, area: obsolete)
        button.updateTrackingAreas()
        let current = try fixture.customTrackingArea(of: button, update: false)
        #expect(current !== obsolete)
        fixture.window.pointerForHoverTesting = oldEntry.locationInWindow
        button.mouseEntered(with: oldEntry)
        #expect(!button.isPointerInside, "An entry queued before updateTrackingAreas must be ignored")
        button.clearPointerHover()
        button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: current))
        #expect(button.isPointerInside)
        button.mouseExited(with: oldExit)
        #expect(button.isPointerInside, "An obsolete exit must not clear the replacement area's hover")
        button.mouseExited(with: try fixture.trackingEvent(.mouseExited, in: button, area: current))
        #expect(!button.isPointerInside)
    }

    @Test
    func queuedCurrentAreaEventsFollowTheLivePointerInsteadOfOldCoordinates() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let button = try fixture.button(named: "Edit address")
        let area = try fixture.customTrackingArea(of: button)
        let queuedEntry = try fixture.trackingEvent(.mouseEntered, in: button, area: area)
        fixture.window.pointerForHoverTesting = fixture.prior.convert(NSPoint(x: 20, y: 10), to: nil)
        button.mouseEntered(with: queuedEntry)
        #expect(!button.isPointerInside, "An old entry must not resurrect hover after the pointer has already left")
        button.mouseEntered(with: try fixture.trackingEvent(.mouseEntered, in: button, area: area))
        #expect(button.isPointerInside)
        let queuedExit = try fixture.trackingEvent(.mouseExited, in: button, area: area)
        fixture.window.pointerForHoverTesting = queuedEntry.locationInWindow
        button.mouseExited(with: queuedExit)
        #expect(button.isPointerInside, "An old exit must not clear the control after the pointer has returned")
        button.mouseExited(with: try fixture.trackingEvent(.mouseExited, in: button, area: area))
        #expect(!button.isPointerInside)
    }

    @Test
    func customTrackingRegionNeverExtendsPastTheButtonBounds() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        for title in [fixture.root.lastPathComponent, "Subfolders of \(fixture.root.lastPathComponent)",
                      "Ancestor folders", "Edit address", "Recent addresses"] {
            let button = try fixture.button(named: title)
            let area = try fixture.customTrackingArea(of: button)
            let effectiveRect = area.options.contains(.inVisibleRect) ? button.visibleRect : area.rect
            #expect(button.bounds.intersection(effectiveRect) == effectiveRect,
                    "The button's custom hover region must not include the surrounding address bar or content")
            #expect(effectiveRect.contains(NSPoint(x: button.bounds.midX, y: button.bounds.midY)))
        }
    }

    // MAC-HOVER-DEF-002 / AT-NAV-HOVER-006: these are allocated address-bar
    // widths, not window widths. The path deliberately creates five long/mixed
    // labels at the wide breakpoint, then exercises shrinking and growing.
    @Test
    func compressedLongBreadcrumbsKeepReadableCurrentAndVisibleLabels() async throws {
        let fixture = try AddressBarFixture(relativeLocation: ["Navigation",
            "Long folder name for breadcrumb truncation", "Unicode cafe\u{301} 日本語", "Leaf"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let location = fixture.store.activeTab.url
        let widths: [CGFloat] = [650, 850, 500, 340, 650]
        for width in widths {
            fixture.view.frame.size.width = width.pt
            fixture.view.needsLayout = true
            fixture.view.layoutSubtreeIfNeeded()
            let current = try fixture.button(named: "Leaf")
            #expect(current.representedURL == location)
            #expect(current.frame.width + 0.5 >= current.intrinsicContentSize.width,
                    "The short current-folder label must remain readable at these available widths")
            let labels = fixture.addressButtons.filter { button in
                (button.superview as? BreadcrumbSegmentView)?.labelButton === button
            }
            #expect(!labels.isEmpty)
            for label in labels {
                let font = label.font ?? NSFont.systemFont(ofSize: 12.pt)
                let ellipsisWidth = ("…" as NSString).size(withAttributes: [.font: font]).width
                #expect(label.frame.width + 0.5 >= min(label.intrinsicContentSize.width, ellipsisWidth),
                        "Every displayed breadcrumb needs room for text or an ellipsis, not just its arrow")
                #expect(!label.hasAmbiguousLayout)
                let segment = try #require(label.superview as? BreadcrumbSegmentView)
                #expect(segment.bounds.width + 0.5 >= label.frame.maxX)
                if let arrow = segment.disclosureButton {
                    #expect(arrow.frame.minX + 0.5 >= label.frame.maxX)
                    #expect(arrow.frame.maxX <= segment.bounds.maxX + 0.5)
                }
            }
            #expect(fixture.findButton(named: "Ancestor folders") != nil)
            #expect(fixture.store.activeTab.url == location)
            #expect(!fixture.store.activeTab.history.canGoBack)
        }
    }

    @Test
    func breadcrumbOverflowExactlyComplementsTheRenderedSuffixAfterResize() async throws {
        let fixture = try AddressBarFixture(relativeLocation: ["Navigation",
            "Long folder name for breadcrumb truncation", "Unicode cafe\u{301} 日本語", "Leaf"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let location = fixture.store.activeTab.url
        var expectedRoute: [URL] = []
        var ancestor = location
        while ancestor.path != "/" {
            expectedRoute.insert(ancestor, at: 0)
            ancestor = ancestor.deletingLastPathComponent()
        }
        expectedRoute.insert(URL(fileURLWithPath: "/"), at: 0)
        let widths: [CGFloat] = [650, 500, 340, 850, 650]
        for width in widths {
            fixture.view.frame.size.width = width.pt
            fixture.view.needsLayout = true
            fixture.view.layoutSubtreeIfNeeded()
            let visible = fixture.addressButtons.filter { button in
                (button.superview as? BreadcrumbSegmentView)?.labelButton === button
            }.compactMap(\.representedURL)
            let hidden = fixture.view.ancestorOverflowMenu().items.compactMap { $0.representedObject as? URL }
            #expect(hidden + visible == expectedRoute, "Overflow must contain each omitted ancestor once, in path order")
            #expect(visible.last == location)
            #expect(Set(hidden).isDisjoint(with: Set(visible)))
        }
    }

    private func typeNativeAddress(_ value: String, in fixture: AddressBarFixture, text: NSTextView) throws {
        try #require(fixture.window.firstResponder === text && fixture.view.editor.currentEditor() === text)
        text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        #expect(text.string == value && fixture.view.editor.stringValue == value)
        #expect(fixture.store.address.text == value, "Native text insertion must deliver the normal control delegate update")
    }

    private func expectSingleAddressLineAndVisibleSelection(_ fixture: AddressBarFixture, text: NSTextView,
                                                           selection: NSRange? = nil, requiresOverflow: Bool = false) async throws {
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.display()
        let wholeText = NSRange(location: 0, length: (text.string as NSString).length)
        let inspectedSelection = selection ?? NSRange(location: wholeText.length, length: 0)
        #expect(text.selectedRange() == inspectedSelection)
        let before = text.firstRect(forCharacterRange: inspectedSelection, actualRange: nil)
        // Accessing NSTextView.layoutManager switches a native TextKit 2 field
        // editor to TextKit 1. Inspect its existing engine without changing it.
        let manager = try #require(text.textLayoutManager)
        var lineRanges: [NSRange] = []
        var lineWidth: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            lineRanges.append(contentsOf: fragment.textLineFragments.map(\.characterRange))
            for line in fragment.textLineFragments { lineWidth = max(lineWidth, line.typographicBounds.width) }
            return true
        }
        #expect(lineRanges.count == 1, "The live field editor must lay out the whole address on one line")
        #expect(lineRanges == [wholeText], "The one-line layout must retain every UTF16 character")
        #expect(text.textLayoutManager === manager)
        if requiresOverflow {
            #expect(lineWidth > fixture.view.editor.bounds.width, "The address must overflow at every tested width")
            #expect(text.visibleRect.minX > 0, "The overflowed end caret must require a positive native scroll offset")
        }
        let after = text.firstRect(forCharacterRange: inspectedSelection, actualRange: nil)
        #expect(after == before, "Inspecting line layout must not change native selection geometry")
        #expect(text.selectedRange() == inspectedSelection)
        let visible = fixture.view.editor.visibleRect.intersection(fixture.view.editor.bounds)
        for screenCaret in [before, after] {
            let caret = fixture.view.editor.convert(fixture.window.convertFromScreen(screenCaret), from: nil)
            #expect(caret.height > 0 && caret.minX.isFinite && caret.minY.isFinite)
            if inspectedSelection.length == 0 {
                #expect(caret.minX >= visible.minX - 2 && caret.maxX <= visible.maxX + 2,
                        "The end caret must be horizontally visible in the address control")
                #expect(caret.minY >= visible.minY - 2 && caret.maxY <= visible.maxY + 2,
                        "The end caret must not be clipped above or below the address control")
            } else {
                let overlap = caret.intersection(visible)
                #expect(caret.width > 0 && overlap.width > 0 && overlap.height > 0,
                        "The unchanged nonempty selection must overlap the address control")
            }
        }
    }

    // Documents-favorite design: these baseline-compatible native controls use
    // an injected synthetic home. No account discovery or personal path I/O.
    @Test(arguments: ["OneDrive-Team Cafe\u{301} 日本語", "OneDrive"])
    func oneDriveAccountBreadcrumbKeepsDocumentsAndRealNavigationURLs(_ accountComponent: String) async throws {
        let fixture = try AddressBarFixture(relativeLocation: ["Library", "CloudStorage", accountComponent, "Documents"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        fixture.view.layoutSubtreeIfNeeded()
        let current = fixture.store.activeTab.url
        let account = current.deletingLastPathComponent()
        let expectedTitle = accountComponent == "OneDrive" ? "OneDrive" : "OneDrive – " + String(accountComponent.dropFirst("OneDrive-".count))
        let labels = fixture.addressButtons.filter { ($0.superview as? BreadcrumbSegmentView)?.labelButton === $0 }
        #expect(labels.map(\.title) == [expectedTitle, "Documents"],
                "Show the account and Documents instead of generic CloudStorage container ancestors")
        #expect(labels.compactMap(\.representedURL) == [account, current])
        let accountButton = try #require(labels.first { $0.representedURL == account })
        #expect(accountButton.accessibilityLabel() == expectedTitle)
        #expect(accountButton.toolTip == account.path)
        let dropdown = try #require((accountButton.superview as? BreadcrumbSegmentView)?.disclosureButton)
        #expect(dropdown.representedURL == account)
        #expect(dropdown.accessibilityLabel() == "Subfolders of \(expectedTitle)")
        #expect(fixture.view.ancestorOverflowMenu().items.compactMap { $0.representedObject as? URL }
                + labels.compactMap(\.representedURL) == NativeAddressBar.breadcrumbURLs(for: current))
    }

    @Test
    func oneDriveCompactBreadcrumbPreservesAccountInVisibleRouteOrOverflow() async throws {
        let component = "OneDrive-Long Account Cafe\u{301} 日本語 \(String(repeating: "Team ", count: 8))"
        let fixture = try AddressBarFixture(relativeLocation: ["Library", "CloudStorage", component, "Documents"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let current = fixture.store.activeTab.url
        let account = current.deletingLastPathComponent()
        let expectedTitle = "OneDrive – " + String(component.dropFirst("OneDrive-".count))
        let widths: [CGFloat] = [650, 500, 340, 260, 850, 650]
        for width in widths {
            fixture.view.frame.size.width = width.pt
            fixture.view.needsLayout = true
            fixture.view.layoutSubtreeIfNeeded()
            let labels = fixture.addressButtons.filter { ($0.superview as? BreadcrumbSegmentView)?.labelButton === $0 }
            let overflow = fixture.view.ancestorOverflowMenu().items
            let visible = labels.compactMap(\.representedURL)
            let hidden = overflow.compactMap { $0.representedObject as? URL }
            #expect(hidden + visible == NativeAddressBar.breadcrumbURLs(for: current))
            #expect(Set(hidden).isDisjoint(with: Set(visible)))
            #expect(visible.last == current)
            let accountTitles = labels.filter { $0.representedURL == account }.map(\.title)
                + overflow.filter { ($0.representedObject as? URL) == account }.map(\.title)
            #expect(accountTitles == [expectedTitle])
            if width >= 350 { #expect(visible.contains(account), "Normal widths retain the account beside Documents") }
            let documents = try #require(labels.first { $0.representedURL == current })
            #expect(documents.frame.width + 0.5 >= documents.intrinsicContentSize.width)
            for label in labels {
                let segment = try #require(label.superview as? BreadcrumbSegmentView)
                let font = label.font ?? NSFont.systemFont(ofSize: 12.pt)
                let ellipsis = ("…" as NSString).size(withAttributes: [.font: font]).width
                #expect(label.frame.width + 0.5 >= min(label.intrinsicContentSize.width, ellipsis))
                #expect(!label.hasAmbiguousLayout && label.frame.maxX <= segment.bounds.maxX + 0.5)
                if let arrow = segment.disclosureButton {
                    #expect(arrow.frame.minX + 0.5 >= label.frame.maxX && arrow.frame.maxX <= segment.bounds.maxX + 0.5)
                }
            }
            #expect(fixture.store.activeTab.url == current && !fixture.store.activeTab.history.canGoBack)
        }
    }

    @Test(arguments: [CGFloat(650), CGFloat(260)])
    func oneDriveFriendlyAccountLabelAndOverflowDispatchTheRealAncestor(_ width: CGFloat) async throws {
        let fixture = try AddressBarFixture(relativeLocation: ["Library", "CloudStorage", "OneDrive-Team", "Documents"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        fixture.view.frame.size.width = width.pt
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()
        let current = fixture.store.activeTab.url
        let account = current.deletingLastPathComponent()
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        if width >= 350 {
            let button = try #require(fixture.addressButtons.first {
                ($0.superview as? BreadcrumbSegmentView)?.labelButton === $0 && $0.representedURL == account
            })
            #expect(button.title == "OneDrive – Team")
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        } else {
            let menu = fixture.view.ancestorOverflowMenu()
            let item = try #require(menu.items.first { ($0.representedObject as? URL) == account })
            #expect(item.title == "OneDrive – Team")
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        try await waitUntil { !fixture.store.activeTab.isLoading && fixture.store.activeTab.url == account }
        #expect(fixture.store.activeTab.history.backStack == [current])
        #expect(fixture.store.address.recentAddresses.isEmpty)
        #expect(fixture.window.firstResponder === fixture.prior)
    }

    @Test
    func oneDriveFriendlyBreadcrumbStillEditsTheExactAbsolutePath() async throws {
        let fixture = try AddressBarFixture(relativeLocation: ["Library", "CloudStorage", "OneDrive-Team Cafe\u{301} 日本語", "Documents"])
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        let current = fixture.store.activeTab.url
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        let text = try fixture.beginEditing()
        #expect(text.string.utf8.elementsEqual(current.path.utf8))
        #expect(fixture.view.editor.stringValue.utf8.elementsEqual(current.path.utf8))
        #expect(fixture.store.address.text.utf8.elementsEqual(current.path.utf8))
        #expect(text.selectedRange() == NSRange(location: 0, length: (current.path as NSString).length))
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(fixture.store.activeTab.url == current && !fixture.store.activeTab.history.canGoBack)
        #expect(fixture.view.editor.stringValue == current.path && fixture.window.firstResponder === fixture.prior)
    }

    @Test(arguments: [["Scratch", "OneDrive-Team", "Documents"],
                      ["Library", "CloudStorageElsewhere", "OneDrive-Team", "Documents"],
                      ["Library", "CloudStorage", "Box-Team", "Documents"],
                      ["Library", "CloudStorage", "OneDrive-", "Documents"]])
    func ordinaryAndLookalikeRootsKeepTheirExistingBreadcrumbLabels(_ components: [String]) async throws {
        let fixture = try AddressBarFixture(relativeLocation: components)
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        fixture.view.synchronize()
        fixture.view.layoutSubtreeIfNeeded()
        let labels = fixture.addressButtons.filter { ($0.superview as? BreadcrumbSegmentView)?.labelButton === $0 }
        #expect(labels.allSatisfy { $0.title == $0.representedURL.map(BrowsingPresentation.title) })
        let route = NativeAddressBar.breadcrumbURLs(for: fixture.store.activeTab.url)
        #expect(labels.compactMap(\.representedURL) == Array(route.suffix(NativeAddressBar.visibleBreadcrumbCount(width: fixture.view.bounds.width))))
    }

    private func fixture() async throws -> AddressBarFixture {
        let fixture = try AddressBarFixture()
        try await waitUntil { !fixture.store.activeTab.isLoading }
        let first = try #require(fixture.store.activeTab.items.first)
        fixture.store.setSelection([first.id], focusedID: first.id)
        fixture.view.synchronize()
        return fixture
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor
private final class AddressBarFixture {
    let root: URL
    let store: ExplorerStore
    let window: AddressBarTestWindow
    let view: NativeAddressBar
    let prior = AddressTestFocusView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
    let pasteboard: NSPasteboard
    let contextMenuPanel: AddressContextTestPanel?

    init(loader: any DirectoryListing = AddressBarLoader(), relativeLocation: [String] = [],
         simulateContextMenu: Bool = false) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-address-Café 🗂-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["ChildOne", "ChildTwo", "Café 🗂"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("address-ui-tests-\(UUID().uuidString)"))
        let initialLocation = relativeLocation.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: initialLocation, withIntermediateDirectories: true)
        store = ExplorerStore(initialURL: initialLocation, loader: loader, homeURL: root,
                              clipboard: TransferClipboard(pasteboard: pasteboard))
        window = AddressBarTestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.simulatesContextMenuOwnership = simulateContextMenu
        if simulateContextMenu {
            let panel = AddressContextTestPanel(contentRect: .zero, styleMask: [.borderless],
                                                backing: .buffered, defer: false)
            panel.originWindow = window
            contextMenuPanel = panel
            view = NativeAddressBar(store: store, contextMenuPanelFactory: { panel },
                                    isContextMenuApplicationActive: { true })
        } else {
            contextMenuPanel = nil
            view = NativeAddressBar(store: store)
        }
        view.frame = NSRect(x: 10, y: 260, width: 650, height: 32)
        window.contentView?.addSubview(prior)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
    }

    func beginEditing() throws -> NSTextView {
        store.requestAddressEditing()
        view.synchronize()
        return try #require(view.editor.currentEditor() as? NSTextView)
    }

    func type(_ value: String) {
        view.editor.stringValue = value
        (view.editor.currentEditor() as? NSTextView)?.string = value
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.editor))
    }

    func button(named label: String) throws -> AddressActionButton {
        try #require(findButton(named: label))
    }

    func hoverEvent(_ type: NSEvent.EventType, in button: AddressActionButton) throws -> NSEvent {
        let area = try customTrackingArea(of: button)
        return try trackingEvent(type, in: button, area: area)
    }

    func mouseMovedEvent(in button: AddressActionButton, point: NSPoint? = nil,
                         eventWindow: NSWindow? = nil) throws -> NSEvent {
        // Do not update tracking or lay out here: either can legitimately
        // reconcile hover and would conceal the missing-movement regression.
        try #require(button.bounds.width > 0 && button.bounds.height > 0)
        let location = point ?? button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        window.pointerForHoverTesting = location
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (eventWindow ?? window).windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        return AddressMouseMoveEvent(event: event, window: eventWindow ?? window)
    }

    func customTrackingArea(of button: AddressActionButton, update: Bool = true) throws -> NSTrackingArea {
        view.layoutSubtreeIfNeeded()
        try #require(button.bounds.width > 0 && button.bounds.height > 0,
                     "A direct hover event needs a laid-out, nonzero native target")
        if update { button.updateTrackingAreas() }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if button.superview is BreadcrumbSegmentView { options.insert(.mouseMoved) }
        return try #require(button.trackingAreas.first { ($0.owner as AnyObject?) === button && $0.options == options })
    }

    func trackingEvent(_ type: NSEvent.EventType, in button: AddressActionButton, area: NSTrackingArea,
                       point: NSPoint? = nil, eventWindow: NSWindow? = nil) throws -> NSEvent {
        let localPoint = NSPoint(x: type == .mouseExited ? button.bounds.maxX + 1 : button.bounds.midX,
                                y: button.bounds.midY)
        let location = point ?? button.convert(localPoint, to: nil)
        window.pointerForHoverTesting = location
        let event = try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (eventWindow ?? window).windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        let wrapped = AddressTrackingAreaEvent(event: event, area: area, window: eventWindow ?? window)
        #expect(wrapped.window === (eventWindow ?? window))
        return wrapped
    }

    var addressButtons: [AddressActionButton] {
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(view).compactMap { $0 as? AddressActionButton }
    }

    func findButton(named label: String) -> AddressActionButton? {
        func descendants(_ parent: NSView) -> [NSView] {
            parent.subviews.flatMap { [$0] + descendants($0) }
        }
        return descendants(view).compactMap { $0 as? AddressActionButton }
            .first { $0.accessibilityLabel() == label }
    }


    func close() {
        view.tearDown()
        store.cancelLoads()
        window.close()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AddressTestFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// A native window with a deterministic pointer-read boundary. These tests send
// responder events directly and never move the desktop pointer or claim OS event
// routing. Tests not using hoverEvent/trackingEvent keep normal window behavior.
@MainActor
private final class AddressBarTestWindow: NSWindow {
    var pointerForHoverTesting: NSPoint?
    var simulatesContextMenuOwnership = false
    override var isMainWindow: Bool { simulatesContextMenuOwnership || super.isMainWindow }
    override var mouseLocationOutsideOfEventStream: NSPoint {
        pointerForHoverTesting ?? super.mouseLocationOutsideOfEventStream
    }
    override var isKeyWindow: Bool { simulatesContextMenuOwnership || pointerForHoverTesting != nil || super.isKeyWindow }
    override var isVisible: Bool { simulatesContextMenuOwnership || pointerForHoverTesting != nil || super.isVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if !simulatesContextMenuOwnership { super.makeKeyAndOrderFront(sender) }
    }
}

@MainActor
private final class AddressContextTestPanel: FileActionsPanel {
    weak var originWindow: NSWindow?
    private var shown = false
    private var hasContextMenuKey = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { hasContextMenuKey }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        shown = true
        hasContextMenuKey = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: originWindow)
    }

    func resignContextMenuKey() {
        hasContextMenuKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: self)
    }

    override func orderOut(_ sender: Any?) {
        shown = false
        hasContextMenuKey = false
        super.orderOut(sender)
    }
}

// Keep a genuine factory-produced mouse-move event, adapting only its owner
// lookup for offscreen windows. Unlike tracking-event fixtures this supplies no
// tracking-area identity: querying trackingArea on a mouse move is invalid.
private final class AddressMouseMoveEvent: NSEvent {
    private let source: NSEvent
    private let sourceWindow: NSWindow
    init(event: NSEvent, window: NSWindow) {
        source = event; sourceWindow = window; super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { source.type }
    override var locationInWindow: NSPoint { source.locationInWindow }
    override var window: NSWindow? { sourceWindow }
    override var windowNumber: Int { sourceWindow.windowNumber }
    override var timestamp: TimeInterval { source.timestamp }
    override var modifierFlags: NSEvent.ModifierFlags { source.modifierFlags }
    override var trackingArea: NSTrackingArea? { source.trackingArea }
}

// NSEvent's public enter/exit factory creates legacy tracking-rectangle events
// with trackingArea == nil. Preserve its real coordinates/window and supply the
// explicit modern tracking-area identity needed to test our event boundary.
private final class AddressTrackingAreaEvent: NSEvent {
    private let source: NSEvent
    private let area: NSTrackingArea
    private let sourceWindow: NSWindow
    init(event: NSEvent, area: NSTrackingArea, window: NSWindow) {
        source = event; self.area = area; sourceWindow = window; super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { source.type }
    override var locationInWindow: NSPoint { source.locationInWindow }
    // Offscreen test windows need not have a server-resolvable window number.
    // Model the native event's supplied owner directly instead of accidentally
    // testing NSEvent's legacy window-number lookup with a negative identifier.
    override var window: NSWindow? { sourceWindow }
    override var windowNumber: Int { sourceWindow.windowNumber }
    override var timestamp: TimeInterval { source.timestamp }
    override var modifierFlags: NSEvent.ModifierFlags { source.modifierFlags }
    override var trackingNumber: Int { source.trackingNumber }
    override var userData: UnsafeMutableRawPointer? { source.userData }
    override var eventNumber: Int { source.eventNumber }
    override var trackingArea: NSTrackingArea? { area }
}

private struct AddressBarLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        [FileItem(url: url.appendingPathComponent("Alpha.txt"), name: "Alpha.txt", isDirectory: false,
                  isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text Document"),
         FileItem(url: url.appendingPathComponent("ChildOne", isDirectory: true), name: "ChildOne", isDirectory: true,
                  isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Folder")]
    }
}

private actor AddressBarChangingLoader: DirectoryListing {
    private var hasSnapshot = false
    private var hasChild = false
    func setHasChild(_ value: Bool) { hasSnapshot = true; hasChild = value }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        guard hasSnapshot else { return [] }
        let file = FileItem(url: url.appendingPathComponent("Alpha.txt"), name: "Alpha.txt", isDirectory: false,
                           isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text Document")
        guard hasChild else { return [file] }
        return [file, FileItem(url: url.appendingPathComponent("ChildOne", isDirectory: true), name: "ChildOne",
                              isDirectory: true, isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Folder")]
    }
}
