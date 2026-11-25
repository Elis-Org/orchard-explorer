import AppKit
import Testing
@testable import ExplorerApp
@testable import ExplorerCore

@Suite @MainActor
struct ContextMenuPlacementTests {
    // WCP-02/05: when the body opens above, the quick strip stays near the
    // invocation point and appears below the body. Existing command order stays.
    @Test func lowerInvocationPlacesActionsBelowBodyNearAnchor() async throws {
        let f = try await PlacementMenuFixture.make(selected: true, lower: true)
        defer { f.close() }
        f.presentation.show()
        let cut = try #require(placementButtons(in: f.panel).first { $0.identifier?.rawValue == "context-cut" })
        let open = try #require(placementButtons(in: f.panel).first { $0.identifier?.rawValue == "context-open" })
        let group = try #require(cut.superview)
        let stripFrame = f.panel.convertToScreen(group.convert(group.bounds, to: nil))
        let bodyFrame = f.panel.convertToScreen(open.convert(open.bounds, to: nil))
        #expect(stripFrame.maxY <= bodyFrame.minY,
                "A lower invocation places the quick-action strip below the ordinary commands")
        #expect(abs(stripFrame.maxY - f.anchor.y) <= 12.pt,
                "The strip's top remains near the invocation, including its normal inset")
        #expect(f.visibleFrame.contains(f.panel.frame))
        #expect(placementDescendants(of: f.panel).isEmpty)
    }

    // WCP-02/03: opening a flyout cannot replace, enlarge or shift its parent.
    @Test func accessibilitySubmenuUsesSeparatePanelAndRetainsParent() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        let originalFrame = f.panel.frame
        let originalContent = try #require(f.panel.contentView)
        #expect(parent.accessibilityPerformShowMenu())
        #expect(f.panel.frame == originalFrame)
        #expect(f.panel.contentView === originalContent)
        #expect(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" } === parent)
        #expect(parent.isAccessibilityExpanded())
        let descendants = placementDescendants(of: f.panel)
        let child = try #require(descendants.first, "AXShowMenu creates an independent owned submenu window")
        #expect(descendants.count == 1 && child !== f.panel)
        #expect(child.title == "File actions")
        #expect(child.accessibilityIdentifier() == "explorer-file-context-submenu-1")
        #expect(child.contentView != nil && !placementButtons(in: child).isEmpty)
        #expect(f.visibleFrame.contains(child.frame))
        let childButton = try #require(placementButtons(in: child).first)
        #expect(childButton.window === child)
        #expect(childButton.accessibilityRole() == .radioButton)
    }

    @Test func closingChildAndDismissingChainPreservesParentUntilDismissal() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        let originalFrame = f.panel.frame
        let originalContent = try #require(f.panel.contentView)
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let childButton = try #require(placementButtons(in: child).first)
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: child.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        #expect(child.performKeyEquivalent(with: left))
        #expect(placementDescendants(of: f.panel).isEmpty)
        #expect(!child.isVisible && child.contentView == nil && childButton.window == nil)
        #expect(!childButton.accessibilityPerformPress(), "A retained AX reference to a removed child cannot dispatch")
        #expect(f.presentation.session.state == .open)
        #expect(f.panel.frame == originalFrame && f.panel.contentView === originalContent)
        #expect(f.presentation.navigation.focused?.title == "View")
        #expect(!parent.isAccessibilityExpanded())
        #expect(parent.accessibilityPerformShowMenu())
        let reopened = try #require(placementDescendants(of: f.panel).first)
        #expect(reopened !== child)
        f.presentation.dismiss(reason: .keyboard)
        #expect(f.panel.contentView == nil && !f.panel.isVisible)
        #expect(placementDescendants(of: f.panel).isEmpty)
        #expect(reopened.contentView == nil && !reopened.isVisible)
        #expect(f.presentation.session.state == .cancelled)
    }

    @Test func scrollingParentClosesDetachedChildWithoutMovingParentOrUndoingScroll() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        let root = f.presentation.navigation.root
        for index in 0..<(Int(f.visibleFrame.height / 26.pt) + 8) {
            root.addItem(withTitle: "Synthetic extra command \(index)", action: nil, keyEquivalent: "")
        }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let originalFrame = f.panel.frame
        let originalContent = try #require(f.panel.contentView)
        let scroll = try #require(placementScrolls(in: f.panel).first)
        try #require((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 26.pt))
        scroll.reflectScrolledClipView(scroll.contentView)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(placementDescendants(of: f.panel).isEmpty && !child.isVisible)
        #expect(f.panel.frame == originalFrame && f.panel.contentView === originalContent)
        #expect(scroll.contentView.bounds.minY > 0, "Closing a detached child must not scroll its parent back")
        #expect(!parent.isAccessibilityExpanded() && f.presentation.navigation.activeColumn == 0)
        #expect(f.presentation.session.state == .open)
    }

    // MAC-USABILITY-MENU-01: P18Router supplies real Open With commands through
    // the file controller. The test panel receives direct component calls.
    @Test func oversizedOpenWithFitsViewportAndReachesWidestChoice() async throws {
        _ = NSApplication.shared
        // A different display may contain the menu anchor after the fixture opens.
        let screenHeight = try #require(NSScreen.screens.map { $0.visibleFrame.height }.max())
        let router = P18Router()
        router.choices = (0..<(Int(screenHeight / 26.pt) + 8)).map { index in
            ApplicationChoice(url: URL(fileURLWithPath: "/tmp/Fixture-Choice-\(index).app"),
                              name: "Synthetic choice \(index)", isDefault: index == 0)
        }
        let widest = ApplicationChoice(url: URL(fileURLWithPath: "/tmp/Fixture-Widest-Choice.app"),
            name: "Zebra synthetic choice with a deliberately long application display name", isDefault: false)
        router.choices.append(widest)
        let f = try await PlacementMenuFixture.make(selected: true, lower: false, router: router)
        defer { f.close() }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "Open With" })
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let scroll = try #require(placementScrolls(in: child).first)
        let buttons = placementButtons(in: child)
        print("MAC-USABILITY-MENU-01 open-with-fixture screenHeight=\(screenHeight) choices=\(router.choices.count) rendered=\(buttons.count)")
        try #require(buttons.count == router.choices.count + 1, "One button per choice plus Other…")
        let button = try #require(buttons.first { $0.accessibilityLabel() == widest.name })
        let cell = try #require(button.cell)
        let font = try #require(button.font)
        let target = try #require(button.target)
        let action = try #require(button.action)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widths = buttons.map { ($0.title as NSString).size(withAttributes: attributes).width }
        let maxWidth = try #require(widths.max())
        try #require((button.title as NSString).size(withAttributes: attributes).width == maxWidth)
        #expect(button.toolTip == widest.name)

        try await layoutOversizedMenu(scroll, in: child, style: .overlay)
        try expectViewportFit("open-with-overlay", scroll: scroll, button: button, region: cell.titleRect(forBounds: button.bounds))
        try await layoutOversizedMenu(scroll, in: child, style: .legacy)
        try expectViewportFit("open-with-legacy", scroll: scroll, button: button, region: cell.titleRect(forBounds: button.bounds))

        let clip = scroll.contentView
        try #require(!clip.bounds.intersects(clip.convert(button.bounds, from: button)), "Choice starts offscreen")
        let typeZ = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: child.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6))
        try #require(child.performKeyEquivalent(with: typeZ))
        #expect(f.presentation.navigation.focused?.title == widest.name && button.keyboardFocused)
        try expectViewportFit("open-with-legacy-focused", scroll: scroll, button: button,
                              region: cell.titleRect(forBounds: button.bounds))
        #expect(clip.bounds.minY > 0)
        let focusedRow = clip.convert(button.bounds, from: button)
        #expect(focusedRow.minY >= clip.bounds.minY - 0.5 && focusedRow.maxY <= clip.bounds.maxY + 0.5)
        #expect(button.target === target && button.action == action)
        #expect(button.accessibilityLabel() == widest.name && button.toolTip == widest.name)
        button.performClick(nil)
        try await p18Wait { router.opens.count == 1 }
        #expect(router.opens.first?.0 == [f.files.items[1].url] && router.opens.first?.1 == widest.url)
        #expect(!button.accessibilityPerformPress() && router.opens.count == 1)
    }

    // A shortcut decoration is a shared-renderer fixture, not an Open With row.
    @Test func oversizedSharedMenuKeepsTrailingDecorationInsideViewport() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        let view = try #require(f.presentation.navigation.root.item(withTitle: "View")?.submenu)
        let title = "Synthetic choice with a trailing shortcut decoration"
        view.insertItem(NSMenuItem(title: title, action: nil, keyEquivalent: "q"), at: 2)
        for index in 0..<(Int(f.visibleFrame.height / 26.pt) + 8) {
            view.addItem(withTitle: "Synthetic extra command \(index)", action: nil, keyEquivalent: "")
        }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let scroll = try #require(placementScrolls(in: child).first)
        let button = try #require(placementButtons(in: child).first { $0.accessibilityLabel() == title })
        let decoration = try #require(button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasSuffix("Q") })

        try await layoutOversizedMenu(scroll, in: child, style: .legacy)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 26.pt))
        scroll.reflectScrolledClipView(scroll.contentView)
        let y = scroll.contentView.bounds.minY
        try #require(y > 0)
        let document = try #require(scroll.documentView)
        let height = document.frame.height
        let styles: [(NSScroller.Style, String)] = [(.legacy, "legacy"), (.overlay, "overlay"), (.legacy, "legacy-again")]
        for (style, label) in styles {
            try await layoutOversizedMenu(scroll, in: child, style: style)
            try expectViewportFit("shared-\(label)", scroll: scroll, button: button, region: decoration.frame)
            #expect(abs(scroll.contentView.bounds.minY - y) <= 0.5)
            #expect(scroll.documentView === document && document.frame.height == height)
            #expect(placementButtons(in: child).first { $0.accessibilityLabel() == title } === button)
            #expect(decoration.superview === button && decoration.frame.width > 0)
            let visible = button.bounds.intersection(button.visibleRect)
            try #require(!visible.isEmpty)
            let ownedAreas = button.trackingAreas.filter { $0.owner === button && $0.options.contains(.activeAlways) }
            #expect(ownedAreas.map(\.rect) == [visible], "\(label): owned tracking follows the clipped button")
        }
    }

    @Test func styleChangeKeepsOversizedMenuDescendantStateConsistent() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        let view = try #require(f.presentation.navigation.root.item(withTitle: "View")?.submenu)
        let nested = NSMenuItem(title: "Synthetic nested choices", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.addItem(withTitle: "Synthetic choice", action: nil, keyEquivalent: "")
        nested.submenu = choices
        view.insertItem(nested, at: 0)
        for index in 0..<(Int(f.visibleFrame.height / 26.pt) + 8) {
            view.addItem(withTitle: "Synthetic extra command \(index)", action: nil, keyEquivalent: "")
        }
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let scroll = try #require(placementScrolls(in: child).first)
        try await layoutOversizedMenu(scroll, in: child, style: .overlay)
        let anchor = try #require(placementButtons(in: child).first { $0.accessibilityLabel() == nested.title })
        try #require(anchor.accessibilityPerformShowMenu())
        let descendant = try #require(placementDescendants(of: child).first)
        let retainedChoice = try #require(placementButtons(in: descendant).first)
        let childFrame = child.frame
        let y = scroll.contentView.bounds.minY

        try await layoutOversizedMenu(scroll, in: child, style: .legacy)
        #expect(child.frame == childFrame && scroll.contentView.bounds.minY == y)
        #expect(placementButtons(in: child).first { $0.accessibilityLabel() == nested.title } === anchor)
        #expect(f.presentation.session.state == .open)
        let descendants = placementDescendants(of: child)
        if descendants.isEmpty {
            #expect(!descendant.isVisible && !anchor.isAccessibilityExpanded())
            #expect(f.presentation.navigation.parents.count == 1)
            #expect(!retainedChoice.accessibilityPerformPress())
        } else {
            #expect(descendants.count == 1 && descendants.first === descendant)
            #expect(descendant.isVisible && anchor.isAccessibilityExpanded() && !anchor.visibleRect.isEmpty)
            #expect(f.presentation.navigation.parents.last === nested)
        }
    }

    @Test func retainedRemovedSubmenuButtonCannotReopenDescendants() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        let view = try #require(f.presentation.navigation.root.item(withTitle: "View")?.submenu)
        let nested = NSMenuItem(title: "Synthetic nested choices", action: nil, keyEquivalent: "")
        nested.submenu = NSMenu()
        nested.submenu?.addItem(withTitle: "Synthetic choice", action: nil, keyEquivalent: "")
        view.addItem(nested)
        f.presentation.show()
        let parent = try #require(placementButtons(in: f.panel).first { $0.accessibilityLabel() == "View" })
        try #require(parent.accessibilityPerformShowMenu())
        let child = try #require(placementDescendants(of: f.panel).first)
        let oldButton = try #require(placementButtons(in: child).first { $0.accessibilityLabel() == nested.title })
        try #require(oldButton.accessibilityPerformShowMenu())
        #expect(placementDescendants(of: f.panel).count == 2)
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: f.panel.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        #expect(f.panel.performKeyEquivalent(with: left))
        #expect(f.panel.performKeyEquivalent(with: left))
        #expect(placementDescendants(of: f.panel).isEmpty)
        #expect(!oldButton.accessibilityPerformShowMenu() && !oldButton.accessibilityPerformPress())
        #expect(placementDescendants(of: f.panel).isEmpty && f.presentation.session.state == .open)
    }

    @Test func typeSelectionInParentClosesPreviouslyOpenDifferentSubmenu() async throws {
        let f = try await PlacementMenuFixture.make(selected: false, lower: false)
        defer { f.close() }
        let navigation = f.presentation.navigation
        let view = try #require(navigation.root.item(withTitle: "View"))
        #expect(navigation.openSubmenu(view, focusChild: false))
        navigation.typeSelect("p", timestamp: 2)
        #expect(navigation.focused?.title == "Properties")
        #expect(navigation.parents.isEmpty && navigation.activeColumn == 0)
    }
}

