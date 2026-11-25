import AppKit
import ExplorerCore

/// Identifies a Home occurrence independently of the file's other tag memberships.
@MainActor
struct HomeFileMenuOrigin {
    let selection: HomeOperationOrigin
    let clicked: HomeOperationOrigin.Occurrence?
    let focusedID: String?

    init?(store: ExplorerStore, row: HomeResultRow?) {
        guard let selection = store.homeOperationOrigin, store.isHomeOperationOriginCurrent(selection) else { return nil }
        self.selection = selection
        focusedID = store.activeTab.homeResults.selection.focusedID
        if let row {
            guard let member = selection.occurrences.first(where: { $0.row.represents(row) }) else { return nil }
            clicked = member
        } else { clicked = nil }
    }

    func matches(_ store: ExplorerStore) -> Bool {
        guard store.isHomeOperationOriginCurrent(selection),
              store.activeTab.homeResults.selection.focusedID == focusedID else { return false }
        guard let clicked else { return true }
        return store.homeResultMembership(clicked.row, in: selection.scope) == clicked.membership
    }

    func rowIdentity(in store: ExplorerStore) -> LocalFileIdentity? {
        guard matches(store), let clicked else { return nil }
        return store.activeTab.homeResults.target(of: clicked.row)?.identity
    }
}

/// MR-MENU-003: menu authority belongs to one invocation, never a later selection.
@MainActor
struct ContextMenuSnapshot {
    let tabID: UUID
    let location: URL
    let generation: UUID?
    let directoryIdentity: LocalFileIdentity?
    let archiveRevision: ArchiveRevision?
    let searchID: UUID?
    let searchGeneration: UUID?
    let items: [FileItem]
    let focusedID: String?
    let clickedItem: FileItem?
    let editorID: UUID?
    let home: HomeFileMenuOrigin?
    var isItemInvocation: Bool { clickedItem != nil || home?.clicked != nil }

    init(store: ExplorerStore, item: FileItem?, home: HomeFileMenuOrigin? = nil) {
        self.home = home
        tabID = store.activeTabID
        location = store.activeTab.url
        generation = store.contextMenuLoadGeneration
        directoryIdentity = store.activeTab.directoryIdentity
        archiveRevision = store.activeTab.archiveRevision
        searchID = store.activeTab.search?.id
        searchGeneration = store.activeTab.search?.generation
        items = home == nil ? store.selectedItemsInOrder : (store.homeOperationEntries ?? []).map(\.item)
        focusedID = store.currentSelection.focusedID
        clickedItem = item
        editorID = store.nameEdit?.id
    }

    func matches(_ store: ExplorerStore) -> Bool {
        if let home { return home.matches(store) && store.nameEdit?.id == editorID }
        return store.activeTabID == tabID && store.activeTab.url == location
            && store.contextMenuLoadGeneration == generation
            && store.activeTab.directoryIdentity == directoryIdentity
            && store.activeTab.archiveRevision == archiveRevision
            && store.activeTab.search?.id == searchID
            && store.activeTab.search?.generation == searchGeneration
            && store.currentSelection.focusedID == focusedID
            && store.nameEdit?.id == editorID
            && ExplorerStore.sameEntries(store.selectedItemsInOrder, items)
    }

    /// nil means cancelled/stale context; names identify failed on-disk samples.
    func identityChanges(in store: ExplorerStore, command: String? = nil) async -> [String]? {
        guard matches(store) else { return nil }
        if let home {
            // Row navigation validates its represented identity and can ask about a
            // changed Recent document. Paste validates its destination, and removing
            // a history entry does not require the underlying file to still exist.
            switch command {
            case "context-open", "context-openInNewTab", "context-openInNewWindow", "context-pin",
                 "context-removeFromRecent", "context-paste": return []
            default: break
            }
            do {
                let verified = try await store.verifiedHomeOperationEntries(for: home.selection)
                guard !Task.isCancelled, matches(store) else { return nil }
                guard !items.isEmpty, ExplorerStore.sameEntries(verified.map(\.item), items) else { return nil }
                return []
            } catch {
                guard !Task.isCancelled, matches(store) else { return nil }
                return home.selection.occurrences.map { $0.row.url.lastPathComponent }
            }
        }
        if ArchiveLocation(url: location) != nil {
            guard await store.validateBrowsingArchive(at: location, revision: archiveRevision) else {
                return [BrowsingPresentation.title(location)]
            }
            return !Task.isCancelled && matches(store) ? [] : nil
        }
        let checkItem = store.validateRoutingTarget
        let checkFolder = store.validateRoutingFolder
        if clickedItem == nil {
            guard await checkFolder(location, directoryIdentity) else { return [location.lastPathComponent] }
        } else {
            var changed: [String] = []
            for item in items {
                guard !Task.isCancelled else { return nil }
                if !(await checkItem(item)) { changed.append(item.name) }
            }
            if !changed.isEmpty { return changed }
        }
        return !Task.isCancelled && matches(store) ? [] : nil
    }
}

