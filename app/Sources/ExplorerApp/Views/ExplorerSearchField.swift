import AppKit
import ExplorerCore
import SwiftUI

/// Command Line Tools lack the SwiftUI macro plugin, so local view state uses
/// ObservableObject storage (as RecoveryViews does) instead of @State.
@MainActor
final class SearchFieldDraft: ObservableObject {
    @Published var text = ""
    /// The committed query last copied into `text`; a different `text` is an
    /// unsubmitted draft that a view rebuild must keep (MAC-074).
    var synchronizedText: String?
    /// The tab and search the draft belongs to; a different one always resets it.
    var synchronizedContext: String?

    /// Adopt the committed query, except that a rebuilt field (`force` false) in
    /// the same tab and search keeps text the user typed but has not submitted.
    func synchronize(committed: String, context: String, force: Bool) {
        if !force, context == synchronizedContext, let last = synchronizedText, text != last { return }
        synchronizedContext = context
        synchronizedText = committed
        text = committed
    }
    @Published var showsPopover = false
    @Published var isFocused = false
}

/// FR-SEARCH-001 / EV-0343/0344 / AT-SEARCH-001, native ⌘F adaptation (MAC-062).
/// The draft stays local to the field; Return submits a filename search and
/// Escape or Clear returns to the original folder.
struct ExplorerSearchField: View {
    @ObservedObject var store: ExplorerStore
    var autoFocus = false
    var onSubmitted: (() -> Void)?
    /// Owned by the store so an unsubmitted query survives an interface-size rebuild.
    @ObservedObject private var draft: SearchFieldDraft

    init(store: ExplorerStore, autoFocus: Bool = false, onSubmitted: (() -> Void)? = nil) {
        self.store = store
        self.autoFocus = autoFocus
        self.onSubmitted = onSubmitted
        draft = store.searchFieldDraft
    }

    var body: some View {
        HStack(spacing: 6.pt) {
            SearchTextFieldRepresentable(draft: draft,
                                         placeholder: store.activePage == nil ? "Search \(store.activeTab.folderTitle)" : "Filter \(store.activeTab.folderTitle)",
                                         isEnabled: store.canSearch,
                                         focusRequest: store.searchFocusRequest,
                                         autoFocus: autoFocus,
                                         onSubmit: submit, onCancel: clear)
            if !draft.text.isEmpty || store.isSearching {
                Button(action: clear) {
                    Image(systemName: "xmark").font(.system(size: 10.pt, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!store.canSearch)
                .accessibilityLabel("Clear search")
                .help(store.activePage == nil ? "Clear the search and return to the folder (Esc)." : "Clear the page filter (Esc).")
            }
            Button(action: submit) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.pt))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!store.canSearch)
            .accessibilityLabel("Search")
            .help(store.activePage == nil ? "Search file names in this folder and its subfolders (Return)." : "Filter the items on this page by name (Return).")
        }
        .overlay(alignment: .bottom) {
            // EV-0343 shows an active blue underline while the field is focused.
            Rectangle().fill(Color.accentColor).frame(height: 2.pt).offset(y: 8.pt).opacity(draft.isFocused ? 1 : 0)
        }
        .onAppear { synchronize(force: false) }
        .onChange(of: store.activeTabID) { _, _ in synchronize(force: true) }
        .onChange(of: store.activeSearch?.id) { _, _ in synchronize(force: true) }
        .onChange(of: store.activePage) { _, _ in synchronize(force: true) }
        .onChange(of: store.activeTab.homeSection) { _, _ in synchronize(force: true) }
        .onChange(of: store.activeTab.pageFilter) { _, _ in synchronize(force: true) }
    }

    private func synchronize(force: Bool) {
        let context = store.activePage?.url.absoluteString ?? store.activeSearch?.id.uuidString ?? ""
        draft.synchronize(committed: store.activeSearch?.query.text ?? store.activeTab.pageFilter,
                          context: "\(store.activeTabID.uuidString):\(context)",
                          force: force)
    }

    private func submit() {
        store.submitSearch(draft.text)
        onSubmitted?()
    }

    private func clear() {
        draft.text = ""
        store.closeSearch()
    }
}

