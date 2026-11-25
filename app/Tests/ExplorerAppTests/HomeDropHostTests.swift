import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

@MainActor
struct HomeDropHostTests {
    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    @Test(arguments: [false, true])
    func visibleResultRowsAndBackgroundReceiveDropsWhileHeaderDoesNot(_ tags: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Target", isDirectory: true)
        let file = root.appendingPathComponent("Witness.txt")
        let offered = root.appendingPathComponent("External.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("visible row".utf8).write(to: file)
        let bytes = Data("native receiver fixture".utf8)
        try bytes.write(to: offered)

        let tag = "HomeDropHost-" + UUID().uuidString
        let shortcuts = FinderTagShortcuts()
        shortcuts.setVisible(tag, visible: true)
        let recent = RecentDocumentStore(defaults: nil)
        let doc = try #require(await RecentDocument.sample(file))
        recent.record([doc], excluding: [])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, homeURL: root, recentDocuments: recent, tagShortcuts: shortcuts)
        defer { store.cancelLoads() }
        if tags { store.selectHomeSection(.tags) }
        let fileItem = try #require(FinderTagItem(indexedURL: file, tags: [tag], contentTypes: ["public.text"]))
        let folderItem = try #require(FinderTagItem(indexedURL: folder, tags: [tag], contentTypes: ["public.directory"]))
        let snapshot = FinderTagsSnapshot(names: [tag], items: [fileItem, folderItem])
        let row = tags ? HomeResultRow(item: fileItem, group: tag) : HomeResultRow(recent: doc)
        let folderRow = HomeResultRow(item: folderItem, group: tag)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scene = NSHostingView(rootView: ExplorerHomeView(store: store, page: .home) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(snapshot)
                continuation.finish()
            }
        })
        window.contentView = scene
        window.orderBack(nil)
        defer { window.close() }

        @MainActor func find(_ id: String) -> HomeResultInputControl? {
            allViews(in: scene).compactMap { $0 as? HomeResultInputControl }.first { $0.dropRow?.id == id }
        }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            scene.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let visible = find(row.id), visible.bounds.height >= 8 && visible.bounds.height < 100 {
                if !tags { break }
                if let directory = find(folderRow.id), directory.bounds.height >= 8 && directory.bounds.height < 100,
                   !visible.convert(visible.bounds, to: nil).intersects(directory.convert(directory.bounds, to: nil)) { break }
            }
            try await Task.sleep(for: .milliseconds(15))
        } while Date() < deadline
        try #require(find(row.id) != nil)
        let receiver = try #require(allViews(in: scene).first { $0 is HomeDropBoundaryOwner })
        let boundary = try #require((receiver as? HomeDropBoundaryOwner)?.resultsBoundary)
        let scroll = try #require(boundary.enclosingScrollView)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([offered as NSURL]))
        let info = FileDragInfoStub(board: board)
        info.draggingDestinationWindow = window
        var chose: ((URL?) -> Void)?
        store.onChooseHomeFolder = { chose = $0 }

        @MainActor func hover(_ point: NSPoint) async throws {
            info.draggingLocation = point
            info.draggingSequenceNumber += 1
            _ = receiver.draggingEntered(info)
            let limit = Date().addingTimeInterval(3)
            while receiver.draggingUpdated(info) != .copy, Date() < limit {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(receiver.draggingUpdated(info) == .copy)
            try #require(receiver.prepareForDragOperation(info))
        }
        @MainActor func verifyChooser(at point: NSPoint) async throws {
            try await hover(point)
            try #require(receiver.performDragOperation(info))
            let answer = try #require(chose)
            answer(nil)
            chose = nil
            receiver.draggingEnded(info)
        }
        @MainActor func rowPoint(_ id: String) throws -> NSPoint {
            scene.layoutSubtreeIfNeeded()
            let concrete = try #require(find(id))
            let visible = concrete.convert(concrete.bounds.intersection(concrete.visibleRect), to: nil).intersection(viewport)
            try #require(visible.width >= 20 && visible.height >= 8 && visible.height < viewport.height / 3)
            if tags, let folderControl = find(folderRow.id), let fileControl = find(row.id) {
                try #require(!folderControl.convert(folderControl.bounds, to: nil).intersects(fileControl.convert(fileControl.bounds, to: nil)))
            }
            let point = NSPoint(x: visible.midX, y: visible.midY)
            let local = scene.convert(point, from: nil)
            let hit = scene.hitTest(scene.convert(local, to: scene.superview))
            let selfPoint = receiver.convert(point, from: nil)
            let receiverHit = receiver.hitTest(receiver.convert(selfPoint, to: receiver.superview))
            let matches = receiverHit === concrete && hit === concrete && concrete.rowIsCurrent?() == true
            try #require(matches)
            return point
        }
        let point = try rowPoint(row.id)
        try #require(viewport.contains(point))
        try await verifyChooser(at: point)
        try await verifyChooser(at: NSPoint(x: viewport.midX, y: viewport.minY + 8))

        if tags {
            try await hover(rowPoint(folderRow.id))
            try #require(receiver.performDragOperation(info))
            #expect(chose == nil)
            let output = folder.appendingPathComponent(offered.lastPathComponent)
            let limit = Date().addingTimeInterval(4)
            while (!FileManager.default.fileExists(atPath: output.path) || store.isPerformingOperation) && Date() < limit {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try Data(contentsOf: output) == bytes)
            receiver.draggingEnded(info)
        }

        info.draggingLocation = NSPoint(x: viewport.midX, y: viewport.maxY - 8)
        info.draggingSequenceNumber += 1
        #expect(receiver.draggingEntered(info).isEmpty)
        #expect(!receiver.prepareForDragOperation(info))
    }
}