/// Canonical commands remain NSMenuItems so the existing body/shortcut policy
/// is shared by component callers and the app-owned panel presentation.
@MainActor
final class ContextCommandMenu: NSMenu {
    let snapshot: ContextMenuSnapshot
    var bindings: [ContextMenuBinding] = []
    weak var nativeShareItem: NSMenuItem?
    init(title: String = "", snapshot: ContextMenuSnapshot) {
        self.snapshot = snapshot
        super.init(title: title)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

@MainActor
final class ContextMenuBinding: NSObject {
    weak var controller: FileContextMenuController?
    private weak var menu: ContextCommandMenu?
    private weak var item: NSMenuItem?
    private let snapshot: ContextMenuSnapshot
    private let selector: Selector
    private let initiallyEnabled: Bool
    private let enabled: (ExplorerStore, NSMenuItem) -> Bool

    init(controller: FileContextMenuController, menu: ContextCommandMenu, item: NSMenuItem, selector: Selector,
         enabled: @escaping (ExplorerStore, NSMenuItem) -> Bool) {
        self.controller = controller
        self.menu = menu
        self.item = item
        snapshot = menu.snapshot
        self.selector = selector
        initiallyEnabled = item.isEnabled
        self.enabled = enabled
    }

    func belongs(to root: ContextCommandMenu) -> Bool {
        guard let menu, let item, menu.items.contains(where: { $0 === item }) else { return false }
        var owner: NSMenu? = menu
        while let current = owner {
            if current === root { return true }
            owner = current.supermenu
        }
        return false
    }

    func isEnabled(_ sender: NSMenuItem, in store: ExplorerStore) -> Bool {
        sender === item && initiallyEnabled && sender.isEnabled && enabled(store, sender)
    }

    @objc func invokeContextCommand(_ sender: NSMenuItem) {
        guard let controller, let store = controller.store, sender === item else { return }
        guard snapshot.matches(store) else { controller.noteStaleRoute(sender, snapshot: snapshot); return }
        guard isEnabled(sender, in: store) else { return }
        NSApp.sendAction(selector, to: controller, from: sender)
    }
}


/// One activation path for panel mouse, keyboard and accessibility. Component
/// menu construction alone does not open a presentation or consume this session.
@MainActor
final class ContextMenuActionSession {
    enum State { case open, validating, completed, cancelled }
    private(set) var state: State = .open
    let menu: ContextCommandMenu
    weak var controller: FileContextMenuController?
    var closeForAction: (() -> Void)?
    var performShare: (([FileItem]) -> Void)?
    var isOriginCurrent: (() -> Bool)?
    private var task: Task<Void, Never>?

    init(menu: ContextCommandMenu, controller: FileContextMenuController) {
        self.menu = menu
        self.controller = controller
    }

    @discardableResult
    func activate(_ item: NSMenuItem) -> Bool {
        guard state == .open, isOriginCurrent?() != false, item.submenu == nil, !item.isSeparatorItem,
              let controller, let store = controller.store,
              controller.commandIsEnabled(item, in: menu) else { return false }
        state = .validating
        closeForAction?()
        task = Task { [self, weak store] in
            guard let store else { state = .cancelled; return }
            let changes = await menu.snapshot.identityChanges(in: store, command: item.identifier?.rawValue)
            guard state == .validating, isOriginCurrent?() != false else {
                if state == .validating { state = .cancelled }
                return
            }
            guard let changes, changes.isEmpty, menu.snapshot.matches(store),
                  controller.commandIsEnabled(item, in: menu) else {
                state = .cancelled
                if let changes, !changes.isEmpty { controller.noteIdentityRefusal(item, snapshot: menu.snapshot, changedNames: changes) }
                else if !menu.snapshot.matches(store) { controller.noteStaleRoute(item, snapshot: menu.snapshot) }
                return
            }
            state = .completed
            if menu.nativeShareItem === item {
                guard store.canShareSelection,
                      menu.snapshot.items.allSatisfy(BrowsingPresentation.isPhysical) else { state = .cancelled; return }
                performShare?(menu.snapshot.items)
            } else if let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return true
    }

    func cancel() {
        guard state != .completed else { return }
        state = .cancelled
        task?.cancel()
        task = nil
    }
}

/// MR-MENU-004: one logical command cursor; submenu scopes retain parent focus.
@MainActor
final class ContextMenuNavigation {
    let root: NSMenu
    let rowItems: [NSMenuItem]
    private(set) var parents: [NSMenuItem] = []
    private(set) var activeColumn = 0
    private(set) var focused: NSMenuItem?
    private var typedPrefix = ""
    private var lastTypeTime = TimeInterval.zero

    init(menu: NSMenu, keyboard: Bool, rowItems: [NSMenuItem] = []) {
        root = menu
        self.rowItems = rowItems
        if keyboard { focused = enabledItems.first }
    }

    convenience init(menu: ContextCommandMenu, keyboard: Bool) {
        let order = ["cut", "copy", "rename", "share", "moveToTrash"].map { "context-" + $0 }
        let rowItems = !menu.snapshot.isItemInvocation ? [] : order.compactMap { id in
            menu.items.first { $0.identifier?.rawValue == id }
        }
        self.init(menu: menu, keyboard: keyboard, rowItems: rowItems)
    }

    var menus: [NSMenu] { [root] + parents.compactMap(\.submenu) }
    func bodyItems(at column: Int) -> [NSMenuItem] {
        guard menus.indices.contains(column) else { return [] }
        var items = menus[column].items.filter {
            !$0.isHidden && (column != 0 || !rowItems.contains($0))
        }
        while items.first?.isSeparatorItem == true { items.removeFirst() }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        return items
    }
    var enabledItems: [NSMenuItem] {
        ((activeColumn == 0 ? rowItems : []) + bodyItems(at: activeColumn))
            .filter { !$0.isSeparatorItem && $0.isEnabled }
    }

    func hover(_ item: NSMenuItem) {
        guard item.isEnabled, !item.isSeparatorItem else { return }
        if let column = menus.indices.first(where: { bodyItems(at: $0).contains(item) || ($0 == 0 && rowItems.contains(item)) }) {
            if parents.count > column, parents[column] !== item { parents.removeLast(parents.count - column) }
            activeColumn = column
            focused = item
            typedPrefix = ""
        }
    }

    func clearHover(_ item: NSMenuItem) {
        if focused === item, !parents.contains(item) { focused = nil }
    }

    @discardableResult
    func openSubmenu(_ item: NSMenuItem, focusChild: Bool = true) -> Bool {
        guard item.isEnabled, item.submenu != nil else { return false }
        hover(item)
        parents = Array(parents.prefix(activeColumn)) + [item]
        if focusChild { activeColumn += 1; focused = enabledItems.first }
        typedPrefix = ""
        return true
    }

    /// A scrolled parent no longer anchors its existing descendant windows.
    func closeSubmenus(after column: Int) {
        guard menus.indices.contains(column), parents.count > column else { return }
        let parent = parents[column]
        parents = Array(parents.prefix(column))
        if activeColumn > column { activeColumn = column; focused = parent }
        typedPrefix = ""
    }

    func move(_ keyCode: UInt16) {
        guard let current = focused else { focused = enabledItems.first; return }
        if keyCode == 123, activeColumn > 0 {
            focused = parents[activeColumn - 1]
            parents = Array(parents.prefix(activeColumn - 1))
            activeColumn -= 1; typedPrefix = ""; return
        }
        if keyCode == 124, current.submenu != nil { _ = openSubmenu(current); return }
        let candidates: [NSMenuItem]
        if keyCode == 123 || keyCode == 124 {
            guard activeColumn == 0, rowItems.contains(current) else { return }
            candidates = rowItems.filter(\.isEnabled)
        } else { candidates = enabledItems }
        guard let index = candidates.firstIndex(of: current), !candidates.isEmpty else { return }
        let step = keyCode == 123 || keyCode == 126 ? -1 : 1
        focused = candidates[min(max(index + step, 0), candidates.count - 1)]
        if parents.count > activeColumn { parents = Array(parents.prefix(activeColumn)) }
        typedPrefix = ""
    }

    func typeSelect(_ text: String, timestamp: TimeInterval) {
        guard !text.isEmpty else { return }
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let startsNew = timestamp - lastTypeTime > 1 || timestamp < lastTypeTime
        if startsNew { typedPrefix = "" }
        lastTypeTime = timestamp
        let repeated = typedPrefix == normalized
        typedPrefix = repeated ? normalized : typedPrefix + normalized
        let candidates = bodyItems(at: activeColumn).filter { !$0.isSeparatorItem && $0.isEnabled }
        let after = focused.flatMap { candidates.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let order = Array(candidates.dropFirst(after)) + Array(candidates.prefix(after))
        if let match = order.first(where: {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(typedPrefix)
        }) {
            focused = match
            if parents.count > activeColumn, parents[activeColumn] !== match {
                parents = Array(parents.prefix(activeColumn))
            }
        }
    }

    func commandEquivalent(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        guard !key.isEmpty else { return nil }
        // AppKit menu declarations may use Backspace while the physical Delete
        // key reports DEL. Both spellings identify the same existing command.
        func normalized(_ value: String) -> String {
            value == "\u{8}" ? "\u{7f}" : value.lowercased()
        }
        let normalizedKey = normalized(key)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items where !item.isHidden {
                if item.isEnabled, !item.keyEquivalent.isEmpty,
                   item.keyEquivalentModifierMask == modifiers,
                   normalized(item.keyEquivalent) == normalizedKey { return item }
                if let child = item.submenu, let item = find(in: child) { return item }
            }
            return nil
        }
        return find(in: root)
    }
}
