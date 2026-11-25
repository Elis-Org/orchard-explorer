import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// Native field-editor assertions for FR-FILE-002/008/018, EV-0226/0227,
/// EV-0232/0235, AT-FILE-002/008/018, including an isolated native refusal.
@Suite(.serialized)
@MainActor
final class NameEditorTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }

    private func field(in window: NSWindow) -> NameEditorTextField {
        let result = NameEditorTextField()
        result.frame = NSRect(x: 20, y: 120, width: 300, height: 24)
        window.contentView?.addSubview(result)
        return result
    }

    @Test
    func initialSelectionUsesUTF16RangeWithoutSelectingFileExtension() throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        let basename = "Café 🗂"
        let name = basename + ".txt"
        let range = NSRange(location: 0, length: (basename as NSString).length)
        field.beginSession(id: UUID(), name: name, selection: range)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == range)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == basename)
        #expect(editor.string == name)
        #expect(field.isEditable && field.isSelectable)
    }

    @Test
    func returnSubmitsCurrentTextAndEscapeOnlyCancels() throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var changes: [String] = []
        var commits = 0
        var cancellations = 0
        field.onProposalChange = { changes.append($0) }
        field.onCommit = { commits += 1 }
        field.onCancel = { cancellations += 1 }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Renamed.txt"
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(changes == ["Renamed.txt"])
        #expect(commits == 1)
        #expect(cancellations == 0)
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(cancellations == 1)
        #expect(commits == 1)
    }

    @Test
    func focusLossCancelsUnsubmittedDraftWithoutCommit() async throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var commits = 0
        var cancellations = 0
        field.onCommit = { commits += 1 }
        field.onCancel = { cancellations += 1 }
        field.beginSession(id: UUID(), name: "New folder", selection: NSRange(location: 0, length: 10))
        _ = try #require(field.currentEditor() as? NSTextView)
        #expect(window.makeFirstResponder(nil))
        try await waitUntil { cancellations == 1 }
        #expect(commits == 0)
    }

    @Test
    func oldFocusLossCallbackCannotCancelReplacementSession() async throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var cancellations = 0
        field.beginSession(id: UUID(), name: "First", selection: NSRange(location: 0, length: 5))
        #expect(window.makeFirstResponder(nil))
        field.finishSession()
        field.onCancel = { cancellations += 1 }
        let replacementID = UUID()
        field.beginSession(id: replacementID, name: "Second", selection: NSRange(location: 0, length: 6))
        try await Task.sleep(for: .milliseconds(20))
        #expect(field.sessionID == replacementID)
        #expect(cancellations == 0)
        #expect(field.stringValue == "Second")
    }

    @Test
    func submissionDisablesEditorAndFailureRestoresDraftWithoutAutomaticRetry() async throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var commits = 0
        var cancellations = 0
        field.onCommit = { commits += 1 }
        field.onCancel = { cancellations += 1 }
        field.beginSession(id: UUID(), name: "Proposed.txt", selection: NSRange(location: 3, length: 2))
        let editor = try #require(field.currentEditor() as? NSTextView)
        field.updateSession(proposedName: "Proposed.txt", isSubmitting: true)
        #expect(field.isSubmitting && !field.isEnabled && !field.isEditable)
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(commits == 0 && cancellations == 0)
        field.updateSession(proposedName: "Proposed.txt", isSubmitting: false)
        try await waitUntil { field.currentEditor() != nil }
        let restored = try #require(field.currentEditor() as? NSTextView)
        #expect(field.isEditable && field.isEnabled && !field.isSubmitting)
        #expect(restored.string == "Proposed.txt")
        #expect(restored.selectedRange() == NSRange(location: 3, length: 2))
        #expect(commits == 0 && cancellations == 0)
    }

    @Test
    func repeatedSessionUpdatesPreserveInsertionPointAndTypedText() throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        field.beginSession(id: UUID(), name: "Draft.txt", selection: NSRange(location: 2, length: 0))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Draft revised.txt"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        field.updateSession(proposedName: "Draft revised.txt", isSubmitting: false)
        #expect(field.currentEditor() === editor)
        #expect(editor.string == "Draft revised.txt")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test
    func submittingFocusedNameEditorReturnsFileFocusForImmediateUndo() throws {
        let window = window()
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        window.contentView?.addSubview(table)
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var eligible = false
        var undoRequests = 0
        table.canUndoRename = { eligible }
        table.onUndoRename = { undoRequests += 1 }
        field.onCommit = {
            DetailsTableView.Coordinator.updateNameEditor(field, proposedName: "Renamed.txt",
                                                         isSubmitting: true, in: table)
        }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Renamed.txt"
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(field.isSubmitting)
        #expect(window.firstResponder === table)
        table.undo(nil)
        #expect(undoRequests == 0)
        // A successful write ends the inline session and makes rename Undo eligible.
        field.finishSession()
        eligible = true
        let undo = NSMenuItem(title: "Undo", action: #selector(ExplorerTableView.undo(_:)), keyEquivalent: "z")
        #expect(table.validateUserInterfaceItem(undo))
        let responder = try #require(window.firstResponder)
        #expect(responder.tryToPerform(#selector(ExplorerTableView.undo(_:)), with: undo))
        #expect(undoRequests == 1)
    }

    @Test
    func submittingEditorDoesNotTakeFocusFromHeaderOrAnotherTextField() throws {
        let window = window()
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        window.contentView?.addSubview(table)
        let field = field(in: window)
        let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 180, width: 400, height: 24))
        window.contentView?.addSubview(header)
        let other = NSTextField(string: "Address")
        other.frame = NSRect(x: 20, y: 60, width: 280, height: 24)
        window.contentView?.addSubview(other)
        defer { field.finishSession(); window.close() }
        field.beginSession(id: UUID(), name: "First.txt", selection: NSRange(location: 0, length: 5))
        #expect(window.makeFirstResponder(header))
        DetailsTableView.Coordinator.updateNameEditor(field, proposedName: "First.txt",
                                                     isSubmitting: true, in: table)
        #expect(window.firstResponder === header)
        field.finishSession()
        field.beginSession(id: UUID(), name: "Second.txt", selection: NSRange(location: 0, length: 6))
        #expect(window.makeFirstResponder(other))
        let otherEditor = try #require(other.currentEditor())
        #expect(window.firstResponder === otherEditor)
        DetailsTableView.Coordinator.updateNameEditor(field, proposedName: "Second.txt",
                                                     isSubmitting: true, in: table)
        #expect(window.firstResponder === otherEditor)
    }

    @Test
    func finishingOldSessionPreservesAnotherFieldsActiveEditor() throws {
        let window = window()
        let field = field(in: window)
        let other = NSTextField(string: "Address draft")
        other.frame = NSRect(x: 20, y: 60, width: 280, height: 24)
        window.contentView?.addSubview(other)
        defer { field.finishSession(); window.close() }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        _ = try #require(field.currentEditor() as? NSTextView)
        #expect(window.makeFirstResponder(other))
        let otherEditor = try #require(other.currentEditor() as? NSTextView)
        otherEditor.string = "Edited address draft"
        otherEditor.setSelectedRange(NSRange(location: 7, length: 3))

        field.finishSession()

        #expect(field.sessionID == nil)
        #expect(!field.isEditable && !field.isSelectable)
        #expect(window.firstResponder === otherEditor)
        #expect(other.currentEditor() === otherEditor)
        #expect(otherEditor.string == "Edited address draft")
        #expect(otherEditor.selectedRange() == NSRange(location: 7, length: 3))
    }

    @Test
    func f2RoutesRenameWithoutActivatingFile() throws {
        let window = window()
        defer { window.close() }
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        window.contentView?.addSubview(table)
        var renames = 0
        var activations = 0
        table.onRename = { renames += 1 }
        table.onActivate = { activations += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120))
        table.keyDown(with: event)
        #expect(renames == 1 && activations == 0)
    }

    @Test(arguments: [FolderViewMode.details, .largeIcons])
    func nativePasteRevealsCaretAndReturnSubmitsExactFilename(mode: FolderViewMode) async throws {
        let window = window()
        let field = field(in: window, mode: mode)
        defer { field.finishSession(); window.close() }
        var proposal = ""
        var commits: [String] = []
        field.onProposalChange = { proposal = $0 }
        field.onCommit = { commits.append(proposal) }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let basename = "HEAD-" + String(repeating: "Café-🗂-segment-", count: 8) + "TAIL"
        let expected = basename + ".txt"
        try paste(basename, into: editor)
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(proposal.utf8.elementsEqual(expected.utf8))
        try await expectVisibleCaret(field, editor: editor, window: window,
                                     offset: (basename as NSString).length, wrapped: mode == .largeIcons, overflow: true)
        editor.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))
        try await expectVisibleCaret(field, editor: editor, window: window, offset: 0, wrapped: mode == .largeIcons)
        editor.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
        let end = (expected as NSString).length
        try await expectVisibleCaret(field, editor: editor, window: window,
                                     offset: end, wrapped: mode == .largeIcons, overflow: true)
        if mode == .details {
            field.setFrameSize(NSSize(width: 130, height: field.frame.height))
            try await expectVisibleCaret(field, editor: editor, window: window, offset: end, wrapped: false, overflow: true)
        }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(commits.map { Array($0.utf8) } == [Array(expected.utf8)])
    }

    @Test(arguments: [FolderViewMode.details, .largeIcons, .list])
    func controlCharacterPastePreservesPerViewBytesAndRestoresIdlePresentation(mode: FolderViewMode) throws {
        let window = window()
        let field = field(in: window, mode: mode)
        defer { field.finishSession(); window.close() }
        let idle = try presentation(of: field)
        for payload in ["Name.txt\n", "a\nb.txt", "a\tb.txt"] {
            var proposal = ""
            var committed: [UInt8]?
            field.onProposalChange = { proposal = $0 }
            field.onCommit = { committed = Array(proposal.utf8) }
            field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 12))
            let editor = try #require(field.currentEditor() as? NSTextView)
            try paste(payload, into: editor)
            let expected = mode == .list ? payload.replacingOccurrences(of: "\n", with: " ") : payload
            #expect(editor.string.utf8.elementsEqual(expected.utf8))
            #expect(proposal.utf8.elementsEqual(expected.utf8))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(committed == Array(expected.utf8))
            field.finishSession()
            field.finishSession()
            let restored = try presentation(of: field)
            #expect(restored == idle)
        }
        if let item = field.superview as? ExplorerCollectionItemView {
            item.configure(item: sampleItem(name: "Reused.txt"), mode: mode)
            let restored = try presentation(of: field)
            #expect(restored == idle)
            #expect(field.stringValue == "Reused.txt")
        }
    }

    @Test
    func markedTextKeepsReturnAndEscapeInNativeFieldEditor() throws {
        let window = window()
        let field = field(in: window)
        defer { field.finishSession(); window.close() }
        var commits = 0
        var cancellations = 0
        field.onCommit = { commits += 1 }
        field.onCancel = { cancellations += 1 }
        field.beginSession(id: UUID(), name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.hasMarkedText())
        #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(commits == 0 && cancellations == 0)
        editor.unmarkText()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(commits == 1 && cancellations == 0)
    }

    @Test
    func replacingStackedSessionRestoresOriginalIdleSettings() throws {
        let window = window()
        let field = field(in: window, mode: .largeIcons)
        defer { field.finishSession(); window.close() }
        let idle = try presentation(of: field)
        field.beginSession(id: UUID(), name: "First.txt", selection: NSRange(location: 0, length: 5))
        let replacement = UUID()
        var replacementCommits = 0
        field.onCommit = { replacementCommits += 1 }
        field.beginSession(id: replacement, name: "Second.txt", selection: NSRange(location: 0, length: 6))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(field.sessionID == replacement && editor.string == "Second.txt")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(replacementCommits == 1)
        field.finishSession()
        let restored = try presentation(of: field)
        #expect(restored == idle)
    }

    @Test
    func refusalAfterFocusMovesDoesNotTakeTheAddressEditor() async throws {
        let window = window()
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        window.contentView?.addSubview(table)
        let field = field(in: window, mode: .details)
        let address = NSTextField(string: "Address draft")
        address.frame = NSRect(x: 20, y: 160, width: 250, height: 24)
        window.contentView?.addSubview(address)
        defer { field.finishSession(); window.close() }
        let sessionID = UUID()
        var proposal = ""
        field.onProposalChange = { proposal = $0 }
        field.onCommit = {
            DetailsTableView.Coordinator.updateNameEditor(field, proposedName: proposal, isSubmitting: true, in: table)
        }
        field.beginSession(id: sessionID, name: "Original.txt", selection: NSRange(location: 0, length: 8))
        let editor = try #require(field.currentEditor() as? NSTextView)
        try paste("Refused", into: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(field.isSubmitting && window.firstResponder === table)
        try #require(window.makeFirstResponder(address))
        let addressEditor = try #require(address.currentEditor() as? NSTextView)
        DetailsTableView.Coordinator.updateNameEditor(field, proposedName: proposal, isSubmitting: false, in: table)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.firstResponder === addressEditor)
        #expect(addressEditor.string == "Address draft")
        #expect(field.currentEditor() == nil && field.isEditable && field.sessionID == sessionID)
        #expect(field.stringValue == "Refused.txt")

        // The editable field remains available through native focus, as on click.
        try #require(window.makeFirstResponder(field))
        let resumed = try #require(field.currentEditor() as? NSTextView)
        #expect(resumed.string == "Refused.txt" && window.firstResponder === resumed)
        field.onCancel = { field.finishSession() }
        resumed.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(field.sessionID == nil)
    }

    @Test
    func cloudBadgeUsesAvailableWidthOnlyDuringStackedEditing() throws {
        let window = window()
        let item = ExplorerCollectionItemView()
        item.frame = NSRect(x: 20, y: 20, width: 122, height: 160)
        item.configure(item: sampleItem(name: "a.txt", availability: .onlineOnly), mode: .largeIcons)
        window.contentView?.addSubview(item)
        let field = item.nameField
        defer { field.finishSession(); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try #require(!item.cloudBadge.isHidden)
        let idleWidth = field.frame.width
        field.beginSession(id: UUID(), name: "a.txt", selection: NSRange(location: 0, length: 1))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(field.frame.width > idleWidth)
        #expect(field.frame.minX >= item.cloudBadge.frame.maxX)
        field.finishSession()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(field.frame.width == idleWidth)
    }

    @Test
    func oversizedUTF8RenameRetainsExactDraftAndOriginalFileAfterReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Maxplorer-rename-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.txt")
        let bytes = Data("original file".utf8)
        try bytes.write(to: original)
        let store = ExplorerStore(initialURL: root, homeURL: root)
        defer { store.cancelLoads() }
        try await waitUntil { !store.activeTab.isLoading }
        let item = try #require(store.displayedItems.first { $0.name == "Original.txt" })
        store.setSelection([item.id], focusedID: item.id)
        store.beginRename()
        let edit = try #require(store.nameEdit)
        let window = window()
        let field = field(in: window, mode: .details)
        defer { field.finishSession(); window.close() }
        field.onProposalChange = { store.updateProposedName($0, sessionID: edit.id) }
        field.onCommit = { store.commitNameEdit(sessionID: edit.id) }
        field.beginSession(id: edit.id, name: edit.proposedName, selection: edit.initialSelection)
        let editor = try #require(field.currentEditor() as? NSTextView)
        // Exceed both character and byte limits so the refusal does not depend
        // on whether this filesystem accepts 300 UTF-8 bytes in 100 characters.
        let basename = String(repeating: "a", count: 300) + "界"
        let proposed = basename + ".txt"
        try #require(proposed.utf8.count > 255)
        try paste(basename, into: editor)
        let selection = editor.selectedRange()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let submitting = try #require(store.nameEdit)
        try #require(submitting.isSubmitting)
        field.updateSession(proposedName: submitting.proposedName, isSubmitting: submitting.isSubmitting)
        try await waitUntil { !store.isPerformingOperation }
        let refused = try #require(store.nameEdit, "Expected the physical rename to refuse the oversized component")
        #expect(refused.errorMessage != nil)
        #expect(refused.id == edit.id && !refused.isSubmitting)
        #expect(refused.proposedName.utf8.elementsEqual(proposed.utf8))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Original.txt"])
        field.updateSession(proposedName: refused.proposedName, isSubmitting: refused.isSubmitting)
        try await waitUntil { field.currentEditor() != nil }
        let restored = try #require(field.currentEditor() as? NSTextView)
        #expect(restored.string.utf8.elementsEqual(proposed.utf8))
        #expect(restored.selectedRange() == selection)
        try await expectVisibleCaret(field, editor: restored, window: window,
                                     offset: selection.location, wrapped: false, overflow: true)
    }


    private func field(in window: NSWindow, mode: FolderViewMode) -> NameEditorTextField {
        if mode == .details {
            let result = field(in: window)
            result.frame.size.width = 193
            result.font = .systemFont(ofSize: 12)
            result.lineBreakMode = .byTruncatingTail
            return result
        }
        let item = ExplorerCollectionItemView()
        item.frame = NSRect(x: 20, y: 20, width: 122, height: 160)
        item.configure(item: sampleItem(), mode: mode)
        window.contentView?.addSubview(item)
        item.layoutSubtreeIfNeeded()
        return item.nameField
    }

    private func sampleItem(name: String = "Original.txt", availability: FileAvailability = .unknown) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp").appendingPathComponent(name), name: name,
                 isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text Document", availability: availability)
    }

    private struct Presentation: Equatable {
        let lineBreakMode: NSLineBreakMode
        let wraps: Bool
        let isScrollable: Bool
        let singleLine: Bool
        let maximumLines: Int
        let truncatesLastLine: Bool
    }

    private func presentation(of field: NameEditorTextField) throws -> Presentation {
        let cell = try #require(field.cell)
        return Presentation(lineBreakMode: field.lineBreakMode, wraps: cell.wraps, isScrollable: cell.isScrollable,
                            singleLine: cell.usesSingleLineMode, maximumLines: field.maximumNumberOfLines,
                            truncatesLastLine: cell.truncatesLastVisibleLine)
    }

    private func paste(_ value: String, into editor: NSTextView) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.setString(value, forType: .string))
        try #require(editor.readSelection(from: board, type: .string))
    }

    private func expectVisibleCaret(_ field: NameEditorTextField, editor: NSTextView, window: NSWindow,
                                    offset: Int, wrapped: Bool, overflow: Bool = false) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.display()
        let selection = NSRange(location: offset, length: 0)
        #expect(editor.selectedRange() == selection)
        #expect(window.firstResponder === editor && field.currentEditor() === editor)
        let before = editor.firstRect(forCharacterRange: selection, actualRange: nil)
        let manager = try #require(editor.textLayoutManager)
        var lines: [NSRange] = []
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            lines.append(contentsOf: fragment.textLineFragments.map(\.characterRange))
            return true
        }
        #expect(editor.textLayoutManager === manager)
        #expect(editor.selectedRange() == selection)
        #expect(editor.firstRect(forCharacterRange: selection, actualRange: nil) == before)
        if wrapped {
            #expect(lines.count > 1)
        } else {
            #expect(lines == [NSRange(location: 0, length: (editor.string as NSString).length)])
        }
        let visible = field.visibleRect.intersection(field.bounds).insetBy(dx: -2, dy: -2)
        let caret = field.convert(window.convertFromScreen(before), from: nil)
        #expect(caret.height > 0 && caret.minX.isFinite && caret.minY.isFinite)
        #expect(caret.minX >= visible.minX && caret.maxX <= visible.maxX)
        #expect(caret.minY >= visible.minY && caret.maxY <= visible.maxY)
        if overflow {
            #expect(wrapped ? editor.visibleRect.minY > 0 : editor.visibleRect.minX > 0)
        }
    }


    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate())
    }
}
