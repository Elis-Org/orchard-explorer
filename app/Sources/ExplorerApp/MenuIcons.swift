import AppKit
import ExplorerCore

/// Decorative artwork shared by the custom and native context menus.
@MainActor
enum MenuIcons {
    nonisolated static let side = 16

    enum Glyph: String, CaseIterable {
        case cut = "scissors", copy = "doc.on.doc", rename = "pencil"
        case share = "square.and.arrow.up", delete = "trash"
        case open = "arrow.up.right.square", newTab = "plus.square.on.square"
        case newWindow = "macwindow.badge.plus", openWith = "app.badge"
        case download = "arrow.down.circle"
        case keepOffline = "checkmark.circle", freeSpace = "cloud"
        case pin = "pin", unpin = "pin.slash", compress = "archivebox"
        case copyPath = "point.topleft.down.to.point.bottomright.curvepath"
        case properties = "wrench", terminal = "terminal.fill", finder = "magnifyingglass"
        case alias = "arrow.turn.up.right", view = "square.grid.2x2", sort = "arrow.up.arrow.down"
        case undo = "arrow.uturn.backward", redo = "arrow.uturn.forward", paste = "clipboard"
        case move = "arrow.right.to.line", new = "plus.circle", location = "folder"
        case close = "xmark", duplicate = "square.on.square", tag = "tag"

        @MainActor var image: NSImage? { MenuIcons.symbol(rawValue) }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side.pt, weight: .regular))
    }

    static func sizedCopy(_ image: NSImage) -> NSImage? {
        guard let copy = image.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side.pt, height: side.pt)
        copy.accessibilityDescription = nil
        return copy
    }

    static func viewMode(_ mode: FolderViewMode) -> NSImage? {
        let name: String = switch mode {
        case .extraLargeIcons: "square"
        case .largeIcons: "square.grid.2x2"
        case .mediumIcons: "square.grid.3x2"
        case .smallIcons: "square.grid.3x3"
        case .list: "list.bullet"
        case .details: "tablecells"
        case .tiles: "rectangle.grid.2x2"
        case .content: "list.bullet.rectangle"
        }
        return symbol(name)
    }
}
