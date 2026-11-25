import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

private struct BadgeViewportEmptyLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
}

@MainActor
private final class BadgeWindowNotifications: NSObject {
    private(set) var events: [String] = []
    init(window: NSWindow) {
        super.init()
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
        }
    }
    @objc private func changed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        events.append("\(notification.name.rawValue):visible=\(window.isVisible),mini=\(window.isMiniaturized)")
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@Suite(.serialized)
@MainActor
struct OneDriveBadgeViewportTests {
    private func item(_ index: Int) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/badge-viewport/\(index).txt"), name: "\(index).txt",
            isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text")
    }

    private func wait(_ condition: () -> Bool) async throws {
        try await wait("Viewport callback did not settle", diagnostics: { "" }, condition)
    }

    private func wait(_ phase: String, diagnostics: () -> String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "\(phase): \(diagnostics())")
    }

    @Test func badgeKeySurvivesPendingFolderReadWhileActionsStayDisabled() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage/OneDrive-BadgeFixture")
        let store = ExplorerStore(initialURL: root, loader: BadgeViewportEmptyLoader(), homeURL: root, observer: nil)
        defer { store.cancelLoads() }
        try await wait { !store.activeTab.isLoading }
        let row = FileItem(url: root.appendingPathComponent("sample.txt"), name: "sample.txt", isDirectory: false,
            isSymbolicLink: false, size: 10, modifiedAt: nil, kind: "Text",
            identity: .init(device: 1, inode: 4, birthSeconds: 1, birthNanoseconds: 0),
            availability: .availableLocally, isRegularFile: true,
            statusVersion: .init(size: 10, modificationSeconds: 1, modificationNanoseconds: 0))
        store.tabs[0].items = [row]
        store.tabs[0].directoryIdentity = .init(device: 1, inode: 3, birthSeconds: 1, birthNanoseconds: 0)
        let settled = try #require(store.pinBadgeEntry(row))
        store.tabs[0].isLoading = true
        #expect(store.currentOperationContext == nil)
        let pending = try #require(store.pinBadgeEntry(row))
        #expect(settled.source == pending.source && settled.item == pending.item)
        store.tabs[0].isUnavailable = true
        #expect(store.pinBadgeEntry(row) == nil)
    }

    @Test func scrollOriginRebuildsDemandWithoutSelectionOrAViewUpdate() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        let viewport = OneDriveBadgeViewport()
        defer { viewport.invalidate(); window.close() }
        var reports: [[FileItem]] = []
        viewport.update(view: document, items: {
            [item(Int(scroll.contentView.bounds.minY / 100))]
        }, report: { _, values in reports.append(values) }, remove: { _ in })
        try await wait { reports.count == 1 }
        let first = reports[0]
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await wait { reports.last != first }
        #expect(reports.last?.map(\.id) == [item(3).id])
        #expect(reports.allSatisfy { $0.count == 1 }, "Only the supplied viewport demand is submitted")
    }

    @Test func oldMountTeardownCannotRemoveReplacementOrRunQueuedCallback() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(document)
        window.orderFront(nil)
        let old = OneDriveBadgeViewport(), replacement = OneDriveBadgeViewport()
        defer { old.invalidate(); replacement.invalidate(); window.close() }
        var active: [UUID: [FileItem]] = [:]
        var oldCalls = 0
        old.update(view: document, items: { [item(0)] },
            report: { owner, items in active[owner] = items; oldCalls += 1 },
            remove: { active.removeValue(forKey: $0) })
        try await wait { active[old.owner] != nil }
        replacement.update(view: document, items: { [item(1)] },
            report: { active[$0] = $1 }, remove: { active.removeValue(forKey: $0) })
        try await wait { active[replacement.owner] != nil }
        old.schedule()
        old.invalidate()
        try await Task.sleep(for: .milliseconds(20))
        #expect(oldCalls == 1)
        #expect(active[old.owner] == nil)
        #expect(active[replacement.owner]?.map(\.id) == [item(1).id])
        document.removeFromSuperview()
        replacement.schedule()
        try await wait { active.isEmpty }
    }

    @Test func pendingReportReadsLatestVisibleIdentityAndCoalescesLayout() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(document)
        window.orderFront(nil)
        let viewport = OneDriveBadgeViewport()
        defer { viewport.invalidate(); window.close() }
        var current = item(0), reports: [[FileItem]] = []
        viewport.update(view: document, items: { [current] },
            report: { _, values in reports.append(values) }, remove: { _ in })
        for _ in 0..<30 { viewport.schedule() }
        current = item(1)
        try await wait { !reports.isEmpty }
        #expect(reports.count == 1)
        #expect(reports[0].map(\.id) == [current.id])
    }

    @Test func orderedOutAndClosedWindowsReleaseDemandWithoutPolling() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(document)
        let viewport = OneDriveBadgeViewport()
        defer { viewport.invalidate(); window.close() }
        var active = false, calls = 0
        let notifications = BadgeWindowNotifications(window: window)
        func state() -> String {
            "active=\(active),calls=\(calls),visible=\(window.isVisible),mini=\(window.isMiniaturized),appHidden=\(NSApp.isHidden),rect=\(document.visibleRect),events=\(notifications.events)"
        }
        viewport.update(view: document, items: { [item(0)] },
            report: { _, _ in active = true; calls += 1 }, remove: { _ in active = false })
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == 0, "Attachment alone does not make a window displayed")
        window.orderFront(nil)
        // Swift Testing does not run NSApplication.run. Drive the same native
        // after-event update AppKit performs, rather than faking a notification.
        NSApp.updateWindows()
        try await wait("First orderFront must publish", diagnostics: state) { active }
        window.orderOut(nil)
        NSApp.updateWindows()
        try await wait("orderOut must remove demand", diagnostics: state) { !active }
        let before = calls
        viewport.schedule()
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == before)
        window.orderFront(nil)
        NSApp.updateWindows()
        try await wait("Second orderFront must restore demand", diagnostics: state) { active }
        window.close()
        #expect(!active, "The owned will-close notification drops demand immediately")
    }

    @Test func detailsAndCollectionDemandTracksGeometryWithoutChangingSelection() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/badge-viewport")
        let store = ExplorerStore(initialURL: root, loader: BadgeViewportEmptyLoader(), homeURL: root, observer: nil)
        defer { store.cancelLoads() }
        try await wait { !store.activeTab.isLoading }
        let values = (0..<100).map(item)
        store.tabs[0].items = values
        store.setSelection([values[0].id], focusedID: values[0].id)
        let selection = store.currentSelection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let details = DetailsTableView.Coordinator(store: store)
        let table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.rowHeight = 24
        table.dataSource = details; table.delegate = details
        details.table = table; details.items = values
        let tableScroll = ExplorerDetailsScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        tableScroll.documentView = table
        window.contentView?.addSubview(tableScroll)
        window.orderFront(nil)
        table.reloadData()
        // Mirror updateNSView's native focus/anchor reconciliation before the
        // selection delegate is allowed to publish the selected row.
        table.focusedItemID = selection.focusedID
        table.anchorItemID = selection.anchorID
        table.itemIDs = values.map(\.id)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableScroll.layoutSubtreeIfNeeded()
        let tableBefore = details.visibleBadgeItems()
        #expect(!tableBefore.isEmpty && tableBefore.count < values.count)
        tableScroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        tableScroll.reflectScrolledClipView(tableScroll.contentView)
        #expect(details.visibleBadgeItems().first?.id != tableBefore.first?.id)
        #expect(store.currentSelection == selection)
        table.dataSource = nil; table.delegate = nil; tableScroll.removeFromSuperview()

        store.setViewMode(.largeIcons)
        let collection = FileCollectionView.Coordinator(store: store)
        let scroll = collection.makeScrollView()
        defer { collection.dismantle() }
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        window.contentView?.addSubview(scroll)
        scroll.layoutSubtreeIfNeeded()
        collection.update()
        try await wait { !collection.visibleBadgeItems().isEmpty }
        // Finish the existing deferred mode/selection viewport restoration before
        // testing a subsequent user scroll, rather than racing that owned restore.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let before = collection.visibleBadgeItems()
        #expect(before.count < values.count)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await wait { collection.visibleBadgeItems().first?.id != before.first?.id }
        #expect(store.currentSelection == selection)
    }
}
