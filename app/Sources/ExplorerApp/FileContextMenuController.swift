import AppKit
import ExplorerCore

/// Shared file actions for the table and collection view. The caller establishes
/// and reconciles context-click selection before asking for a menu (FR-MENU-007/
/// 008/009); this helper does not own selection, responder routing or filesystem
/// operations. NATIVE-P18A / MAC-077: one native menu per context, ordered after
/// the v0.6 captures (EV-0271/0273, EV-0394, EV-0397, EV-0221/0479/0538); see
/// docs/CONTEXT_MENU_AUDIT.md for every command's disposition.
@MainActor
final class FileContextMenuController: NSObject {
    weak var store: ExplorerStore?
    private var presentation: FileContextMenuPanelController?
    private weak var homeOriginView: NSView?
    private(set) var pendingHome: Task<Void, Never>?
    private var pendingInputMonitor: Any?
    private var pendingObservers: [NSObjectProtocol] = []

    init(store: ExplorerStore) {
        self.store = store
    }

    /// Stable identifiers for tests and accessibility; titles may be localized.
    enum Command: String, CaseIterable {
        case cut, copy, rename, share, moveToTrash
        case open, openInNewTab, openInNewWindow, openWith, download, pin, oneDriveKeep, oneDriveFreeSpace
        case compress, copyPathname, properties, editTags
        case openInTerminal, showInFinder, makeAlias
        case view, sortBy, undoRename, redoRename, paste, moveHere, new, folderProperties
        case openFileLocation, closeSearch, removeFromRecent

        var glyph: MenuIcons.Glyph {
            switch self {
            case .cut: .cut
            case .copy: .copy
            case .rename: .rename
            case .share: .share
            case .moveToTrash: .delete
            case .open: .open
            case .openInNewTab: .newTab
            case .openInNewWindow: .newWindow
            case .openWith: .openWith
            case .download: .download
            case .oneDriveKeep: .keepOffline
            case .oneDriveFreeSpace: .freeSpace
            case .pin: .pin
            case .compress: .compress
            case .editTags: .tag
            case .copyPathname: .copyPath
            case .properties, .folderProperties: .properties
            case .openInTerminal: .terminal
            case .showInFinder: .finder
            case .makeAlias: .alias
            case .view: .view
            case .sortBy: .sort
            case .undoRename: .undo
            case .redoRename: .redo
            case .paste: .paste
            case .moveHere: .move
            case .new: .new
            case .openFileLocation: .location
            case .closeSearch, .removeFromRecent: .close
            }
        }
    }

    func menu(for item: FileItem?) -> NSMenu {
        guard let store else { return NSMenu() }
        return buildMenu(ContextMenuSnapshot(store: store, item: item), store: store)
    }

    func menu(for home: HomeFileMenuOrigin) -> ContextCommandMenu? {
        guard let store, home.matches(store) else { return nil }
        let item = home.clicked.flatMap { clicked in
            store.homeOperationEntries?.first { HomeFileLocations.pathKey($0.item.url) == HomeFileLocations.pathKey(clicked.row.url) }?.item
        }
        return buildMenu(ContextMenuSnapshot(store: store, item: item, home: home), store: store)
    }

