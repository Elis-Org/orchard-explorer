import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

/// MAC-082: requests from other applications to open items. Plan grouping is a
/// model test with an injected classifier; classification and the store's reveal use
/// real temporary folders; the busy-window test uses synthetic doubles. No
/// applications are launched.
@Suite(.serialized) @MainActor
struct OpenRequestTests {
    @Test func plainLaunchUsesHomeAndAnExplicitFolderKeepsItsPhysicalLocation() {
        let dashboard = BrowserPage.home.url
        #expect(ExplorerAppDelegate.initialLocation(arguments: ["Maxplorer"]) == dashboard)
        #expect(ExplorerAppDelegate.initialLocation(arguments: ["Maxplorer", "--folder"]) == dashboard)
        for folder in [URL(fileURLWithPath: "/synthetic/Folder With Spaces", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser] {
            let location = ExplorerAppDelegate.initialLocation(arguments: ["Maxplorer", "--folder", folder.path])
            #expect(location == folder && location.isFileURL)
        }
    }

    @Test func planGroupsRevealsByFolderKeepsOrderAndIgnoresNonFiles() {
        let root = URL(fileURLWithPath: "/tmp/open-request-model", isDirectory: true)
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let a1 = folderA.appendingPathComponent("one.txt"), a2 = folderA.appendingPathComponent("two.txt")
        let b1 = root.appendingPathComponent("B/three.txt")
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let plan = OpenRequestPlan.make([a1, URL(string: "https://example.com")!, docs, b1, a2, a1],
                                        isFolder: { $0.path == docs.path })
        #expect(plan.targets == [
            .init(folder: folderA, reveal: [a1, a2]),
            .init(folder: docs, reveal: []),
            .init(folder: root.appendingPathComponent("B", isDirectory: true), reveal: [b1]),
        ])
        #expect(OpenRequestPlan.make([URL(string: "https://example.com")!], isFolder: { _ in true }).isEmpty)
    }

    @Test func classificationOpensFoldersAndRevealsFilesPackagesAndLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRequest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let package = root.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt"); try Data("x".utf8).write(to: file)
        let link = root.appendingPathComponent("FolderLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(OpenRequestPlan.isOpenableFolder(folder))
        #expect(OpenRequestPlan.isOpenableFolder(link), "a link to a folder opens the folder")
        #expect(!OpenRequestPlan.isOpenableFolder(file))
        #expect(!OpenRequestPlan.isOpenableFolder(package), "packages are revealed, not entered")
        #expect(!OpenRequestPlan.isOpenableFolder(root.appendingPathComponent("missing")))
    }

    @Test func storeRevealsRequestedItemsSelectedInANewTabAndInTheActiveTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenReveal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let board = NSPasteboard(name: NSPasteboard.Name("open-request-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        func selectedNames() -> Set<String> {
            Set(store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name))
        }
        try await settled()
        // New tab at the folder with two items selected, the first focused.
        store.openTab(at: folder, revealing: [folder.appendingPathComponent("b.txt"), folder.appendingPathComponent("c.txt")])
        try await settled()
        #expect(store.tabs.count == 2 && store.activeTab.url.path == folder.standardizedFileURL.path)
        #expect(selectedNames() == ["b.txt", "c.txt"])
        #expect(store.activeTab.items.first { $0.id == store.activeTab.selection.focusedID }?.name == "b.txt")
        #expect(store.operationNotice == nil)
        // A folder request: new tab, nothing selected.
        store.openTab(at: folder, revealing: [])
        try await settled(); #expect(store.tabs.count == 3 && selectedNames().isEmpty)
        // The active tab reveals in place; a missing item is reported, the rest selected.
        store.reveal([folder.appendingPathComponent("a.txt"), folder.appendingPathComponent("gone.txt")], in: folder)
        try await settled()
        #expect(store.tabs.count == 3 && selectedNames() == ["a.txt"])
        #expect(store.operationNotice?.hasPrefix("Some requested items aren’t shown in this folder.") == true)
        #expect(store.activeTab.history.canGoBack == false, "revealing in the same folder adds no history entry")
    }

    /// Review bf692ae9 finding 2: a request spelling the name differently from the
    /// listing (case on a case-insensitive volume) selects the entry through its
    /// sampled identity; the search reveal still requires the exact path.
    @Test func caseVariantRequestSelectsTheEntryByIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("r".utf8).write(to: folder.appendingPathComponent("README.md"))
        let variant = folder.appendingPathComponent("readme.MD")
        try #require(FileManager.default.fileExists(atPath: variant.path), "temporary volume is case-insensitive")
        let plan = await OpenRequestPlan.classify([variant])
        let target = try #require(plan.targets.first)
        #expect(target.reveal.map(\.lastPathComponent) == ["readme.MD"] && target.identities[variant.path] != nil)
        let board = NSPasteboard(name: NSPasteboard.Name("open-case-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        let deadline = Date().addingTimeInterval(5)
        func settled() async throws {
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        try await settled()
        #expect(store.openTab(at: target.folder, revealing: target.reveal, identities: target.identities))
        try await settled()
        let selected = store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name)
        #expect(selected == ["README.md"] && store.operationNotice == nil)
        // A search-style entry with the same identity but a different path is not accepted.
        let entry = ItemReveal.Entry(url: variant, identity: target.identities[variant.path])
        let listed = try #require(store.activeTab.items.first { $0.name == "README.md" })
        #expect(!entry.matches(listed), "search reveals keep requiring the exact path (MAC-065)")
    }

    /// Review bf692ae9 finding 1: a window busy with a name draft (or an operation or
    /// Recently Trashed) refuses the request without changing anything, so the app
    /// opens it in a new window instead of dropping it or discarding the draft.
    @Test func busyWindowRefusesAndKeepsItsDraft() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let tabs = f.store.tabs.count
        #expect(f.store.canAcceptOpenRequest)
        f.store.setSelection([f.items[1].id], focusedID: f.items[1].id); f.store.beginRename()
        let draft = try #require(f.store.nameEdit); f.store.updateProposedName("draft-name.txt", sessionID: draft.id)
        #expect(!f.store.canAcceptOpenRequest)
        #expect(!f.store.openTab(at: f.root, revealing: [f.items[2].url]))
        #expect(f.store.tabs.count == tabs && f.store.nameEdit?.proposedName == "draft-name.txt", "draft kept, no tab added")
        f.store.cancelNameEdit()
        f.store.archiver = P18Archive(); f.select([f.items[1]]); f.store.compressSelection(.zip)
        #expect(f.store.isPerformingOperation && !f.store.canAcceptOpenRequest)
        #expect(!f.store.openTab(at: f.root, revealing: []) && f.store.tabs.count == tabs)
        try await p18Wait { !f.store.isPerformingOperation }
        #expect(f.store.openTab(at: f.root, revealing: []) && f.store.tabs.count == tabs + 1)
    }

    /// Review 3c46ad9e finding 4: hard links share an identity, so the identity
    /// fallback also requires the same name apart from case and normalization. A
    /// hidden name never selects a visible hard link, and a case variant selects its
    /// own entry rather than another link to the same file.
    @Test func hardLinksAreNeverSelectedInsteadOfTheRequestedName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLinks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hidden = folder.appendingPathComponent(".wanted.txt"), visible = folder.appendingPathComponent("other.txt")
        try Data("w".utf8).write(to: hidden); try FileManager.default.linkItem(at: hidden, to: visible)
        let readme = folder.appendingPathComponent("README.md"), copy = folder.appendingPathComponent("copy.md")
        try Data("r".utf8).write(to: readme); try FileManager.default.linkItem(at: readme, to: copy)
        let board = NSPasteboard(name: NSPasteboard.Name("open-links-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        func selected() -> [String] { store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name).sorted() }
        try await settled()
        for (request, expected) in [(hidden, [String]()), (folder.appendingPathComponent("readme.MD"), ["README.md"])] {
            let target = try #require(await OpenRequestPlan.classify([request]).targets.first)
            #expect(target.identities[request.path] != nil)
            store.dismissOperationNotice()
            #expect(store.openTab(at: target.folder, revealing: target.reveal, identities: target.identities))
            try await settled()
            #expect(selected() == expected, "\(request.lastPathComponent)")
            #expect((store.operationNotice != nil) == expected.isEmpty, "a hidden requested name is reported, not substituted")
        }
    }

    /// Review 865f9739 finding 6: on a case-sensitive volume `report.txt` and
    /// `REPORT.txt` can be hard links to one file. No identity is sampled there, so
    /// if the requested name disappears before the listing, the other link is never
    /// selected instead; the missing item is reported.
    @Test func caseSensitiveVolumeNeverFallsBackToAnotherLink() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCaseSensitive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("cs.dmg"), mount = base.appendingPathComponent("Volume", isDirectory: true)
        func run(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0, "hdiutil \(arguments.first ?? "")")
        }
        try run(["create", "-quiet", "-size", "16m", "-fs", "Case-sensitive APFS", "-volname", "OpenCS", image.path])
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { try? run(["detach", "-quiet", "-force", mount.path]); try? FileManager.default.removeItem(at: base) }
        let folder = mount.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lower = folder.appendingPathComponent("report.txt"), upper = folder.appendingPathComponent("REPORT.txt")
        try Data("r".utf8).write(to: lower); try FileManager.default.linkItem(at: lower, to: upper)
        #expect(try mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true)
        let target = try #require(await OpenRequestPlan.classify([lower]).targets.first)
        #expect(target.identities.isEmpty, "no fallback identity on a case-sensitive volume")
        try FileManager.default.removeItem(at: lower)   // gone before the listing is read
        let board = NSPasteboard(name: NSPasteboard.Name("open-cs-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: folder, homeURL: folder, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(10)
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        try await settled()
        #expect(store.openTab(at: target.folder, revealing: target.reveal, identities: target.identities))
        try await settled()
        #expect(store.activeTab.selection.selectedIDs.isEmpty, "REPORT.txt is not selected instead")
        #expect(store.operationNotice?.hasPrefix("“report.txt” isn’t shown in this folder.") == true)
    }

    /// MAC-083: a request for a folder that a tab already shows reuses that tab
    /// (activating it and selecting the items) instead of adding one; a folder
    /// spelled through a link (/var vs /private/var) is recognized; search tabs and
    /// busy windows are not reused.
    @Test func requestsReuseATabAlreadyShowingTheFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenReuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true), other = root.appendingPathComponent("Other", isDirectory: true)
        for directory in [folder, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        // The tab shows the link-resolved spelling (/private/var/…); requests use /var/….
        let resolvedFolder = URL(fileURLWithPath: try #require(OpenRequestPlan.alternateSpellings(of: folder).first { $0.hasPrefix("/private/") }), isDirectory: true)
        try #require(resolvedFolder.path != folder.path, "temporary directory is reached through a link")
        let board = NSPasteboard(name: NSPasteboard.Name("open-reuse-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: resolvedFolder, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        func selected() -> [String] { store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name).sorted() }
        try await settled()
        let folderTab = store.activeTabID
        store.openTab(at: other); try await settled()
        #expect(store.tabs.count == 2 && store.activeTabID != folderTab)
        let plan = await OpenRequestPlan.classify([folder.appendingPathComponent("b.txt")])
        let target = try #require(plan.targets.first)
        #expect(target.alternateFolderPaths.contains(resolvedFolder.path))
        // Reused: the Folder tab becomes active with b.txt selected; no tab is added.
        #expect(store.showInExistingTab(target.folder, revealing: target.reveal, identities: target.identities, alternatePaths: target.alternateFolderPaths))
        try await settled()
        #expect(store.tabs.count == 2 && store.activeTabID == folderTab && selected() == ["b.txt"])
        #expect(!store.activeTab.history.canGoBack, "no history entry for the same folder")
        // A folder request just activates its tab.
        store.activateTab(store.tabs[1].id); try await settled()
        #expect(store.showInExistingTab(folder, revealing: [], alternatePaths: target.alternateFolderPaths))
        #expect(store.activeTabID == folderTab && store.tabs.count == 2)
        try await settled()   // a folder request re-reads the reused tab (it supersedes pending navigation)
        // No tab shows the folder: nothing changes.
        #expect(!store.showInExistingTab(root, revealing: [root.appendingPathComponent("Folder")]))
        #expect(store.tabs.count == 2 && store.activeTabID == folderTab)
        // A busy window (name draft) is not reused and keeps its draft.
        store.setSelection([store.activeTab.items[0].id], focusedID: store.activeTab.items[0].id); store.beginRename()
        #expect(!store.showInExistingTab(target.folder, revealing: target.reveal, alternatePaths: target.alternateFolderPaths))
        #expect(store.nameEdit != nil); store.cancelNameEdit()
        // A search tab shows results, not the folder, and is not reused.
        store.submitSearch("a")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.tabShowing(target.folder, alternatePaths: target.alternateFolderPaths) == nil)
    }

    /// Review e73b0f67 findings 2–3: folders are matched by identity, so a tab opened
    /// through a link is reused for a request using the real path and vice versa, and
    /// items reaching one folder through different spellings are merged into one
    /// target so every requested item is selected.
    @Test func linkedFoldersAreReusedInBothDirectionsAndMergedRequestsKeepEveryItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLinked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Real", isDirectory: true), link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: real.appendingPathComponent(name)) }
        let board = NSPasteboard(name: NSPasteboard.Name("open-linked-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        for (tabFolder, requested) in [(link, real), (real, link)] {
            let store = ExplorerStore(initialURL: tabFolder, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
            defer { store.cancelLoads() }
            func settled() async throws {
                let deadline = Date().addingTimeInterval(5)
                while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
                try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
            }
            try await settled()
            let target = try #require(await OpenRequestPlan.classify([requested.appendingPathComponent("b.txt")]).targets.first)
            #expect(target.folderIdentity != nil && target.folderIdentity == store.activeTab.directoryIdentity)
            #expect(store.showInExistingTab(target.folder, revealing: target.reveal, identities: target.identities,
                                            alternatePaths: target.alternateFolderPaths, folderIdentity: target.folderIdentity),
                    "tab at \(tabFolder.lastPathComponent) reused for \(requested.lastPathComponent)")
            try await settled()
            #expect(store.tabs.count == 1)
            #expect(store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name) == ["b.txt"])
        }
        // One request naming items through both spellings becomes one target with both items.
        let plan = await OpenRequestPlan.classify([real.appendingPathComponent("a.txt"), link.appendingPathComponent("b.txt")])
        #expect(plan.targets.count == 1)
        #expect(plan.targets.first?.reveal.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(plan.targets.first?.folder.lastPathComponent == "Real")
    }

    /// Review e73b0f67 finding 1: reusing a tab for a folder request supersedes a
    /// navigation still pending in that tab, so the requested folder stays shown.
    @Test func folderRequestSupersedesAPendingNavigationInTheReusedTab() async throws {
        let a = URL(fileURLWithPath: "/tmp/open-pending-A", isDirectory: true), b = URL(fileURLWithPath: "/tmp/open-pending-B", isDirectory: true)
        let loader = DeferredOpenLoader()
        let board = NSPasteboard(name: NSPasteboard.Name("open-pending-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: a, loader: loader, homeURL: a, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func requests(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while await loader.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(await loader.count >= count)
        }
        try await requests(1); await loader.complete(0)
        let deadline = Date().addingTimeInterval(5)
        while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        store.navigate(to: b); try await requests(2)            // B is pending
        #expect(store.activeTab.url.path == a.path)
        #expect(store.showInExistingTab(a, revealing: []))
        try await requests(3)                                   // the request issued its own read of A
        await loader.complete(2)
        await loader.complete(1)                                // the superseded B read finishes late
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.activeTab.url.path == a.path, "the requested folder stays shown")
    }

    /// Review dfdb1ba9 finding 5: without identities (e.g. network volumes), a folder
    /// and items in it still form one target, in either order, and targets whose
    /// link-resolved paths agree are merged, so no request cancels another's reveal.
    @Test func sameFolderTargetsCombineWithoutIdentities() {
        let folder = URL(fileURLWithPath: "/Volumes/Share/A", isDirectory: true)
        let item = folder.appendingPathComponent("item.txt")
        for urls in [[item, folder], [folder, item]] {
            let plan = OpenRequestPlan.make(urls, isFolder: { $0.path == folder.path })
            #expect(plan.targets.count == 1 && plan.targets.first?.reveal == [item], "\(urls.map(\.lastPathComponent))")
        }
        var viaLink = OpenRequestPlan.Target(folder: URL(fileURLWithPath: "/Volumes/Share/Link", isDirectory: true),
                                             reveal: [URL(fileURLWithPath: "/Volumes/Share/Link/b.txt")])
        viaLink.alternateFolderPaths = [folder.path]
        var direct = OpenRequestPlan.Target(folder: folder, reveal: [item])
        direct.alternateFolderPaths = []
        let merged = OpenRequestPlan.mergingSameFolder([direct, viaLink])
        #expect(merged.count == 1 && merged.first?.reveal.map(\.lastPathComponent) == ["item.txt", "b.txt"])
    }

    /// Review dfdb1ba9 finding 4: a tab matched only by its cached folder identity
    /// navigates to the requested spelling, so a link retargeted since the tab loaded
    /// cannot redirect the request into another folder.
    @Test func retargetedLinkUnderAnInactiveTabDoesNotRedirectTheRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRetarget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A", isDirectory: true), b = root.appendingPathComponent("B", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true), home = root.appendingPathComponent("Home", isDirectory: true)
        for directory in [a, b, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: a.appendingPathComponent("x.txt")); try Data("y".utf8).write(to: b.appendingPathComponent("y.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let board = NSPasteboard(name: NSPasteboard.Name("open-retarget-\(UUID().uuidString)")); defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: home, homeURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (store.activeTab.isLoading || !store.activeTab.hasLoaded), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading)
        }
        try await settled()
        let homeTab = store.activeTabID
        store.openTab(at: link); try await settled()
        let linkTab = store.activeTabID
        store.activateTab(homeTab); try await settled()         // the Link tab is inactive, with A's identity cached
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)   // Link now names B
        let target = try #require(await OpenRequestPlan.classify([a.appendingPathComponent("x.txt")]).targets.first)
        #expect(store.showInExistingTab(target.folder, revealing: target.reveal, identities: target.identities,
                                        alternatePaths: target.alternateFolderPaths, folderIdentity: target.folderIdentity))
        try await settled()
        #expect(store.activeTabID == linkTab)
        #expect(store.activeTab.url.lastPathComponent == "A", "shows the requested folder, not Link's new target")
        #expect(store.activeTab.items.filter { store.activeTab.selection.selectedIDs.contains($0.id) }.map(\.name) == ["x.txt"])
    }
}

/// A listing whose reads complete only when the test says so (MAC-083 tests).
actor DeferredOpenLoader: DirectoryListing {
    private var pending: [(url: URL, continuation: CheckedContinuation<DirectorySnapshot, Error>)] = []
    var count: Int { pending.count }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { try await snapshot(of: url, showHidden: showHidden).items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await withCheckedThrowingContinuation { pending.append((url, $0)) }
    }
    func complete(_ index: Int) {
        let request = pending[index]
        let item = FileItem(url: request.url.appendingPathComponent("item.txt"), name: "item.txt", isDirectory: false,
                            isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text",
                            identity: LocalFileIdentity(device: 9, inode: UInt64(index + 500), birthSeconds: 1, birthNanoseconds: 0))
        request.continuation.resume(returning: DirectorySnapshot(items: [item], directoryIdentity: LocalFileIdentity(device: 9, inode: UInt64(index + 400), birthSeconds: 1, birthNanoseconds: 0)))
    }
}