@MainActor private final class PlacementMenuFixture {
    let files: P18Fixture
    let source: PlacementTestPanel
    let panel: PlacementTestPanel
    let presentation: FileContextMenuPanelController
    let controller: FileContextMenuController
    let anchor: NSPoint
    let visibleFrame: NSRect

    private init(files: P18Fixture, source: PlacementTestPanel, panel: PlacementTestPanel,
                 presentation: FileContextMenuPanelController, controller: FileContextMenuController,
                 anchor: NSPoint, visibleFrame: NSRect) {
        self.files = files; self.source = source; self.panel = panel
        self.presentation = presentation; self.controller = controller
        self.anchor = anchor; self.visibleFrame = visibleFrame
    }

    static func make(selected: Bool, lower: Bool, router: P18Router? = nil) async throws -> PlacementMenuFixture {
        let files = try await P18Fixture.make()
        if let router { files.store.applications = router }
        files.select(selected ? [files.items[1]] : [])
        let controller = FileContextMenuController(store: files.store)
        let menu = try #require(controller.menu(for: selected ? files.items[1] : nil) as? ContextCommandMenu)
        let visible = try #require(NSScreen.main?.visibleFrame)
        let anchor = NSPoint(x: visible.midX, y: lower ? visible.minY + 90.pt : visible.midY)
        let source = PlacementTestPanel(contentRect: NSRect(x: anchor.x - 50, y: anchor.y - 50, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = PlacementTestPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; panel.isReleasedWhenClosed = false
        source.ownsMainWindow = true; source.makeKeyAndOrderFront(nil)
        let origin = try #require(source.contentView)
        let point = origin.convert(source.convertPoint(fromScreen: anchor), from: nil)
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: origin, point: point, keyboard: false, panel: panel, panelFactory: {
                let child = PlacementTestPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                child.isReleasedWhenClosed = false
                return child
            }, isApplicationActive: { true })
        return PlacementMenuFixture(files: files, source: source, panel: panel, presentation: presentation,
                                    controller: controller, anchor: anchor, visibleFrame: visible)
    }

    func close() {
        presentation.dismiss(reason: .replacement)
        // Defensive cleanup remains bounded to descendants of this synthetic root.
        for child in placementDescendants(of: panel).reversed() { child.orderOut(nil); child.close() }
        panel.close(); source.close(); files.close()
    }
}

@MainActor private final class PlacementTestPanel: FileActionsPanel {
    var ownsMainWindow = false
    private var shown = false
    override var isMainWindow: Bool { ownsMainWindow }
    override var isKeyWindow: Bool { shown }
    override var isVisible: Bool { shown }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
    override func orderFront(_ sender: Any?) { shown = true }
    override func orderOut(_ sender: Any?) { shown = false; super.orderOut(sender) }
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: -10000, y: -10000) }
}

