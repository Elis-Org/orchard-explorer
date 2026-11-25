import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

@MainActor
struct HomeResultOperationInputTests {
    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                       timestamp: 1, windowNumber: 0, context: nil,
                                       eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @Test func contextMenuCapturesTheNewSelectionWhenSecondaryClickTargetsAnUnselectedRow() throws {
        let row = HomeResultInputControl(frame: NSRect(x: 0, y: 0, width: 150, height: 30))
        let window = NSWindow(contentRect: row.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        defer { window.close() }
        let item = try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/example"), tags: ["example"],
                                             contentTypes: ["public.text"]))
        row.dropRow = HomeResultRow(item: item, group: "example")
        let presenter = RecordingHomeMenuPresenter()
        row.menuPresenter = presenter
        row.rowIsCurrent = { true }
        var selected = false
        row.selectedNow = { selected }
        row.onSelect = { _, _ in
            #expect(presenter.calls.isEmpty)
            selected = true
        }
        row.rightMouseDown(with: try homeSecondaryEvent(at: NSPoint(x: 10, y: 10), in: window))
        #expect(selected && presenter.calls.count == 1)
    }

    @Test func pressOnASelectedRowPreservesDragCandidatesUntilRelease() throws {
        let row = HomeResultInputControl(frame: .zero)
        var selected = ["first", "second"]
        row.clickTarget = HomeResultClickTarget(id: "first", membership: UUID(), identity: nil)
        row.selectedNow = { selected.contains("first") }
        row.selectedState = true
        row.onSelect = { _, _ in selected = ["first"] }

        row.mouseDown(with: try mouse(.leftMouseDown))
        #expect(selected == ["first", "second"])
        row.mouseUp(with: try mouse(.leftMouseUp))
        #expect(selected == ["first"])
    }

    @Test func secondaryOnResultsBackgroundDelegatesToTheSharedPanel() throws {
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: RecentDocumentStore(defaults: nil))
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        store.replaceHomeResults([], in: scope)
        try #require(store.homeOperationOrigin != nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let presenter = RecordingHomeMenuPresenter()
        let host = HomeDropHost(store: store, root: EmptyView(), menuPresenter: presenter)
        window.contentView = host
        let scroll = NSScrollView(frame: host.bounds)
        host.addSubview(scroll)
        let document = NSView(frame: scroll.bounds)
        scroll.documentView = document
        let marker = NSView(frame: NSRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
        document.addSubview(marker)
        host.resultsBoundary = marker
        window.displayIfNeeded()
        let point = scroll.contentView.convert(NSPoint(x: 20, y: 20), to: nil)
        let hit = host.hitTest(host.convert(host.convert(point, from: nil), to: host.superview))
        try #require(hit === host)
        let event = try homeSecondaryEvent(at: point, in: window)
        #expect(host.menu(for: event) == nil, "A native popup would bypass the shared file actions panel")
        host.rightMouseDown(with: event)
        let pointer = try #require(presenter.calls.first)
        #expect(presenter.calls.count == 1 && pointer.row == nil && !pointer.keyboard)
        #expect(pointer.origin === host && window.firstResponder === host)
        #expect(host.accessibilityPerformShowMenu())
        #expect(presenter.calls.count == 2 && presenter.calls.last?.row == nil && presenter.calls.last?.keyboard == true)
        let item = try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/selected"), tags: ["example"],
                                             contentTypes: ["public.text"]))
        let selected = HomeResultRow(item: item, group: "example")
        store.replaceHomeResults([selected], in: scope)
        store.selectHomeResult(selected, in: scope)
        host.rightMouseDown(with: event)
        #expect(presenter.calls.last?.row == nil)
        #expect(store.activeTab.homeResults.selection.selectedIDs == [selected.id])
        #expect(host.accessibilityPerformShowMenu())
        #expect(presenter.calls.last?.row == selected)
    }
}