    private func buildMenu(_ snapshot: ContextMenuSnapshot, store: ExplorerStore) -> ContextCommandMenu {
        let menu = ContextCommandMenu(snapshot: snapshot)
        menu.autoenablesItems = false
        // Services and other plug-in items are not part of the file command set.
        menu.allowsContextMenuPlugIns = false
        if snapshot.home != nil && !snapshot.isItemInvocation { addHomePaste(menu) }
        else if store.isSearching { buildSearchMenu(menu, item: snapshot.clickedItem, store: store) }
        else if snapshot.isItemInvocation { buildItemMenu(menu, store: store) }
        else { buildBackgroundMenu(menu, store: store) }
        // No leading, trailing or doubled separators.
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var index = 1
        while index < menu.items.count {
            if menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) }
            else { index += 1 }
        }
        return menu
    }

    /// Called only after the originating file view reconciles context selection.
    func present(for item: FileItem?, at point: NSPoint, in origin: NSView, keyboard: Bool) {
        dismissPresentedMenu()
        guard let menu = menu(for: item) as? ContextCommandMenu, !menu.items.isEmpty else { return }
        show(menu, at: point, in: origin, keyboard: keyboard)
    }

    @discardableResult
    func presentHome(row: HomeResultRow?, at point: NSPoint, in origin: NSView, keyboard: Bool) -> Bool {
        dismissPresentedMenu()
        guard let store, let window = origin.window, let home = HomeFileMenuOrigin(store: store, row: row) else { return false }
        homeOriginView = origin
        let state = store.homeFileOperations
        if row == nil || state.prepared != nil || state.preparation == nil || state.unavailable {
            guard let menu = menu(for: home) else { return false }
            show(menu, at: point, in: origin, keyboard: keyboard)
            return true
        }

        // The proof may arrive after another click or a window change. In that
        // case the old request must never put a panel underneath the new pointer.
        pendingInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.cancelPendingHome()
            return event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            pendingObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPendingHome() }
            })
        }
        let responder = window.firstResponder
        pendingHome = Task { [weak self, weak origin, weak window, weak responder, weak store] in
            guard let store else { return }
            await store.finishHomeSelectionPreparation(for: home.selection)
            guard !Task.isCancelled, let self else { return }
            self.finishPendingHome()
            guard let origin, let window, origin.window === window, window.isKeyWindow, NSApp.isActive,
                  !origin.isHiddenOrHasHiddenAncestor, window.firstResponder === responder,
                  self.homeOriginView === origin, let menu = self.menu(for: home) else { return }
            self.show(menu, at: point, in: origin, keyboard: keyboard)
        }
        return true
    }

    private func show(_ menu: ContextCommandMenu, at point: NSPoint, in origin: NSView, keyboard: Bool) {
        store?.cancelPointerRename()
        let panel = FileContextMenuPanelController(controller: self, menu: menu, origin: origin, point: point, keyboard: keyboard)
        presentation = panel
        panel.show()
    }

    private func cancelPendingHome() {
        pendingHome?.cancel()
        finishPendingHome()
    }

    private func finishPendingHome() {
        pendingHome = nil
        if let pendingInputMonitor { NSEvent.removeMonitor(pendingInputMonitor); self.pendingInputMonitor = nil }
        for observer in pendingObservers { NotificationCenter.default.removeObserver(observer) }
        pendingObservers.removeAll()
    }

    func dismissPresentedMenu(from view: NSView) {
        if homeOriginView === view { dismissPresentedMenu() }
    }

    func dismissPresentedMenu() {
        cancelPendingHome()
        homeOriginView = nil
        presentation?.dismiss(reason: .replacement)
        presentation = nil
    }

    func noteStaleRoute(_ item: NSMenuItem, snapshot: ContextMenuSnapshot, changedNames: [String]? = nil) {
        let routes = ["open", "openWith", "openInNewTab", "openInNewWindow", "openInTerminal", "download", "oneDriveKeep", "oneDriveFreeSpace", "editTags"].map { "context-" + $0 }
        guard routes.contains(item.identifier?.rawValue ?? ""), let store else { return }
        if let changedNames { store.noteContextRouteRefusal(changedNames: changedNames); return }
        var names: [String] = []
        if store.activeTabID == snapshot.tabID, store.activeTab.url == snapshot.location {
            if store.activeTab.directoryIdentity != snapshot.directoryIdentity || store.activeTab.archiveRevision != snapshot.archiveRevision {
                names = [BrowsingPresentation.title(snapshot.location)]
            } else {
                let listing = store.activeTab.search?.displayedItems ?? store.activeTab.items
                names = snapshot.items.filter { old in
                    !listing.contains { $0.id == old.id && $0.identity == old.identity && $0.archiveRevision == old.archiveRevision }
                }.map(\.name)
            }
        }
        store.noteContextRouteRefusal(changedNames: names)
    }

    func noteIdentityRefusal(_ item: NSMenuItem, snapshot: ContextMenuSnapshot, changedNames: [String]) {
        guard !changedNames.isEmpty else { return }
        noteStaleRoute(item, snapshot: snapshot, changedNames: changedNames)
        let actions = ["cut", "copy", "rename", "share", "moveToTrash"].map { "context-" + $0 }
        guard actions.contains(item.identifier?.rawValue ?? ""), let store, snapshot.matches(store) else { return }
        store.noteContextActionRefusal()
    }

    func commandIsEnabled(_ item: NSMenuItem, in menu: ContextCommandMenu) -> Bool {
        guard let store, menu.snapshot.matches(store), item.isEnabled else { return false }
        if menu.nativeShareItem === item {
            return menu.items.contains { $0 === item } && Self.shareIsVisible(menu.snapshot.items) && store.canShareSelection
        }
        guard let binding = item.target as? ContextMenuBinding, binding.controller === self,
              binding.belongs(to: menu) else { return false }
        return binding.isEnabled(item, in: store)
    }

    // MARK: Construction

    @discardableResult
    private func add(_ menu: ContextCommandMenu, _ title: String, _ command: Command, action: Selector,
                     enabled: @escaping (ExplorerStore) -> Bool,
                     revalidate: ((ExplorerStore, NSMenuItem) -> Bool)? = nil,
                     key: String = "", modifiers: NSEvent.ModifierFlags = [], object: Any? = nil,
                     image: NSImage? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.isEnabled = store.map(enabled) ?? false
        entry.identifier = NSUserInterfaceItemIdentifier("context-" + command.rawValue)
        entry.representedObject = object
        let binding = ContextMenuBinding(controller: self, menu: menu, item: entry, selector: action) { store, item in
            enabled(store) && (revalidate?(store, item) ?? true)
        }
        menu.bindings.append(binding)
        entry.target = binding
        entry.action = #selector(ContextMenuBinding.invokeContextCommand(_:))
        // Child rows share parent command identifiers but opt into their own artwork.
        entry.image = image ?? (menu.supermenu == nil ? command.glyph.image : nil)
        menu.addItem(entry)
        return entry
    }

    private func submenu(_ menu: ContextCommandMenu, _ title: String, _ command: Command, enabled: Bool = true) -> ContextCommandMenu {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.identifier = NSUserInterfaceItemIdentifier("context-" + command.rawValue)
        entry.isEnabled = enabled
        entry.image = command.glyph.image
        let child = ContextCommandMenu(title: title, snapshot: menu.snapshot)
        child.autoenablesItems = false
        entry.submenu = child
        menu.addItem(entry)
        return child
    }

    private static func singleItem(in store: ExplorerStore) -> FileItem? {
        let items = store.homeResultScope == nil ? store.selectedItemsInOrder : (store.homeOperationEntries ?? []).map(\.item)
        guard items.count == 1, let item = items.first, store.nameEdit?.rowID != item.id else { return nil }
        return item
    }

    private static func shareIsVisible(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { BrowsingPresentation.isPhysical($0) && !$0.isDirectory }
    }

    private static let f2 = String(UnicodeScalar(NSF2FunctionKey)!)

    private func openArtwork(for item: FileItem?) -> NSImage? {
        guard let item else { return nil }
        let artwork = FileActivationTarget(item).browsingURL == nil ? ExplorerIcons.icon(for: item) : ExplorerIcons.folder
        return MenuIcons.sizedCopy(artwork)
    }

    /// The store projects captured row/context metadata only. Menu construction
    /// does not stat, coordinate or query a provider; invocation revalidates.
    private func addDownload(_ menu: ContextCommandMenu, store: ExplorerStore) {
        guard let availability = store.downloadSelectionAvailability else { return }
        let item = add(menu, "Download", .download, action: #selector(downloadSelection),
                       enabled: { $0.canDownloadSelection })
        item.toolTip = availability.disabledReason
    }

    private func addOneDriveRetention(_ menu: ContextCommandMenu, store: ExplorerStore) {
        guard let availability = store.oneDriveRetentionSelectionAvailability else { return }
        let keep = add(menu, "Always Keep on This Device", .oneDriveKeep, action: #selector(keepOnDevice),
                       enabled: { $0.canChangeOneDriveRetention })
        let free = add(menu, "Free Up Space", .oneDriveFreeSpace, action: #selector(freeUpSpace),
                       enabled: { $0.canChangeOneDriveRetention })
        keep.toolTip = availability.disabledReason; free.toolTip = availability.disabledReason
    }

    /// File, folder and multiple-selection menus (UI-MENU-003/004, FR-MENU-001/003).
    private func buildItemMenu(_ menu: ContextCommandMenu, store: ExplorerStore) {
        let items = menu.snapshot.items
        let home = menu.snapshot.home
        guard !items.isEmpty || home?.clicked != nil else { return }
        let single = items.count == 1 ? items[0] : nil
        let singleFolder = single.flatMap { $0.isDirectory && store.nameEdit?.rowID != $0.id ? $0 : nil }
        let singleBrowsable = single.flatMap { FileActivationTarget($0).browsingURL != nil && store.nameEdit?.rowID != $0.id ? $0 : nil }

        // Windows compact action strip, in order: Cut, Copy, Rename, Share, Delete.
        add(menu, "Cut", .cut, action: #selector(cutSelection), enabled: { $0.canCutSelection }, key: "x", modifiers: .command)
        add(menu, "Copy", .copy, action: #selector(copySelection), enabled: { $0.canCopySelection }, key: "c", modifiers: .command)
        add(menu, "Rename", .rename, action: #selector(renameSelection), enabled: { $0.canRenameSelection }, key: Self.f2)
        if Self.shareIsVisible(items) {
            // Share ▸ — the native share menu (AirDrop, Mail, Messages…). Folders omit it, as in Windows.
            let share = NSSharingServicePicker(items: items.map { $0.url as NSURL }).standardShareMenuItem
            share.identifier = NSUserInterfaceItemIdentifier("context-" + Command.share.rawValue)
            share.isEnabled = store.canShareSelection
            menu.nativeShareItem = share
            menu.addItem(share)
        }
        add(menu, store.deleteActionTitle, .moveToTrash, action: #selector(trashSelection), enabled: { $0.canDeleteSelection },
            key: "\u{8}", modifiers: .command)
        menu.addItem(.separator())

        // Body (EV-0271 / EV-0394 / EV-0397 order).
        add(menu, "Open", .open, action: #selector(openSelection(_:)), enabled: { store in
            if let home { return store.isCommandIdle && home.rowIdentity(in: store) != nil }
            return store.canOpenSelection
        }, image: openArtwork(for: single))
        if let folder = singleBrowsable {
            add(menu, "Open in New Tab", .openInNewTab, action: #selector(openInNewTab(_:)),
                enabled: { Self.singleItem(in: $0).flatMap { FileActivationTarget($0).browsingURL } != nil
                    && (home == nil ? $0.canOpenInNewTab(folder) : $0.isCommandIdle) }, object: folder)
            add(menu, "Open in New Window", .openInNewWindow, action: #selector(openInNewWindow(_:)),
                enabled: { Self.singleItem(in: $0).flatMap { FileActivationTarget($0).browsingURL } != nil
                    && (home == nil ? $0.canOpenInNewTab(folder) : $0.isCommandIdle) }, object: folder)
        }
        if let file = store.openWithTarget, single != nil {
            buildOpenWith(menu, file: file, store: store)
        }
        addDownload(menu, store: store)
        addOneDriveRetention(menu, store: store)
        if let folder = singleFolder {
            let pinned = store.pins.contains(folder.url)
            add(menu, pinned ? "Unpin from Quick access" : "Pin to Quick access", .pin, action: #selector(togglePin(_:)),
                enabled: { Self.singleItem(in: $0)?.isDirectory == true
                    && $0.canPinFolder(folder.url) && $0.pins.contains(folder.url) == pinned }, object: folder.url,
                image: pinned ? MenuIcons.Glyph.unpin.image : nil)
        }
        let compress = submenu(menu, "Compress to", .compress, enabled: store.canCompressSelection)
        for format in ArchiveFormat.allCases {
            add(compress, format.title, .compress, action: #selector(compressSelection(_:)),
                enabled: { $0.canCompressSelection }, object: format.rawValue)
        }
        if home != nil { addHomePaste(menu) }
        add(menu, "Copy as Pathname", .copyPathname, action: #selector(copyPathnames), enabled: { $0.canCopyPathnames },
            key: "c", modifiers: [.command, .option])
        add(menu, "Properties", .properties, action: #selector(showProperties), enabled: { $0.canShowProperties },
            key: "i", modifiers: .command)
        menu.addItem(.separator())

        // Mac counterparts of the expanded menu and installed commands (MAC-077).
        if let folder = singleFolder {
            add(menu, "Open in Terminal", .openInTerminal, action: #selector(openInTerminal(_:)),
                enabled: { Self.singleItem(in: $0)?.isDirectory == true && $0.canOpenInTerminal(folder) }, object: folder)
        }
        add(menu, "Show in Finder", .showInFinder, action: #selector(showInFinder(_:)),
            enabled: { $0.canRevealInFinder }, object: items.map(\.url))
        add(menu, "Make Alias", .makeAlias, action: #selector(makeAliases), enabled: { $0.canMakeAliases })
        addTagEditing(menu, store: store)
        if home?.clicked?.row.recent != nil {
            menu.addItem(.separator())
            add(menu, "Remove from Recent", .removeFromRecent, action: #selector(removeFromRecent(_:)),
                enabled: { $0.isCommandIdle })
        }
    }

    private func addHomePaste(_ menu: ContextCommandMenu) {
        let row = menu.snapshot.home?.clicked?.row
        add(menu, "Paste", .paste, action: #selector(pasteSelection(_:)), enabled: { store in
            if let row, row.isDirectory { return store.canPaste(toHomeRow: row) }
            return store.canPaste
        }, key: "v", modifiers: .command)
    }

    /// Open With ▸ (FR-MENU-004): default app first, other capable apps, then Other….
    private func buildOpenWith(_ menu: ContextCommandMenu, file: FileItem, store: ExplorerStore) {
        let child = submenu(menu, "Open With", .openWith)
        let choices = store.applicationsToOpen(file)
        for (index, choice) in choices.enumerated() {
            let payload = OpenWithPayload(file: file, applicationURL: choice.url)
            add(child, choice.isDefault ? "\(choice.name) (default)" : choice.name, .openWith,
                action: #selector(openWith(_:)), enabled: { Self.isCurrentOpenWithTarget(file, in: $0) },
                revalidate: { store, item in
                    (item.representedObject as? OpenWithPayload) == payload
                        && store.applicationsToOpen(payload.file).contains { $0.url == payload.applicationURL }
                }, object: payload,
                image: MenuIcons.sizedCopy(store.applications.icon(forApplicationAt: choice.url)))
            if choice.isDefault, index == 0, choices.count > 1 { child.addItem(.separator()) }
        }
        if !choices.isEmpty { child.addItem(.separator()) }
        add(child, "Other…", .openWith, action: #selector(chooseApplication(_:)),
            enabled: { Self.isCurrentOpenWithTarget(file, in: $0) }, object: file)
    }

    /// Background menu (UI-MENU-001/006, FR-MENU-006/009).
    private func buildBackgroundMenu(_ menu: ContextCommandMenu, store: ExplorerStore) {
        let view = submenu(menu, "View", .view, enabled: store.canChangeViewMode)
        for mode in FolderViewMode.allCases {
            let entry = add(view, mode.title, .view, action: #selector(setViewMode(_:)), enabled: { $0.canChangeViewMode },
                            object: mode.rawValue, image: MenuIcons.viewMode(mode))
            entry.state = store.activeTab.viewMode == mode ? .on : .off
        }
        let sortEnabled: (ExplorerStore) -> Bool = { $0.canSortItems }
        let sort = submenu(menu, "Sort by", .sortBy, enabled: sortEnabled(store))
        for key in SortKey.allCases {
            let entry = add(sort, Self.sortTitle(key), .sortBy, action: #selector(sortBy(_:)), enabled: sortEnabled,
                            object: key.rawValue)
            entry.state = store.activeTab.sort.key == key ? .on : .off
        }
        sort.addItem(.separator())
        for (title, ascending) in [("Ascending", true), ("Descending", false)] {
            let entry = add(sort, title, .sortBy, action: #selector(setSortDirection(_:)), enabled: sortEnabled,
                            object: ascending)
            entry.state = store.activeTab.sort.ascending == ascending ? .on : .off
        }
        menu.addItem(.separator())
        // Session-dependent entries appear only when available (EV-0221 / EV-0479 / EV-0538).
        if store.canUndoRename {
            add(menu, "Undo Rename", .undoRename, action: #selector(undoRename), enabled: { $0.canUndoRename }, key: "z", modifiers: .command)
        }
        if store.canRedoRename {
            add(menu, "Redo Rename", .redoRename, action: #selector(redoRename), enabled: { $0.canRedoRename }, key: "z",
                modifiers: [.command, .shift])
        }
        if store.canPaste {
            add(menu, "Paste", .paste, action: #selector(pasteSelection(_:)), enabled: { $0.canPaste }, key: "v", modifiers: .command)
            add(menu, "Move Here", .moveHere, action: #selector(moveHere), enabled: { $0.canPaste && $0.canMoveHere }, key: "v", modifiers: [.command, .option])
        }
        let new = submenu(menu, "New", .new, enabled: store.canCreateFolder)
        for command in NewCommand.allCases {
            add(new, command.title, .new, action: #selector(createItem(_:)),
                enabled: { $0.canCreateFolder }, object: command.rawValue, image: MenuIcons.symbol(command.symbol))
        }
        add(menu, "Properties", .folderProperties, action: #selector(showFolderProperties),
            enabled: { $0.canShowFolderProperties }, key: "i", modifiers: .command)
        menu.addItem(.separator())
        let current = store.currentFolderItem
        add(menu, "Open in Terminal", .openInTerminal, action: #selector(openCurrentFolderInTerminal(_:)),
            enabled: { $0.canOpenCurrentFolderInTerminal }, object: current)
        add(menu, "Show in Finder", .showInFinder, action: #selector(showInFinder(_:)),
            enabled: { $0.activeTab.hasLoaded && $0.canRevealInFinder }, object: [current.url])
    }

    /// NATIVE-P14 / MAC-065: only result actions that revalidate actual parents.
    private func buildSearchMenu(_ menu: ContextCommandMenu, item: FileItem?, store: ExplorerStore) {
        guard item != nil else {
            add(menu, "Close Search", .closeSearch, action: #selector(closeSearch), enabled: { $0.canSearch })
            return
        }
        let idle: (ExplorerStore) -> Bool = { $0.nameEdit == nil && !$0.isPerformingOperation && !$0.isShowingRecovery }
        let selection = store.selectedItemsInOrder
        add(menu, "Open", .open, action: #selector(openSelection(_:)), enabled: { idle($0) && $0.canOpenSelection },
            image: openArtwork(for: selection.count == 1 ? selection.first : nil))
        addDownload(menu, store: store)
        add(menu, "Open File Location", .openFileLocation, action: #selector(openLocation),
            enabled: { $0.canOpenSearchResultLocation })
        menu.addItem(.separator())
        add(menu, "Cut", .cut, action: #selector(cutSelection), enabled: { $0.canCutSelection }, key: "x", modifiers: .command)
        add(menu, "Copy", .copy, action: #selector(copySelection), enabled: { $0.canCopySelection }, key: "c", modifiers: .command)
        add(menu, store.deleteActionTitle, .moveToTrash, action: #selector(trashSelection), enabled: { $0.canDeleteSelection },
            key: "\u{8}", modifiers: .command)
        add(menu, "Copy as Pathname", .copyPathname, action: #selector(copyPathnames), enabled: { $0.canCopyPathnames },
            key: "c", modifiers: [.command, .option])
        add(menu, "Properties", .properties, action: #selector(showProperties), enabled: { $0.canShowProperties },
            key: "i", modifiers: .command)
        menu.addItem(.separator())
        add(menu, "Show in Finder", .showInFinder, action: #selector(showInFinder(_:)), enabled: { idle($0) && $0.canRevealInFinder },
            object: selection.map(\.url))
        addTagEditing(menu, store: store)
    }

    private func addTagEditing(_ menu: ContextCommandMenu, store: ExplorerStore) {
        guard store.hasPhysicalSelection || menu.snapshot.home?.clicked != nil else { return }
        add(menu, "Tags…", .editTags, action: #selector(editTags), enabled: { $0.canEditSelectionTags })
    }

    static func sortTitle(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .modifiedAt: return "Date modified"
        case .kind: return "Type"
        case .size: return "Size"
        }
    }

    // MARK: Actions
    // Store methods recheck current operation/selection eligibility when invoked;
    // a menu's earlier enabled state is never authority to perform an operation.

    @objc private func editTags() { store?.beginSelectionTagEditing() }
    @objc private func renameSelection() { store?.beginRename() }
    @objc private func showProperties() { store?.showProperties() }
    @objc private func showFolderProperties() { store?.showFolderProperties() }
    @objc private func copySelection() { store?.copySelection() }
    @objc private func cutSelection() { store?.cutSelection() }
    @objc private func pasteSelection(_ sender: NSMenuItem) {
        if let row = homeOrigin(of: sender)?.clicked?.row, row.isDirectory { store?.pasteSelection(toHomeRow: row) }
        else { store?.pasteSelection() }
    }
    @objc private func moveHere() { store?.moveHere() }
    @objc private func trashSelection() { store?.deleteSelection() }
    @objc private func openLocation() { store?.openSelectedSearchResultLocation() }
    @objc private func closeSearch() { store?.closeSearch() }
    private func homeOrigin(of sender: NSMenuItem) -> HomeFileMenuOrigin? {
        (sender.menu as? ContextCommandMenu)?.snapshot.home
    }

    private func invokeHomeRow(_ action: ExplorerStore.PageItemAction, from sender: NSMenuItem) -> Bool {
        guard let home = homeOrigin(of: sender) else { return false }
        if let store, let row = home.clicked?.row, let identity = home.rowIdentity(in: store) {
            store.performHomeResultAction(action, row: row, in: home.selection.scope, identity: identity) { [weak store] in
                store.map { home.matches($0) } ?? false
            }
        }
        return true
    }

    @objc private func openSelection(_ sender: NSMenuItem) {
        if !invokeHomeRow(.open, from: sender) { store?.openSelection() }
    }

    @objc private func removeFromRecent(_ sender: NSMenuItem) {
        guard let store, let home = homeOrigin(of: sender), home.matches(store), let row = home.clicked?.row else { return }
        store.removeHomeRecent(row, in: home.selection.scope)
    }
    @objc private func downloadSelection() { store?.downloadSelection() }
    @objc private func keepOnDevice() { store?.performOneDriveRetention(.keep) }
    @objc private func freeUpSpace() { store?.performOneDriveRetention(.freeSpace) }
    @objc private func copyPathnames() { store?.copyPathnames() }
    @objc private func makeAliases() { store?.makeAliasesForSelection() }
    @objc private func undoRename() { store?.undoRename() }
    @objc private func redoRename() { store?.redoRename() }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        if invokeHomeRow(.newTab, from: sender) { return }
        guard let folder = sender.representedObject as? FileItem else { return }
        store?.openInNewTab(folder)
    }
    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        if invokeHomeRow(.newWindow, from: sender) { return }
        guard let folder = sender.representedObject as? FileItem else { return }
        store?.openInNewWindow(folder)
    }
    private static func isCurrentOpenWithTarget(_ file: FileItem, in store: ExplorerStore) -> Bool {
        guard let target = store.openWithTarget else { return false }
        return ExplorerStore.sameEntries([target], [file])
    }

    struct OpenWithPayload: Equatable {
        let file: FileItem
        let applicationURL: URL
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpenWithPayload else { return }
        store?.open(payload.file, withApplicationAt: payload.applicationURL)
    }
    @objc private func chooseApplication(_ sender: NSMenuItem) {
        guard let store, let file = sender.representedObject as? FileItem else { return }
        store.chooseApplicationAndOpen(file)
    }
    @objc private func compressSelection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = ArchiveFormat(rawValue: raw) else { return }
        store?.compressSelection(format)
    }
    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileItem else { return }
        store?.openInTerminal(folder)
    }
    @objc private func openCurrentFolderInTerminal(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FileItem else { return }
        store?.openCurrentFolderInTerminal(folder)
    }
    @objc private func showInFinder(_ sender: NSMenuItem) {
        if homeOrigin(of: sender) != nil { store?.revealSelectionInFinder(); return }
        guard let urls = sender.representedObject as? [URL] else { return }
        store?.revealInFinder(urls)
    }
    @objc private func setViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let mode = FolderViewMode(rawValue: raw) else { return }
        store?.setViewMode(mode)
    }
    @objc private func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        store?.sort(by: key)
    }
    @objc private func setSortDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        store?.setSortAscending(ascending)
    }
    @objc private func createItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = NewCommand(rawValue: raw) else { return }
        store?.runNewCommand(command)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        if invokeHomeRow(.togglePin, from: sender) { return }
        guard let store, !store.isPerformingOperation,
              let url = sender.representedObject as? URL else { return }
        guard store.canPinFolder(url) else { return }
        // The folder URL belongs to this menu invocation. Consult the current
        // shared pin state rather than assuming the menu title is still current.
        if store.pins.contains(url) { store.pins.unpin(url) }
        else { store.pins.pin(url) }
    }
}
