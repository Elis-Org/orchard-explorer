import AppKit
import Combine
import ExplorerCore
import SwiftUI

@main
enum ExplorerApplication {
    static func main() {
        let app = NSApplication.shared
        // MAC-074: the scale must be known before any window or panel is built.
        ExplorerScale.factor = ExplorerScale.stored(in: .standard)
        let sidebarPreferences = SidebarBackgroundCheckPreferences(defaults: .standard)
        let delegate = ExplorerAppDelegate(sidebarBackgroundCheckPreferences: sidebarPreferences)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ExplorerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var windows: [NSWindow] = []
    private var stores: [Int: ExplorerStore] = [:]
    private var subscriptions: [Int: AnyCancellable] = [:]
    private let pinnedFolders = PinnedFolderStore(defaults: .standard)
    private let sidebarBackgroundCheckPreferences: SidebarBackgroundCheckPreferences
    private let transferClipboard = TransferClipboard()
    private let recoveryHistory = RecoveryHistory()
    private let recentAddressHistory = RecentAddressHistory()
    private let recentDocuments = RecentDocumentStore(defaults: .standard, systemSnapshots: SystemRecentProvider.snapshots)
    private let tagShortcuts = FinderTagShortcuts(defaults: .standard)
    private let accessSetup = FileAccessWindowController()
    private let properties = ItemPropertiesWindowController()
    private var focusMonitor: Any?
    private var pointerRenameMonitor: Any?
    /// MAC-082: open requests that arrive while launching replace the default window.
    private var hasFinishedLaunching = false
    private var launchOpenRequests: [URL] = []
    private let launchLocation: URL
    private var menuTrackingObserver: NSObjectProtocol?
    private var isFinishingContentSession = false
    private let contentTermination = ContentSessionTermination()

    static func initialLocation(arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--folder"), arguments.indices.contains(index + 1) else {
            return BrowserPage.home.url
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    init(sidebarBackgroundCheckPreferences: SidebarBackgroundCheckPreferences? = nil) {
        launchLocation = Self.initialLocation(arguments: ProcessInfo.processInfo.arguments)
        self.sidebarBackgroundCheckPreferences = sidebarBackgroundCheckPreferences ?? SidebarBackgroundCheckPreferences()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(UserDefaults.standard.string(forKey: "nativeExplorer.appearance") ?? "light")
        installMenus()
        properties.model.onShowAccessHelp = { [weak self] context in self?.accessSetup.show(context: context) }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 97,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let store = self?.currentStore else { return event }
            guard !store.isPerformingOperation else { return nil }
            return store.focus.cycle(backwards: event.modifierFlags.contains(.shift)) ? nil : event
        }
        // MAC-076: any key (including shortcuts the main menu handles before the list
        // sees keyDown), any press anywhere in the app and any menu tracking (menu bar
        // or context menu) cancel a pending second-click rename. A press that arms a
        // new candidate does so only after its release, so it is never cancelled here.
        pointerRenameMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.cancelPendingPointerRenames()
            return event
        }
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPendingPointerRenames() }
        }
        hasFinishedLaunching = true
        if launchOpenRequests.isEmpty {
            makeWindow(url: launchLocation)
        } else {
            let requests = launchOpenRequests
            launchOpenRequests = []
            handleOpenRequest(requests)
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            do {
                let artifacts = try await ContentLeaseRegistry.shared.retainedArtifacts()
                if !artifacts.isEmpty { self?.currentStore?.showRetainedZIPFiles(artifacts) }
            } catch { self?.currentStore?.showRetainedZIPReceiptError(error.localizedDescription) }
        }
    }

    /// MAC-082: other applications (open -a, Open With, a Finder replacement's
    /// "Show in Finder") ask Orchard Explorer to open items.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasFinishedLaunching else { launchOpenRequests += urls; return }
        handleOpenRequest(urls)
    }

    private func handleOpenRequest(_ urls: [URL]) {
        Task { @MainActor [weak self] in
            let plan = await OpenRequestPlan.classify(urls)
            self?.present(plan)
        }
    }

    /// Folders open in new tabs and items are revealed (selected in their folder's
    /// tab) in the frontmost Orchard Explorer window, or in a new window when none is open.
    private func present(_ plan: OpenRequestPlan) {
        var targets = plan.targets
        if targets.isEmpty {
            if stores.isEmpty { makeWindow(url: launchLocation) }
            return
        }
        // MAC-083: a tab that already shows the folder is reused (frontmost window
        // first). Otherwise the request opens as a new tab in the front window, or in
        // a new window when that window is busy (operation, Recently Trashed, name
        // draft — review bf692ae9 finding 1) or none is open.
        var front = frontmostStore.flatMap { $0.canAcceptOpenRequest ? $0 : nil }
        var shown: ExplorerStore?
        while !targets.isEmpty {
            let target = targets.removeFirst()
            if let reused = storesFrontToBack.first(where: {
                $0.showInExistingTab(target.folder, revealing: target.reveal, identities: target.identities,
                                     alternatePaths: target.alternateFolderPaths, folderIdentity: target.folderIdentity)
            }) {
                shown = reused
            } else if let front, front.openTab(at: target.folder, revealing: target.reveal, identities: target.identities) {
                shown = front
            } else {
                let created = openRequestWindow(for: target)
                front = created
                shown = created
            }
        }
        if let window = windows.first(where: { stores[$0.windowNumber] === shown }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openRequestWindow(for target: OpenRequestPlan.Target) -> ExplorerStore {
        let store = makeWindow(url: target.folder)
        if !target.reveal.isEmpty { store.reveal(target.reveal, in: target.folder, identities: target.identities) }
        return store
    }

    /// Every window's store, frontmost first (windows not in the ordered list last).
    private var storesFrontToBack: [ExplorerStore] {
        var ordered: [ExplorerStore] = []
        if let frontmostStore { ordered.append(frontmostStore) }
        for window in NSApp.orderedWindows { if let store = stores[window.windowNumber], !ordered.contains(where: { $0 === store }) { ordered.append(store) } }
        for window in windows { if let store = stores[window.windowNumber], !ordered.contains(where: { $0 === store }) { ordered.append(store) } }
        return ordered
    }

    /// The key or main window's store, else the frontmost Orchard Explorer window's (the app
    /// may be inactive when a request arrives).
    private var frontmostStore: ExplorerStore? {
        if let currentStore { return currentStore }
        return NSApp.orderedWindows.lazy.compactMap { self.stores[$0.windowNumber] }.first
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !stores.values.contains(where: \.isPerformingOperation) else { NSSound.beep(); return .terminateCancel }
        if contentTermination.state == .finished { return .terminateNow }
        guard !isFinishingContentSession else { return .terminateLater }
        isFinishingContentSession = true
        stores.values.forEach { $0.setPreviewSurfaceVisible(false) }
        transferClipboard.retireOwnedExports()
        contentTermination.onFailure = { [weak self] message in self?.currentStore?.showRetainedZIPReceiptError(message) }
        Task { [weak self] in
            // The registry bounds background work to five seconds and writes a
            // next-launch receipt. Shutdown never presents an alert or sweeps paths.
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            if await self.contentTermination.finish() {
                ExternalOpenContents.shared.endSession()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.isFinishingContentSession = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard stores[sender.windowNumber]?.isPerformingOperation != true else { NSSound.beep(); return false }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        if let pointerRenameMonitor { NSEvent.removeMonitor(pointerRenameMonitor) }
        if let menuTrackingObserver { NotificationCenter.default.removeObserver(menuTrackingObserver) }
        stores.values.forEach { $0.cancelLoads() }
        properties.model.dismiss()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        OneDriveBadgeCache.shared.setActive(true)
        OneDriveBadgeCache.shared.hint(folder: nil, reason: .activation)
        transferClipboard.refresh()
        // Activation reconciles changes missed while the application was suspended.
        currentStore?.refreshAfterActivation()
    }
    func applicationDidResignActive(_ notification: Notification) {
        OneDriveBadgeCache.shared.setActive(false)
    }
    private func cancelPendingPointerRenames() {
        for store in stores.values { store.notePointerInterruption() }
    }
    /// MAC-076: a pending second-click rename never fires in an inactive window.
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        stores[window.windowNumber]?.cancelPointerRename()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        stores.removeValue(forKey: window.windowNumber)?.cancelLoads()
        subscriptions.removeValue(forKey: window.windowNumber)
        windows.removeAll { $0 === window }
    }

    private var currentStore: ExplorerStore? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return stores[window.windowNumber]
    }

    @discardableResult
    private func makeWindow(url: URL, sidebarKey: String? = nil) -> ExplorerStore {
        let store = ExplorerStore(initialURL: url, initialSidebarKey: sidebarKey, pins: pinnedFolders,
                                  observer: LocalDirectoryObserver(), clipboard: transferClipboard,
                                  recoveryHistory: recoveryHistory, recentAddressHistory: recentAddressHistory, recentDocuments: recentDocuments,
                                  tagShortcuts: tagShortcuts,
                                  sidebarBackgroundCheckPreferences: sidebarBackgroundCheckPreferences, sidebarLocations: .shared)
        makeWindow(store: store)
        return store
    }

    /// The reference 1127 × 635 window at the interface scale, kept on screen.
    private static func initialWindowSize(on screen: NSScreen?) -> NSSize {
        let size = NSSize(width: 1127.pt, height: 635.pt)
        guard let visible = screen?.visibleFrame else { return size }
        return NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    }

    private func installShell(in window: NSWindow, store: ExplorerStore) {
        window.minSize = NSSize(width: 185.pt, height: 320.pt)
        window.contentView = NSHostingView(rootView: ExplorerShell(store: store).ignoresSafeArea())
    }

    private func makeWindow(store: ExplorerStore, at point: NSPoint? = nil) {
        let size = Self.initialWindowSize(on: NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = AppIdentity.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self
        installShell(in: window, store: store)
        window.center()
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        if let point {
            let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
            var origin = NSPoint(x: point.x - 110, y: point.y - window.frame.height + 20)
            if let visible {
                origin.x = max(visible.minX, min(origin.x, visible.maxX - window.frame.width))
                origin.y = max(visible.minY, min(origin.y, visible.maxY - window.frame.height))
            }
            window.setFrameOrigin(origin)
        }
        store.onShowAccessHelp = { [weak self] context in self?.accessSetup.show(context: context) }
        store.onShowProperties = { [weak self] item in self?.properties.show(item) }
        store.onChooseHomeFolder = { [weak window, weak store] reply in
            guard let window, window.attachedSheet == nil else { reply(nil); return }
            let panel = NSOpenPanel()
            panel.identifier = NSUserInterfaceItemIdentifier("home-operation-destination-panel")
            panel.setAccessibilityIdentifier("home-operation-destination-panel")
            panel.title = "Choose a destination folder"
            panel.message = "Choose a destination folder"
            panel.prompt = "Choose"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            store?.onCancelHomeFolder = { [weak panel] in panel?.cancel(nil) }
            panel.beginSheetModal(for: window) { response in
                reply(response == .OK ? panel.url : nil)
            }
        }
        store.onShowMultipleProperties = { [weak self] items in self?.properties.show(items: items) }
        store.onOpenWindow = { [weak self] url, key in self?.makeWindow(url: url, sidebarKey: key) }
        store.onLastTabClosed = { [weak window] in window?.performClose(nil) }
        store.onDetachTab = { [weak self, weak store] tab, point in
            guard let self, let store else { return }
            let receiver = ExplorerStore(tab: tab, homeURL: store.homeURL,
                                         pins: self.pinnedFolders, showHidden: store.showHidden,
                                         observer: LocalDirectoryObserver(), clipboard: self.transferClipboard,
                                         recoveryHistory: self.recoveryHistory,
                                         recentAddressHistory: self.recentAddressHistory, recentDocuments: self.recentDocuments,
                                         tagShortcuts: self.tagShortcuts,
                                         sidebarBackgroundCheckPreferences: self.sidebarBackgroundCheckPreferences, sidebarLocations: .shared)
            self.makeWindow(store: receiver, at: point)
        }
        let number = window.windowNumber
        stores[number] = store
        subscriptions[number] = store.$tabs.combineLatest(store.$activeTabID).sink { [weak window, weak store] _ in
            Task { @MainActor in
                guard let store else { return }
                window?.title = "\(store.activeTab.title) — \(AppIdentity.name)"
            }
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppIdentity.name)
        appMenu.addItem(withTitle: "About \(AppIdentity.name)", action: #selector(showAbout), keyEquivalent: "")
        add("File Access…", #selector(showFileAccess), "", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppIdentity.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileMenu = addMenu("File", to: main)
        fileMenu.delegate = self
        add("New Window", #selector(newWindow), "n", to: fileMenu)
        add("New Tab", #selector(newTab), "t", to: fileMenu)
        let newFolder = add("New Folder", #selector(newFolder), "n", to: fileMenu)
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        let rename = add("Rename", #selector(renameSelection), String(UnicodeScalar(NSF2FunctionKey)!), to: fileMenu)
        rename.keyEquivalentModifierMask = []
        fileMenu.addItem(withTitle: "Move to Trash", action: #selector(ExplorerTableView.moveToTrash(_:)), keyEquivalent: "\u{7f}")
        add("Recently Trashed…", #selector(showRecovery), "", to: fileMenu)
        add("Properties", #selector(showProperties), "i", to: fileMenu)
        let duplicate = add("Duplicate Tab", #selector(duplicateTab), "d", to: fileMenu)
        duplicate.keyEquivalentModifierMask = [.command, .shift]
        add("Move Tab to New Window", #selector(detachTab), "", to: fileMenu)
        add("Open Folder…", #selector(openFolder), "o", to: fileMenu)
        fileMenu.addItem(.separator())
        add("Close Tab", #selector(closeTab), "w", to: fileMenu)

        // Responder-chain actions preserve text-editing semantics in the address field.
        let editMenu = addMenu("Edit", to: main)
        editMenu.addItem(withTitle: "Undo Rename", action: #selector(ExplorerTableView.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo Rename", action: #selector(ExplorerTableView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let move = add("Move Here", #selector(moveHere), "v", to: editMenu)
        move.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // NATIVE-P18A: Finder's Copy as Pathname (Windows Copy as path, Ctrl+Shift+C).
        let pathname = add("Copy as Pathname", #selector(copyPathnames), "c", to: editMenu)
        pathname.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(.separator())
        // FR-SEARCH-001 / AT-SEARCH-001: native ⌘F adaptation of Ctrl+F (MAC-062).
        add("Find…", #selector(findInFolder), "f", to: editMenu)
        add("Open File Location", #selector(openSearchResultLocation), "", to: editMenu)

        let goMenu = addMenu("Go", to: main)
        add("Back", #selector(back), "[", to: goMenu)
        add("Forward", #selector(forward), "]", to: goMenu)
        add("Enclosing Folder", #selector(up), String(UnicodeScalar(NSUpArrowFunctionKey)!), to: goMenu)
        add("Go to Folder…", #selector(focusAddress), "l", to: goMenu)
        add("Refresh", #selector(refresh), "r", to: goMenu)
        let next = add("Next Tab", #selector(nextTab), "\t", to: goMenu)
        next.keyEquivalentModifierMask = [.control]
        let previous = add("Previous Tab", #selector(previousTab), "\t", to: goMenu)
        previous.keyEquivalentModifierMask = [.control, .shift]
        goMenu.addItem(.separator())
        add("Next Focus Area", #selector(nextFocus), String(UnicodeScalar(NSF6FunctionKey)!), to: goMenu).keyEquivalentModifierMask = []
        add("Pin Current Folder to Quick Access", #selector(pinCurrentFolder), "", to: goMenu)

        populateViewMenu(addMenu("View", to: main))

        let windowMenu = addMenu("Window", to: main)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    func populateViewMenu(_ viewMenu: NSMenu) {
        for mode in FolderViewMode.allCases {
            let item = add(mode.title, #selector(changeViewMode(_:)), String(mode.rawValue), to: viewMenu)
            item.keyEquivalentModifierMask = [.control, .shift]
            item.tag = mode.rawValue
        }
        viewMenu.addItem(.separator())
        let details = add("Details Pane", #selector(toggleDetailsPane), "p", to: viewMenu)
        details.keyEquivalentModifierMask = [.command, .shift]
        let preview = add("Preview Pane", #selector(togglePreviewPane), "p", to: viewMenu)
        preview.keyEquivalentModifierMask = [.command, .option]
        let checksItem = viewMenu.addItem(withTitle: "Background Folder Checks", action: nil, keyEquivalent: "")
        let checksMenu = NSMenu(title: checksItem.title)
        for check in SidebarBackgroundCheck.allCases {
            let item = add(check.title, #selector(toggleSidebarBackgroundCheck(_:)), "", to: checksMenu)
            item.representedObject = check.rawValue
            item.toolTip = check.help
            item.state = check.isEnabled(in: sidebarBackgroundCheckPreferences.options) ? .on : .off
        }
        checksItem.submenu = checksMenu
        viewMenu.addItem(.separator())
        for (title, value) in [("Follow System Appearance", "system"), ("Light Appearance", "light"), ("Dark Appearance", "dark")] {
            let item = add(title, #selector(changeAppearance(_:)), "", to: viewMenu)
            item.representedObject = value
        }
        viewMenu.addItem(.separator())
        // MAC-074: one scale for text, controls, icons and layout in every window.
        let sizeItem = viewMenu.addItem(withTitle: "Interface Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "Interface Size")
        for factor in ExplorerScale.presets {
            let item = add(ExplorerScale.title(for: factor), #selector(changeInterfaceScale(_:)), "", to: sizeMenu)
            item.representedObject = NSNumber(value: Double(factor))
        }
        sizeItem.submenu = sizeMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(ExplorerTableView.moveToTrash(_:)) {
            item.title = currentStore?.deleteActionTitle ?? "Move to Trash"
        }
    }
    private func addMenu(_ title: String, to main: NSMenu) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
    @discardableResult
    private func add(_ title: String, _ action: Selector, _ key: String, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func showFileAccess() {
        guard !stores.values.contains(where: \.isPerformingOperation) else { return }
        accessSetup.show()
    }
    @objc private func newWindow() { makeWindow(url: currentStore?.activeTab.url ?? FileManager.default.homeDirectoryForCurrentUser) }
    @objc private func newTab() { currentStore?.addTab() }
    // Fallback after the native responder chain: text editors and the table get
    // first opportunity to handle their standard Cut/Copy/Paste actions.
    @objc private func copy(_ sender: Any?) { currentStore?.copySelection() }
    @objc private func cut(_ sender: Any?) { currentStore?.cutSelection() }
    @objc private func paste(_ sender: Any?) { currentStore?.pasteSelection() }
    // Recovery shortcuts have no application fallback: only the file table or
    // native text editor can handle them through the responder chain.
    @objc private func showRecovery() { currentStore?.showRecovery() }
    @objc private func copyPathnames() {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        currentStore?.copyPathnames()
    }
    @objc private func showProperties() { currentStore?.showProperties() }
    @objc private func toggleDetailsPane() { currentStore?.toggleDetailsPane() }
    @objc private func togglePreviewPane() { currentStore?.togglePreviewPane() }
    @objc private func changeViewMode(_ sender: NSMenuItem) {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView), let mode = FolderViewMode(rawValue: sender.tag) else { return }
        currentStore?.setViewMode(mode)
    }
    @objc private func moveHere() {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        currentStore?.moveHere()
    }
    @objc private func newFolder() { currentStore?.beginCreateFolder() }
    @objc private func renameSelection() { currentStore?.beginRename() }
    @objc private func duplicateTab() { if let store = currentStore { store.duplicateTab(store.activeTabID) } }
    @objc private func detachTab() { if let store = currentStore { store.detachTab(store.activeTabID) } }
    @objc private func closeTab() {
        if accessSetup.window === NSApp.keyWindow { accessSetup.close(); return }
        if properties.window === NSApp.keyWindow { properties.close(); return }
        if let store = currentStore { store.closeTab(store.activeTabID) }
    }
    @objc private func openFolder() { currentStore?.chooseFolder() }
    @objc private func back() { currentStore?.back() }
    @objc private func forward() { currentStore?.forward() }
    @objc private func up() { currentStore?.up() }
    @objc private func refresh() { currentStore?.refresh() }
    @objc private func focusAddress() { currentStore?.requestAddressEditing() }
    @objc private func findInFolder() { currentStore?.requestSearchFocus() }
    @objc private func openSearchResultLocation() { currentStore?.openSelectedSearchResultLocation() }
    @objc private func nextTab() { currentStore?.cycleTab() }
    @objc private func previousTab() { currentStore?.cycleTab(backwards: true) }
    @objc private func nextFocus() { currentStore?.focus.cycle() }
    @objc private func pinCurrentFolder() { currentStore?.pinCurrentFolder() }
    private func sidebarCheck(for item: NSMenuItem) -> SidebarBackgroundCheck? {
        (item.representedObject as? String).flatMap(SidebarBackgroundCheck.init(rawValue:))
    }
    @objc private func toggleSidebarBackgroundCheck(_ sender: NSMenuItem) {
        guard let check = sidebarCheck(for: sender) else { return }
        let enabled = !check.isEnabled(in: sidebarBackgroundCheckPreferences.options)
        sidebarBackgroundCheckPreferences.set(check, enabled: enabled)
        sender.state = enabled ? .on : .off
    }
    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "nativeExplorer.appearance")
        applyAppearance(value)
    }
    @objc private func changeInterfaceScale(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue,
              CGFloat(value) != ExplorerScale.factor, canChangeInterfaceScale else { return }
        UserDefaults.standard.set(value, forKey: ExplorerScale.defaultsKey)
        ExplorerScale.factor = CGFloat(value)
        // Views read the scale when they are built: rebuild every window's content.
        // Window state lives in each store, so tabs, locations and selection survive.
        for window in windows {
            guard let store = stores[window.windowNumber] else { continue }
            // Review 7a1a7cf8 #3/#4: keep the focused region and the first visible item.
            let region = store.focus.liveRegion
            let anchor = Self.fileList(in: window.contentView).flatMap(Self.topVisibleItemID)
            let restoration = ViewportRestorationGuard(store: store)
            installShell(in: window, store: store)
            let minimum = window.minSize
            if window.frame.width < minimum.width || window.frame.height < minimum.height {
                window.setContentSize(NSSize(width: max(window.frame.width, minimum.width),
                                             height: max(window.frame.height, minimum.height)))
            }
            window.contentView?.layoutSubtreeIfNeeded()
            if let region { _ = store.focus.focus(region) }
            // After the rebuilt views' own first-update scrolling (icon views reveal asynchronously).
            DispatchQueue.main.async { [weak window, weak store] in
                guard let store, restoration.allowsRestoration(in: store),
                      let anchor, let list = Self.fileList(in: window?.contentView) else { return }
                Self.scroll(list, toTop: anchor)
            }
        }
        properties.installContent()
        accessSetup.installContent()
    }

    /// Rebuilding views mid-edit, mid-transfer, under a sheet or while text is being
    /// typed (address, search) would discard in-flight UI state.
    private var canChangeInterfaceScale: Bool {
        !stores.values.contains { $0.isPerformingOperation || $0.nameEdit != nil || $0.isShowingRecovery }
            && !windows.contains { $0.firstResponder is NSTextView }
    }

    private static func fileList(in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root is ExplorerDetailsScrollView || root is ExplorerFileCollectionView { return root }
        for child in root.subviews { if let found = fileList(in: child) { return found } }
        return nil
    }
    private static func topVisibleItemID(_ list: NSView) -> String? {
        (list as? ExplorerDetailsScrollView)?.topVisibleItemID ?? (list as? ExplorerFileCollectionView)?.topVisibleItemID
    }
    private static func scroll(_ list: NSView, toTop id: String) {
        if let details = list as? ExplorerDetailsScrollView { details.scrollItemToTop(id) }
        else if let collection = list as? ExplorerFileCollectionView { collection.scrollItemToTop(id) }
    }

    private func applyAppearance(_ value: String) {
        switch value {
        case "system": NSApp.appearance = nil
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validateMenuItem(item, currentStore: currentStore)
    }

    func validateMenuItem(_ item: NSMenuItem, currentStore resolveStore: @autoclosure () -> ExplorerStore?) -> Bool {
        if item.action == #selector(toggleSidebarBackgroundCheck(_:)) {
            guard let check = sidebarCheck(for: item) else { return false }
            item.state = check.isEnabled(in: sidebarBackgroundCheckPreferences.options) ? .on : .off
            return true
        }

        let currentStore = resolveStore()
        if item.action == #selector(closeTab) {
            let isUtility = accessSetup.window === NSApp.keyWindow || properties.window === NSApp.keyWindow
            item.title = isUtility ? "Close Window" : "Close Tab"
            return isUtility || (currentStore?.isPerformingOperation == false && currentStore?.isShowingRecovery == false)
        }
        if item.action == #selector(showProperties) { return currentStore?.canShowProperties == true }
        if item.action == #selector(copyPathnames) {
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && currentStore?.canCopyPathnames == true
        }
        if item.action == #selector(toggleDetailsPane) {
            item.state = currentStore?.showsDetailsPane == true ? .on : .off
            return currentStore?.canToggleDetailsPane == true
        }
        if item.action == #selector(togglePreviewPane) {
            item.state = currentStore?.showsPreviewPane == true ? .on : .off
            return currentStore?.canToggleDetailsPane == true
        }
        if item.action == #selector(changeViewMode(_:)) {
            item.state = currentStore?.activePage == nil && currentStore?.activeTab.viewMode.rawValue == item.tag ? .on : .off
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && currentStore?.canChangeViewMode == true
        }
        if item.action == #selector(showFileAccess) { return !stores.values.contains(where: \.isPerformingOperation) }
        if item.action == #selector(showRecovery) { return currentStore?.canShowRecovery == true }
        if item.action == #selector(copy(_:)) {
            return currentStore?.canCopySelection == true
        }
        if item.action == #selector(cut(_:)) { return currentStore?.canCutSelection == true }
        if item.action == #selector(paste(_:)) { return currentStore?.canPaste == true }
        if item.action == #selector(moveHere) {
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && currentStore?.canMoveHere == true
        }
        if item.action == #selector(newFolder) { return currentStore?.canCreateFolder == true }
        if item.action == #selector(renameSelection) {
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && currentStore?.canRenameSelection == true
        }
        if item.action == #selector(changeInterfaceScale(_:)) {
            item.state = (item.representedObject as? NSNumber).map { CGFloat($0.doubleValue) == ExplorerScale.factor } == true ? .on : .off
            return canChangeInterfaceScale
        }
        if currentStore?.isPerformingOperation == true || currentStore?.isShowingRecovery == true { return false }
        if item.action == #selector(changeAppearance(_:)) {
            item.state = (item.representedObject as? String) == (UserDefaults.standard.string(forKey: "nativeExplorer.appearance") ?? "light") ? .on : .off
            return true
        }
        if item.action == #selector(detachTab) { return currentStore.map { $0.canDetachTab($0.activeTabID) } ?? false }
        if item.action == #selector(back) { return currentStore?.canGoBack == true }
        if item.action == #selector(findInFolder) { return currentStore?.canSearch == true }
        if item.action == #selector(pinCurrentFolder) { return currentStore?.canPinCurrentFolder == true }
        if item.action == #selector(openSearchResultLocation) {
            return currentStore?.canOpenSearchResultLocation == true
        }
        if item.action == #selector(forward) { return currentStore?.activeTab.history.canGoForward == true }
        if item.action == #selector(up) {
            // Command-Up keeps its text-navigation meaning while editing an address.
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && currentStore?.activeTab.history.parent != nil
        }
        return true
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.name,
            .applicationVersion: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") — Native macOS preview",
            .credits: NSAttributedString(string: "A native file browser inspired by the Windows 11 Explorer reference. Create, rename, copy, move and Trash local items, and search file names in a folder and its subfolders. Copy and move between volumes, compare and replace same-name items recoverably, restore this session’s verified Trash items and undo or redo the last rename. Click a selected name again to rename it; use context menus to open with another app, compress to ZIP or TAR, make aliases and copy pathnames. ZIP contents can be deleted permanently after confirmation. Content search and permanent deletion of ordinary files remain unavailable.")
        ])
    }
}
