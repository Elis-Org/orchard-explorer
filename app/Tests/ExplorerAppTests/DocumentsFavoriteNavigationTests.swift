import AppKit
@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private final class DocumentsFavoriteFixture {
    let home: URL
    let documents: URL
    let target: URL

    init(redirected: Bool = true) throws {
        let lexical = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentsFavorite-\(UUID())")
        try FileManager.default.createDirectory(at: lexical, withIntermediateDirectories: true)
        home = try FileSystemPath.resolvingExisting(lexical)
        documents = home.appendingPathComponent("Documents", isDirectory: true)
        target = redirected ? home.appendingPathComponent("Library/CloudStorage/OneDrive-Test/Documents", isDirectory: true) : documents
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("owned Documents favorite fixture".utf8).write(to: target.appendingPathComponent("fixture.txt"))
        if redirected { try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: target) }
        for name in ["Desktop", "Downloads", "Pictures", "Music", "Movies"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: home) }
}

private actor DocumentsHeldLoader: DirectoryListing {
    private(set) var hasHeld = false
    private(set) var paths: [String] = []
    private var shouldHold: Bool
    private var releaseRead: CheckedContinuation<Bool, Never>?
    init(holdsFirstDocuments: Bool = true) { shouldHold = holdsFirstDocuments }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let result = try await LocalDirectoryLoader().snapshot(of: url, showHidden: showHidden)
        paths.append(url.standardizedFileURL.path)
        if url.lastPathComponent == "Documents", shouldHold {
            shouldHold = false
            hasHeld = true
            let fail = await withCheckedContinuation { releaseRead = $0 }
            if fail { throw CocoaError(.fileReadNoPermission) }
        }
        return result
    }
    func arm() { shouldHold = true; hasHeld = false }
    func release(failing: Bool = false) { releaseRead?.resume(returning: failing); releaseRead = nil }
}

private final class DocumentsObserver: DirectoryObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation?
    var paths: [String] { lock.withLock { urls.map { $0.standardizedFileURL.path } } }
    func events(for url: URL) throws -> AsyncThrowingStream<DirectoryChange, Error> {
        let pair = AsyncThrowingStream<DirectoryChange, Error>.makeStream()
        lock.withLock { urls.append(url); continuation = pair.continuation }
        return pair.stream
    }
    func emit() { _ = lock.withLock { continuation?.yield(.changed) } }
}

