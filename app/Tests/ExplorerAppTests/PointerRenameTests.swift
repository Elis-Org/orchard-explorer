import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct PointerRenameTests {
    // MAC-076; FR-FILE-026/027/028/030/032; AT-FILE-026–032.
    @Test func schedulerSupersedesCancelsAndFiresLatestExactlyOnce() {
        let scheduler = P18Scheduler()
        let intent = PointerRenameIntent(schedule: scheduler.schedule, delay: { 0.731 })
        let first = PointerRenameIntent.Target(tabID: UUID(), directoryURL: URL(fileURLWithPath: "/tmp"), itemID: "first", identity: nil)
        let second = PointerRenameIntent.Target(tabID: first.tabID, directoryURL: first.directoryURL, itemID: "second", identity: nil)
        var fired: [PointerRenameIntent.Target] = []
        intent.arm(first) { fired.append($0) }
        intent.arm(second) { fired.append($0) }
        #expect(scheduler.delays == [0.731, 0.731])
        #expect(scheduler.cancelCount == 1)
        scheduler.work[0]()
        #expect(fired.isEmpty && intent.target == second)
        scheduler.work[1](); scheduler.work[1]()
        #expect(fired == [second] && !intent.isPending)
        intent.arm(first) { fired.append($0) }
        intent.cancel(); scheduler.work[2]()
        #expect(fired == [second] && !intent.isPending)
    }

    // MAC-076; FR-FILE-022/026/031; AT-FILE-022/026/031.
    @Test func storeEligibilityAndInitialSelection() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], folder = f.items[0]
        f.select([file])
        #expect(!f.store.armPointerRename(itemID: folder.id))
        f.select([file, f.items[2]])
        #expect(!f.store.armPointerRename(itemID: file.id))
        f.select([file]); f.store.tabs[0].search = SearchSession(query: try #require(FilenameSearchQuery(text: "x")), rootURL: f.root, rootTitle: "root")
        #expect(!f.store.armPointerRename(itemID: file.id))
        f.store.tabs[0].search = nil
        #expect(f.store.armPointerRename(itemID: file.id)); f.scheduler.work.last?()
        #expect(f.store.nameEdit?.item?.id == file.id)
        #expect(f.store.nameEdit?.initialSelection == NSRange(location: 0, length: 5))
        #expect(!f.store.armPointerRename(itemID: file.id))
        f.store.cancelNameEdit(); f.select([folder])
        #expect(f.store.armPointerRename(itemID: folder.id)); f.scheduler.work.last?()
        #expect(f.store.nameEdit?.initialSelection == NSRange(location: 0, length: folder.name.utf16.count))
    }

    // MAC-076; FR-FILE-027/028/030/032; FR-NAV-011/012; AT-NAV-011/012.
    @Test(arguments: 0..<7) func interruptionsInvalidateCapturedCallback(_ interruption: Int) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        #expect(f.store.armPointerRename(itemID: f.items[1].id))
        let callback = try #require(f.scheduler.work.last)
        switch interruption {
        case 0: f.select([f.items[2]])
        case 1:
            let tab = BrowserTab(url: f.root); f.store.tabs.append(tab); f.store.activeTabID = tab.id
        case 2: f.store.navigate(to: f.items[0].url)
        case 3: f.store.setViewMode(.largeIcons)
        case 4: f.store.beginRename(); f.store.cancelNameEdit()
        case 5: f.store.beginCreateItem(.file(.textDocument)); f.store.cancelNameEdit()
        default: f.store.tabs[0].history.navigate(to: f.items[0].url)
        }
        #expect(!f.store.pointerRename.isPending)
        callback()
        #expect(f.store.nameEdit == nil)
    }

    // MAC-076; FR-FILE-028/030/032.
    @Test func firingRevalidatesIdentitySelectionAndBusyState() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1]; f.select([file]); f.store.armPointerRename(itemID: file.id)
        let target = try #require(f.store.pointerRename.target)
        f.store.tabs[0].items[1] = FileItem(url: file.url, name: file.name, isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text", identity: P18Fixture.identity(999))
        f.store.firePointerRename(target); #expect(f.store.nameEdit == nil)
        f.select([f.items[2]]); f.store.firePointerRename(target); #expect(f.store.nameEdit == nil)
        f.select([f.items[1]]); f.store.archiver = P18Archive()
        f.store.compressSelection(.zip)
        #expect(!f.store.armPointerRename(itemID: file.id))
        try await p18Wait { !f.store.isPerformingOperation }
    }

    // MAC-076; FR-FILE-022/026/027/031; FR-NAV-011/012.
    @Test(arguments: 0..<6) func collectionClickQualification(_ scenario: Int) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        view.pointerRenameFocusCheck = { true }
        let folderURL = f.items[0].url
        let index = scenario == 4 ? 0 : 1
        let path = IndexPath(item: index, section: 0)
        view.selectItem(at: index, extending: false, toggling: false)
        if scenario == 2 { f.store.setSelection([], focusedID: nil, anchorID: nil); f.coordinator?.update() }
        let cell = try #require(view.item(at: path) as? ExplorerCollectionItem)
        let label = cell.itemView.nameField
        var point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: view)
        if scenario == 1 { point = NSPoint(x: cell.view.frame.midX, y: cell.view.frame.minY + 10) }
        let windowPoint = view.convert(point, to: nil)
        let flags: NSEvent.ModifierFlags = scenario == 3 ? .command : []
        if scenario == 4 { f.store.armPointerRename(itemID: f.items[0].id) }
        if scenario == 5 { f.store.tabs[0].isUnavailable = true }
        view.mouseDown(with: try f.mouse(.leftMouseDown, point: windowPoint, flags: flags, clicks: scenario == 4 ? 2 : 1))
        if scenario == 5 {
            // Invalidate drag entries before crossing the threshold to avoid a native drag session.
            f.store.tabs[0].isUnavailable = true
            view.mouseDragged(with: try f.mouse(.leftMouseDragged, point: NSPoint(x: windowPoint.x + 7, y: windowPoint.y)))
        }
        view.mouseUp(with: try f.mouse(.leftMouseUp, point: windowPoint, flags: flags))
        #expect(f.store.pointerRename.isPending == (scenario == 0))
        if scenario == 0 { f.scheduler.work.last?(); #expect(f.store.nameEdit?.item?.id == f.items[1].id) }
        else { #expect(f.store.nameEdit == nil) }
        if scenario == 4 { try await p18Wait { !f.store.activeTab.isLoading }; #expect(f.store.activeTab.url == folderURL) }
    }

    // MAC-076 (Astra review 4980d3b6 findings 5 and 7): focus loss cancels an armed
    // candidate, and a press held while focus moves away cannot arm on release.
    // Operation start cancels too.
    // Scenario 3 (follow-up 029698a5 finding 10): a key or other interruption while the
    // press is held invalidates it, so the release does not arm.
    @Test(arguments: 0..<4) func focusLossAndOperationStartCancel(_ scenario: Int) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        var focused = true; view.pointerRenameFocusCheck = { focused }
        let path = IndexPath(item: 1, section: 0)
        view.selectItem(at: 1, extending: false, toggling: false)
        let cell = try #require(view.item(at: path) as? ExplorerCollectionItem)
        let label = cell.itemView.nameField
        let point = view.convert(label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: view), to: nil)
        switch scenario {
        case 0:
            // Armed, then the list resigns first responder.
            #expect(f.store.armPointerRename(itemID: f.items[1].id))
            #expect(f.window?.makeFirstResponder(nil) == true)
        case 1:
            // Press, focus moves away while held, release over the same item.
            view.mouseDown(with: try f.mouse(.leftMouseDown, point: point))
            focused = false; _ = f.window?.makeFirstResponder(nil)
            view.mouseUp(with: try f.mouse(.leftMouseUp, point: point))
        case 3:
            view.mouseDown(with: try f.mouse(.leftMouseDown, point: point))
            f.store.notePointerInterruption()   // what the app-wide key/press/menu monitor does
            view.mouseUp(with: try f.mouse(.leftMouseUp, point: point))
        default:
            #expect(f.store.armPointerRename(itemID: f.items[1].id))
            f.store.archiver = P18Archive(); f.store.compressSelection(.zip)
        }
        #expect(!f.store.pointerRename.isPending)
        f.scheduler.work.last?(); #expect(f.store.nameEdit == nil)
        if scenario == 2 { try await p18Wait { !f.store.isPerformingOperation } }
    }

    // MAC-076; FR-FILE-031; AT-FILE-031. Geometry uses the current scale without changing it.
    @Test func detailsNameCellIncludesBlankSpaceButExcludesIconAndDate() {
        let source = P18Rows(); let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        for (id, width) in [(SortKey.name.rawValue, CGFloat(300)), (SortKey.modifiedAt.rawValue, CGFloat(200))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.width = width; table.addTableColumn(column)
        }
        table.dataSource = source; table.reloadData()
        let name = table.frameOfCell(atColumn: 0, row: 0), date = table.frameOfCell(atColumn: 1, row: 0)
        #expect(table.isPointerRenameRegion(NSPoint(x: name.minX + 40, y: name.midY), row: 0))
        #expect(table.isPointerRenameRegion(NSPoint(x: name.maxX - 5, y: name.midY), row: 0))
        #expect(!table.isPointerRenameRegion(NSPoint(x: name.minX + 10, y: name.midY), row: 0))
        #expect(!table.isPointerRenameRegion(NSPoint(x: date.midX, y: date.midY), row: 0))
    }
}

