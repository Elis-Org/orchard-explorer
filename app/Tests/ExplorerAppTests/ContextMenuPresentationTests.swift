import AppKit
import Testing
@testable import ExplorerApp

@MainActor
@Suite(.serialized)
struct ContextMenuPresentationTests {
    @Test(arguments: [1.0, 1.5, 2.0], [NSAppearance.Name.aqua, .darkAqua])
    func ordinaryRootsUseGrayRenderer(scale: CGFloat, appearance: NSAppearance.Name) throws {
        let oldScale = ExplorerScale.factor
        ExplorerScale.factor = scale
        defer { ExplorerScale.factor = oldScale }
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.panel.appearance = NSAppearance(named: appearance)
        let command = fixture.add("Open in New Tab", id: "context-test-open")
        command.image = MenuIcons.Glyph.newTab.image
        let longTitle = "Open a second tab for the currently selected destination"
        fixture.menu.addItem(.separator())
        fixture.add(longTitle, id: "context-test-long")
        fixture.presentation.show()

        let content = try #require(fixture.panel.contentView as? NSVisualEffectView)
        #expect(content.material == .menu && content.blendingMode == .behindWindow && content.state == .active)
        #expect(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
        let rows = fixture.rows
        #expect(rows.map(\.title) == [command.title, longTitle])
        #expect(rows.allSatisfy { $0.frame.height == 26.pt && $0.font?.pointSize == 12.pt })
        let open = try #require(rows.first)
        #expect(open.accessibilityIdentifier() == "context-test-open")
        let icon = try #require(open.cell).imageRect(forBounds: open.bounds)
        #expect(icon.width > 0 && icon.width <= 16.pt && icon.height > 0 && icon.height <= 16.pt)
        #expect(fixture.presentation.owns(fixture.panel))
        let titleWidth = (longTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.pt)]).width
        let available = try #require(NSScreen.main?.visibleFrame).insetBy(dx: 8, dy: 8)
        let expectedWidth = min(available.width, max(220, ceil(titleWidth) + 64.pt))
        #expect(fixture.panel.frame.width == expectedWidth)
    }

    @Test func nativeButtonDispatchClosesFirstAndKeepsOriginalSender() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let item = fixture.add("Action", id: "context-test-action")
        let disabled = fixture.add("Disabled", id: "context-test-disabled")
        disabled.isEnabled = false
        let payload = NSObject()
        item.representedObject = payload
        fixture.target.onInvoke = { sender in
            #expect(sender === item)
            #expect((sender.representedObject as? NSObject) === payload)
            #expect(!fixture.presentation.isPresented && !fixture.panel.isVisible)
            #expect(fixture.dismissals == [.command])
        }
        fixture.presentation.show()
        let action = try #require(fixture.rows.first)
        let disabledButton = try #require(fixture.rows.last)
        #expect(!disabledButton.accessibilityPerformPress())
        #expect(fixture.target.invocations == 0)
        action.performClick(nil)
        #expect(fixture.target.invocations == 1)
        #expect(!action.accessibilityPerformPress())
        fixture.presentation.show()
        #expect(!fixture.presentation.isPresented)
        #expect(fixture.dismissals == [.command])
        fixture.target.onInvoke = nil
    }

    @Test(arguments: [false, true])
    func keyboardAndAXUseTheSameDispatcher(keyboard: Bool) throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let item = fixture.add("Action", id: "context-test-action")
        item.keyEquivalent = "x"
        item.keyEquivalentModifierMask = .command
        fixture.presentation.show()

        let button = try #require(fixture.rows.first)
        if keyboard {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: fixture.panel.windowNumber,
                context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
            #expect(fixture.panel.performKeyEquivalent(with: event))
        } else {
            #expect(button.accessibilityPerformPress())
        }
        #expect(fixture.target.invocations == 1)
        #expect(!button.accessibilityPerformPress())
        #expect(fixture.dismissals == [.command])
    }

    @Test func closingPanelCanInvalidateCommandBeforeDispatch() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.add("Action", id: "context-test-action")
        fixture.onDismiss = { [weak fixture] in fixture?.isCurrent = false }
        fixture.presentation.show()

        let button = try #require(fixture.rows.first)
        #expect(!button.accessibilityPerformPress())
        #expect(fixture.dismissals == [.command])
        #expect(fixture.target.invocations == 0)
    }

    @Test(arguments: ["stale", "disabled", "hidden", "detached", "missing-target", "replaced"])
    func refusedActionsNeverReachTarget(change: String) throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let item = fixture.add("Action", id: "context-test-action")
        fixture.presentation.show()
        let button = try #require(fixture.rows.first)
        switch change {
        case "stale": fixture.isCurrent = false
        case "disabled": item.isEnabled = false
        case "hidden": item.isHidden = true
        case "detached": fixture.origin.removeFromSuperview()
        case "missing-target": item.target = nil
        default: fixture.presentation.dismiss(reason: .replacement)
        }
        #expect(!button.accessibilityPerformPress())
        #expect(fixture.target.invocations == 0)
    }

    @Test func visiblePanelThatRefusesKeyClosesAsFailedStart() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.add("Action", id: "context-test-action")
        fixture.panel.refusesKey = true
        fixture.presentation.show()

        #expect(fixture.panel.orderAttempts == 1)
        #expect(fixture.source.isKeyWindow)
        #expect(!fixture.presentation.isPresented && !fixture.panel.isVisible)
        #expect(fixture.panel.contentView == nil)
        #expect(fixture.dismissals == [.replacement])
        fixture.presentation.show()
        fixture.presentation.dismiss(reason: .replacement)
        #expect(fixture.panel.orderAttempts == 1)
        #expect(fixture.dismissals == [.replacement])
    }

    @Test func invalidPendingPresentationDismissesOnlyOnce() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.add("Action", id: "context-test-action")
        fixture.isCurrent = false
        fixture.presentation.show()
        fixture.isCurrent = true
        fixture.presentation.show()
        fixture.presentation.dismiss(reason: .replacement)
        #expect(!fixture.presentation.isPresented && !fixture.panel.isVisible)
        #expect(fixture.dismissals == [.replacement])
    }
}