@Suite(.serialized) @MainActor
struct DocumentsFavoriteNavigationTests {
    private func loaded(_ store: ExplorerStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.activeTab.isLoading || !store.activeTab.hasLoaded {
            if ContinuousClock.now >= deadline { Issue.record("Documents navigation did not settle"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { Issue.record("Documents test condition did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: [false, true])
    func builtInDocumentsFavoriteCommitsCanonicalDirectoryAndRows(newTab: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try DocumentsFavoriteFixture()
        let pins = PinnedFolderStore(homeURL: fixture.home)
        // A repeated pin must retain the built-in Documents routing identity.
        try #require(pins.pin(fixture.documents))
        let store = ExplorerStore(initialURL: fixture.home, homeURL: fixture.home, pins: pins)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        let originalTab = store.activeTabID
        let coordinator = SidebarOutline.Coordinator(store: store, model: store.sidebarModel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let outline = NavigationOutlineView(frame: NSRect(x: 0, y: 0, width: 340, height: 480))
        window.contentView?.addSubview(outline)
        let column = NSTableColumn(identifier: .init("destination"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = coordinator; outline.delegate = coordinator; coordinator.outline = outline
        coordinator.update()
        func documentsRow() throws -> Int {
            try #require((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarNode)?.key == "favorite:Documents"
            })
        }
        let row = try documentsRow()
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if newTab {
            let menu = try #require(coordinator.menu(for: row))
            let action = try #require(menu.items.first { $0.identifier?.rawValue == "context-sidebar-open-in-new-tab" })
            try #require(action.target === coordinator && action.action != nil)
            menu.performActionForItem(at: menu.index(of: action))
        } else { coordinator.activateSelection() }
        try await loaded(store)
        let expectedPath = fixture.target.standardizedFileURL.path
        #expect(store.activeTab.url.path == expectedPath)
        #expect(store.activeTab.items.count == 1)
        #expect(store.activeTab.items.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL.path == expectedPath })
        let sampledIdentity = try LocalFileIdentity.read(at: fixture.target, ifLocal: true)
        #expect(store.activeTab.directoryIdentity == sampledIdentity)
        #expect(store.currentSelection.selectedIDs.isEmpty)
        #expect(store.tabs.count == (newTab ? 2 : 1))
        #expect((store.activeTabID != originalTab) == newTab)
        #expect(store.activeTab.history.backStack.map(\.path) == (newTab ? [] : [fixture.home.standardizedFileURL.path]))
        #expect(store.activeTab.errorMessage == nil)
        coordinator.update()
        let selected = outline.item(atRow: outline.selectedRow) as? SidebarNode
        #expect(selected?.key == "favorite:Documents")
        if !newTab {
            outline.onActivateSelection = { [weak coordinator] in coordinator?.activateSelection() }
            for (key, character, folder) in [(UInt16(125), "\u{F701}", "Pictures"), (UInt16(126), "\u{F700}", "Downloads")] {
                outline.selectRowIndexes(IndexSet(integer: try documentsRow()), byExtendingSelection: false)
                coordinator.activateSelection(); try await loaded(store); coordinator.update()
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: key))
                outline.keyDown(with: event)
                try await loaded(store); coordinator.update()
                #expect(store.activeTab.url.path == fixture.home.appendingPathComponent(folder).standardizedFileURL.path)
            }
        }
    }

    @Test(arguments: [true, false])
    func newWindowFromHomePreservesTheSelectedDocumentsRoute(knownPin: Bool) async throws {
        let fixture = try DocumentsFavoriteFixture()
        let pins = PinnedFolderStore(homeURL: fixture.home)
        let source = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: fixture.home, pins: pins)
        let observer = DocumentsObserver()
        var receiver: ExplorerStore?
        defer { source.cancelLoads(); receiver?.cancelLoads() }
        source.onOpenWindow = { url, key in
            receiver = ExplorerStore(initialURL: url, initialSidebarKey: key,
                                     homeURL: fixture.home, pins: pins, observer: observer)
        }
        let key = knownPin ? "favorite:Documents" : nil
        source.performPageAction(.newWindow, url: fixture.documents, folder: true, pinKey: key)
        try await until { receiver != nil }
        let window = try #require(receiver)
        try await loaded(window)
        let expected = knownPin ? fixture.target : fixture.documents
        #expect(source.activePage == .home)
        #expect(window.activeTab.url.path == expected.standardizedFileURL.path)
        #expect(window.activeTab.history.backStack.isEmpty)
        #expect(window.selectedSidebarFavoriteKey == key)
        #expect(observer.paths == [expected.standardizedFileURL.path])
        #expect(window.activeTab.items.map(\.name) == ["fixture.txt"])
    }

    @Test func ordinaryDocumentsAndPersonalPinsKeepTheirExistingRoute() async throws {
        for redirected in [false, true] {
            let fixture = try DocumentsFavoriteFixture(redirected: redirected)
            let store = ExplorerStore(initialURL: fixture.home, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
            defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
            try await loaded(store)
            let key = redirected ? "pin:" + fixture.documents.path : "favorite:Documents"
            store.activateSidebarItem(key: key, url: fixture.documents)
            try await loaded(store)
            #expect(store.activeTab.url.path == fixture.documents.standardizedFileURL.path)
            #expect(store.activeTab.documentsFavoriteAssociation == nil)
            store.navigate(to: fixture.home); try await loaded(store)
            store.navigate(to: fixture.documents); try await loaded(store)
            #expect(store.activeTab.url.path == fixture.documents.standardizedFileURL.path)
            #expect(store.activeTab.documentsFavoriteAssociation == nil)
        }
    }

    @Test func repeatedFavoritePreservesHistoryAndWatcherAndPassiveRefreshPreservesAssociation() async throws {
        let fixture = try DocumentsFavoriteFixture(), observer = DocumentsObserver()
        let store = ExplorerStore(initialURL: fixture.home, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home), observer: observer)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await loaded(store)
        let history = store.activeTab.history
        #expect(observer.paths.last == fixture.target.standardizedFileURL.path)
        #expect(!observer.paths.contains(fixture.documents.standardizedFileURL.path))
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await loaded(store)
        #expect(store.activeTab.history == history)
        let file = try #require(store.activeTab.items.first)
        store.setSelection([file.id], focusedID: file.id)
        try Data("new synthetic row".utf8).write(to: fixture.target.appendingPathComponent("new.txt"))
        observer.emit()
        try await until { store.activeTab.items.contains { $0.name == "new.txt" } && !store.activeTab.isRefreshing }
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
        #expect(store.currentSelection.selectedIDs == [file.id])
        #expect(store.activeTab.history == history)
        store.back(); try await loaded(store)
        #expect(store.activeTab.url.path == fixture.home.standardizedFileURL.path)
        store.forward(); try await loaded(store)
        #expect(store.activeTab.url.path == fixture.target.standardizedFileURL.path)
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
    }

    @Test func clickingFavoriteFromItsCanonicalFolderDoesNotAddDuplicateBackEntry() async throws {
        let fixture = try DocumentsFavoriteFixture()
        let store = ExplorerStore(initialURL: URL(fileURLWithPath: fixture.target.path, isDirectory: false),
                                  homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        let history = store.activeTab.history
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await loaded(store)
        #expect(store.activeTab.history == history)
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
    }

    @Test func replacingPendingHistoryDestinationPreservesBackAndForwardStacks() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
        let target = URL(fileURLWithPath: "/real-target")
        var history = NavigationHistory(initialURL: a)
        history.navigate(to: b); history.navigate(to: c); _ = history.goBack()
        history.replaceCurrent(with: target)
        #expect(history.current == target && history.backStack == [a] && history.forwardStack == [c])
    }

    @Test(arguments: [false, true])
    func changedLinkOrTargetRefusesSnapshotAndRetryResolvesFavorite(replaceTarget: Bool) async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader()
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await until { await loader.hasHeld }
        let replacement: URL
        if replaceTarget {
            replacement = fixture.target
            try FileManager.default.moveItem(at: fixture.target, to: fixture.target.deletingLastPathComponent().appendingPathComponent("Previous"))
        } else {
            replacement = fixture.home.appendingPathComponent("Library/CloudStorage/OneDrive-Other/Documents")
            try FileManager.default.removeItem(at: fixture.documents)
            try FileManager.default.createSymbolicLink(at: fixture.documents, withDestinationURL: replacement)
        }
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("replacement fixture".utf8).write(to: replacement.appendingPathComponent("replacement.txt"))
        await loader.release(); try await loaded(store)
        #expect(store.activeTab.url.path == fixture.home.standardizedFileURL.path)
        #expect(store.activeTab.errorMessage != nil && store.selectedSidebarFavoriteKey == nil)
        store.retry(); try await loaded(store)
        #expect(store.activeTab.url.path == replacement.standardizedFileURL.path)
        #expect(store.activeTab.items.map(\.name) == ["replacement.txt"])
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
        #expect(store.activeTab.history.backStack.map(\.path) == [fixture.home.standardizedFileURL.path])
    }

    @Test func lateFavoriteLoadCannotReplaceNewerNavigation() async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader()
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await until { await loader.hasHeld }
        let destination = fixture.home.appendingPathComponent("Pictures", isDirectory: true)
        store.navigate(to: destination); try await loaded(store)
        await loader.release()
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.activeTab.url.path == destination.standardizedFileURL.path)
        #expect(store.selectedSidebarFavoriteKey == nil && store.activeTab.errorMessage == nil)
    }

    @Test func closingPendingFavoriteTabCannotChangeRemainingTab() async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader()
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        let original = store.activeTabID
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents, newTab: true)
        try await until { await loader.hasHeld }
        store.closeTab(store.activeTabID)
        await loader.release()
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.activeTabID == original && store.tabs.count == 1)
        #expect(store.activeTab.url.path == fixture.home.standardizedFileURL.path && store.selectedSidebarFavoriteKey == nil)
    }

    @Test func failedNewFavoriteTabNeverObservesOrLoadsItsUncommittedAlias() async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader(), observer = DocumentsObserver()
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home,
                                  pins: PinnedFolderStore(homeURL: fixture.home), observer: observer)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        let originalTab = store.activeTabID
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents, newTab: true)
        let failedTab = store.activeTabID
        try await until { await loader.hasHeld }
        await loader.release(failing: true)
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        // The observation debounce is 150 ms. Leave it time to expose any
        // automatic fallback; the final assertions concern committed state.
        try await Task.sleep(for: .milliseconds(350))
        #expect(!store.activeTab.hasLoaded && store.activeTab.isUnavailable)
        #expect(store.activeTab.errorMessage != nil && store.activeTab.items.isEmpty)
        #expect(!observer.paths.contains(fixture.documents.standardizedFileURL.path))
        #expect(!(await loader.paths).contains(fixture.documents.standardizedFileURL.path))

        store.activateTab(originalTab)
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        store.activateTab(failedTab)
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(!store.activeTab.hasLoaded && store.activeTab.errorMessage != nil)
        #expect(!(await loader.paths).contains(fixture.documents.standardizedFileURL.path))
        store.retry(); try await loaded(store)
        #expect(store.activeTab.url.path == fixture.target.standardizedFileURL.path)
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
        #expect(store.activeTab.errorMessage == nil && !store.activeTab.isUnavailable)
    }

    @Test(arguments: ["refresh", "activation", "hidden"])
    func failedNewFavoriteTabRefreshPathsPreserveFavoriteIntent(trigger: String) async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader()
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents, newTab: true)
        try await until { await loader.hasHeld }
        await loader.release(failing: true)
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        try #require(!store.activeTab.hasLoaded && store.activeTab.errorMessage != nil)
        switch trigger {
        case "refresh": store.refresh()
        case "activation": store.refreshAfterActivation()
        default: store.toggleHidden()
        }
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(!(await loader.paths).contains(fixture.documents.standardizedFileURL.path))
        if trigger == "refresh" {
            // Explicit Refresh is a user retry even before the first commit.
            #expect(store.activeTab.hasLoaded && store.activeTab.url.path == fixture.target.standardizedFileURL.path)
        } else {
            #expect(!store.activeTab.hasLoaded && store.activeTab.errorMessage != nil)
            store.retry(); try await loaded(store)
        }
        #expect(store.activeTab.url.path == fixture.target.standardizedFileURL.path)
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
        #expect(store.activeTab.errorMessage == nil && !store.activeTab.isUnavailable)
    }

    @Test(arguments: [false, true])
    func explicitSameCanonicalPinOrTypedAddressClearsFavoriteSelection(typedAddress: Bool) async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader(holdsFirstDocuments: false)
        let pins = PinnedFolderStore(homeURL: fixture.home)
        try #require(pins.pin(fixture.target))
        let store = ExplorerStore(initialURL: fixture.home, loader: loader, homeURL: fixture.home, pins: pins)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await loaded(store)
        try #require(store.selectedSidebarFavoriteKey == "favorite:Documents")
        let canonical = store.activeTab.url, priorReads = await loader.paths.count
        if typedAddress { store.submitTypedAddress(canonical) }
        else { store.activateSidebarItem(key: "pin:" + canonical.path, url: canonical) }
        // Typed address classification precedes the load; wait for that actual
        // request rather than accepting the previous loaded state as success.
        try await until { await loader.paths.count > priorReads }
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url == canonical)
        #expect(store.activeTab.documentsFavoriteAssociation == nil)
        #expect(store.selectedSidebarFavoriteKey == nil)
    }

    @Test func uncertainSameDestinationRecheckClearsSelectionAndRetryResolvesFavorite() async throws {
        let fixture = try DocumentsFavoriteFixture(), loader = DocumentsHeldLoader(holdsFirstDocuments: false)
        let store = ExplorerStore(initialURL: fixture.target, loader: loader, homeURL: fixture.home, pins: PinnedFolderStore(homeURL: fixture.home))
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        try await loaded(store)
        let row = try #require(store.activeTab.items.first)
        store.setSelection([row.id], focusedID: row.id)
        await loader.arm()
        store.activateSidebarItem(key: "favorite:Documents", url: fixture.documents)
        try await until { await loader.hasHeld }
        let replacement = fixture.home.appendingPathComponent("Library/CloudStorage/OneDrive-Other/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("replacement fixture".utf8).write(to: replacement.appendingPathComponent("replacement.txt"))
        try FileManager.default.removeItem(at: fixture.documents)
        try FileManager.default.createSymbolicLink(at: fixture.documents, withDestinationURL: replacement)
        await loader.release()
        try await until { !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        #expect(store.activeTab.url.path == fixture.target.standardizedFileURL.path)
        #expect(store.activeTab.isUnavailable && store.currentSelection.selectedIDs.isEmpty)
        #expect(store.activeTab.errorMessage != nil && store.selectedSidebarFavoriteKey == nil)
        store.retry(); try await loaded(store)
        #expect(store.activeTab.url.path == replacement.standardizedFileURL.path)
        #expect(store.activeTab.items.map(\.name) == ["replacement.txt"])
        #expect(!store.activeTab.isUnavailable && store.activeTab.errorMessage == nil)
        #expect(store.selectedSidebarFavoriteKey == "favorite:Documents")
    }

    @Test func homeAliasUsesBadgeCompatibleSpellingAndValidatesCanonicalSnapshot() async throws {
        let fixture = try DocumentsFavoriteFixture()
        let alias = fixture.home.appendingPathComponent("HomeAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let candidate = try await DocumentsFavoriteRedirect.resolve(homeURL: alias)
        let redirect = try #require(candidate)
        #expect(redirect.destinationURL.path == alias.standardizedFileURL.appendingPathComponent("Library/CloudStorage/OneDrive-Test/Documents").path)
        #expect(OneDriveRetentionService.isBadgeLocation(redirect.destinationURL, homeURL: alias))
        let snapshot = try await LocalDirectoryLoader().snapshot(of: redirect.destinationURL)
        try await redirect.validate(snapshot)
        await #expect(throws: (any Error).self) { try await redirect.validate(DirectorySnapshot(items: snapshot.items)) }
    }

    @Test(arguments: ["OneDriveElsewhere/Documents", "OneDrive-/Documents", "OneDrive-Test/Nested/Documents", "Other/Documents"])
    func unrelatedAndNonImmediateTargetsUseOrdinaryNavigation(relative: String) async throws {
        let fixture = try DocumentsFavoriteFixture()
        let target = fixture.home.appendingPathComponent("Library/CloudStorage").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.documents)
        try FileManager.default.createSymbolicLink(at: fixture.documents, withDestinationURL: target)
        #expect(try await DocumentsFavoriteRedirect.resolve(homeURL: fixture.home) == nil)
    }

    @Test func unavailableOptionalClassificationFallsBackWithoutGrantingRedirect() async throws {
        let fixture = try DocumentsFavoriteFixture()
        try FileManager.default.removeItem(at: fixture.documents)
        try FileManager.default.createSymbolicLink(at: fixture.documents, withDestinationURL: fixture.home.appendingPathComponent("missing"))
        #expect(try await DocumentsFavoriteRedirect.resolve(homeURL: fixture.home) == nil)
        #expect(try await DocumentsFavoriteRedirect.resolve(homeURL: fixture.home.appendingPathComponent("missing-home")) == nil)
    }
}
