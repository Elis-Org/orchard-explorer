import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@MainActor
struct HomeResultInputTests {
    private let file = LocalFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 0, linkCount: 1)

    private func mouse(_ count: Int, _ flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: Double(count),
                                       windowNumber: 0, context: nil, eventNumber: count, clickCount: count, pressure: 1))
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }

    @Test func primarySelectsImmediatelyAndDoubleActivatesExactlyOnce() throws {
        let row = HomeResultInputControl(frame: .zero)
        row.clickTarget = HomeResultClickTarget(id: "one", membership: UUID(), identity: file)
        var selections = 0, opens = 0
        row.onSelect = { _, _ in selections += 1 }
        row.onOpen = { opens += 1; return true }
        row.mouseDown(with: try mouse(1))
        #expect(selections == 1 && opens == 0)
        row.mouseDown(with: try mouse(2))
        row.mouseDown(with: try mouse(3))
        #expect(opens == 1)
        row.mouseDown(with: try mouse(1))
        row.clickTarget = HomeResultClickTarget(id: "one", membership: UUID(), identity: file)
        row.mouseDown(with: try mouse(2))
        #expect(opens == 1)
    }

    @Test func modifiedPrimarySelectsWithoutActivationOrContextMenu() throws {
        let row = HomeResultInputControl(frame: .zero)
        row.clickTarget = HomeResultClickTarget(id: "one", membership: UUID(), identity: file)
        var changes: [String] = [], opens = 0
        row.onSelect = { extend, toggle in changes.append(extend ? "range" : toggle ? "toggle" : "single") }
        row.onOpen = { opens += 1; return true }
        for flag: NSEvent.ModifierFlags in [.control, .command, .shift] {
            let event = try mouse(1, flag)
            #expect(row.menu(for: event) == nil)
            row.mouseDown(with: event)
            row.mouseDown(with: try mouse(2, flag))
        }
        #expect(changes == ["toggle", "toggle", "toggle", "toggle", "range", "range"])
        #expect(opens == 0)
    }

    @Test func keyboardAndAccessibilityUseDistinctSelectionAndOpenActions() throws {
        let row = HomeResultInputControl(frame: .zero)
        var moves: [String] = [], toggles = 0, opens = 0
        row.onMove = { offset, extend, _ in moves.append("\(offset) \(extend)") }
        row.onSelect = { _, toggling in if toggling { toggles += 1 } }
        row.onOpen = { opens += 1; return true }
        row.canOpenWithReturn = { true }
        row.keyDown(with: try key(125, .shift))
        row.keyDown(with: try key(126))
        row.keyDown(with: try key(49))
        row.setAccessibilitySelected(true)
        row.keyDown(with: try key(36))
        #expect(row.accessibilityPerformPress())
        #expect(moves == ["1 true", "-1 false"] && opens == 2 && toggles == 2)
        row.canOpenWithReturn = { false }
        row.keyDown(with: try key(36))
        #expect(opens == 2)
    }

    @Test func secondaryAndAccessibilityShowUseTheSharedPresenterAndKeepAnExistingSelection() throws {
        let row = HomeResultInputControl(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        let window = NSWindow(contentRect: row.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        defer { window.close() }
        let presenter = RecordingHomeMenuPresenter()
        row.menuPresenter = presenter
        let item = try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/synthetic-item"), tags: ["example"],
                                             contentTypes: ["public.text"]))
        let result = HomeResultRow(item: item, group: "example")
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: RecentDocumentStore(defaults: nil))
        defer { store.cancelLoads() }
        let scope = try #require(store.homeResultScope)
        store.replaceHomeResults([result], in: scope)
        store.selectHomeResult(result, in: scope)
        row.commandStore = store
        row.rowIsCurrent = { true }
        row.dropRow = result
        row.clickTarget = .init(id: result.id, membership: UUID(), identity: nil)
        row.selectedState = true
        var selections = 0
        row.onSelect = { _, _ in selections += 1 }
        row.rightMouseDown(with: try homeSecondaryEvent(at: NSPoint(x: 10, y: 10), in: window))
        let pointer = try #require(presenter.calls.first)
        #expect(presenter.calls.count == 1 && pointer.row == result && pointer.origin === row && !pointer.keyboard)
        #expect(selections == 0 && window.firstResponder === row)
        row.keyDown(with: try key(109, .shift))
        #expect(row.accessibilityPerformShowMenu())
        #expect(presenter.calls.map(\.keyboard) == [false, true, true] && selections == 0)
        let otherItem = try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/other"), tags: ["example"],
                                                  contentTypes: ["public.text"]))
        let other = HomeResultRow(item: otherItem, group: "example")
        store.replaceHomeResults([other, result], in: scope)
        store.selectHomeResult(other, in: scope)
        row.selectedState = false
        #expect(row.accessibilityPerformShowMenu())
        #expect(presenter.calls.last?.row == other && selections == 0)
        store.selectHomeResult(other, in: scope, toggling: true)
        #expect(row.accessibilityPerformShowMenu())
        #expect(presenter.calls.last?.row == nil && selections == 0)
        presenter.admits = false
        #expect(!row.accessibilityPerformShowMenu())
        row.clickTarget = .init(id: result.id, membership: UUID(), identity: nil)
        #expect(presenter.dismissed.contains { $0 === row })
        presenter.dismissed.removeAll()
        HomeResultInput.dismantleNSView(row, coordinator: ())
        #expect(presenter.dismissed.contains { $0 === row })
    }
}

@MainActor
final class RecordingHomeMenuPresenter: HomeResultMenuPresenting {
    struct Call {
        let row: HomeResultRow?
        let origin: NSView
        let keyboard: Bool
    }
    var admits = true
    var calls: [Call] = []
    var dismissed: [NSView] = []
    func presentHome(row: HomeResultRow?, at point: NSPoint, in origin: NSView, keyboard: Bool) -> Bool {
        calls.append(.init(row: row, origin: origin, keyboard: keyboard))
        return admits
    }
    func dismissPresentedMenu(from origin: NSView) { dismissed.append(origin) }
    func dismissPresentedMenu() {}
}

@MainActor
func homeSecondaryEvent(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
    let template = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    // AppKit's factory reports button 0 even for .rightMouseDown. Supply the same
    // physical button field as the signed pointer trial and retain the window-local hit.
    let cg = try #require(template.cgEvent)
    cg.setIntegerValueField(.mouseEventButtonNumber, value: 1)
    let initial = try #require(NSEvent(cgEvent: cg)).locationInWindow
    cg.location = CGPoint(x: cg.location.x + point.x - initial.x, y: cg.location.y - point.y + initial.y)
    let event = try #require(NSEvent(cgEvent: cg))
    try #require(event.buttonNumber == 1 && event.windowNumber == window.windowNumber)
    try #require(abs(point.x - event.locationInWindow.x) < 0.01 && abs(point.y - event.locationInWindow.y) < 0.01)
    return event
}
