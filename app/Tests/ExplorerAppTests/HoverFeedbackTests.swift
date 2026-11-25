import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// HV-OBS-002/003: pointer feedback is presentation only. These component tests
/// exercise native drawing and tracking boundaries, not physical OS routing or
/// exact Windows colors; those require the separate scoped UI run.
@Suite(.serialized)
@MainActor
final class HoverFeedbackTests {
    @Test
    func collectionHoverPaintsAndClearsWithoutSelectingFocusingOrActivating() throws {
        let fixture = HoverItemFixture()
        defer { fixture.window.close() }
        let view = fixture.view
        var activations = 0
        var selections = 0
        view.onActivate = { activations += 1 }
        view.onAccessibilitySelection = { _ in selections += 1 }
        let firstResponder = fixture.window.firstResponder
        let idle = try paint(view)
        let area = try fixture.area()
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: area, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) != idle, "Entering an unselected file must paint visible feedback")
        #expect(!view.isAccessibilitySelected())
        #expect(!view.isAccessibilityFocused())
        #expect(fixture.window.firstResponder === firstResponder)
        #expect(activations == 0 && selections == 0)
        view.mouseExited(with: try fixture.event(.mouseExited, area: area, point: NSPoint(x: 150, y: 120)))
        #expect(try paint(view) == idle, "Leaving must remove feedback without requiring a click")

        view.applyState(selected: true, focused: false, hasKeyboardFocus: false)
        let selected = try paint(view)
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: area, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) == selected, "Hover must not replace selected-item emphasis")
        #expect(view.isAccessibilitySelected())
        #expect(activations == 0 && selections == 0)
    }

    @Test
    func collectionHoverRejectsObsoleteTrackingAndClearsOnResignAndReuse() throws {
        let fixture = HoverItemFixture()
        defer { fixture.window.close() }
        let view = fixture.view
        let idle = try paint(view)
        let old = try fixture.area()
        view.updateTrackingAreas()
        let current = try fixture.area(update: false)
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: old, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) == idle, "A queued event from a replaced tracking area must be ignored")
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: current, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) != idle)
        fixture.window.pointerWindowIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(try paint(view) == idle, "Deactivation must remove pointer emphasis immediately")
        fixture.window.pointerWindowIsKey = true
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: current, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) != idle)
        view.reset()
        #expect(try paint(view) == idle, "A reused item cannot retain its previous file's hover")
        view.mouseEntered(with: try fixture.event(.mouseEntered, area: current, point: NSPoint(x: 20, y: 20)))
        #expect(try paint(view) == idle, "An unconfigured reused item cannot reenter hover")
    }

    @Test
    func collectionTrackingIsClippedToTheItemAndScrolledViewport() throws {
        let fixture = HoverItemFixture()
        defer { fixture.window.close() }
        let view = fixture.view
        #expect(try fixture.area().rect == NSRect(x: 0, y: 0, width: 120, height: 100),
                "A modern nonclipping ancestor must not enlarge item hover into surrounding content")
        view.removeFromSuperview()
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 60, height: 50))
        fixture.window.contentView?.addSubview(clip)
        clip.documentView = view
        clip.scroll(to: NSPoint(x: 30, y: 20))
        #expect(try fixture.area().rect == NSRect(x: 30, y: 20, width: 60, height: 50),
                "A partially scrolled item must track only its visible portion")
    }

    @Test
    func contextButtonTrackingReplacementClearsHoverOutsideWithoutStaleExit() throws {
        _ = NSApplication.shared
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = ContextActionButton(title: "Copy", identifier: "context-copy")
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        window.contentView?.addSubview(button)
        button.updateTrackingAreas()
        let area = try #require(button.trackingAreas.first {
            ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited)
        })
        var entries = 0, exits = 0
        button.pointerEntered = { entries += 1 }
        button.pointerExited = { exits += 1 }
        button.mouseEntered(with: try contextEvent(.mouseEntered, in: button, area: area,
            window: window, point: NSPoint(x: 20, y: 20)))
        #expect(button.pointerInside && entries == 1)
        // Scrolling/layout can replace tracking before its old exit is delivered.
        // The live-pointer boundary is authoritative even without another move.
        window.pointer = button.convert(NSPoint(x: 150, y: 80), to: nil)
        button.updateTrackingAreas()
        #expect(!button.pointerInside, "Replacing a clipped tracking region must clear a now-outside pointer")
        #expect(exits == 1, "Navigation must receive the actual leave once")
        button.mouseExited(with: try contextEvent(.mouseExited, in: button, area: area,
            window: window, point: NSPoint(x: 150, y: 80)))
        #expect(!button.pointerInside && entries == 1 && exits == 1,
                "A replaced area's queued exit must not duplicate the transition")
    }

    @Test
    func contextButtonQueuedExitKeepsHoverWhenLivePointerAlreadyReturned() throws {
        _ = NSApplication.shared
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = ContextActionButton(title: "Copy", identifier: "context-copy")
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        window.contentView?.addSubview(button)
        button.updateTrackingAreas()
        let area = try #require(button.trackingAreas.first {
            ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited)
        })
        var exits = 0
        button.pointerExited = { exits += 1 }
        button.mouseEntered(with: try contextEvent(.mouseEntered, in: button, area: area,
            window: window, point: NSPoint(x: 20, y: 20)))
        #expect(button.pointerInside)
        let queuedExit = try contextEvent(.mouseExited, in: button, area: area,
            window: window, point: NSPoint(x: 150, y: 80))
        window.pointer = button.convert(NSPoint(x: 20, y: 20), to: nil)
        button.mouseExited(with: queuedExit)
        #expect(button.pointerInside && exits == 0,
                "An exit queued before a return must not erase the live pointer's feedback")
    }

    private func contextEvent(_ type: NSEvent.EventType, in view: NSView, area: NSTrackingArea,
                              window: HoverTestWindow, point: NSPoint) throws -> NSEvent {
        let location = view.convert(point, to: nil)
        window.pointer = location
        let source = try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        return HoverTrackingEvent(source: source, area: area, window: window)
    }

    private func paint(_ view: NSView) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        view.bounds.fill()
        view.draw(view.bounds)
        context.flushGraphics()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class HoverItemFixture {
    let window: HoverTestWindow
    let view = ExplorerCollectionItemView()
    init() {
        _ = NSApplication.shared
        window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 100)
        view.configure(item: FileItem(url: URL(fileURLWithPath: "/synthetic/hover.txt"), name: "hover.txt",
            isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text"), mode: .largeIcons)
        view.layoutSubtreeIfNeeded()
    }
    func area(update: Bool = true) throws -> NSTrackingArea {
        if update { view.updateTrackingAreas() }
        return try #require(view.trackingAreas.first {
            ($0.owner as AnyObject?) === view && $0.options.contains(.mouseEnteredAndExited)
                && !$0.options.contains(.inVisibleRect)
        }, "File items need a bounded, owned pointer tracking area")
    }
    func event(_ type: NSEvent.EventType, area: NSTrackingArea, point: NSPoint) throws -> NSEvent {
        let location = view.convert(point, to: nil)
        window.pointer = location
        let source = try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        return HoverTrackingEvent(source: source, area: area, window: window)
    }
}

// Deterministic OS pointer-read boundary; never moves the desktop pointer.
@MainActor
private final class HoverTestWindow: NSWindow {
    var pointer = NSPoint(x: -100, y: -100)
    var pointerWindowIsKey = true
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { pointerWindowIsKey }
    override var isVisible: Bool { true }
}

private final class HoverTrackingEvent: NSEvent {
    let source: NSEvent
    let area: NSTrackingArea
    let ownerWindow: NSWindow
    init(source: NSEvent, area: NSTrackingArea, window: NSWindow) {
        self.source = source; self.area = area; ownerWindow = window; super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { source.type }
    override var locationInWindow: NSPoint { source.locationInWindow }
    override var window: NSWindow? { ownerWindow }
    override var windowNumber: Int { ownerWindow.windowNumber }
    override var timestamp: TimeInterval { source.timestamp }
    override var trackingArea: NSTrackingArea? { area }
}
