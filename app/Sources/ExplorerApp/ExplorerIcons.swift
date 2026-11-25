import AppKit
import ExplorerCore
import UniformTypeIdentifiers

/// MAC-075: item icons. Ordinary folders use Explorer's own drawn yellow folder
/// (original artwork, resolution independent); files, packages and links keep
/// the native macOS icons. No reference artwork is extracted.
enum ExplorerIcons {
    static func locationIcon(_ url: URL) -> NSImage {
        if let location = ArchiveLocation(url: url), location.components.isEmpty { return compressedFolder }
        return folder
    }
    static func icon(for item: FileItem) -> NSImage {
        if showsCompressedFolder(item) { return compressedFolder }
        if showsFolder(item) { return folder }
        if !usesPhysicalIcon(item) { return ItemMetadataFormatting.genericIcon(for: item) }
        return NSWorkspace.shared.icon(forFile: item.url.path)
    }

    static func usesPhysicalIcon(_ item: FileItem) -> Bool { BrowsingPresentation.isPhysical(item) }

    /// The icon of a creation draft before anything exists on disk.
    static func draftIcon(_ kind: NewItemKind) -> NSImage {
        switch kind {
        case .folder: return folder
        case .file(.bitmapImage): return NSWorkspace.shared.icon(for: .bmp)
        case .file(.textDocument): return NSWorkspace.shared.icon(for: .plainText)
        case .file(.zipArchive): return compressedFolder
        }
    }

    static func showsCompressedFolder(_ item: FileItem) -> Bool {
        !item.isDirectory && !item.isSymbolicLink && item.url.pathExtension.lowercased() == "zip"
    }

    static let compressedFolder: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            drawFolder(in: rect)
            let unit = rect.width / 64
            NSColor(srgbRed: 0.29, green: 0.32, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + 5 * unit, y: rect.minY + 22 * unit,
                                     width: 54 * unit, height: 6 * unit)).fill()
            NSColor(srgbRed: 0.84, green: 0.87, blue: 0.89, alpha: 1).setFill()
            for index in 0..<13 {
                let x = rect.minX + CGFloat(7 + index * 4) * unit
                NSBezierPath(rect: NSRect(x: x, y: rect.minY + 25 * unit, width: 2 * unit, height: 3 * unit)).fill()
                NSBezierPath(rect: NSRect(x: x + 2 * unit, y: rect.minY + 22 * unit, width: 2 * unit, height: 3 * unit)).fill()
            }
            let pull = NSBezierPath(roundedRect: NSRect(x: rect.minX + 10 * unit, y: rect.minY + 12 * unit,
                width: 7 * unit, height: 15 * unit), xRadius: 2 * unit, yRadius: 2 * unit)
            NSColor(srgbRed: 0.72, green: 0.75, blue: 0.78, alpha: 1).setFill()
            pull.fill()
            NSColor(srgbRed: 0.25, green: 0.28, blue: 0.31, alpha: 1).setStroke()
            pull.lineWidth = max(0.7, unit)
            pull.stroke()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 12 * unit, y: rect.minY + 15 * unit,
                width: 3 * unit, height: 6 * unit), xRadius: unit, yRadius: unit).stroke()
            return true
        }
        image.accessibilityDescription = "Compressed folder"
        return image
    }()

    static func showsFolder(_ item: FileItem) -> Bool {
        guard item.isDirectory, !item.isSymbolicLink else { return false }
        if !BrowsingPresentation.isPhysical(item) { return true }
        let pathExtension = item.url.pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension, conformingTo: .directory) else { return true }
        return !type.conforms(to: .package)
    }

    static let folder: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            drawFolder(in: rect)
            return true
        }
        image.accessibilityDescription = "Folder"
        return image
    }()

    /// A generic manila folder: darker back panel with a tab, a sheet of paper
    /// and a lighter front panel. Coordinates are fractions of the icon square.
    static func drawFolder(in rect: NSRect) {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                   width: w * rect.width, height: h * rect.height)
        }
        let radius = rect.width * 0.05
        let back = NSBezierPath()
        let tabTop = rect.minY + 0.86 * rect.height, bodyTop = rect.minY + 0.78 * rect.height
        let left = rect.minX + 0.06 * rect.width, right = rect.minX + 0.94 * rect.width
        let bottom = rect.minY + 0.14 * rect.height
        back.move(to: NSPoint(x: left + radius, y: bottom))
        back.line(to: NSPoint(x: right - radius, y: bottom))
        back.curve(to: NSPoint(x: right, y: bottom + radius), controlPoint1: NSPoint(x: right, y: bottom),
                   controlPoint2: NSPoint(x: right, y: bottom))
        back.line(to: NSPoint(x: right, y: bodyTop - radius))
        back.curve(to: NSPoint(x: right - radius, y: bodyTop), controlPoint1: NSPoint(x: right, y: bodyTop),
                   controlPoint2: NSPoint(x: right, y: bodyTop))
        back.line(to: NSPoint(x: rect.minX + 0.47 * rect.width, y: bodyTop))
        back.line(to: NSPoint(x: rect.minX + 0.40 * rect.width, y: tabTop))
        back.line(to: NSPoint(x: left + radius, y: tabTop))
        back.curve(to: NSPoint(x: left, y: tabTop - radius), controlPoint1: NSPoint(x: left, y: tabTop),
                   controlPoint2: NSPoint(x: left, y: tabTop))
        back.line(to: NSPoint(x: left, y: bottom + radius))
        back.curve(to: NSPoint(x: left + radius, y: bottom), controlPoint1: NSPoint(x: left, y: bottom),
                   controlPoint2: NSPoint(x: left, y: bottom))
        back.close()
        NSColor(srgbRed: 0.90, green: 0.64, blue: 0.13, alpha: 1).setFill()
        back.fill()

        NSColor(white: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: r(0.13, 0.30, 0.74, 0.43), xRadius: radius * 0.6, yRadius: radius * 0.6).fill()

        let front = NSBezierPath(roundedRect: r(0.06, 0.14, 0.88, 0.54), xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.86, blue: 0.42, alpha: 1),
                   ending: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.22, alpha: 1))?.draw(in: front, angle: -90)
        NSColor(srgbRed: 0.85, green: 0.58, blue: 0.10, alpha: 0.55).setStroke()
        front.lineWidth = max(0.5, rect.width / 64)
        front.stroke()
    }
}