@MainActor private func placementDescendants(of window: NSWindow) -> [NSWindow] {
    (window.childWindows ?? []).flatMap { [$0] + placementDescendants(of: $0) }
}

@MainActor private func placementButtons(in window: NSWindow) -> [ContextActionButton] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    return window.contentView.map { descendants($0).compactMap { $0 as? ContextActionButton } } ?? []
}

@MainActor private func placementScrolls(in window: NSWindow) -> [NSScrollView] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    return window.contentView.map { descendants($0).compactMap { $0 as? NSScrollView } } ?? []
}

@MainActor private func layoutOversizedMenu(_ scroll: NSScrollView, in window: NSWindow,
                                           style: NSScroller.Style) async throws {
    scroll.scrollerStyle = style
    window.contentView?.layoutSubtreeIfNeeded()
    // Layout is synchronous, but AppKit can update tracking on a later turn.
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    try #require(scroll.scrollerStyle == style)
    let document = try #require(scroll.documentView)
    try #require(document.bounds.height > scroll.contentView.bounds.height)
    if style == .legacy {
        let scroller = try #require(scroll.verticalScroller)
        try #require(!scroller.isHiddenOrHasHiddenAncestor && scroller.frame.width > 0)
    }
}

@MainActor private func expectViewportFit(_ caseID: String, scroll: NSScrollView,
                                          button: ContextActionButton, region: NSRect) throws {
    let document = try #require(scroll.documentView)
    let clip = scroll.contentView
    let converted = clip.convert(region, from: button)
    let panel = try #require(button.window)
    func rect(_ frame: NSRect) -> [String: CGFloat] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    let sample: [String: Any] = ["case": caseID, "preferredStyle": NSScroller.preferredScrollerStyle.rawValue,
        "appliedStyle": scroll.scrollerStyle.rawValue,
        "scrollerWidth": NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroll.scrollerStyle),
        "scrollerVisible": scroll.verticalScroller?.isHiddenOrHasHiddenAncestor == false,
        "panel": rect(panel.frame), "scroll": rect(scroll.frame), "clip": rect(clip.bounds),
        "document": rect(document.frame), "button": rect(clip.convert(button.bounds, from: button)),
        "region": rect(converted), "rightOverlap": converted.maxX - clip.bounds.maxX]
    let json = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
    print("MAC-USABILITY-MENU-01 \(String(decoding: json, as: UTF8.self))")
    #expect(abs(document.frame.width - clip.bounds.width) <= 0.5, "\(caseID): document follows the clip viewport")
    #expect(converted.maxX <= clip.bounds.maxX + 0.5, "\(caseID): title or decoration fits inside the clip viewport")
    #expect(abs(clip.bounds.minX) <= 0.5, "\(caseID): no horizontal scrolling")
}
