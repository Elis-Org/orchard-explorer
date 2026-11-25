import AppKit
import SwiftUI
import ExplorerCore

private enum ExplorerPalette {
    static let navigation = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .controlBackgroundColor : NSColor(srgbRed: 0.953, green: 0.957, blue: 0.965, alpha: 1)
    })
    static let border = Color(nsColor: .separatorColor)
    static let background = Color(nsColor: .textBackgroundColor)
    static let field = Color(nsColor: NavigationFieldSurface.color)
    static let blue = Color(nsColor: .systemBlue)
}

/// A nonmodal projection of the store-owned command; this view owns no task,
/// provider state or selection and does not move keyboard focus.
struct CloudCommandProgressRow: View {
    let progress: CloudCommandProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10.pt) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3.pt) {
                Text(progress.itemName).font(.system(size: 12.pt)).lineLimit(1).truncationMode(.middle)
                Text(progress.statusText).font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloud-command-status")
            }
            Spacer(minLength: 8.pt)
            Button(scaled: "Cancel", action: cancel)
                .accessibilityIdentifier("cloud-command-cancel")
        }
        .padding(10.pt)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud-command-progress")
    }
}

// UI-SHELL-001/003, UI-TAB-001 / AT-UISHELL-001/003, AT-UITAB-001.
// Bands derive from EV-0211 + EV-0212 and the design-token register. Their
// point values are a comparison baseline, not a claimed Windows DPI conversion.
struct ExplorerShell: View {
    @ObservedObject var store: ExplorerStore
    @StateObject private var searchPresentation = SearchFieldDraft()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ExplorerTabStrip(store: store, width: geometry.size.width)
                navigationBar(width: geometry.size.width)
                commandBar(layout: ExplorerLayout(width: geometry.size.width))
                Rectangle().fill(ExplorerPalette.border).frame(height: 1)
                HStack(spacing: 0) {
                    if ExplorerLayout(width: geometry.size.width).showsSidebar {
                        ExplorerSidebar(store: store).frame(width: ExplorerLayout(width: geometry.size.width).sidebarWidth)
                        Rectangle().fill(Color(white: 0.9)).frame(width: 1)
                    }
                    content
                    if store.inspectorPane.mode != .none && ExplorerLayout(width: geometry.size.width).canShowDetailsPane {
                        let layout = ExplorerLayout(width: geometry.size.width)
                        let available = max(220, (geometry.size.width - layout.sidebarWidth) / ExplorerScale.factor - 200)
                        InspectorDivider(width: store.inspectorPane.width, available: available) {
                            store.resizeInspectorPane(to: $0, available: available)
                        }.frame(width: 7.pt)
                        Group {
                            if store.showsPreviewPane { ItemPreviewView(model: store.preview, focus: store.focus) }
                            else { ItemDetailsView(store: store) }
                        }
                        .frame(width: min(store.inspectorPane.width, available).pt)
                    }
                }
                if store.inspectorPane.mode != .none && !ExplorerLayout(width: geometry.size.width).canShowDetailsPane {
                    Text("Make the window wider to show the \(store.showsPreviewPane ? "Preview" : "Details") pane.")
                        .font(.system(size: 11.pt)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8.pt)
                        .accessibilityIdentifier("details-pane-narrow-notice")
                }
                statusBar(width: geometry.size.width)
            }
            .background(ExplorerPalette.background)
            .foregroundStyle(Color.primary)
            .font(.system(size: 12.pt))
            .controlSize(ExplorerScale.controlSize)
            .onAppear { store.setPreviewSurfaceVisible(ExplorerLayout(width: geometry.size.width).canShowDetailsPane) }
            .onChange(of: geometry.size.width) { _, width in
                store.setPreviewSurfaceVisible(ExplorerLayout(width: width).canShowDetailsPane)
            }
        }
        .onDisappear { store.setPreviewSurfaceVisible(false) }
        .ignoresSafeArea()
        .sheet(isPresented: Binding(
            get: { store.transfer != nil || store.trashProgress != nil || store.archiveProgress != nil || store.isShowingRecovery || store.archiveDeleteConfirmation != nil || store.recentOpenConfirmation != nil || store.shortcutDraft != nil || store.finderTagEditor != nil || store.nameEdit?.homeOrigin != nil },
            set: { presented in
                guard !presented else { return }
                if store.transfer != nil { store.cancelTransfer() }
                else if store.trashProgress != nil { store.cancelTrash() }
                else if store.archiveProgress != nil { store.cancelArchive() }
                else if store.archiveDeleteConfirmation != nil { store.cancelArchiveDelete() }
                else if let editor = store.finderTagEditor { if !editor.isApplying { store.cancelFinderTagEditing() } }
                else if store.recentOpenConfirmation != nil { store.cancelRecentOpen() }
                else if store.shortcutDraft != nil { store.cancelShortcutDraft() }
                else if store.nameEdit?.homeOrigin != nil { store.cancelNameEdit() }
                else { store.dismissRecovery() }
            }
        )) {
            Group {
                if store.transfer != nil { TransferProgressView(store: store) }
                else if store.trashProgress != nil { TrashProgressView(store: store) }
                else if store.archiveProgress != nil { ArchiveProgressView(store: store) }
                else if let edit = store.nameEdit, edit.homeOrigin != nil {
                    VStack(alignment: .leading, spacing: 12.pt) {
                        Text("Rename").font(.headline)
                        HomeRenameField(store: store, edit: edit).frame(height: 24.pt)
                        if let error = edit.errorMessage { Text(error).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            Spacer()
                            Button(scaled: "Cancel") { store.cancelNameEdit(sessionID: edit.id) }
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("home-rename-cancel")
                            Button(scaled: "Rename") { store.commitNameEdit(sessionID: edit.id) }
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("home-rename-submit")
                        }
                    }
                    .disabled(edit.isSubmitting)
                    .padding(20.pt).frame(width: 400.pt)
                }
                else if let confirmation = store.archiveDeleteConfirmation {
                    VStack(alignment: .leading, spacing: 16.pt) {
                        Text("Permanently delete from ZIP?").font(.system(size: 15.pt, weight: .semibold))
                        Text("Delete \(confirmation.entries.count) selected item\(confirmation.entries.count == 1 ? "" : "s") and any contents from \(confirmation.context.location.archiveURL.lastPathComponent)? These items will not go to the Trash.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(confirmation.entries.map(\.item.name).joined(separator: ", ")).lineLimit(4)
                        HStack {
                            Spacer()
                            Button(scaled: "Yes", action: store.confirmArchiveDelete)
                                .accessibilityIdentifier("archive-delete-confirm")
                            Button(scaled: "No", action: store.cancelArchiveDelete)
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("archive-delete-cancel")
                        }
                    }
                    .padding(24.pt).frame(width: 460.pt)
                    .onExitCommand(perform: store.cancelArchiveDelete)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("archive-delete-confirmation")
                }
                else if let editor = store.finderTagEditor {
                    FinderTagEditorView(editor: editor, apply: store.applyFinderTagEdits, cancel: store.cancelFinderTagEditing)
                }
                else if let confirmation = store.recentOpenConfirmation {
                    VStack(alignment: .leading, spacing: 14.pt) {
                        Text("Open the file currently at this location?").font(.system(size: 15.pt, weight: .semibold))
                        Text("\(AppIdentity.name) could not verify this is the document you opened before. Opening the current file will update Recent.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(confirmation.candidate.url.path).lineLimit(3).truncationMode(.middle)
                        HStack {
                            Spacer()
                            Button(scaled: "Open Current File") { store.confirmRecentOpen(confirmation) }
                                .accessibilityIdentifier("recent-open-confirm")
                            Button(scaled: "Cancel", action: store.cancelRecentOpen)
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("recent-open-cancel")
                        }
                    }
                    .padding(24.pt).frame(width: 460.pt)
                    .onExitCommand(perform: store.cancelRecentOpen)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recent-open-confirmation")
                }
                else if store.isShowingRecovery { RecentlyTrashedView(store: store) }
                else if let draft = store.shortcutDraft { ShortcutSheet(store: store, draft: draft) }
            }
            .interactiveDismissDisabled(true)
            .font(.system(size: 12.pt))
            .controlSize(ExplorerScale.controlSize)
        }
    }

    private func navigationBar(width: CGFloat) -> some View {
        let layout = ExplorerLayout(width: width)
        return HStack(spacing: 6.pt) {
            HStack(spacing: 0) {
                chromeButton("arrow.left", "Back", enabled: store.canGoBack, action: store.back)
                chromeButton("arrow.right", "Forward", enabled: store.activeTab.history.canGoForward, action: store.forward)
                chromeButton("arrow.up", "Up", enabled: store.activeTab.history.parent != nil, action: store.up)
                chromeButton("arrow.clockwise", "Refresh", action: store.refresh)
            }
            .frame(width: layout.navigationButtonWidth * 4)
            if layout.showsAddress {
                AddressBar(store: store).frame(minWidth: 0).frame(height: 32.pt).clipped()
                Group {
                    if layout.showsInlineSearch {
                        ExplorerSearchField(store: store)
                    } else {
                        // Narrow windows keep the field in a popover (native adaptation).
                        Button { searchPresentation.showsPopover = true } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 11.pt))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(ChromeButtonStyle())
                        .foregroundStyle(store.isSearching ? Color.accentColor : .secondary)
                        .disabled(!store.canSearch)
                        .accessibilityLabel("Search")
                        .help("Search file names (⌘F).")
                        .popover(isPresented: $searchPresentation.showsPopover, arrowEdge: .bottom) {
                            ExplorerSearchField(store: store, autoFocus: true) { searchPresentation.showsPopover = false }
                                .frame(width: 260.pt).padding(10.pt)
                        }
                    }
                }
                .padding(.horizontal, layout.showsInlineSearch ? 12.pt : 0)
                .frame(width: layout.showsInlineSearch ? max(145.pt, min(260.pt, width * 0.23)) : 35.pt, height: 32.pt)
                .background(ExplorerPalette.field, in: RoundedRectangle(cornerRadius: 4.pt))
                .onChange(of: store.searchFocusRequest) { _, _ in
                    if !layout.showsInlineSearch { searchPresentation.showsPopover = true }
                }
            }
        }
        .padding(.trailing, layout.showsAddress ? 12.pt : 0)
        .frame(height: 50.pt)
        .background(ExplorerPalette.navigation)
        .overlay(alignment: .bottom) { Rectangle().fill(ExplorerPalette.border).frame(height: 1) }
        .accessibilityIdentifier("navigation-bar")
    }

    private func commandBar(layout: ExplorerLayout) -> some View {
        Group {
            if layout.commandMode == .full {
                ViewThatFits(in: .horizontal) {
                    commandBarContent(mode: .full)
                    commandBarContent(mode: .compact)
                }
            } else {
                commandBarContent(mode: layout.commandMode)
            }
        }
        .frame(height: 46.pt)
        .clipped()
        .accessibilityIdentifier("command-bar")
    }

    private func commandBarContent(mode: ExplorerLayout.CommandMode) -> some View {
        HStack(spacing: 8.pt) {
            if mode != .minimal {
                Menu { newOptions } label: { menuLabel("New", "plus.circle") }
                    .menuOrder(.fixed)
                    .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize()
                    .disabled(!store.canCreateFolder)
                    .accessibilityLabel("New")
                    .help("Create a new item")
                separator
                command("scissors", "Cut", showsTitle: false, disabled: !store.canCutSelection, action: store.cutSelection)
                command("square.on.square", "Copy", showsTitle: false, disabled: !store.canCopySelection, action: store.copySelection)
            }
            if mode == .full {
                command("clipboard", "Paste", showsTitle: false, disabled: !store.canPaste, action: store.pasteSelection)
                command("rectangle.and.pencil.and.ellipsis", "Rename", showsTitle: false,
                        disabled: !store.canRenameSelection, action: store.beginRename)
                command("square.and.arrow.up", "Share", showsTitle: false, disabled: true)
                command("trash", store.deleteActionTitle, showsTitle: false,
                        disabled: !store.canDeleteSelection, action: store.deleteSelection)
                separator
                Menu { sortOptions } label: { menuLabel("Sort", "arrow.up.arrow.down") }
                    .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize().accessibilityLabel("Sort")
                    .disabled(!store.canSortItems)
                Menu { viewOptions } label: { menuLabel("View", "list.bullet") }
                    .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize().accessibilityLabel("View")
                if store.isSearching {
                    separator
                    // UI-SEARCH-001 / EV-0347/0348 / AT-UISEARCH-001; MAC-063 entries.
                    Menu { searchOptions } label: { menuLabel("Search options", "line.3.horizontal.decrease.circle") }
                        .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize()
                        .disabled(!store.canSearch)
                        .accessibilityLabel("Search options")
                    Button(action: store.closeSearch) { Label("Close search", systemImage: "xmark") }
                        .buttonStyle(ChromeButtonStyle())
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(!store.canSearch)
                        .accessibilityLabel("Close search")
                        .help("Return to the folder (Esc in the search box).")
                }
                separator
            }
            Menu {
                if mode == .minimal {
                    Menu { newOptions } label: { Label("New", systemImage: "plus.circle") }
                        .menuOrder(.fixed)
                        .disabled(!store.canCreateFolder)
                    Button(scaled: "Cut", action: store.cutSelection).disabled(!store.canCutSelection)
                    Button(scaled: "Copy", action: store.copySelection).disabled(!store.canCopySelection)
                }
                if mode != .full {
                    Button(scaled: "Paste", action: store.pasteSelection).disabled(!store.canPaste)
                    Button(scaled: "Rename", action: store.beginRename).disabled(!store.canRenameSelection)
                    Button(scaled: store.deleteActionTitle, action: store.deleteSelection).disabled(!store.canDeleteSelection)
                }
                Button(scaled: "Move Here", action: store.moveHere).disabled(!store.canMoveHere)
                Button(scaled: "Properties", action: store.showProperties).disabled(!store.canShowProperties)
                Divider()
                Button(scaled: "Undo Rename", action: store.undoRename).disabled(!store.canUndoRename)
                Button(scaled: "Redo Rename", action: store.redoRename).disabled(!store.canRedoRename)
                Button(scaled: "Recently Trashed…", action: store.showRecovery).disabled(!store.canShowRecovery)
                Divider()
                Button(scaled: "Open Folder…", action: store.chooseFolder)
                    .disabled(store.isPerformingOperation)
                Button(scaled: "Refresh", action: store.refresh)
                    .disabled(store.nameEdit != nil || store.isPerformingOperation)
                Button(scaled: "Pin Current Folder to Quick Access", action: store.pinCurrentFolder)
                    .disabled(!store.canPinCurrentFolder)
                    .disabled(!store.activeTab.hasLoaded)
                if mode != .full {
                    Divider()
                    Menu("Sort") { sortOptions }.disabled(!store.canSortItems)
                    Menu("View") { viewOptions }
                    if store.isSearching {
                        Menu("Search options") { searchOptions }.disabled(!store.canSearch)
                        Button(scaled: "Close search", action: store.closeSearch).disabled(!store.canSearch)
                    }
                }
                if store.isSearching {
                    Divider()
                    Button(scaled: "Open File Location", action: store.openSelectedSearchResultLocation)
                        .disabled(!store.canOpenSearchResultLocation)
                }
            } label: {
                HStack(spacing: 3.pt) {
                    Image(systemName: "ellipsis").font(.system(size: 14.pt))
                    Image(systemName: "chevron.down").font(.system(size: 7.pt, weight: .semibold))
                }
                .frame(minWidth: 34.pt, minHeight: 30.pt).contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("More options")
            }
                .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
            Spacer(minLength: 0)
            Button(action: store.toggleInspectorPane) {
                Label(store.inspectorPane.lastMode == .preview ? "Preview" : "Details", systemImage: "sidebar.right")
            }
            .buttonStyle(ChromeButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(store.inspectorPane.mode != .none ? Color.accentColor : Color.primary)
            .disabled(!store.canToggleDetailsPane)
            .accessibilityLabel(store.inspectorPane.lastMode == .preview ? "Preview pane" : "Details pane")
            .accessibilityIdentifier("inspector-pane-toggle")
            .accessibilityValue(store.inspectorPane.mode != .none ? "Shown" : "Hidden")
            .help("Show or hide the selected inspector pane.")
        }
        .padding(.horizontal, mode == .full ? 18.pt : 12.pt)
    }

    @ViewBuilder private var sortOptions: some View {
        ForEach(SortKey.allCases, id: \.rawValue) { key in
            Button { store.sort(by: key) } label: {
                if store.activeTab.sort.key == key { Label(sortTitle(key), systemImage: "checkmark") }
                else { Text(sortTitle(key)) }
            }
        }
        Divider()
        Button { store.setSortAscending(true) } label: {
            if store.activeTab.sort.ascending { Label("Ascending", systemImage: "checkmark") }
            else { Text("Ascending") }
        }
        Button { store.setSortAscending(false) } label: {
            if !store.activeTab.sort.ascending { Label("Descending", systemImage: "checkmark") }
            else { Text("Descending") }
        }
    }

    @ViewBuilder private var searchOptions: some View {
        if let search = store.activeSearch {
            ForEach(SearchScope.allCases, id: \.rawValue) { scope in
                Button { store.setSearchScope(scope) } label: { checked(scope.title, search.query.scope == scope) }
            }
            Divider()
            Menu("Date modified") {
                Button { store.setSearchDate(nil) } label: { checked("Any date", search.query.filters.dateModified == nil) }
                ForEach(SearchDateFilter.allCases, id: \.rawValue) { date in
                    Button { store.setSearchDate(date) } label: { checked(date.title, search.query.filters.dateModified == date) }
                }
            }
            Menu("Kind") {
                Button { store.setSearchKind(nil) } label: { checked("Any kind", search.query.filters.kind == nil) }
                ForEach(SearchKindFilter.allCases, id: \.rawValue) { kind in
                    Button { store.setSearchKind(kind) } label: { checked(kind.title, search.query.filters.kind == kind) }
                }
            }
            Menu("Size") {
                Button { store.setSearchSize(nil) } label: { checked("Any size", search.query.filters.size == nil) }
                ForEach(SearchSizeFilter.allCases, id: \.rawValue) { size in
                    Button { store.setSearchSize(size) } label: { checked(size.title, search.query.filters.size == size) }
                }
            }
        }
    }

    @ViewBuilder private func checked(_ title: String, _ isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder private var viewOptions: some View {
        if store.activePage == nil {
            ForEach(FolderViewMode.allCases, id: \.rawValue) { mode in
                Button { store.setViewMode(mode) } label: {
                    if store.activeTab.viewMode == mode { Label(mode.title, systemImage: "checkmark") }
                    else { Text(mode.title) }
                }
                .disabled(!store.canChangeViewMode)
            }
            Divider()
        }
        Button(action: store.toggleDetailsPane) {
            if store.showsDetailsPane { Label("Details pane", systemImage: "checkmark") }
            else { Text("Details pane") }
        }
        .disabled(!store.canToggleDetailsPane)
        Button(action: store.togglePreviewPane) {
            if store.showsPreviewPane { Label("Preview pane", systemImage: "checkmark") }
            else { Text("Preview pane") }
        }
        .disabled(!store.canToggleDetailsPane)
        Button { store.toggleHidden() } label: {
            if store.showHidden { Label("Show hidden files", systemImage: "checkmark") }
            else { Text("Show hidden files") }
        }
    }

    /// Command-bar menu label: blue glyph, title and a small chevron at the interface scale.
    /// Decorative glyphs are hidden from accessibility: the menu is one named control.
    private var newOptions: some View {
        ForEach(NewCommand.allCases, id: \.rawValue) { command in
            Button { store.runNewCommand(command) } label: {
                Label(command.title, systemImage: command.symbol)
            }
            .accessibilityIdentifier("new-\(command.rawValue)")
        }
    }

    private func menuLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6.pt) {
            Image(systemName: symbol).font(.system(size: 14.pt)).foregroundStyle(ExplorerPalette.blue)
            Text(title).font(.system(size: 12.pt))
            Image(systemName: "chevron.down").font(.system(size: 7.pt, weight: .semibold))
        }
        .frame(minHeight: 30.pt).contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var separator: some View {
        Rectangle().fill(Color(white: 0.88)).frame(width: 1, height: 20.pt).padding(.horizontal, 2.pt)
    }

    private func command(_ symbol: String, _ title: String, showsTitle: Bool = true, disabled: Bool,
                         action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 7.pt) {
                Image(systemName: symbol).font(.system(size: 14.pt)).foregroundStyle(ExplorerPalette.blue)
                if showsTitle { Text(title); Image(systemName: "chevron.down").font(.system(size: 7.pt)) }
            }.frame(minWidth: showsTitle ? 58 : 30, minHeight: 30.pt)
        }
        .buttonStyle(ChromeButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(title)
        .help(commandHelp(title))
    }

    private func commandHelp(_ title: String) -> String {
        switch title {
        case "Cut": return "Cut the selected items (⌘X)."
        case "Copy": return "Copy the selected items (⌘C)."
        case "Paste": return "Paste items into this folder (⌘V)."
        case "Rename": return "Rename the selected item (F2)."
        case "Move to Trash": return "Move the selected items to Trash (⌘⌫)."
        case "Delete": return "Permanently delete the selected ZIP contents after confirmation."
        default: return "\(title) is not available in this version."
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let progress = store.cloudCommandProgress {
                CloudCommandProgressRow(progress: progress, cancel: store.cancelCloudCommand)
            }
            if let notice = store.operationNotice {
                HStack(alignment: .top, spacing: 8.pt) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    if notice.count > 280 {
                        // Long reports (e.g. every original kept by a move) scroll rather than truncate.
                        ScrollView(.vertical) {
                            Text(notice).font(.system(size: 12.pt)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 96.pt)
                        .accessibilityIdentifier("operation-notice-scroll")
                    } else {
                        Text(notice).font(.system(size: 12.pt)).lineLimit(4).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if let issue = store.operationAccessIssue {
                        Button(scaled: "Access Help…") { store.showAccessHelp(issue) }
                            .disabled(store.isPerformingOperation)
                    }
                    Button(scaled: "Dismiss", action: store.dismissOperationNotice)
                }
                .padding(12.pt)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityIdentifier("operation-notice")
            }
            if let edit = store.nameEdit, let error = edit.errorMessage {
                HStack(alignment: .top, spacing: 9.pt) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4.pt) {
                        Text(error).font(.system(size: 12.pt)).lineLimit(4).textSelection(.enabled)
                        Text(edit.accessIssue == nil ? "Edit the name and press Return to try again." : "Review access, then press Return to try again.").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let issue = edit.accessIssue {
                        Button(scaled: "Access Help…") { store.showAccessHelp(issue) }
                    }
                    Button(scaled: "Cancel") { store.cancelNameEdit(sessionID: edit.id) }
                }
                .padding(12.pt)
                .background(Color.orange.opacity(0.08))
                .accessibilityIdentifier("name-edit-error")
            }
            if let warning = store.observationWarning {
                HStack(alignment: .top, spacing: 8.pt) {
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary)
                    Text(warning).font(.system(size: 11.pt)).lineLimit(3)
                    Spacer(minLength: 0)
                    Button(scaled: "Refresh", action: store.refresh)
                }
                .padding(10.pt)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityIdentifier("observation-warning")
            }
            if let search = store.activeSearch { searchBanner(search) }
            if let error = store.activeTab.errorMessage {
                HStack(alignment: .top, spacing: 9.pt) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12.pt)).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let issue = store.activeTab.accessIssue {
                        Button(scaled: "Access Help…") { store.showAccessHelp(issue) }
                            .disabled(store.isPerformingOperation)
                    }
                    Button(scaled: "Retry", action: store.retry)
                    Button { store.dismissError() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss error")
                }
                .padding(12.pt)
                .background(Color.orange.opacity(0.08))
                .accessibilityIdentifier("navigation-error")
            }
            ZStack(alignment: .top) {
                Group {
                    if let page = store.activePage {
                        ExplorerHomeView(store: store, page: page)
                    } else if store.activeTab.viewMode == .details {
                        DetailsTableView(store: store).padding(.leading, 16.pt)
                    } else {
                        FileCollectionView(store: store)
                    }
                }
                    .frame(minWidth: 0).clipped()
                    .allowsHitTesting(!showsUnavailableFolder && !store.isPerformingOperation)
                    .opacity(showsUnavailableFolder ? 0.5 : 1)
                if store.activeTab.isLoading {
                    HStack(spacing: 8.pt) {
                        ProgressView().controlSize(.small)
                        Text("Loading folder…").foregroundStyle(.secondary)
                    }
                    .padding(10.pt)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6.pt))
                    .padding(.top, 45.pt)
                    .allowsHitTesting(false)
                } else if let message = store.activeSearch?.emptyMessage {
                    // FR-SEARCH-004 / EV-0349/0350: a settled zero-result search is distinct.
                    Text(message)
                        .foregroundStyle(.secondary)
                        .padding(.top, 58.pt)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("search-empty-state")
                } else if store.isSearching {
                    EmptyView()
                } else if store.activeTab.isUnavailable || !store.activeTab.hasLoaded {
                    Text(store.activeTab.hasLoaded
                         ? "Folder unavailable. Showing the last loaded contents."
                         : "Folder unavailable. Choose another folder or retry.")
                        .foregroundStyle(.secondary)
                        .padding(10.pt)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6.pt))
                        .padding(.top, 58.pt)
                        .allowsHitTesting(false)
                } else if store.activePage == nil && store.activeTab.items.isEmpty && store.activeTab.errorMessage == nil && store.nameEdit == nil {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 58.pt)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(ExplorerPalette.background)
    }

    private var showsUnavailableFolder: Bool { store.activeTab.isUnavailable && !store.isSearching }

    /// MAC-064: searching, partial, cancelled and unavailable are distinct banners.
    @ViewBuilder private func searchBanner(_ search: SearchSession) -> some View {
        switch search.phase {
        case .complete:
            EmptyView()
        case .searching:
            HStack(spacing: 8.pt) {
                ProgressView().controlSize(.small)
                Text(search.progressText)
                    .font(.system(size: 12.pt)).lineLimit(1)
                Spacer(minLength: 8)
                Button(scaled: "Stop", action: store.stopSearch)
            }
            .padding(10.pt)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-progress")
        case .partial:
            HStack(alignment: .top, spacing: 8.pt) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(search.coverageSummary).font(.system(size: 12.pt)).lineLimit(3).textSelection(.enabled)
                    .help(search.coverage.unreadableSamples.map(\.path).joined(separator: "\n"))
                Spacer(minLength: 8)
                if let issue = search.accessIssue {
                    Button(scaled: "Access Help…") { store.showAccessHelp(issue) }.disabled(store.isPerformingOperation)
                }
            }
            .padding(10.pt)
            .background(Color.orange.opacity(0.08))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-partial")
        case .cancelled:
            HStack(spacing: 8.pt) {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Search stopped. Results found before stopping are shown; they may be incomplete.")
                    .font(.system(size: 12.pt)).lineLimit(2)
                Spacer(minLength: 8)
                Button(scaled: "Search Again", action: store.refresh).disabled(store.isPerformingOperation)
            }
            .padding(10.pt)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-cancelled")
        case .unavailable(let message):
            HStack(alignment: .top, spacing: 8.pt) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).font(.system(size: 12.pt)).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 8)
                if let issue = search.accessIssue {
                    Button(scaled: "Access Help…") { store.showAccessHelp(issue) }.disabled(store.isPerformingOperation)
                }
                Button(scaled: "Retry", action: store.refresh).disabled(store.isPerformingOperation)
            }
            .padding(10.pt)
            .background(Color.orange.opacity(0.08))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-unavailable")
        }
    }

    private func statusBar(width: CGFloat) -> some View {
        HStack(spacing: 12.pt) {
            if let page = store.activePage {
                Text(page.title).lineLimit(1)
            } else if let search = store.activeSearch {
                let count = search.displayedItems.count
                Text("\(count) \(count == 1 ? "item" : "items")").lineLimit(1)
                if let status = search.statusText {
                    Rectangle().fill(Color(white: 0.9)).frame(width: 1, height: 14.pt)
                    Text(status).lineLimit(1)
                }
            } else if store.activeTab.isUnavailable {
                Text("Folder unavailable").lineLimit(1)
            } else if !store.activeTab.hasLoaded {
                Text(store.activeTab.isLoading ? "Loading…" : "Folder unavailable")
            } else {
                Text("\(store.activeTab.items.count) \(store.activeTab.items.count == 1 ? "item" : "items")")
            }
            if store.isPerformingOperation {
                Text(store.transfer != nil ? "Transferring…" : store.trashProgress != nil ? "Moving to Trash…"
                     : store.archiveProgress != nil ? "Compressing…" : "Saving…").lineLimit(1)
            } else if let kind = store.nameEdit?.newItemKind {
                Text(kind.statusName).lineLimit(1)
            } else if !store.currentSelection.selectedIDs.isEmpty {
                Rectangle().fill(Color(white: 0.9)).frame(width: 1, height: 14.pt)
                Text(ExplorerLayout(width: width).showsFullSelectionStatus ? selectionSummary : "\(store.currentSelection.selectedIDs.count) selected").lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.activePage == nil {
                StatusViewButton(store: store).frame(width: 28.pt, height: 26.pt)
                if ExplorerLayout(width: width).showsSecondViewButton {
                    StatusViewButton(store: store, mode: .largeIcons, registersFocusStop: false)
                        .frame(width: 28.pt, height: 26.pt).padding(.trailing, 8.pt)
                }
            }
        }
        .font(.system(size: 11.pt))
        .padding(.leading, 14.pt)
        .frame(height: 28.pt)
        .background(ExplorerPalette.background)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.94)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-bar")
    }

    private var selectionSummary: String {
        let selected = store.displayedItems.filter { store.currentSelection.selectedIDs.contains($0.id) }
        let count = selected.count
        let prefix = "\(count) \(count == 1 ? "item" : "items") selected"
        let sizes = selected.compactMap(\.size)
        guard !sizes.isEmpty else { return prefix }
        let bytes = sizes.reduce(Int64(0)) { sum, size in
            let result = sum.addingReportingOverflow(size)
            return result.overflow ? Int64.max : result.partialValue
        }
        return prefix + "  \(bytes.formatted()) bytes"
    }

    private func sortTitle(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .modifiedAt: return "Date modified"
        case .kind: return "Type"
        case .size: return "Size"
        }
    }

    private func chromeButton(_ symbol: String, _ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14.pt)).frame(maxWidth: .infinity).frame(height: 30.pt)
        }
            .buttonStyle(ChromeButtonStyle())
            .disabled(!enabled)
            .accessibilityLabel(title)
            .help(title)
    }
}

// Shared semantic feedback for plain chrome controls. Pointer-associated fills
// are observed for Back/Refresh/More; other controls are native adaptations.
struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonContent(configuration: configuration)
    }
}

private struct ChromeButtonContent: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var hover = ChromeHoverState()

    private var showsHover: Bool { isEnabled && activeState == .key && hover.isHovered }

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isEnabled && configuration.isPressed ? 0.12 : (showsHover ? 0.06 : 0)))
            .overlay {
                if showsHover, contrast == .increased {
                    RoundedRectangle(cornerRadius: 3.pt).strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3.pt))
            // Retain geometry independently of feedback eligibility so a
            // stationary pointer can regain feedback when the control re-enables.
            .onHover { hover.isHovered = $0 }
            .onDisappear { hover.isHovered = false }
    }
}

// Match the existing search/recovery views: this CLT toolchain lacks the
// SwiftUI @State macro plugin, while ObservableObject storage is available.
private final class ChromeHoverState: ObservableObject {
    @Published var isHovered = false
}
