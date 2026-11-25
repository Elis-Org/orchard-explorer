import AppKit
import ExplorerCore

/// UI-VIEW-003 / FR-VIEW-001/008/010; EV-0306/0307 and EV-0318–0329.
/// Native item presentation uses snapshot metadata and generic type icons only.
final class ExplorerCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExplorerCollectionItem")

    var itemView: ExplorerCollectionItemView { view as! ExplorerCollectionItemView }
    var representedID: String? { itemView.representedID }
    var onReuse: (() -> Void)?

    var onAccessibilitySelection: ((Bool) -> Void)? {
        get { itemView.onAccessibilitySelection }
        set { itemView.onAccessibilitySelection = newValue }
    }
    var onAccessibilityFocus: (() -> Void)? {
        get { itemView.onAccessibilityFocus }
        set { itemView.onAccessibilityFocus = newValue }
    }
    var onActivate: (() -> Void)? {
        get { itemView.onActivate }
        set { itemView.onActivate = newValue }
    }

    override func loadView() {
        view = ExplorerCollectionItemView()
        textField = itemView.nameField
        imageView = itemView.icon
    }

    func configure(item: FileItem, mode: FolderViewMode, folder: URL? = nil,
                   cloudStatus: (presentation: CloudStatusPresentation?, checkedAt: Date?)? = nil) {
        itemView.configure(item: item, mode: mode, folder: folder, cloudStatus: cloudStatus)
    }

    func applyState(selected: Bool, focused: Bool, hasKeyboardFocus: Bool) {
        isSelected = selected
        itemView.applyState(selected: selected, focused: focused, hasKeyboardFocus: hasKeyboardFocus)
    }

    override func prepareForReuse() {
        // Let the coordinator cancel the exact session before clearing its token.
        // Ordinary cell reuse must never end another field's shared editor.
        onReuse?()
        if itemView.nameField.sessionID != nil { itemView.nameField.finishSession() }
        onReuse = nil
        itemView.reset()
        super.prepareForReuse()
    }
}

final class ExplorerCollectionItemView: NSView {
    let nameField = NameEditorTextField()
    let icon = NSImageView()
    let cloudBadge = CloudStatusBadgeView()
    private var metadataAccessibilityValue = ""
    let kindField = NSTextField(labelWithString: "")
    let sizeField = NSTextField(labelWithString: "")
    let dateField = NSTextField(labelWithString: "")

    weak var collection: ExplorerFileCollectionView?
    private(set) var representedID: String?
    private(set) var mode: FolderViewMode = .largeIcons
    var onAccessibilitySelection: ((Bool) -> Void)?
    var onAccessibilityFocus: (() -> Void)?
    var onActivate: (() -> Void)?

    var isFileDropTarget = false { didSet { if oldValue != isFileDropTarget { needsDisplay = true } } }
    private lazy var pointerHover = PointerHoverTracker(view: self,
        enabled: { [weak self] in self?.representedID != nil })
    private var selectedState = false
    private var focusedState = false
    private var hasKeyboardFocus = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        nameField.font = .systemFont(ofSize: 12.pt)
        nameField.textColor = .labelColor
        for field in [kindField, sizeField, dateField] {
            field.font = .systemFont(ofSize: 11.pt)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setAccessibilityElement(false)
        }
        [icon, nameField, kindField, sizeField, dateField, cloudBadge].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("collection-file-item")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `folder` is a search result's actual parent (NATIVE-P14), shown in help/AX only.
    func configure(item: FileItem, mode: FolderViewMode, folder: URL? = nil,
                   cloudStatus: (presentation: CloudStatusPresentation?, checkedAt: Date?)? = nil) {
        if representedID != item.id { pointerHover.clear() }
        representedID = item.id
        self.mode = mode
        icon.image = ItemMetadataFormatting.genericIcon(for: item)
        // NSImageView registers its own drag destinations even when read-only.
        // The collection owns file drops across the entire item, including icons.
        icon.unregisterDraggedTypes()
        if nameField.sessionID == nil {
            nameField.stringValue = item.name
            configureNamePresentation()
        }
        let kind = item.kind.isEmpty ? "Unavailable" : item.kind
        let size = ItemMetadataFormatting.size(item.size, isDirectory: item.isDirectory,
                                               isSymbolicLink: item.isSymbolicLink)
        let date = ItemMetadataFormatting.date(item.modifiedAt)
        kindField.stringValue = mode == .content ? "Type: \(kind)" : kind
        sizeField.stringValue = mode == .content ? "Size: \(size)" : size
        dateField.stringValue = "Date modified: \(date)"
        nameField.toolTip = item.name
        kindField.toolTip = kind
        sizeField.toolTip = size
        dateField.toolTip = date
        setAccessibilityLabel(item.name)
        if let folder {
            metadataAccessibilityValue = "Folder: \(folder.path). Type: \(kind). Size: \(size). Date modified: \(date)."
            toolTip = "\(item.name)\n\(folder.path)"
        } else {
            metadataAccessibilityValue = "Type: \(kind). Size: \(size). Date modified: \(date)."
            toolTip = item.name
        }
        let status = cloudStatus ?? (CloudStatusPresentation.forItem(item), nil)
        updateCloudStatus(status.presentation, checkedAt: status.checkedAt)
        needsLayout = true
        needsDisplay = true
    }

