import AppKit

/// HV-OBS-001: a shared boundary with separate label/disclosure emphasis.
/// The native buttons retain their own actions, accessibility and focus behavior.
@MainActor
final class BreadcrumbSegmentView: NSView {
    let labelButton: AddressActionButton
    let disclosureButton: AddressActionButton?
    private(set) weak var hoveredButton: AddressActionButton?

    init(label: AddressActionButton, disclosure: AddressActionButton?) {
        labelButton = label
        disclosureButton = disclosure
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Let the segment's intrinsic padding win over the native label's
        // preferred width, without preventing truncation in a narrow bar.
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 249), for: .horizontal)
        for button in [label] + (disclosure.map { [$0] } ?? []) {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26.pt),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        // MAC-HOVER-DEF-002: equal low compression priorities otherwise allow
        // some labels to disappear completely while their arrows remain. Keep
        // room for the native truncation glyph and the existing label padding.
        // This native sizing policy yields only when even those minima cannot
        // physically fit; it must not introduce conflicting required constraints.
        let font = label.font ?? NSFont.systemFont(ofSize: 12.pt)
        let ellipsisWidth = ceil(("…" as NSString).size(withAttributes: [.font: font]).width)
        let readableWidth = min(label.intrinsicContentSize.width + 12.pt, ellipsisWidth + 12.pt)
        let readableMinimum = label.widthAnchor.constraint(greaterThanOrEqualToConstant: readableWidth)
        readableMinimum.priority = NSLayoutConstraint.Priority(rawValue: 999)
        readableMinimum.isActive = true
        if let disclosure {
            NSLayoutConstraint.activate([
                disclosure.leadingAnchor.constraint(equalTo: label.trailingAnchor),
                disclosure.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        } else {
            label.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: labelButton.intrinsicContentSize.width + 12.pt
            + (disclosureButton == nil ? 0 : 17.pt), height: 26.pt)
    }

    func updateHover(for button: AddressActionButton, isInside: Bool) {
        guard button === labelButton || button === disclosureButton else { return }
        if isInside {
            if hoveredButton !== button { hoveredButton?.clearPointerHover() }
            hoveredButton = button
        } else if hoveredButton === button {
            hoveredButton = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let hoveredButton, hoveredButton.isEnabled, hoveredButton.isPointerInside else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let lineWidth: CGFloat = contrast ? 2 : 1
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 3.pt, yRadius: 3.pt)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.labelColor.withAlphaComponent(hoveredButton.isHighlighted ? 0.14 : (contrast ? 0.14 : 0.06)).setFill()
        convert(hoveredButton.bounds, from: hoveredButton).fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                   xRadius: 3.pt, yRadius: 3.pt)
        NSColor.labelColor.withAlphaComponent(contrast ? 0.65 : 0.10).setStroke()
        outline.lineWidth = lineWidth
        outline.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
