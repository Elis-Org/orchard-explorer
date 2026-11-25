import AppKit
import ExplorerCore

@MainActor
final class AddressSuggestionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    let table = AddressSuggestionTable()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private var urls: [URL] = []
    private var generation = UUID()
    private var showsPaths = false
    var onActivate: ((Int, UUID) -> Void)?
    var onHighlight: ((Int?, UUID) -> Void)?
    private var synchronizingSelection = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func preferredHeight(suggestionCount: Int, scale: CGFloat) -> CGFloat {
        CGFloat(min(8, suggestionCount)) * 26 * scale + 30 * scale
    }

    /// Screen coordinates throughout. The preferred minimum may shrink to the
    /// owner's visible width, but never below the existing content chrome.
    static func placementFrame(addressFrame: NSRect, preferredLeadingX: CGFloat,
                               ownerFrame: NSRect, visibleScreen: NSRect,
                               preferredHeight: CGFloat, scale: CGFloat) -> NSRect? {
        func usable(_ rect: NSRect) -> Bool {
            !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.size.width.isFinite && rect.size.height.isFinite
                && rect.size.width > 0 && rect.size.height > 0
                && rect.maxX.isFinite && rect.maxY.isFinite
        }
        guard usable(addressFrame), usable(ownerFrame), usable(visibleScreen),
              scale.isFinite, scale > 0, preferredLeadingX.isFinite,
              preferredHeight.isFinite, preferredHeight >= 30 * scale else { return nil }
        let horizontal = ownerFrame.intersection(visibleScreen)
        guard usable(horizontal), horizontal.width >= 20 * scale else { return nil }
        let width = min(max(addressFrame.width, 260 * scale), horizontal.width)
        let x = min(max(preferredLeadingX, horizontal.minX), horizontal.maxX - width)
        let belowEdge = min(addressFrame.minY - 2, visibleScreen.maxY)
        let aboveEdge = max(addressFrame.maxY + 2, visibleScreen.minY)
        let below = max(0, belowEdge - visibleScreen.minY)
        let above = max(0, visibleScreen.maxY - aboveEdge)
        let useBelow = preferredHeight <= below || (preferredHeight > above && below >= above)
        let height = min(preferredHeight, useBelow ? below : above)
        guard height >= 30 * scale else { return nil }
        return NSRect(x: x, y: useBelow ? belowEdge - height : aboveEdge, width: width, height: height)
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .controlBackgroundColor
        hidesOnDeactivate = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 5.pt
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = content
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")))
        table.tableColumns.first?.minWidth = 0
        table.headerView = nil
        table.rowHeight = 26.pt
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.tableColumns.first?.resizingMask = .autoresizingMask
        table.intercellSpacing = .zero
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Address suggestions")
        table.setAccessibilityIdentifier("address-suggestions")
        table.onClick = { [weak self] row in guard let self else { return }; self.onActivate?(row, self.generation) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        status.font = .systemFont(ofSize: 11.pt)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4.pt),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4.pt),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4.pt),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10.pt),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10.pt),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5.pt),
            status.heightAnchor.constraint(equalToConstant: 19.pt)
        ])
    }

    func update(model: AddressNavigationModel) {
        urls = model.suggestions
        generation = model.requestID
        showsPaths = model.presentation == .history
        let message: String
        if model.isLoading { message = "Loading folders…" }
        else if let error = model.errorMessage { message = error }
        else if urls.isEmpty { message = showsPaths ? "No recent addresses" : "No matching folders" }
        else if model.isTruncated { message = "More folders may exist; refine the path to narrow results." }
        else {
            let noun = showsPaths ? (urls.count == 1 ? "recent address" : "recent addresses")
                : (urls.count == 1 ? "folder" : "folders")
            message = "\(urls.count) \(noun)"
        }
        status.stringValue = message
        status.setAccessibilityLabel(message)
        status.toolTip = message
        synchronizingSelection = true
        table.reloadData()
        if let row = model.highlightedIndex { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
        synchronizingSelection = false
    }

    func fitColumn() {
        contentView?.layoutSubtreeIfNeeded()
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.sizeLastColumnToFit()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection else { return }
        onHighlight?(table.selectedRow >= 0 ? table.selectedRow : nil, generation)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard urls.indices.contains(row) else { return nil }
        let url = urls[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: showsPaths ? BrowsingPresentation.path(url) : BrowsingPresentation.title(url))
        label.font = .systemFont(ofSize: 12.pt)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityLabel(BrowsingPresentation.path(url))
        label.toolTip = BrowsingPresentation.path(url)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6.pt),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6.pt),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel(BrowsingPresentation.path(url))
        return cell
    }
}

@MainActor
final class AddressSuggestionTable: NSTableView {
    var onClick: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
    }
}
