import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

private actor SidebarControlledLoader: DirectoryListing {
    struct Request: Sendable { let url: URL; let showHidden: Bool }
    private(set) var requests: [Request] = []
    private var completions: [Int: CheckedContinuation<DirectorySnapshot, Error>] = [:]

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(Request(url: url, showHidden: showHidden))
            completions[index] = continuation
        }
    }
    func succeed(_ index: Int, _ items: [FileItem] = []) {
        succeed(index, snapshot: DirectorySnapshot(items: items))
    }
    func succeed(_ index: Int, snapshot: DirectorySnapshot) {
        completions.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func fail(_ index: Int) { completions.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
}

@MainActor
final class SidebarTests {
    @Test
    func testNativeSidebarMenuRetainsDispatchWithPinAndUnpinArtwork() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerSidebarMenu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let pins = PinnedFolderStore(homeURL: root)
        let store = ExplorerStore(initialURL: root, homeURL: root, pins: pins)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        let coordinator = SidebarOutline.Coordinator(store: store, model: store.sidebarModel)
        let outline = NavigationOutlineView()
        let column = NSTableColumn(identifier: .init("destination"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline

        let home = try #require(store.sidebarModel.roots.first { $0.key == "home" })
        store.sidebarModel.expand(home)
        try await waitUntil { home.state == .loaded }

        func menu() throws -> NSMenu {
            coordinator.update()
            let row = try #require((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarNode)?.url == target
            })
            return try #require(coordinator.menu(for: row))
        }
        let stalePinMenu = try menu()
        #expect(pins.pin(target))
        stalePinMenu.performActionForItem(at: 1)
        #expect(pins.contains(target), "A retained Pin action must never toggle an already-pinned URL")
        pins.unpin(target)

        for (title, expectedPinned) in [("Pin to Quick access", true), ("Unpin from Quick access", false)] {
            let context = try menu()
            #expect(context.items.map(\.title) == ["Open in New Tab", title])
            #expect(context.items.allSatisfy { $0.image != nil && $0.target === coordinator && $0.action != nil })
            let action = try #require(context.item(withTitle: title))
            context.performActionForItem(at: context.index(of: action))
            #expect(pins.contains(target) == expectedPinned)
        }
    }

    @Test
    func sidebarSecondaryAndControlClicksKeepSelectionAndUseTheClickedRow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let outline = NavigationOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(outline)
        let column = NSTableColumn(identifier: .init("destination"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerSidebarRouting-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExplorerStore(initialURL: root, homeURL: root, pins: PinnedFolderStore(homeURL: root))
        let coordinator = SidebarOutline.Coordinator(store: store, model: store.sidebarModel)
        defer { store.cancelLoads(); store.sidebarModel.cancelLoads() }
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.update()
        outline.deselectAll(nil)
        let selected = outline.selectedRowIndexes
        let row = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.url == root
        })
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        var received: [Int] = []
        outline.onContextMenu = { row, _ in received.append(row) }
        let invocations: [(NSEvent.EventType, NSEvent.ModifierFlags)] = [
            (.rightMouseDown, []), (.leftMouseDown, .control)
        ]
        for (type, modifiers) in invocations {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .rightMouseDown { outline.rightMouseDown(with: event) }
            else { outline.mouseDown(with: event) }
        }
        #expect(received == [row, row])
        #expect(outline.selectedRowIndexes == selected)
        #expect(store.tabs.count == 1)
    }

    /// FR-NAV-006/008 / EV-9002 / AT-NAV-006/008; native persistence and validation subset.
    @Test
    func testPinsPersistDeduplicateLexicalPathsAndNeverAcceptFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerPins-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ExplorerPinTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("Pinned folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("unchanged.txt")
        let bytes = Data("keep me".utf8)
        try bytes.write(to: file)
        let pins = PinnedFolderStore(defaults: defaults)
        for url in pins.urls { pins.unpin(url) }
        #expect(pins.pin(folder))
        #expect(pins.pin(URL(fileURLWithPath: folder.path + "/")))
        #expect(pins.urls.count == 1)
        #expect(!pins.pin(file))
        #expect(pins.errorMessage != nil)
        #expect(!pins.pin(URL(string: "https://example.com/folder")!))
        #expect(!pins.pin(URL(string: "file://server/tmp")!))
        #expect(pins.urls.count == 1)
        #expect(try Data(contentsOf: file) == bytes)
        let restored = PinnedFolderStore(defaults: defaults)
        #expect(restored.contains(folder))
        restored.unpin(folder)
        #expect(restored.urls.isEmpty)
        #expect(PinnedFolderStore(defaults: defaults).urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test
    func testPinsPreserveSymlinkIdentityAndPreviouslySavedUnavailableLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerPinLinks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let pins = PinnedFolderStore()
        #expect(pins.pin(link))
        #expect(pins.urls.last?.path == link.path)
        #expect(!pins.contains(target))
        let suite = "ExplorerUnavailablePinTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = root.appendingPathComponent("Unavailable", isDirectory: true)
        defaults.set([missing.path, missing.path + "/", "https://example.com", "relative", "bad\0path"],
                     forKey: PinnedFolderStore.preferencesKey)
        let restored = PinnedFolderStore(defaults: defaults)
        #expect(restored.urls.filter { $0.path == missing.path }.count == 1)
        #expect(!restored.pin(missing))
        #expect(restored.contains(missing))
        #expect(restored.errorMessage != nil)
    }

    /// FR-SID-LEAF-001 / WLEAF-02: a successful empty listing has no synthetic child.
    @Test
    func testSuccessfulEmptyExpansionHasNoSyntheticChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerSidebarEmpty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root))
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })

        model.expand(home)
        try await waitUntil { home.state == .loaded }

        #expect(home.children.isEmpty)
    }

    @Test
    func testIncompleteEmptyExpansionRemainsExpandableAndCollapseAllowsFreshRead() async throws {
        let root = URL(fileURLWithPath: "/tmp/sidebar-incomplete", isDirectory: true)
        let loader = SidebarControlledLoader()
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0)
        try await waitUntil { home.state == .loaded }
        #expect(home.children.isEmpty && home.isExpandable && home.expanded)
        model.collapse(home)
        model.expand(home)
        try await waitForRequests(2, loader)
        await loader.succeed(1, [item("New", root)])
        try await waitUntil { home.state == .loaded }
        #expect(home.children.map(\.title) == ["New"])
        observe(model, root, [], complete: false)
        #expect(home.children.isEmpty && home.isExpandable && home.expanded)
    }

    @Test
    func testReplacementSnapshotDoesNotTurnTheOldIdentityIntoALeaf() async throws {
        let root = URL(fileURLWithPath: "/tmp/sidebar-replaced-branch", isDirectory: true)
        let loader = SidebarControlledLoader()
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        let original = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 0)
        let replacement = LocalFileIdentity(device: 1, inode: 4, birthSeconds: 5, birthNanoseconds: 0)
        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Child", root, identity: original)])
        try await waitUntil { home.state == .loaded }
        let child = try #require(home.children.first)
        model.expand(child)
        try await waitForRequests(2, loader)
        await loader.succeed(1, snapshot: DirectorySnapshot(items: [], directoryIdentity: replacement,
                                                           isStructureComplete: true))
        try await waitUntil { child.state == .failed }
        #expect(child.isExpandable && child.fileIdentity == original)
        #expect(child.children.first?.retryParent === child)
        let childURL = try #require(child.url)
        model.retry(child)
        try await waitForRequests(3, loader)
        await loader.succeed(2, snapshot: DirectorySnapshot(items: [item("Fresh grandchild", childURL)],
                                                           directoryIdentity: replacement, isStructureComplete: true))
        try await waitUntil { child.state != .loading }
        try #require(child.state == .loaded)
        #expect(child.children.map(\.title) == ["Fresh grandchild"])
        #expect(child.directoryIdentity == replacement && child.fileIdentity == original)

        model.observePhysicalSnapshot(at: childURL,
            snapshot: DirectorySnapshot(items: [], directoryIdentity: original, isStructureComplete: true),
            showHidden: false, explicitlyOpened: false)
        #expect(child.isExpandable && child.children.map(\.title) == ["Fresh grandchild"])

        let secondReplacement = LocalFileIdentity(device: 1, inode: 6, birthSeconds: 7, birthNanoseconds: 0)
        model.collapse(child)
        model.expand(child)
        try await waitForRequests(4, loader)
        await loader.succeed(3, snapshot: DirectorySnapshot(items: [], directoryIdentity: secondReplacement,
                                                           isStructureComplete: true))
        try await waitUntil { child.state == .failed }
        #expect(child.isExpandable && child.directoryIdentity == replacement)

        model.retry(child)
        try await waitForRequests(5, loader)
        let current = DirectorySnapshot(items: [item("Second grandchild", childURL)],
                                        directoryIdentity: secondReplacement, isStructureComplete: true)
        model.observePhysicalSnapshot(at: childURL, snapshot: current, showHidden: false, explicitlyOpened: false)
        #expect(child.state == .failed && child.children.first?.retryParent === child)
        await loader.succeed(4, snapshot: DirectorySnapshot(items: [], directoryIdentity: replacement,
                                                           isStructureComplete: true))
        model.collapse(child)
        model.expand(child)
        try await waitForRequests(6, loader)
        await loader.succeed(5, snapshot: current)
        try await waitUntil { child.state == .loaded }
        #expect(child.children.map(\.title) == ["Second grandchild"])
        #expect(child.directoryIdentity == secondReplacement && child.fileIdentity == original)
    }

    /// FR-NAV-001 / EV-9003 / AT-NAV-001: read-only tree-model subset.
    @Test
    func testExpansionIsLazyShowsOnlyFoldersAndCollapseRejectsLateRead() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-fixture", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        let home = try #require(model.roots.first { $0.key == "home" })
        #expect(await loader.requests.isEmpty)
        model.expand(home)
        try await waitForRequests(1, loader)
        model.collapse(home)
        await loader.succeed(0, [item("stale", root)])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!home.expanded)
        #expect(home.state == .idle)
        #expect(home.children.compactMap(\.url).isEmpty)
        model.expand(home)
        try await waitForRequests(2, loader)
        await loader.succeed(1, [item("Folder", root), item("file.txt", root, directory: false)])
        try await waitUntil { home.state == .loaded }
        #expect(home.children.map(\.title) == ["Folder"])
        #expect(home.children.first?.url?.path == root.appendingPathComponent("Folder").path)
        #expect(await loader.requests.count == 2, "Child folders must not recursively enumerate themselves")
        model.cancelLoads()
    }

    @Test
    func testHiddenSettingRejectsStaleSnapshotAndReadFailureCanRetry() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-fixture", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        let home = try #require(model.roots.first { $0.key == "home" })
        model.expand(home)
        try await waitForRequests(1, loader)
        model.setShowHidden(true)
        try await waitForRequests(2, loader)
        let requests = await loader.requests
        #expect(!requests[0].showHidden)
        #expect(requests[1].showHidden)
        await loader.succeed(0, [item("stale", root)])
        await loader.fail(1)
        try await waitUntil { home.state == .failed }
        #expect(home.children.first?.retryParent === home)
        #expect(home.failure?.contains(root.path) == true)
        #expect(home.children.compactMap(\.url).isEmpty)
        model.retry(home)
        try await waitForRequests(3, loader)
        await loader.succeed(2, [item(".hidden", root)])
        try await waitUntil { home.state == .loaded }
        #expect(home.children.map(\.title) == [".hidden"])
        #expect(home.failure == nil)
        model.cancelLoads()
    }

    /// Native concurrency regression: one folder can be a pin and an expanded child.
    @Test
    func testNestedPinAndExpandedChildOwnIndependentConcurrentReads() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerNestedPins-" + UUID().uuidString)
        let parentURL = fixture.appendingPathComponent("Parent", isDirectory: true)
        let childURL = parentURL.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pins = PinnedFolderStore()
        try #require(pins.pin(parentURL))
        try #require(pins.pin(childURL))
        let loader = SidebarControlledLoader()
        let model = SidebarModel(homeURL: fixture, pins: pins, loader: loader)
        defer { model.cancelLoads() }
        let pinned = model.roots
        let parentPin = try #require(pinned.first { $0.url?.path == parentURL.path })
        let childPin = try #require(pinned.first { $0.url?.path == childURL.path })
        model.expand(parentPin)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Child", parentURL)])
        try await waitUntil { parentPin.state == .loaded }
        let expandedChild = try #require(parentPin.children.first)
        #expect(expandedChild !== childPin)
        #expect(expandedChild.url?.path == childPin.url?.path)

        model.expand(expandedChild)
        try await waitForRequests(2, loader)
        model.expand(childPin)
        try await waitForRequests(3, loader)
        await loader.succeed(2, [item("From pin", childURL)])
        await loader.succeed(1, [item("From child", childURL)])
        try await waitUntil { expandedChild.state == .loaded && childPin.state == .loaded }
        #expect(expandedChild.children.map(\.title) == ["From child"])
        #expect(childPin.children.map(\.title) == ["From pin"])
        model.collapse(expandedChild)
        #expect(childPin.expanded)
        #expect(childPin.children.map(\.title) == ["From pin"])
    }

    /// Native observation adaptation of FR-NAV-001 / EV-9003 / AT-NAV-001.
    /// Only the current directory snapshot is reconciled; other branches are not watched.
    @Test
    func testObservedSnapshotPreservesRetainedSubtreeAndUnrelatedReadWhileRemovingLateChild() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-observed", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        let documents = try #require(model.roots.first { $0.key == "favorite:Documents" })
        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Keep", root), item("Removed", root)])
        try await waitUntil { home.state == .loaded }
        let keep = try #require(home.children.first { $0.title == "Keep" })
        let removed = try #require(home.children.first { $0.title == "Removed" })
        model.expand(keep)
        try await waitForRequests(2, loader)
        await loader.succeed(1, [item("Grandchild", try #require(keep.url))])
        try await waitUntil { keep.state == .loaded }
        let grandchild = try #require(keep.children.first)
        model.expand(removed)
        try await waitForRequests(3, loader)
        model.expand(documents)
        try await waitForRequests(4, loader)

        observe(model, root, [item("Keep", root), item("Added", root), item("file.txt", root, directory: false)])
        #expect(home.children.map(\.title) == ["Added", "Keep"])
        #expect(home.children.last === keep)
        #expect(keep.expanded && keep.state == .loaded)
        #expect(keep.children.first === grandchild)
        #expect(documents.expanded && documents.state == .loading)
        let revision = model.revision
        await loader.succeed(2, [item("Stale", try #require(removed.url))])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.revision == revision, "A removed child's read must not publish an orphan revision")
        #expect(!removed.expanded)
        #expect(removed.children.compactMap(\.url).isEmpty)
        await loader.succeed(3, [item("Unaffected", try #require(documents.url))])
        try await waitUntil { documents.state == .loaded }
        #expect(documents.children.map(\.title) == ["Unaffected"])
        #expect(await loader.requests.count == 4, "Observed snapshots must not trigger recursive or redundant reads")
    }

    @Test
    func testObservedSnapshotSupersedesEveryExpandedPresentationAndRejectsTheirOldReads() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerObservedPins-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("Branch", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let pins = PinnedFolderStore(homeURL: fixture)
        try #require(pins.pin(target))
        let loader = SidebarControlledLoader()
        let model = SidebarModel(homeURL: fixture, pins: pins, loader: loader)
        defer { model.cancelLoads() }
        let root = try #require(model.roots.first { $0.key == "home" })
        model.expand(root)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Branch", fixture)])
        try await waitUntil { root.state == .loaded }
        let home = try #require(root.children.first)
        let pin = try #require(model.roots.first { $0.url?.path == target.path })
        model.expand(home)
        try await waitForRequests(2, loader)
        model.expand(pin)
        try await waitForRequests(3, loader)
        observe(model, target, [item("Current", target)])
        #expect(home.state == .loaded && pin.state == .loaded)
        #expect(home.expanded && pin.expanded)
        #expect(home.children.map(\.title) == ["Current"])
        #expect(pin.children.map(\.title) == ["Current"])
        #expect(home.children.first !== pin.children.first)
        let revision = model.revision
        await loader.succeed(1, [item("Old home", target)])
        await loader.succeed(2, [item("Old pin", target)])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.revision == revision)
        #expect(home.children.map(\.title) == ["Current"])
        #expect(pin.children.map(\.title) == ["Current"])
        #expect(await loader.requests.count == 3)
    }

    @Test
    func testCollapsedBranchKeepsChildrenUnloadedAndUnchangedSnapshotsDoNotReloadOutline() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-no-op", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        let initialRevision = model.revision
        observe(model, root, [item("Ignored", root)])
        #expect(model.revision == initialRevision)
        #expect(home.state == .idle && !home.expanded)
        #expect(home.children.compactMap(\.url).isEmpty)
        #expect(await loader.requests.isEmpty)

        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Keep", root)])
        try await waitUntil { home.state == .loaded }
        let keep = try #require(home.children.first)
        let loadedRevision = model.revision
        observe(model, root, [item("changed-file.txt", root, directory: false), item("Keep", root)])
        #expect(model.revision == loadedRevision)
        #expect(home.children.first === keep)
        observe(model, root, [])
        #expect(home.children.isEmpty && !home.isExpandable && !home.expanded)
        let emptyRevision = model.revision
        observe(model, root, [])
        #expect(model.revision == emptyRevision)
        #expect(await loader.requests.count == 1)
    }

    @Test
    func testObservedRenameAndKnownSamePathReplacementDiscardOldSubtrees() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-identity", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        let oldIdentity = LocalFileIdentity(device: 1, inode: 1, birthSeconds: 10, birthNanoseconds: 0)
        let newIdentity = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 20, birthNanoseconds: 0)
        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Original", root, identity: oldIdentity)])
        try await waitUntil { home.state == .loaded }
        let original = try #require(home.children.first)
        model.expand(original)
        try await waitForRequests(2, loader)
        // Even the same identity at a renamed lexical path needs a fresh subtree:
        // all descendant URLs are based on the old path.
        observe(model, root, [item("Renamed", root, identity: oldIdentity)])
        let renamed = try #require(home.children.first)
        #expect(renamed !== original && renamed.title == "Renamed")
        #expect(!renamed.expanded && renamed.state == .idle)
        await loader.succeed(1, [item("Stale", try #require(original.url))])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(original.children.compactMap(\.url).isEmpty)
        model.expand(renamed)
        try await waitForRequests(3, loader)
        observe(model, root, [item("Renamed", root, identity: newIdentity)])
        let replacement = try #require(home.children.first)
        #expect(replacement !== renamed)
        #expect(replacement.fileIdentity == newIdentity)
        #expect(!replacement.expanded && replacement.state == .idle)
        let revision = model.revision
        await loader.succeed(2, [item("Also stale", try #require(renamed.url))])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.revision == revision)
        #expect(replacement.children.compactMap(\.url).isEmpty)
    }

    @Test
    func testKnownToUnknownIdentityDiscardsExpandedSubtreeAndRejectsPendingDescendantRead() async throws {
        let loader = SidebarControlledLoader()
        let root = URL(fileURLWithPath: "/tmp/sidebar-lost-identity", isDirectory: true)
        let model = SidebarModel(homeURL: root, pins: PinnedFolderStore(homeURL: root), loader: loader)
        defer { model.cancelLoads() }
        let home = try #require(model.roots.first { $0.key == "home" })
        let identity = LocalFileIdentity(device: 1, inode: 1, birthSeconds: 10, birthNanoseconds: 0)
        model.expand(home)
        try await waitForRequests(1, loader)
        await loader.succeed(0, [item("Folder", root, identity: identity)])
        try await waitUntil { home.state == .loaded }
        let original = try #require(home.children.first)
        model.expand(original)
        try await waitForRequests(2, loader)
        await loader.succeed(1, [item("Descendant", try #require(original.url))])
        try await waitUntil { original.state == .loaded }
        let descendant = try #require(original.children.first)
        model.expand(descendant)
        try await waitForRequests(3, loader)

        // An unavailable identity cannot establish that a same-path entry is
        // still the previously observed directory, even if its name is unchanged.
        observe(model, root, [item("Folder", root)])
        let replacement = try #require(home.children.first)
        #expect(replacement !== original)
        #expect(replacement.fileIdentity == nil)
        #expect(!replacement.expanded && replacement.state == .idle)
        #expect(replacement.children.compactMap(\.url).isEmpty)
        #expect(!descendant.expanded && descendant.state == .idle)
        let revision = model.revision
        await loader.succeed(2, [item("Stale", try #require(descendant.url))])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.revision == revision)
        #expect(descendant.children.compactMap(\.url).isEmpty)
        #expect(replacement.children.compactMap(\.url).isEmpty)
        #expect(await loader.requests.count == 3)
    }

    private func observe(_ model: SidebarModel, _ url: URL, _ items: [FileItem], complete: Bool = true) {
        model.observePhysicalSnapshot(at: url, snapshot: DirectorySnapshot(items: items, isStructureComplete: complete),
                                     showHidden: model.showHidden, explicitlyOpened: false)
    }

    private func item(_ name: String, _ parent: URL, directory: Bool = true, identity: LocalFileIdentity? = nil) -> FileItem {
        FileItem(url: parent.appendingPathComponent(name, isDirectory: directory), name: name,
                 isDirectory: directory, isSymbolicLink: false, size: directory ? nil : 1,
                 modifiedAt: nil, kind: directory ? "File folder" : "File", identity: identity)
    }
    private func waitForRequests(_ count: Int, _ loader: SidebarControlledLoader) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await loader.requests.count < count, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(await loader.requests.count >= count)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try #require(predicate())
    }
}
