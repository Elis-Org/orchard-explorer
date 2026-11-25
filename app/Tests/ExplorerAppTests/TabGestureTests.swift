import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

private struct GestureDirectoryLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
}

/// Allocates native responders only; the synthetic paths are never read or written.
@MainActor
private final class TabGestureHarness {
    let window: NSWindow
    let store: ExplorerStore
    let button: TabDragButton
    let draggedTabID: UUID
    var transferredIDs: [UUID] = []
    var releasePoints: [NSPoint?] = []
    let downPoint = NSPoint(x: 50, y: 240)
    let outsidePoint = NSPoint(x: 650, y: 240)
    let insidePoint = NSPoint(x: 250, y: 240)

    init() {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-gesture-fixture", isDirectory: true)
        store = ExplorerStore(initialURL: root, loader: GestureDirectoryLoader(), homeURL: root)
        store.openTab(at: root.appendingPathComponent("Source", isDirectory: true))
        draggedTabID = store.activeTabID
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        button = TabDragButton(frame: NSRect(x: 20, y: 225, width: 180, height: 30))
        button.store = store
        button.tabID = draggedTabID
        window.contentView?.addSubview(button)
        store.onDetachTab = { [weak self] tab, point in
            self?.transferredIDs.append(tab.id)
            self?.releasePoints.append(point)
        }
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                     isARepeat: false, keyCode: 53))
    }

    func close() {
        button.endEventMonitoring()
        store.cancelLoads()
        window.close()
    }
}

/// FR-TAB-008 / EV-0386 / AT-TAB-008. Direct native responder delivery is an
/// integration check; physical-pointer routing and Windows cancellation fidelity
/// remain separate claims. The six-point threshold is explicit native policy.
@Suite(.serialized)
@MainActor
final class TabGestureTests {
    @Test
    func nativeTabMenuUsesArtworkForCommandsAndLeavesBulkCloseUnadorned() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        harness.store.openTab(at: harness.store.activeTab.url.appendingPathComponent("Right", isDirectory: true))
        let menu = harness.button.makeContextMenu()
        let actions = menu.items.filter { !$0.isSeparatorItem }
        #expect(actions.map(\.title) == ["Close tab", "Close other tabs", "Close tabs to the right", "Duplicate tab", "Move Tab to New Window"])
        #expect(actions.filter { $0.image != nil }.map(\.title) == ["Close tab", "Duplicate tab", "Move Tab to New Window"])
        #expect(actions.filter { $0.title.hasPrefix("Close") }.allSatisfy { $0.isEnabled })
        #expect(actions.allSatisfy { $0.target === harness.button && $0.action != nil })
    }

    @Test(arguments: ["secondary", "control", "keyboard", "accessibility"])
    func tabMenuEntryCancelsPendingRenameWithoutActivatingAnInactiveTab(_ invocation: String) throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        let otherTab = try #require(harness.store.tabs.first)
        harness.store.activateTab(otherTab.id)
        harness.store.pointerRename.arm(.init(tabID: otherTab.id, directoryURL: otherTab.url,
                                             itemID: "synthetic-row", identity: nil)) { _ in }
        #expect(harness.store.pointerRename.isPending)
        switch invocation {
        case "secondary":
            harness.button.rightMouseDown(with: try harness.mouse(.rightMouseDown, at: harness.downPoint))
        case "control":
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: harness.downPoint,
                modifierFlags: .control, timestamp: 1, windowNumber: harness.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            harness.button.mouseDown(with: event)
        case "keyboard":
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 1, windowNumber: harness.window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109))
            harness.button.keyDown(with: event)
        default:
            #expect(harness.button.accessibilityPerformShowMenu())
        }
        #expect(!harness.store.pointerRename.isPending)
        #expect(harness.store.activeTabID == otherTab.id)
    }

    @Test
    func retainedTabMenuCannotDispatchToAReconfiguredButton() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        let menu = harness.button.makeContextMenu()
        let otherTab = try #require(harness.store.tabs.first)
        harness.button.tabID = otherTab.id
        let originalIDs = harness.store.tabs.map(\.id)
        let duplicate = try #require(menu.item(withTitle: "Duplicate tab"))
        menu.performActionForItem(at: menu.index(of: duplicate))
        #expect(harness.store.tabs.map(\.id) == originalIDs)
    }

    @Test
    func draggingBeyondThresholdAndReleasingOutsideTransfersOnce() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        let sourceFrame = harness.window.frame
        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: harness.outsidePoint))
        #expect(harness.transferredIDs.isEmpty, "A drag alone is not a committed release")
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs == [harness.draggedTabID])
        #expect(harness.store.tabs.count == 1)
        let release = try #require(harness.releasePoints.first ?? nil)
        #expect(!sourceFrame.contains(release))
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs.count == 1, "A repeated mouse-up must not transfer twice")
    }

    @Test
    func draggingBeyondThresholdButReleasingInsideKeepsBothTabs() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: harness.insidePoint))
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.insidePoint))
        #expect(harness.transferredIDs.isEmpty)
        #expect(harness.store.tabs.count == 2)
        #expect(harness.store.activeTabID == harness.draggedTabID)
    }

    @Test
    func belowThresholdGestureCannotDetachOnAnOutsideMouseUp() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        let tinyMove = NSPoint(x: harness.downPoint.x + 4, y: harness.downPoint.y)
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: tinyMove))
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs.isEmpty)
        #expect(harness.store.tabs.count == 2)
    }

    @Test
    func escapeCancelsAnOutsideDragAndTheNextGestureResetsCancellation() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: harness.outsidePoint))
        harness.button.keyDown(with: try harness.escape())
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs.isEmpty)
        #expect(harness.store.tabs.count == 2)

        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: harness.outsidePoint))
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs == [harness.draggedTabID])
        #expect(harness.store.tabs.count == 1)
    }

    @Test
    func responderCancelOperationPreventsTransfer() throws {
        let harness = TabGestureHarness()
        defer { harness.close() }
        harness.button.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.downPoint))
        harness.button.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: harness.outsidePoint))
        harness.button.cancelOperation(nil)
        harness.button.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.outsidePoint))
        #expect(harness.transferredIDs.isEmpty)
        #expect(harness.store.tabs.count == 2)
    }
}
