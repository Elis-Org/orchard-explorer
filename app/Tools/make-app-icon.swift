// MAC-081 — Orchard Explorer application icon generator (original artwork).
//
// Draws a manila folder with a blue band on a light macOS rounded-square tile,
// evoking (not reproducing) the yellow-folder File Explorer identity. No Windows
// artwork is extracted or traced (MAC-009/075). Vector drawing in a 1024-point
// design space, rendered at every size an .iconset needs.
//
// Usage: swiftc -O -o /tmp/make-app-icon app/Tools/make-app-icon.swift
//        /tmp/make-app-icon <output.iconset> [preview.png]
//        iconutil -c icns <output.iconset> -o app/Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() {
    // Tile on the macOS icon grid: 824-point body, continuous-looking corners.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x000000, 0.28); tileShadow.shadowBlurRadius = 28; tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    color(0xFFFFFF).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xF4F9FF), ending: color(0xC7E0FA))?.draw(in: tile, angle: -90)
    color(0x9CC3EA, 0.6).setStroke(); tile.lineWidth = 3; tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Back panel with a tab on the left.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 196, y: 300))
    back.line(to: NSPoint(x: 196, y: 728))
    back.curve(to: NSPoint(x: 240, y: 772), controlPoint1: NSPoint(x: 196, y: 752), controlPoint2: NSPoint(x: 216, y: 772))
    back.line(to: NSPoint(x: 418, y: 772))
    back.curve(to: NSPoint(x: 458, y: 752), controlPoint1: NSPoint(x: 434, y: 772), controlPoint2: NSPoint(x: 448, y: 764))
    back.line(to: NSPoint(x: 496, y: 708))
    back.line(to: NSPoint(x: 784, y: 708))
    back.curve(to: NSPoint(x: 828, y: 664), controlPoint1: NSPoint(x: 808, y: 708), controlPoint2: NSPoint(x: 828, y: 688))
    back.line(to: NSPoint(x: 828, y: 300))
    back.close()
    NSGraphicsContext.saveGraphicsState()
    let folderShadow = NSShadow()
    folderShadow.shadowColor = color(0x5A3A00, 0.30); folderShadow.shadowBlurRadius = 22; folderShadow.shadowOffset = NSSize(width: 0, height: -10)
    folderShadow.set()
    color(0xE79A16).setFill(); back.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xF2AE2E), ending: color(0xD98A0B))?.draw(in: back, angle: -90)

    // A sheet of paper peeking out.
    let paper = NSBezierPath(roundedRect: NSRect(x: 238, y: 470, width: 548, height: 214), xRadius: 18, yRadius: 18)
    color(0xFFFFFF).setFill(); paper.fill()
    color(0xD7DEE8).setStroke(); paper.lineWidth = 3; paper.stroke()
    for (index, width) in [CGFloat(360), 300].enumerated() {
        let line = NSBezierPath(roundedRect: NSRect(x: 286, y: 628 - CGFloat(index) * 34, width: width, height: 12), xRadius: 6, yRadius: 6)
        color(0xC9D6E6).setFill(); line.fill()
    }

    // Front panel: lighter yellow, slightly wider, with a blue band along its base.
    let frontRect = NSRect(x: 176, y: 228, width: 672, height: 392)
    let front = NSBezierPath(roundedRect: frontRect, xRadius: 46, yRadius: 46)
    NSGraphicsContext.saveGraphicsState()
    let frontShadow = NSShadow()
    frontShadow.shadowColor = color(0x6B4500, 0.28); frontShadow.shadowBlurRadius = 16; frontShadow.shadowOffset = NSSize(width: 0, height: -6)
    frontShadow.set()
    color(0xFFCB45).setFill(); front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFE38A), ending: color(0xFFC437))?.draw(in: front, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    let band = NSRect(x: frontRect.minX, y: frontRect.minY, width: frontRect.width, height: 128)
    NSGradient(starting: color(0x4C9BF5), ending: color(0x1C64CF))?.draw(in: band, angle: -90)
    color(0xFFFFFF, 0.55).setFill(); NSRect(x: band.minX, y: band.maxY - 6, width: band.width, height: 6).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Top highlight and outline of the front panel.
    let highlight = NSBezierPath(roundedRect: frontRect.insetBy(dx: 10, dy: 10), xRadius: 38, yRadius: 38)
    color(0xFFFFFF, 0.35).setStroke(); highlight.lineWidth = 4; highlight.stroke()
    color(0xC98A12, 0.55).setStroke(); front.lineWidth = 3; front.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: make-app-icon <output.iconset> [preview.png]"); exit(2) }
let iconset = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
if arguments.count >= 3 {
    try render(pixels: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(iconset.path)")