@MainActor
private final class PresentationFixture {
    let source: PresentationTestPanel
    let panel: PresentationTestPanel
    let origin = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let target = PresentationTestTarget()
    let menu = NSMenu()
    var isCurrent = true
    var dismissals: [ContextMenuPanelController.DismissReason] = []
    var onDismiss: (() -> Void)?
    lazy var presentation = ContextMenuPanelController(menu: menu, title: "Test menu",
        accessibilityIdentifier: "explorer-test-context-menu", origin: origin,
        point: NSPoint(x: 50, y: 200), keyboard: false, isCurrent: { [weak self] in self?.isCurrent == true },
        onDismiss: { [weak self] in
            self?.dismissals.append($0)
            self?.onDismiss?()
        }, panel: panel,
        isApplicationActive: { true })

    init() throws {
        _ = NSApplication.shared
        source = PresentationTestPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel = PresentationTestPanel(contentRect: .zero,
            styleMask: [.borderless], backing: .buffered, defer: false)
        let screen = try #require(NSScreen.main)
        source.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 50, y: screen.visibleFrame.midY - 200))
        source.isReleasedWhenClosed = false
        panel.isReleasedWhenClosed = false
        source.ownsMainWindow = true
        source.contentView?.addSubview(origin)
        source.makeKeyAndOrderFront(nil)
        menu.autoenablesItems = false
    }

    @discardableResult
    func add(_ title: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(PresentationTestTarget.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.identifier = NSUserInterfaceItemIdentifier(id)
        menu.addItem(item)
        return item
    }

    var rows: [ContextActionButton] {
        func descendants(_ view: NSView) -> [ContextActionButton] {
            if let row = view as? ContextActionButton { return [row] }
            return view.subviews.flatMap(descendants)
        }
        return panel.contentView.map(descendants) ?? []
    }

    func close() {
        presentation.dismiss(reason: .replacement)
        target.onInvoke = nil
        panel.close()
        source.close()
    }
}

@MainActor
private final class PresentationTestTarget: NSObject {
    var invocations = 0
    var onInvoke: ((NSMenuItem) -> Void)?

    @objc func invoke(_ sender: NSMenuItem) {
        invocations += 1
        onInvoke?(sender)
    }
}

@MainActor
private final class PresentationTestPanel: FileActionsPanel {
    var ownsMainWindow = false
    var refusesKey = false
    private(set) var orderAttempts = 0
    private var shown = false
    override var isMainWindow: Bool { ownsMainWindow }
    override var isKeyWindow: Bool { shown && !refusesKey }
    override var isVisible: Bool { shown }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderAttempts += 1
        shown = true
    }
    override func orderOut(_ sender: Any?) { shown = false; super.orderOut(sender) }
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: -10000, y: -10000) }
}
