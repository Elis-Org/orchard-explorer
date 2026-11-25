import AppKit
import ExplorerCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ExplorerApp

private struct ZIPAppEmptyLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
}

private struct ZIPAppRefusingContentProvider: ItemContentProviding {
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        throw ItemContentError.unsupportedType
    }
}

private final class ZIPAppObserver: DirectoryObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var observed: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        lock.lock(); urls.append(url); lock.unlock()
        return AsyncThrowingStream { _ in }
    }
}

private actor ZIPRevisionGate {
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var releasedResult: Bool?
    func check() async -> Bool {
        calls += 1
        if let releasedResult { return releasedResult }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ result: Bool) {
        releasedResult = result
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume(returning: result) }
    }
}

@MainActor
final class ZIPAppRouter: ApplicationRouting {
    var applicationRequests: [URL] = []
    var opened: [URL] = []
    var revealed: [URL] = []
    var terminals: [URL] = []
    func applications(toOpen url: URL) -> [ApplicationChoice] { applicationRequests.append(url); return [] }
    func open(_ urls: [URL], withApplicationAt application: URL) async throws { opened += urls }
    func openInTerminal(_ folder: URL) async throws { terminals.append(folder) }
    func revealInFinder(_ urls: [URL]) { revealed += urls }
    func eligibleOpenWithType(for file: URL) -> UTType? { nil }
    func chooseApplication(for document: URL, title: String, allowsDefaultAssociation: Bool,
                           eligibleType: UTType?) -> ApplicationPickerSelection? { nil }
    func setDefaultApplication(at application: URL, forType type: UTType) async throws {
        Issue.record("ZIP browsing should not assign a type default")
    }
    func setDefaultApplication(at application: URL, forFile file: URL) async throws {
        Issue.record("ZIP browsing should not assign an external app")
    }
    func icon(forApplicationAt url: URL) -> NSImage { NSImage(size: NSSize(width: 16, height: 16)) }
    func openWithDefaultApplications(_ urls: [URL]) -> [URL] { opened += urls; return [] }
}

/// FR-EXT-007 / EV-0338–0342 / AT-EXT-007, with supplemental Windows ZIP
/// Back/Forward/Up observations. These are native model/control assertions,
/// separate from actual desktop input and visual fidelity. No payload is extracted.
@Suite(.serialized)
@MainActor
struct ZIPBrowsingStoreTests {
    // Deterministic stored ZIP generated in memory: explicit inside/nested and
    // empty folders plus two 24-byte synthetic text files; no external ZIP tool.
    private static let zipBase64 = "UEsDBBQAAAAAAIMYIlwAAAAAAAAAAAAAAAAHAAAAaW5zaWRlL1BLAwQUAAAAAACDGCJcAAAAAAAAAAAAAAAADgAAAGluc2lkZS9uZXN0ZWQvUEsDBBQAAAAAAIMYIlwEjfnBGAAAABgAAAAfAAAAaW5zaWRlL25lc3RlZC9hcmNoaXZlZC1ub3RlLnR4dFN5bnRoZXRpYyBhcmNoaXZlZCBub3RlLlBLAwQUAAAAAACDGCJcBI35wRgAAAAYAAAADQAAAHJvb3Qtbm90ZS50eHRTeW50aGV0aWMgYXJjaGl2ZWQgbm90ZS5QSwMEFAAAAAAAgxgiXAAAAAAAAAAAAAAAAAYAAABlbXB0eS9QSwECFAAUAAAAAACDGCJcAAAAAAAAAAAAAAAABwAAAAAAAAAAAAAAAAAAAAAAaW5zaWRlL1BLAQIUABQAAAAAAIMYIlwAAAAAAAAAAAAAAAAOAAAAAAAAAAAAAAAAACUAAABpbnNpZGUvbmVzdGVkL1BLAQIUABQAAAAAAIMYIlwEjfnBGAAAABgAAAAfAAAAAAAAAAAAAAAAAFEAAABpbnNpZGUvbmVzdGVkL2FyY2hpdmVkLW5vdGUudHh0UEsBAhQAFAAAAAAAgxgiXASN+cEYAAAAGAAAAA0AAAAAAAAAAAAAAAAApgAAAHJvb3Qtbm90ZS50eHRQSwECFAAUAAAAAACDGCJcAAAAAAAAAAAAAAAABgAAAAAAAAAAAAAAAADpAAAAZW1wdHkvUEsFBgAAAAAFAAUALQEAAA0BAAAAAA=="