/// An editable field that is never chosen automatically as the window's initial
/// or Tab key view, so launching or switching layouts keeps file commands with
/// the file list. A click or ⌘F still focuses it (MAC-062).
final class ExplorerSearchTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override var canBecomeKeyView: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

struct SearchTextFieldRepresentable: NSViewRepresentable {
    @ObservedObject var draft: SearchFieldDraft
    let placeholder: String
    let isEnabled: Bool
    let focusRequest: Int
    let autoFocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ExplorerSearchTextField {
        let field = ExplorerSearchTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.pt)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("search-field")
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.draft.isFocused = focused
        }
        context.coordinator.lastFocusRequest = focusRequest
        if autoFocus {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: ExplorerSearchTextField, context: Context) {
        context.coordinator.parent = self
        // Typing keeps these equal; a tab switch or new session replaces the draft.
        if field.stringValue != draft.text { field.stringValue = draft.text }
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        field.setAccessibilityLabel(placeholder)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, field.isEnabled else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextFieldRepresentable
        var lastFocusRequest = 0

        init(_ parent: SearchTextFieldRepresentable) { self.parent = parent }


        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.draft.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.draft.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                textView.string = ""
                return true
            default:
                return false
            }
        }
    }
}

extension SearchSession {
    /// MAC-064: partial coverage names each reason; it never reads as complete.
    var coverageSummary: String {
        func count(_ value: Int, _ singular: String, _ plural: String) -> String {
            "\(value.formatted()) \(value == 1 ? singular : plural)"
        }
        var parts: [String] = []
        if coverage.unreadableFolders > 0 {
            parts.append("\(count(coverage.unreadableFolders, "folder", "folders")) couldn’t be read")
        }
        if coverage.changedFolders > 0 {
            parts.append("\(count(coverage.changedFolders, "folder", "folders")) changed during the search")
        }
        if coverage.otherVolumeFolders > 0 {
            parts.append("\(count(coverage.otherVolumeFolders, "folder is", "folders are")) on another volume")
        }
        if coverage.unavailableFolders > 0 {
            parts.append("\(count(coverage.unavailableFolders, "folder isn’t", "folders aren’t")) available locally")
        }
        if coverage.depthLimitedFolders > 0 {
            parts.append("\(count(coverage.depthLimitedFolders, "folder is", "folders are")) nested more than \(LocalFilenameSearcher.maximumDepth) levels deep")
        }
        if coverage.reachedResultLimit {
            parts.append("only the first \(results.count.formatted()) matches are shown")
        }
        guard !parts.isEmpty else { return "Search complete." }
        return "Some locations weren’t searched: " + parts.joined(separator: "; ") + "."
    }

    /// FR-SEARCH-003: the wording follows the selected scope.
    var progressText: String {
        guard query.scope == .allSubfolders else { return "Searching \(rootTitle)…" }
        let folders = coverage.foldersSearched
        return "Searching \(rootTitle) and its subfolders… \(folders.formatted()) \(folders == 1 ? "folder" : "folders") checked"
    }

    var emptyMessage: String? {
        guard displayedItems.isEmpty else { return nil }
        switch phase {
        case .searching: return "Searching…"
        case .complete: return "No items match your search."
        case .partial: return "No items match your search in the locations that were searched."
        case .cancelled: return "Search stopped before any matching items were found."
        case .unavailable: return nil
        }
    }

    var statusText: String? {
        switch phase {
        case .searching: return "Searching…"
        case .complete: return nil
        case .partial: return "Search incomplete"
        case .cancelled: return "Search stopped"
        case .unavailable: return "Search unavailable"
        }
    }
}
