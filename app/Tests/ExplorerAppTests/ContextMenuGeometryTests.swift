import AppKit
import Testing
@testable import ExplorerApp

@Suite struct ContextMenuGeometryTests {
    private let available = NSRect(x: -1600, y: -900, width: 1200, height: 800)

    @Test func rootKeepsQuickActionsNearAnchorWhenBodyChangesSides() {
        let size = NSSize(width: 320, height: 440)
        let upper = ContextMenuPlacement.root(anchor: NSPoint(x: -1400, y: -150),
            size: size, actionRowHeight: 70, availableFrame: available)
        #expect(!upper.actionsAtBottom)
        #expect(upper.frame == NSRect(x: -1400, y: -590, width: 320, height: 440))
        let lower = ContextMenuPlacement.root(anchor: NSPoint(x: -1400, y: -800),
            size: size, actionRowHeight: 70, availableFrame: available)
        #expect(lower.actionsAtBottom)
        #expect(lower.frame == NSRect(x: -1400, y: -870, width: 320, height: 440))
        #expect(lower.frame.minY + 70 == -800)
    }

    @Test func rootFlipsHorizontallyBeforeClamping() {
        let result = ContextMenuPlacement.root(anchor: NSPoint(x: -420, y: -200),
            size: NSSize(width: 320, height: 300), actionRowHeight: 70, availableFrame: available)
        #expect(result.frame.maxX == -420)
        #expect(available.contains(result.frame))
    }

    @Test func backgroundAboveHasNoReservedQuickStrip() {
        let result = ContextMenuPlacement.root(anchor: NSPoint(x: -1300, y: -850),
            size: NSSize(width: 300, height: 300), actionRowHeight: 0, availableFrame: available)
        #expect(result.frame.minY == -850)
        #expect(available.contains(result.frame))
    }

    @Test func childUsesIndependentWidthAndAlignsToParentRow() {
        let parent = NSRect(x: -1400, y: -700, width: 320, height: 500)
        let row = NSRect(x: -1390, y: -400, width: 300, height: 30)
        let child = ContextMenuPlacement.submenu(parentFrame: parent, parentRow: row,
            size: NSSize(width: 250, height: 180), availableFrame: available)
        #expect(child.minX == parent.maxX && child.maxY == row.maxY)
        #expect(child.size == NSSize(width: 250, height: 180))
    }

    @Test func childFlipsLeftAndClampsVerticallyWithoutMovingParent() {
        let parent = NSRect(x: -750, y: -880, width: 320, height: 400)
        let row = NSRect(x: -740, y: -840, width: 300, height: 30)
        let child = ContextMenuPlacement.submenu(parentFrame: parent, parentRow: row,
            size: NSSize(width: 250, height: 300), availableFrame: available)
        #expect(child.maxX == parent.minX)
        #expect(child.minY == available.minY)
        #expect(available.contains(child))
        #expect(parent == NSRect(x: -750, y: -880, width: 320, height: 400))
    }

    @Test func constrainedScreensBoundEveryMenuIndependently() {
        let frame = NSRect(x: 400, y: 200, width: 180, height: 140)
        for point in [NSPoint(x: 400, y: 200), NSPoint(x: 490, y: 270), NSPoint(x: 580, y: 340)] {
            let root = ContextMenuPlacement.root(anchor: point, size: NSSize(width: 400, height: 900),
                actionRowHeight: 70, availableFrame: frame)
            #expect(root.frame == frame)
            let child = ContextMenuPlacement.submenu(parentFrame: root.frame,
                parentRow: NSRect(origin: point, size: NSSize(width: 100, height: 25)),
                size: NSSize(width: 300, height: 800), availableFrame: frame)
            #expect(child == frame)
        }
    }

    @Test func boundaryGridNeverEscapesAvailableArea() {
        for x in stride(from: available.minX - 50, through: available.maxX + 50, by: 130) {
            for y in stride(from: available.minY - 50, through: available.maxY + 50, by: 90) {
                let root = ContextMenuPlacement.root(anchor: NSPoint(x: x, y: y),
                    size: NSSize(width: 336, height: 500), actionRowHeight: 70, availableFrame: available)
                #expect(available.contains(root.frame))
                let child = ContextMenuPlacement.submenu(parentFrame: root.frame,
                    parentRow: NSRect(x: root.frame.minX, y: y, width: 336, height: 30),
                    size: NSSize(width: 280, height: 650), availableFrame: available)
                #expect(available.contains(child))
            }
        }
    }

    @Test func equallyConstrainedSidesUseStableBelowAndRightPreferences() {
        let area = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let root = ContextMenuPlacement.root(anchor: NSPoint(x: 400, y: 300),
            size: NSSize(width: 300, height: 400), actionRowHeight: 0, availableFrame: area)
        #expect(root.frame.minY == 0)
        let child = ContextMenuPlacement.submenu(
            parentFrame: NSRect(x: 400, y: 100, width: 200, height: 400),
            parentRow: NSRect(x: 400, y: 300, width: 200, height: 30),
            size: NSSize(width: 500, height: 200), availableFrame: area)
        #expect(child.minX == 500 && area.contains(child))
    }
}
