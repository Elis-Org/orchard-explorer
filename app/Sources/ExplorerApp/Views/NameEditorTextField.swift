import AppKit

/// FR-FILE-002/008/018 / EV-0226 + EV-0227, EV-0232, EV-0235 /
/// AT-FILE-002/008/018. The native editor owns the draft and UTF-16 selection.
/// Return requests a write. Escape and focus loss cancel an unsubmitted draft.
@MainActor
final class NameEditorTextField: NSTextField, NSTextFieldDelegate {
    var onProposalChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var sessionID: UUID?
    private(set) var isSubmitting = false
    private var savedSelection: NSRange?
    private var idlePresentation: Presentation?

    private struct Presentation {
        let lineBreakMode: NSLineBreakMode
        let wraps: Bool
        let isScrollable: Bool
        let singleLine: Bool
        let maximumLines: Int
        let truncatesLastLine: Bool
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        maximumNumberOfLines = 1
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginSession(id: UUID, name: String, selection: NSRange) {
        guard sessionID != id else { return }
        if sessionID != nil { endEditingSession() }
        if let cell {
            idlePresentation = Presentation(lineBreakMode: lineBreakMode, wraps: cell.wraps,
                isScrollable: cell.isScrollable, singleLine: cell.usesSingleLineMode,
                maximumLines: maximumNumberOfLines, truncatesLastLine: cell.truncatesLastVisibleLine)
            // Stacked icons already use wrapped labels. Preserve that distinction
            // and each view's native single-line setting for pasted line breaks.
            if cell.wraps {
                lineBreakMode = .byWordWrapping
                cell.wraps = true
                cell.isScrollable = false
                maximumNumberOfLines = 0
                cell.truncatesLastVisibleLine = false
            } else {
                lineBreakMode = .byClipping
                cell.isScrollable = true
            }
        }
        sessionID = id
        stringValue = name
        savedSelection = selection
        isEnabled = true
        isEditable = true
        isSelectable = true
        isBordered = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .labelColor
        setAccessibilityIdentifier("inline-name-editor")
        superview?.needsLayout = true
        focusEditor(selection: selection)
    }

    func updateSession(proposedName: String, isSubmitting submitting: Bool, focusOwner: NSView? = nil) {
        guard let sessionID else { return }
        if submitting != isSubmitting {
            isSubmitting = submitting
            if submitting, let editor = ownedEditor {
                savedSelection = editor.selectedRange()
                window?.endEditing(for: self)
            }
            isEditable = !submitting
            isEnabled = !submitting
            if !submitting {
                restoreAfterRefusal(sessionID: sessionID, focusOwner: focusOwner)
            }
        }
        if currentEditor() == nil, !stringValue.utf8.elementsEqual(proposedName.utf8) {
            stringValue = proposedName
        }
    }

    private func restoreAfterRefusal(sessionID: UUID, focusOwner: NSView?) {
        let requiresListFocus = focusOwner != nil
        DispatchQueue.main.async { [weak self, weak focusOwner] in
            guard let self, self.sessionID == sessionID, !self.isSubmitting,
                  self.currentEditor() == nil else { return }
            if requiresListFocus {
                guard let focusOwner, let window = self.window, focusOwner.window === window,
                      window.firstResponder === focusOwner else { return }
            }
            let selection = self.savedSelection ?? NSRange(location: (self.stringValue as NSString).length, length: 0)
            self.focusEditor(selection: selection)
        }
    }

    func finishSession() {
        endEditingSession()
        onProposalChange = nil
        onCommit = nil
        onCancel = nil
        setAccessibilityIdentifier(nil)
        setAccessibilityLabel(nil)
    }

    private func endEditingSession() {
        guard sessionID != nil else { return }
        sessionID = nil
        if ownedEditor != nil { window?.endEditing(for: self) }
        isSubmitting = false
        savedSelection = nil
        isEnabled = true
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        if let presentation = idlePresentation, let cell {
            lineBreakMode = presentation.lineBreakMode
            cell.wraps = presentation.wraps
            cell.isScrollable = presentation.isScrollable
            cell.usesSingleLineMode = presentation.singleLine
            maximumNumberOfLines = presentation.maximumLines
            cell.truncatesLastVisibleLine = presentation.truncatesLastLine
        }
        idlePresentation = nil
        superview?.needsLayout = true
    }

    private var ownedEditor: NSTextView? {
        guard let editor = currentEditor() as? NSTextView, window?.firstResponder === editor else { return nil }
        return editor
    }

    private func focusEditor(selection: NSRange) {
        guard sessionID != nil, !isSubmitting, window?.makeFirstResponder(self) == true,
              let editor = ownedEditor else { return }
        let length = (editor.string as NSString).length
        let start = min(selection.location, length)
        let range = NSRange(location: start, length: min(selection.length, length - start))
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changedWidth, newSize.width > 0, let sessionID, let editor = ownedEditor {
            revealSelectionAfterLayout(in: editor, sessionID: sessionID)
        }
    }

    private func revealSelectionAfterLayout(in editor: NSTextView, sessionID: UUID) {
        // Paste can update the selection after delivering the text notification.
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.sessionID == sessionID, !self.isSubmitting,
                  self.ownedEditor === editor, !editor.hasMarkedText() else { return }
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let sessionID, !isSubmitting, let editor = ownedEditor else { return }
        onProposalChange?(editor.string)
        revealSelectionAfterLayout(in: editor, sessionID: sessionID)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === self, let sessionID, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !isSubmitting, ownedEditor === textView {
                let proposal = textView.string
                onProposalChange?(proposal)
                if self.sessionID == sessionID, !isSubmitting, ownedEditor === textView { onCommit?() }
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !isSubmitting, ownedEditor === textView { onCancel?() }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let sessionID, !isSubmitting else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == sessionID, !self.isSubmitting,
                  self.currentEditor() == nil else { return }
            self.onCancel?()
        }
    }
}
