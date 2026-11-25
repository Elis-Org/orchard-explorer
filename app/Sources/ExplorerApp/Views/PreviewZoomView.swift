import AppKit

/// One controller per accepted presentation. Native buttons hold a weak target.
@MainActor
final class PreviewZoomController: NSObject {
    private static let textSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4]

    let row: NSStackView
    private let minus = NSButton(title: "−", target: nil, action: nil)
    private let plus = NSButton(title: "+", target: nil, action: nil)
    private let reset: NSButton
    private let level = NSTextField(labelWithString: "")
    private let steps: [CGFloat]
    private var scale: CGFloat = 1
    private var onChange: ((CGFloat?, PreviewZoomController) -> Void)?

    init(fitsRaster: Bool, onChange: @escaping (CGFloat?, PreviewZoomController) -> Void) {
        steps = fitsRaster ? [0.125, 0.25] + Self.textSteps : Self.textSteps
        self.onChange = onChange
        reset = NSButton(title: fitsRaster ? "Fit" : "Reset", target: nil, action: nil)
        row = NSStackView()
        super.init()
        configure(minus, identifier: "preview-zoom-out", label: "Zoom out", action: #selector(zoomOut(_:)))
        configure(plus, identifier: "preview-zoom-in", label: "Zoom in", action: #selector(zoomIn(_:)))
        configure(reset, identifier: "preview-zoom-reset", label: fitsRaster ? "Fit to pane" : "Reset zoom",
            action: #selector(resetZoom(_:)))
        level.font = .monospacedDigitSystemFont(ofSize: 11.pt, weight: .regular)
        level.alignment = .center
        level.setAccessibilityIdentifier("preview-zoom-level")
        level.widthAnchor.constraint(equalToConstant: 40.pt).isActive = true
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5.pt
        for view in [minus, level, plus, reset] { row.addArrangedSubview(view) }
        row.setContentHuggingPriority(.required, for: .vertical)
        update(scale: 1, resetIsRedundant: true)
    }

    func update(scale: CGFloat, resetIsRedundant: Bool) {
        self.scale = scale
        level.stringValue = scale == 0.125 ? "12.5%" : "\(Int((scale * 100).rounded()))%"
        minus.isEnabled = lowerStep != nil
        plus.isEnabled = higherStep != nil
        reset.isEnabled = !resetIsRedundant
    }

    func invalidate() {
        onChange = nil
        for button in [minus, plus, reset] {
            button.target = nil
            button.isEnabled = false
        }
    }

    private var lowerStep: CGFloat? { steps.last { $0 < scale - 0.0001 } }
    private var higherStep: CGFloat? { steps.first { $0 > scale + 0.0001 } }

    private func configure(_ button: NSButton, identifier: String, label: String, action: Selector) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12.pt)
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
    }

    @objc private func zoomOut(_ sender: NSButton) {
        if let lowerStep { onChange?(lowerStep, self) }
    }

    @objc private func zoomIn(_ sender: NSButton) {
        if let higherStep { onChange?(higherStep, self) }
    }

    @objc private func resetZoom(_ sender: NSButton) {
        if sender.isEnabled { onChange?(nil, self) }
    }
}

/// AppKit magnifies the original pixel-sized view and owns the scrollbars.
/// Center the image on any axis too small to scroll.
private final class PreviewImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if let document = documentView?.frame {
            if bounds.width >= document.width { bounds.origin.x = document.midX - bounds.width / 2 }
            if bounds.height >= document.height { bounds.origin.y = document.midY - bounds.height / 2 }
        }
        return bounds
    }
}

@MainActor
final class PreviewRasterView: NSView {
    private let scroll = NSScrollView()
    private let imageSize: NSSize
    private var manualScale: CGFloat?
    private var viewportSize = NSSize.zero
    var onScaleChange: ((CGFloat, Bool) -> Void)?

    init(image: CGImage) {
        imageSize = NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        super.init(frame: .zero)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: imageSize))
        imageView.image = NSImage(cgImage: image, size: imageSize)
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityIdentifier("preview-raster")
        imageView.setAccessibilityLabel("File preview image")
        scroll.contentView = PreviewImageClipView(frame: .zero)
        scroll.documentView = imageView
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.allowsMagnification = false
        scroll.minMagnification = 0.001
        scroll.maxMagnification = 4
        scroll.setAccessibilityIdentifier("preview-raster-scroll")
        scroll.setAccessibilityLabel("File preview")
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        // The child scroll view keeps its old frame until this layout pass.
        let priorCenter = visibleCenter
        super.layout()
        scroll.frame = bounds
        scroll.tile()
        let viewport = scroll.contentView.frame.size
        guard viewport.width > 0, viewport.height > 0, viewport != viewportSize else { return }
        viewportSize = viewport
        if manualScale == nil { applyScale() }
        else { center(on: priorCenter) }
    }

    func setScale(_ scale: CGFloat?) {
        manualScale = scale
        applyScale()
    }

    private var visibleCenter: NSPoint {
        let visible = scroll.contentView.bounds
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    private func applyScale() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let fitting = manualScale == nil
        let anchor = fitting ? NSPoint(x: imageSize.width / 2, y: imageSize.height / 2) : visibleCenter
        let scale = manualScale ?? min(1, viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        scroll.setMagnification(scale, centeredAt: visibleCenter)
        center(on: anchor)
        onScaleChange?(scroll.magnification, fitting)
    }

    private func center(on point: NSPoint) {
        let clip = scroll.contentView
        let size = clip.bounds.size
        let requested = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
            width: size.width, height: size.height)
        clip.scroll(to: clip.constrainBoundsRect(requested).origin)
        scroll.reflectScrolledClipView(clip)
    }
}
