import AppKit

/// Screen-space placement for independently sized context surfaces.
/// The caller supplies the invocation screen's usable area, including its margin.
/// WCP-02/05: keep the action strip near the anchor as the body changes sides.
enum ContextMenuPlacement {
    struct Root {
        let frame: NSRect
        let actionsAtBottom: Bool
    }

    static func root(anchor: NSPoint, size: NSSize, actionRowHeight: CGFloat,
                     availableFrame area: NSRect) -> Root {
        let size = bounded(size, in: area)
        let strip = min(max(0, actionRowHeight), size.height)
        let belowY = anchor.y - size.height
        let aboveY = anchor.y - strip
        let fitsBelow = belowY >= area.minY && anchor.y <= area.maxY
        let fitsAbove = aboveY >= area.minY && aboveY + size.height <= area.maxY
        let roomBelow = max(0, min(anchor.y, area.maxY) - area.minY - strip)
        let roomAbove = max(0, area.maxY - max(anchor.y, area.minY))
        let above = !fitsBelow && (fitsAbove || roomAbove > roomBelow)
        let rightX = anchor.x
        let leftX = anchor.x - size.width
        let x = rightX + size.width <= area.maxX ? rightX : leftX
        return Root(frame: clamped(origin: NSPoint(x: x, y: above ? aboveY : belowY), size: size, in: area),
                    actionsAtBottom: above && actionRowHeight > 0)
    }

    static func submenu(parentFrame: NSRect, parentRow: NSRect, size: NSSize,
                        availableFrame area: NSRect) -> NSRect {
        let size = bounded(size, in: area)
        let rightX = parentFrame.maxX
        let leftX = parentFrame.minX - size.width
        let fitsRight = rightX + size.width <= area.maxX
        let fitsLeft = leftX >= area.minX
        let rightRoom = area.maxX - parentFrame.maxX
        let leftRoom = parentFrame.minX - area.minX
        let x = fitsRight || (!fitsLeft && rightRoom >= leftRoom) ? rightX : leftX
        return clamped(origin: NSPoint(x: x, y: parentRow.maxY - size.height), size: size, in: area)
    }

    private static func bounded(_ size: NSSize, in area: NSRect) -> NSSize {
        NSSize(width: min(max(0, size.width), max(0, area.width)),
               height: min(max(0, size.height), max(0, area.height)))
    }

    private static func clamped(origin: NSPoint, size: NSSize, in area: NSRect) -> NSRect {
        NSRect(x: min(max(origin.x, area.minX), area.maxX - size.width),
               y: min(max(origin.y, area.minY), area.maxY - size.height),
               width: size.width, height: size.height)
    }
}