    func updateCloudStatus(_ status: CloudStatusPresentation?, checkedAt: Date? = nil) {
        let changed = cloudBadge.presentation != status
        let changedVisibility = cloudBadge.isHidden != (status == nil)
        if changed { cloudBadge.configure(status) }
        let help = status?.help(checkedAt: checkedAt)
        cloudBadge.toolTip = help
        setAccessibilityHelp(help)
        let value = metadataAccessibilityValue + (status.map {
            let label = $0.label
            return " Status: " + label + (label.hasSuffix(".") ? "" : ".")
        } ?? "")
        let valueChanged = accessibilityValue() as? String != value
        if valueChanged { setAccessibilityValue(value) }
        if changedVisibility { needsLayout = true }
        if valueChanged { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    func applyState(selected: Bool, focused: Bool, hasKeyboardFocus: Bool) {
        let focusChanged = self.focusedState != focused || self.hasKeyboardFocus != hasKeyboardFocus
        selectedState = selected
        focusedState = focused
        self.hasKeyboardFocus = hasKeyboardFocus
        needsDisplay = true
        if focusChanged, focused, hasKeyboardFocus {
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    func reset() {
        pointerHover.clear()
        representedID = nil
        isFileDropTarget = false
        collection = nil
        onAccessibilitySelection = nil
        onAccessibilityFocus = nil
        onActivate = nil
        icon.image = nil
        cloudBadge.configure(nil)
        metadataAccessibilityValue = ""
        for field in [nameField, kindField, sizeField, dateField] { field.stringValue = ""; field.toolTip = nil }
        toolTip = nil
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
        applyState(selected: false, focused: false, hasKeyboardFocus: false)
    }

    private var usesStackedIcon: Bool {
        [.extraLargeIcons, .largeIcons, .mediumIcons].contains(mode)
    }

    private func configureNamePresentation() {
        nameField.alignment = usesStackedIcon ? .center : .left
        nameField.maximumNumberOfLines = usesStackedIcon ? 2 : 1
        nameField.cell?.usesSingleLineMode = !usesStackedIcon
        nameField.lineBreakMode = usesStackedIcon ? .byWordWrapping : .byTruncatingTail
        nameField.cell?.wraps = usesStackedIcon
        nameField.cell?.isScrollable = !usesStackedIcon
        nameField.cell?.truncatesLastVisibleLine = usesStackedIcon
    }

    override func layout() {
        super.layout()
        // MAC-074: lay out in reference units, then scale every frame.
        let scale = ExplorerScale.factor
        let width = bounds.width / scale
        let height = bounds.height / scale
        func scaled(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        kindField.isHidden = true
        sizeField.isHidden = true
        dateField.isHidden = true
        if usesStackedIcon {
            let side: CGFloat = mode == .extraLargeIcons ? 144 : (mode == .largeIcons ? 84 : 48)
            let top: CGFloat = mode == .extraLargeIcons ? 6 : 4
            icon.frame = scaled(NSRect(x: max(0, (width - side) / 2), y: top, width: side, height: side))
            let nameTop = top + side + 7
            nameField.frame = scaled(NSRect(x: 4, y: nameTop, width: max(0, width - 8),
                                     height: max(20, min(36, height - nameTop - 3))))
        } else if mode == .tiles {
            icon.frame = scaled(NSRect(x: 8, y: 12, width: 40, height: 40))
            let textWidth = max(0, width - 66)
            nameField.frame = scaled(NSRect(x: 58, y: 5, width: textWidth, height: 18))
            kindField.frame = scaled(NSRect(x: 58, y: 24, width: textWidth, height: 16))
            sizeField.frame = scaled(NSRect(x: 58, y: 41, width: textWidth, height: 16))
            kindField.isHidden = false
            sizeField.isHidden = false
        } else if mode == .content {
            icon.frame = scaled(NSRect(x: 8, y: 20, width: 32, height: 32))
            let textWidth = max(0, width - 58)
            if width >= 440 {
                let rightStart = max(220, width * 0.54)
                nameField.frame = scaled(NSRect(x: 50, y: 13, width: max(0, rightStart - 62), height: 20))
                kindField.frame = scaled(NSRect(x: 50, y: 37, width: max(0, rightStart - 62), height: 17))
                dateField.frame = scaled(NSRect(x: rightStart, y: 13, width: max(0, width - rightStart - 8), height: 18))
                sizeField.frame = scaled(NSRect(x: rightStart, y: 37, width: max(0, width - rightStart - 8), height: 17))
                kindField.isHidden = false
            } else {
                nameField.frame = scaled(NSRect(x: 50, y: 6, width: textWidth, height: 19))
                dateField.frame = scaled(NSRect(x: 50, y: 28, width: textWidth, height: 16))
                sizeField.frame = scaled(NSRect(x: 50, y: 47, width: textWidth, height: 16))
            }
            sizeField.isHidden = false
            dateField.isHidden = false
        } else {
            // EV-0324/0325 establishes one vertical List column; overflow beyond
            // that evidence uses the native vertical scrolling policy.
            icon.frame = scaled(NSRect(x: 6, y: 6, width: 16, height: 16))
            nameField.frame = scaled(NSRect(x: 28, y: 5, width: max(0, width - 34), height: 19))
        }
        guard !cloudBadge.isHidden else { return }
        let gap = 20.pt, side = 16.pt
        var name = nameField.frame
        if usesStackedIcon {
            let availableWidth = max(0, name.width - gap)
            let textWidth: CGFloat
            if nameField.sessionID != nil {
                textWidth = availableWidth
            } else {
                let measured = (nameField.stringValue as NSString).size(withAttributes:
                    [.font: nameField.font ?? NSFont.systemFont(ofSize: 12.pt)]).width + 4.pt
                textWidth = min(availableWidth, measured)
            }
            let left = max(0, (bounds.width - textWidth - gap) / 2)
            cloudBadge.frame = NSRect(x: left, y: name.minY + 1.pt, width: side, height: side)
            name.origin.x = left + gap; name.size.width = textWidth
        } else if mode == .list || mode == .smallIcons {
            cloudBadge.frame = NSRect(x: icon.frame.minX, y: icon.frame.minY, width: side, height: side)
            icon.frame.origin.x += gap
            name.origin.x += gap; name.size.width = max(0, name.width - gap)
        } else {
            cloudBadge.frame = NSRect(x: name.minX, y: name.minY + 1.pt, width: side, height: side)
            name.origin.x += gap; name.size.width = max(0, name.width - gap)
        }
        nameField.frame = name
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if pointerHover.isHovered, !selectedState {
            ExplorerHoverPalette.item(for: self).setFill()
            rect.fill()
        }
        if selectedState {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fill = dark ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.80, green: 0.91, blue: 0.996, alpha: 1)
            fill.setFill()
            rect.fill()
            (contrast ? NSColor.labelColor : NSColor.separatorColor).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = contrast ? 2 : 1
            border.stroke()
        }
        if isFileDropTarget {
            NSColor.controlAccentColor.setStroke()
            let target = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            target.lineWidth = 3
            target.stroke()
        }
        if focusedState, hasKeyboardFocus {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            focus.lineWidth = contrast ? 3 : 2
            focus.stroke()
        }
        if mode == .content {
            NSColor.separatorColor.setFill()
            NSRect(x: 5, y: bounds.maxY - 1, width: max(0, bounds.width - 10), height: 0.5).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func clearPointerHover() { pointerHover.clear() }
    override var isHidden: Bool { didSet { if isHidden { pointerHover.clear() } } }
    override func updateTrackingAreas() { super.updateTrackingAreas(); pointerHover.update() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); pointerHover.movedToWindow() }
    override func mouseEntered(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseEntered(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseExited(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if !pointerHover.handle(event) { super.mouseMoved(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if nameField.sessionID != nil, hit === nameField || hit.isDescendant(of: nameField) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if let collection { collection.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let collection { collection.mouseDragged(with: event) }
        else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if let collection { collection.mouseUp(with: event) }
        else { super.mouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        collection?.menu(for: event) ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let collection { collection.showPointerContextMenu(with: event) }
        else { super.rightMouseDown(with: event) }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let representedID else { return false }
        return collection?.showItemContextMenu(itemID: representedID) ?? false
    }

    override func isAccessibilitySelected() -> Bool { selectedState }
    override func setAccessibilitySelected(_ selected: Bool) { onAccessibilitySelection?(selected) }
    override func isAccessibilityFocused() -> Bool { focusedState && hasKeyboardFocus }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { onAccessibilityFocus?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