@MainActor final class P18Scheduler {
    var work: [@MainActor () -> Void] = []; var delays: [TimeInterval] = []; var cancelCount = 0
    lazy var schedule: PointerRenameIntent.Scheduler = { [unowned self] delay, callback in
        delays.append(delay); work.append(callback); return { self.cancelCount += 1 }
    }
}
@MainActor final class P18Rows: NSObject, NSTableViewDataSource { func numberOfRows(in tableView: NSTableView) -> Int { 3 } }
@MainActor func p18Wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition())
}
@MainActor final class P18Fixture {
    let root: URL, board: NSPasteboard, store: ExplorerStore
    let scheduler = P18Scheduler()
    let loader = P18Loader()
    let operations = P18Operations()
    var coordinator: FileCollectionView.Coordinator?, window: NSWindow?
    var items: [FileItem] { store.tabs[0].items }
    static func identity(_ inode: UInt64) -> LocalFileIdentity { LocalFileIdentity(device: 1, inode: inode, birthSeconds: 1, birthNanoseconds: 0) }
    private init(openWithTypeReservations: OpenWithTypeReservations?) {
        root = URL(fileURLWithPath: "/tmp/explorer-p18a-model-\(UUID().uuidString)", isDirectory: true)
        board = NSPasteboard(name: NSPasteboard.Name("p18a-\(UUID().uuidString)"))
        store = ExplorerStore(initialURL: root, loader: loader, homeURL: root, operations: operations, clipboard: TransferClipboard(pasteboard: board), recovery: operations,
                              openWithTypeReservations: openWithTypeReservations)
        store.pointerRename = PointerRenameIntent(schedule: scheduler.schedule, delay: { 0.5 })
        // Synthetic items have no on-disk entries; routing revalidation is tested separately.
        store.validateRoutingTarget = { _ in true }
        store.validateRoutingFolder = { _, _ in true }
        store.applications = P18Router()
    }
    static func make(openWithTypeReservations: OpenWithTypeReservations? = nil) async throws -> P18Fixture {
        _ = NSApplication.shared
        let fixture = P18Fixture(openWithTypeReservations: openWithTypeReservations)
        try await p18Wait { !fixture.store.activeTab.isLoading }
        return fixture
    }
    func select(_ items: [FileItem]) { store.setSelection(Set(items.map(\.id)), focusedID: items.last?.id, anchorID: items.first?.id); coordinator?.update() }
    func mountCollection() {
        _ = NSApplication.shared; store.setViewMode(.largeIcons)
        let c = FileCollectionView.Coordinator(store: store); coordinator = c
        let scroll = c.makeScrollView(); scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let w = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; window = w; w.contentView = scroll
        scroll.tile(); scroll.layoutSubtreeIfNeeded(); c.collection?.layoutSubtreeIfNeeded()
        if let view = c.collection { w.makeFirstResponder(view) }
    }
    func mouse(_ type: NSEvent.EventType, point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }
    func close() { store.cancelNameEdit(); store.cancelPointerRename(); coordinator?.dismantle(); store.cancelLoads(); window?.close(); board.releaseGlobally() }
}
actor P18Loader: DirectoryListing {
    var snapshotCount = 0
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        snapshotCount += 1
        let items = ["Folder", "Alpha.txt", "Bravo.txt"].enumerated().map { i, name in
            FileItem(url: url.appendingPathComponent(name), name: name, isDirectory: i == 0, isSymbolicLink: false, size: i == 0 ? nil : 1, modifiedAt: nil, kind: i == 0 ? "Folder" : "Text", identity: LocalFileIdentity(device: 1, inode: UInt64(i + 101), birthSeconds: 1, birthNanoseconds: 0))
        }
        return DirectorySnapshot(items: items, directoryIdentity: LocalFileIdentity(device: 1, inode: 100, birthSeconds: 1, birthNanoseconds: 0))
    }
}
actor P18Operations: FileOperating, FileRecovering {
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult { throw FileOperationError.collision(name) }
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult { FileOperationResult(url: context.directoryURL.appendingPathComponent(name), identity: item.identity, warning: nil) }
    private(set) var trashedNames: [String] = []
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult { trashedNames.append(item.name); throw FileOperationError.unsupported("Synthetic test") }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult { throw FileOperationError.unsupported("Synthetic test") }
}