    private func virtual(_ archive: URL, _ components: [String] = []) -> URL {
        try! ArchiveLocation(archiveURL: archive, components: components).url
    }

    private func settle(_ store: ExplorerStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.activeTab.isLoading || store.activeTab.isRefreshing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(!store.activeTab.isLoading && !store.activeTab.isRefreshing, "ZIP browsing did not settle")
    }

    @Test
    func rootNestedBackForwardAndUpNeverExtractAndRevealDepartedChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPApp-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic bundle.zip")
        let original = try #require(Data(base64Encoded: Self.zipBase64))
        try original.write(to: archive)
        let board = NSPasteboard(name: .init("ZIPApp-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let archiveRoot = virtual(archive)
        store.navigate(to: archiveRoot)
        try await settle(store)
        try #require(store.activeTab.url == archiveRoot, "ZIP root must commit through in-app navigation")
        #expect(Set(store.activeTab.items.map(\.name)) == ["inside", "root-note.txt", "empty"])
        #expect(store.activeTab.folderTitle == archive.lastPathComponent)
        let inside = try #require(store.activeTab.items.first { $0.name == "inside" })
        store.setSelection([inside.id], focusedID: inside.id)
        store.activate(inside)
        try await settle(store)
        #expect(store.activeTab.url == virtual(archive, ["inside"]))
        let nested = try #require(store.activeTab.items.first { $0.name == "nested" })
        store.setSelection([nested.id], focusedID: nested.id)
        store.activate(nested)
        try await settle(store)
        #expect(store.activeTab.items.map(\.name) == ["archived-note.txt"])
        store.back()
        try await settle(store)
        #expect(store.activeTab.url == inside.url)
        #expect(store.selectedItemsInOrder.map(\.name) == ["nested"])
        store.forward()
        try await settle(store)
        #expect(store.activeTab.url == nested.url)
        store.up()
        try await settle(store)
        #expect(store.selectedItemsInOrder.map(\.name) == ["nested"])
        store.up()
        try await settle(store)
        #expect(store.activeTab.url == archiveRoot)
        #expect(store.selectedItemsInOrder.map(\.name) == ["inside"])
        store.up()
        try await settle(store)
        #expect(store.activeTab.url == root.standardizedFileURL)
        #expect(store.selectedItemsInOrder.map(\.name) == [archive.lastPathComponent])
        store.navigate(to: archiveRoot)
        try await settle(store)
        let rootNote = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
        store.setSelection([rootNote.id], focusedID: rootNote.id)
        store.requestAddressEditing()
        store.address.updateText(archive.path + "/inside/nested", showHidden: false)
        store.submitAddress(try #require(store.address.submissionURL(relativeTo: store.activeTab.url)))
        try await settle(store)
        #expect(store.activeTab.url == virtual(archive, ["inside", "nested"]))
        store.back()
        try await settle(store)
        #expect(store.selectedItemsInOrder.map(\.name) == ["root-note.txt"], "History restores the actual prior selection")
        store.navigate(to: virtual(archive, ["inside", "nested"]))
        try await settle(store)
        store.navigateBreadcrumb(to: archiveRoot)
        try await settle(store)
        #expect(store.selectedItemsInOrder.map(\.name) == ["inside"], "Breadcrumb reveals the child instead")
        let empty = try #require(store.activeTab.items.first { $0.name == "empty" })
        store.activate(empty)
        try await settle(store)
        #expect(store.activeTab.items.isEmpty && store.activeTab.hasLoaded && !store.activeTab.isUnavailable)
        #expect(try Data(contentsOf: archive) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [archive.lastPathComponent])
    }

    @Test
    func physicalZIPActivationUsesInAppListingWithoutDefaultApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPActivation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic.ZIP")
        try #require(Data(base64Encoded: Self.zipBase64)).write(to: archive)
        let board = NSPasteboard(name: .init("ZIPActivation-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let router = ZIPAppRouter()
        store.applications = router
        let item = try #require(store.activeTab.items.first)
        store.activate(item)
        try await settle(store)
        #expect(router.opened.isEmpty)
        #expect(store.activeTab.url == virtual(archive))
        #expect(Set(store.activeTab.items.map(\.name)) == ["inside", "root-note.txt", "empty"])
    }

    @Test
    func mixedPhysicalSelectionRoutesZIPToBrowsingAndOnlyOrdinaryFileToApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPRouting-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic bundle.zip")
        let original = try #require(Data(base64Encoded: Self.zipBase64))
        try original.write(to: archive)
        let ordinary = root.appendingPathComponent("ordinary.txt")
        try Data("Synthetic ordinary file.".utf8).write(to: ordinary)
        let board = NSPasteboard(name: .init("ZIPRouting-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let router = ZIPAppRouter()
        store.applications = router
        let items = store.activeTab.items
        try #require(items.count == 2)
        store.setSelection(Set(items.map(\.id)), focusedID: items.first?.id)
        // Baseline multi-open already uses this injected router. Never invoke
        // baseline single-file activate(), which directly uses NSWorkspace.
        store.openSelection()
        let deadline = Date().addingTimeInterval(3)
        while router.opened.isEmpty && store.tabs.count == 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await settle(store)
        #expect(router.opened.map(\.path) == [ordinary.path])
        #expect(!router.opened.contains { $0.path == archive.path })
        #expect(store.tabs.contains { $0.url == virtual(archive) && $0.hasLoaded && !$0.isUnavailable })
        #expect(store.tabs.count == 2)
        #expect(try Data(contentsOf: archive) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            == [archive.lastPathComponent, ordinary.lastPathComponent])
    }

    @Test
    func breadcrumbsIncludePhysicalParentsArchiveRootAndVirtualAncestors() {
        let archive = URL(fileURLWithPath: "/tmp/ZIP App/Synthetic bundle.zip")
        let location = virtual(archive, ["inside", "nested"])
        let expected = NativeAddressBar.breadcrumbURLs(for: archive.deletingLastPathComponent())
            + [virtual(archive), virtual(archive, ["inside"]), location]
        #expect(NativeAddressBar.breadcrumbURLs(for: location) == expected)
        let composed = virtual(archive, ["\u{00e9}"])
        let decomposed = virtual(archive, ["e\u{0301}"])
        let row = FileItem(url: decomposed, name: "e\u{0301}", isDirectory: true,
            isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Folder")
        #expect(!ItemReveal.navigationChild(composed).entries[0].matches(row))
        #expect(ItemReveal.navigationChild(decomposed).entries[0].matches(row))
    }

    @Test
    func virtualEntriesCannotAdvertiseOrDispatchPhysicalCommands() async throws {
        let root = URL(fileURLWithPath: "/tmp/ZIP App", isDirectory: true)
        let archive = root.appendingPathComponent("Synthetic bundle.zip")
        let location = virtual(archive)
        let folder = FileItem(url: virtual(archive, ["inside"]), name: "inside", isDirectory: true,
            isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Folder")
        let file = FileItem(url: virtual(archive, ["root-note.txt"]), name: "root-note.txt", isDirectory: false,
            isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text Document")
        let board = NSPasteboard(name: .init("ZIPCapabilities-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, loader: ZIPAppEmptyLoader(), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        // Install a committed virtual snapshot through existing APIs so this
        // boundary regression compiles and fails even before archive loading exists.
        store.tabs[0].history = NavigationHistory(initialURL: location)
        store.tabs[0].items = [folder, file]
        store.tabs[0].directoryIdentity = nil
        store.setSelection([file.id], focusedID: file.id)
        let router = ZIPAppRouter()
        store.applications = router
        var propertyCalls = 0
        store.onShowProperties = { _ in propertyCalls += 1 }

        #expect(!store.canCreateFolder && !store.canRenameSelection && !store.canCopySelection)
        #expect(!store.canPaste && !store.canTrashSelection && !store.canCompressSelection && !store.canMakeAliases)
        #expect(!store.canSearch)
        #expect(!store.canOpenSelection)
        #expect(store.openWithTarget == nil)
        #expect(!store.canShowProperties && !store.canShowFolderProperties)
        #expect(!store.canOpenInTerminal(folder) && !store.canOpenCurrentFolderInTerminal)
        #expect(!store.canRevealInFinder)
        #expect(store.fileDragEntries(itemIDs: [file.id]) == nil)
        #expect(store.fileDropBinding(destinationURL: folder.url) == nil)
        store.showProperties()
        store.showFolderProperties()
        store.revealInFinder([file.url])
        _ = store.applicationsToOpen(file)
        #expect(propertyCalls == 0)
        #expect(router.revealed.isEmpty && router.applicationRequests.isEmpty)
        store.beginCreateFolder(); store.beginRename(); store.copySelection(); store.cutSelection(); store.trashSelection()
        #expect(store.nameEdit == nil && !store.isPerformingOperation && store.clipboard.payload == nil)
    }

    @Test
    func archiveAddressUsesLogicalPathAndDoesNotExportFileTransferURL() async throws {
        let root = URL(fileURLWithPath: "/tmp/ZIP App", isDirectory: true)
        let archive = root.appendingPathComponent("Synthetic bundle.zip")
        let location = virtual(archive, ["inside"])
        let board = NSPasteboard(name: .init("ZIPAddress-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, loader: ZIPAppEmptyLoader(), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        store.tabs[0].history = NavigationHistory(initialURL: location)
        store.requestAddressEditing()
        #expect(store.address.text == archive.path + "/inside")
        #expect(store.address.submissionURL(relativeTo: location) == location)
        store.address.cancel()
        store.copyAddress(asText: false, to: board)
        #expect(board.string(forType: .string) == archive.path + "/inside")
        #expect(board.string(forType: .fileURL) == nil)
        #expect(store.clipboard.payload == nil)
    }

    @Test
    func archiveContextCommandsTabsAndReplacementShareRevisionValidation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPContext-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic.zip")
        let original = try #require(Data(base64Encoded: Self.zipBase64))
        try original.write(to: archive)
        let board = NSPasteboard(name: .init("ZIPContext-\(UUID())"))
        defer { board.releaseGlobally() }
        let archiveRoot = virtual(archive)
        let store = ExplorerStore(tab: BrowserTab(url: archiveRoot), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board), contentProvider: ZIPAppRefusingContentProvider())
        var detachedStore: ExplorerStore?
        defer { store.cancelLoads(); detachedStore?.cancelLoads() }
        try await settle(store)
        try #require(store.activeTab.hasLoaded && !store.activeTab.isUnavailable)
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: nil) as? ContextCommandMenu)
        let viewMenu = try #require(menu.items.first { $0.identifier?.rawValue == "context-view" }?.submenu)
        let listItem = try #require(viewMenu.items.first { ($0.representedObject as? Int) == FolderViewMode.list.rawValue })
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        #expect(session.activate(listItem))
        let deadline = Date().addingTimeInterval(3)
        while store.activeTab.viewMode != .list, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(store.activeTab.viewMode == .list, "Virtual background menus validate the container rather than a physical member folder")
        let folder = try #require(store.activeTab.items.first { $0.name == "inside" })
        store.setSelection([folder.id], focusedID: folder.id)
        let captured = ContextMenuSnapshot(store: store, item: folder)
        let revision = try #require(store.activeTab.archiveRevision)
        #expect(folder.identity == nil && folder.archiveRevision == revision)
        #expect(!ExplorerIcons.usesPhysicalIcon(folder))
        let file = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
        store.setSelection([file.id], focusedID: file.id)
        #expect(!controller.menu(for: file).items.contains { $0.identifier?.rawValue == "context-share" })
        let router = ZIPAppRouter(); store.applications = router
        store.activate(file)
        let refusalDeadline = Date().addingTimeInterval(3)
        while store.isPerformingOperation, Date() < refusalDeadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(!store.isPerformingOperation, "Failed content preparation must release the routing command")
        #expect(router.opened.isEmpty)
        store.setSelection([folder.id], focusedID: folder.id)
        var openedWindow: URL?
        store.onOpenWindow = { url, key in
            #expect(key == nil)
            openedWindow = url
        }
        store.openInNewWindow(folder)
        let windowDeadline = Date().addingTimeInterval(3)
        while openedWindow == nil, Date() < windowDeadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(openedWindow == folder.url)

        try original.write(to: archive, options: .atomic)
        store.refresh(); try await settle(store)
        #expect(store.activeTab.archiveRevision != revision)
        #expect(store.currentSelection.selectedIDs.isEmpty)
        #expect(!captured.matches(store))
        let replacement = try #require(store.activeTab.items.first { $0.name == "inside" })
        #expect(folder.id == replacement.id && !ExplorerStore.sameEntries([folder], [replacement]))
        store.openInNewTab(folder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.tabs.count == 1, "Old row revision cannot open a new tab")
        store.duplicateTab(store.activeTabID)
        try await settle(store)
        #expect(store.tabs.count == 2 && store.activeTab.url == archiveRoot)
        #expect(!store.activeTab.history.canGoBack && store.currentSelection.selectedIDs.isEmpty)
        store.onDetachTab = { tab, _ in
            detachedStore = ExplorerStore(tab: tab, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        }
        store.detachTab(store.activeTabID)
        let detached = try #require(detachedStore)
        try await settle(detached)
        #expect(detached.activeTab.url == archiveRoot && detached.activeTab.hasLoaded && !detached.activeTab.isUnavailable)
        #expect(router.opened.isEmpty)
        #expect(try Data(contentsOf: archive) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [archive.lastPathComponent])
    }

    @Test
    func corruptRetrySkipsVirtualWatchAndDirectoryNamedZIPRemainsPhysical() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPRetry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("corrupt.zip")
        try Data("not a ZIP".utf8).write(to: archive)
        let directory = root.appendingPathComponent("folder.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("ordinary folder entry".utf8).write(to: directory.appendingPathComponent("folder-note.txt"))
        let board = NSPasteboard(name: .init("ZIPRetry-\(UUID())"))
        defer { board.releaseGlobally() }
        let observer = ZIPAppObserver()
        let store = ExplorerStore(initialURL: root, homeURL: root, observer: observer,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let before = store.activeTab.history
        store.navigate(to: virtual(archive)); try await settle(store)
        #expect(store.activeTab.history == before && store.activeTab.errorMessage != nil)
        try #require(Data(base64Encoded: Self.zipBase64)).write(to: archive, options: .atomic)
        store.retry(); try await settle(store)
        #expect(store.activeTab.url == virtual(archive) && !store.activeTab.isUnavailable)
        #expect(observer.observed.allSatisfy { $0.isFileURL } && store.observationWarning == nil)
        store.up(); try await settle(store)
        let folder = try #require(store.activeTab.items.first { $0.name == "folder.zip" })
        #expect(folder.isDirectory)
        store.activate(folder); try await settle(store)
        #expect(store.activeTab.url.isFileURL && store.activeTab.items.map(\.name) == ["folder-note.txt"])
        store.up(); try await settle(store)
        let link = root.appendingPathComponent("Link.ZIP")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        store.refresh(); try await settle(store)
        let linkedZIP = try #require(store.activeTab.items.first { $0.name == "Link.ZIP" })
        store.activate(linkedZIP); try await settle(store)
        #expect(store.activeTab.url == virtual(link) && store.activeTab.items.contains { $0.name == "inside" })
        #expect(observer.observed.allSatisfy { $0.isFileURL })
    }

    @Test
    func physicalRouterRejectsVirtualURLsBeforeCallingExternalServices() async throws {
        let url = virtual(URL(fileURLWithPath: "/tmp/no-file-needed.zip"), ["note.txt"])
        let router = LocalApplicationRouter()
        #expect(router.applications(toOpen: url).isEmpty)
        #expect(router.openWithDefaultApplications([url]) == [url])
        router.revealInFinder([url])
        await #expect(throws: CocoaError.self) { try await router.openInTerminal(url) }
        await #expect(throws: CocoaError.self) {
            try await router.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Unused.app"))
        }
    }

    @Test
    func cachedContextChecksDiskRevisionWithoutRefreshAndRejectsGenerationChangeDuringValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPDiskRevision-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic.zip")
        let original = try #require(Data(base64Encoded: Self.zipBase64))
        try original.write(to: archive)
        let board = NSPasteboard(name: .init("ZIPDiskRevision-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: virtual(archive), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        let gate = ZIPRevisionGate()
        defer { store.cancelLoads(); Task { await gate.release(false) } }
        try await settle(store)
        try #require(store.activeTab.hasLoaded && !store.activeTab.isUnavailable)
        let folder = try #require(store.activeTab.items.first { $0.name == "inside" })
        store.setSelection([folder.id], focusedID: folder.id)
        let background = ContextMenuSnapshot(store: store, item: nil)
        let item = ContextMenuSnapshot(store: store, item: folder)
        let cachedRevision = store.activeTab.archiveRevision
        let router = ZIPAppRouter(); store.applications = router

        // No Refresh: store generation, rows and revision still match both menus.
        // Only the descriptor check can detect the replaced on-disk container.
        try original.write(to: archive, options: .atomic)
        #expect(store.activeTab.archiveRevision == cachedRevision)
        #expect(background.matches(store) && item.matches(store))
        let backgroundChanges = try #require(await background.identityChanges(in: store))
        let itemChanges = try #require(await item.identityChanges(in: store))
        #expect(!backgroundChanges.isEmpty && !itemChanges.isEmpty)
        #expect(router.opened.isEmpty && router.revealed.isEmpty && router.terminals.isEmpty)

        store.refresh(); try await settle(store)
        let fresh = ContextMenuSnapshot(store: store, item: nil)
        try #require(fresh.matches(store))
        store.validateArchiveRevision = { _, _ in await gate.check() }
        let validation = Task { await fresh.identityChanges(in: store) }
        defer { validation.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while await gate.calls == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let calls = await gate.calls
        try #require(calls == 1)
        // Same location and archive revision; only the load generation changes.
        store.refresh(); try await settle(store)
        #expect(store.activeTab.archiveRevision == fresh.archiveRevision)
        #expect(!fresh.matches(store))
        await gate.release(true)
        let changes = await validation.value
        #expect(changes == nil, "A successful disk check cannot revive a superseded context snapshot")
        #expect(router.opened.isEmpty)
    }

    @Test
    func typedArchiveAddressesNormalizeSeparatorsAndParentsAcrossTheBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPLexicalAddress-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic.zip")
        // Stored, empty sub/, a/ and a/b/ entries; address normalization must not
        // relax the central-directory parser's strict member-name validation.
        let bytes = try #require(Data(base64Encoded: "UEsDBBQAAAAAAIMYIlwAAAAAAAAAAAAAAAAEAAAAc3ViL1BLAwQUAAAAAACDGCJcAAAAAAAAAAAAAAAAAgAAAGEvUEsDBBQAAAAAAIMYIlwAAAAAAAAAAAAAAAAEAAAAYS9iL1BLAQIUABQAAAAAAIMYIlwAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAACAAQAAAABzdWIvUEsBAhQAFAAAAAAAgxgiXAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAIABIgAAAGEvUEsBAhQAFAAAAAAAgxgiXAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAIABQgAAAGEvYi9QSwUGAAAAAAMAAwCUAAAAZAAAAAAA"))
        try bytes.write(to: archive)
        let board = NSPasteboard(name: .init("ZIPLexicalAddress-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: virtual(archive), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        let router = ZIPAppRouter(); store.applications = router
        try await settle(store)
        let cases: [(start: [String], input: String, expected: URL)] = [
            ([], "sub/", virtual(archive, ["sub"])),
            ([], ".", virtual(archive)),
            (["a", "b"], "..", virtual(archive, ["a"])),
            ([], "..", root),
            (["a"], "../..", root),
            ([], "../..", root.deletingLastPathComponent()),
            ([], "a//b", virtual(archive, ["a", "b"])),
            ([], archive.path + "//a/./b/", virtual(archive, ["a", "b"])),
            (["sub"], archive.path + "/a/b/../..", virtual(archive)),
            ([], archive.path + "/../", root)
        ]
        for value in cases {
            store.navigate(to: virtual(archive, value.start)); try await settle(store)
            store.requestAddressEditing()
            store.address.updateText(value.input, showHidden: false)
            let destination = try #require(store.address.submissionURL(relativeTo: store.activeTab.url),
                "Address must resolve: \(value.input)")
            #expect(BrowsingLocation(url: destination) == BrowsingLocation(url: value.expected))
            store.submitAddress(destination); try await settle(store)
            #expect(BrowsingLocation(url: store.activeTab.url) == BrowsingLocation(url: value.expected))
            #expect(store.activeTab.errorMessage == nil)
        }
        // Completion and Enter interpret the same normalized logical address.
        store.navigate(to: virtual(archive)); try await settle(store)
        store.requestAddressEditing()
        store.address.updateText(archive.path + "//a/./", showHidden: false)
        let deadline = Date().addingTimeInterval(3)
        while store.address.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!store.address.isLoading && store.address.errorMessage == nil)
        #expect(store.address.suggestions == [virtual(archive, ["a", "b"])])
        #expect(store.address.submissionURL(relativeTo: store.activeTab.url) == virtual(archive, ["a"]))
        #expect(router.opened.isEmpty && router.applicationRequests.isEmpty)
        #expect(try Data(contentsOf: archive) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [archive.lastPathComponent])
    }

    @Test
    func invalidTypedArchiveAddressShowsFeedbackAndPreservesCommittedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPInvalidAddress-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic.zip")
        try #require(Data(base64Encoded: Self.zipBase64)).write(to: archive)
        let board = NSPasteboard(name: .init("ZIPInvalidAddress-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: virtual(archive), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let item = try #require(store.activeTab.items.first)
        store.setSelection([item.id], focusedID: item.id)
        let history = store.activeTab.history, selection = store.currentSelection, items = store.activeTab.items
        let router = ZIPAppRouter(); store.applications = router
        for input in ["", "bad\0name", "bad\\name"] {
            store.requestAddressEditing()
            store.address.updateText(input, showHidden: false)
            #expect(store.address.submissionURL(relativeTo: store.activeTab.url) == nil)
            #expect(store.address.errorMessage?.isEmpty == false, "Invalid input must explain why Enter did not navigate")
            #expect(store.address.presentation == .completion && store.address.isEditing)
            #expect(store.activeTab.history == history && store.currentSelection == selection)
            #expect(store.activeTab.items == items && !store.activeTab.isLoading)
        }
        #expect(router.opened.isEmpty && router.applicationRequests.isEmpty)
    }

    @Test
    func typedDescendantInDifferentArchiveRefusesWithGuidanceAndPreservesCommittedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPOtherAddress-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentArchive = root.appendingPathComponent("current.zip")
        let otherArchive = root.appendingPathComponent("other.zip")
        let bytes = try #require(Data(base64Encoded: Self.zipBase64))
        try bytes.write(to: currentArchive); try bytes.write(to: otherArchive)
        let board = NSPasteboard(name: .init("ZIPOtherAddress-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: virtual(currentArchive), homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        try await settle(store)
        let note = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
        store.setSelection([note.id], focusedID: note.id)
        let history = store.activeTab.history, selection = store.currentSelection, items = store.activeTab.items
        let router = ZIPAppRouter(); store.applications = router
        store.requestAddressEditing()
        store.address.updateText(otherArchive.path + "/inside/nested", showHidden: false)
        let destination = try #require(store.address.submissionURL(relativeTo: store.activeTab.url))
        #expect(destination.isFileURL, "An unknown archive boundary is not guessed from the extension")
        store.submitAddress(destination); try await settle(store)
        #expect(store.activeTab.history == history)
        #expect(store.currentSelection == selection && store.activeTab.items == items)
        #expect(store.activeTab.errorMessage?.contains("open that ZIP from its containing folder first") == true)
        #expect(router.opened.isEmpty && router.applicationRequests.isEmpty)
        let currentBytes = try Data(contentsOf: currentArchive), otherBytes = try Data(contentsOf: otherArchive)
        #expect(currentBytes == bytes && otherBytes == bytes)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["current.zip", "other.zip"])
    }
}
