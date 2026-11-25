import AppKit
import ExplorerCore
import SwiftUI
import UniformTypeIdentifiers

/// FR-PREVIEW-003 / AT-PREVIEW-003 / EV-0313 screenshot + EV-0314 UIA.
/// The pane renders the store's read-only inspector projection.
struct ItemDetailsView: View {
    @ObservedObject var store: ExplorerStore

    var body: some View {
        ScrollView {
            let selection = store.inspectorDetails
            if case .single(let item) = selection {
                selectedItem(item)
            } else {
                VStack(alignment: .leading, spacing: 12.pt) {
                    Text("Details").font(.system(size: 13.pt, weight: .bold))
                    switch selection {
                    case .empty:
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("details-empty")
                    case .multiple(let count):
                        Text("\(count) items selected").font(.system(size: 13.pt, weight: .bold))
                            .accessibilityIdentifier("details-selection-count")
                        Text("Select one item to see its details")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("details-multiple")
                    case .preparing, .unavailable:
                        Text(selection == .preparing ? "Loading details…" : HomeInspectorDetails.unavailableMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("details-item-status")
                    case .single: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22.pt)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details pane")
        .accessibilityIdentifier("item-details-pane")
    }

    private var emptyMessage: String {
        guard !store.tabs.isEmpty else { return "Select an item to see details" }
        if store.activeTab.isLoading { return "Loading folder…" }
        if store.activeTab.isUnavailable { return "Details unavailable while this folder cannot be read." }
        if store.nameEdit != nil || store.isPerformingOperation || store.isShowingRecovery {
            return "Finish the current action to see details."
        }
        return "Select an item to see details"
    }

    private func selectedItem(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: ItemMetadataFormatting.genericIcon(for: item))
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 84.pt, height: 100.pt)
                .frame(maxWidth: .infinity, minHeight: 196.pt)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18.pt) {
                HStack(alignment: .top, spacing: 10.pt) {
                    Image(nsImage: ItemMetadataFormatting.genericIcon(for: item))
                        .resizable().scaledToFit().frame(width: 22.pt, height: 26.pt)
                        .accessibilityHidden(true)
                    Text(item.name).font(.system(size: 13.pt, weight: .semibold))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("details-item-name")
                }
                Text("Details").font(.system(size: 12.pt, weight: .semibold)).padding(.top, 4.pt)
                VStack(alignment: .leading, spacing: 11.pt) {
                    value("Type", item.kind.isEmpty ? "Unavailable" : item.kind, id: "details-type")
                    value("Size", ItemMetadataFormatting.size(item.size, isDirectory: item.isDirectory,
                          isSymbolicLink: item.isSymbolicLink), id: "details-size")
                    value("File location", BrowsingPresentation.parentPath(item.url), id: "details-location")
                    value("Date modified", ItemMetadataFormatting.date(item.modifiedAt), id: "details-modified")
                }
                if let explanation = ItemMetadataFormatting.sizeExplanation(for: item) {
                    Text(explanation).font(.system(size: 10.pt)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DetailsPropertiesButton(store: store)
                    .frame(width: 112.pt, height: 30.pt)
            }
            .padding(22.pt)
        }
    }

    private func value(_ label: String, _ value: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 10.pt) {
            Text(label).foregroundStyle(.secondary).frame(width: 84.pt, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing).help(value)
        }
        .font(.system(size: 11.pt))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }
}

/// A real responder makes the Details pane reachable through the window's F6 cycle.
struct DetailsPropertiesButton: NSViewRepresentable {
    let store: ExplorerStore

    func makeNSView(context: Context) -> DetailsPanePropertiesButton {
        let button = DetailsPanePropertiesButton()
        button.title = "Properties"
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12.pt)
        button.target = button
        button.action = #selector(DetailsPanePropertiesButton.activate)
        button.toolTip = "Open read-only properties for the selected item"
        button.setAccessibilityLabel("Properties")
        button.setAccessibilityIdentifier("details-properties-button")
        return button
    }

    func updateNSView(_ button: DetailsPanePropertiesButton, context: Context) {
        if button.focus !== store.focus { button.focus?.unregister(.details, owner: button) }
        button.focus = store.focus
        button.isEnabled = store.canShowProperties
        button.onActivate = { [weak store] in store?.showProperties() }
        store.focus.register(.details, owner: button) { [weak button] in
            guard let button, button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { return false }
            return button.window?.makeFirstResponder(button) == true
        }
    }

    static func dismantleNSView(_ button: DetailsPanePropertiesButton, coordinator: ()) {
        if button.window?.firstResponder === button { _ = button.focus?.focus(.list) }
        button.focus?.unregister(.details, owner: button)
        button.onActivate = nil
        button.focus = nil
    }
}

final class DetailsPanePropertiesButton: NSButton {
    weak var focus: ExplorerFocusCoordinator?
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        let accepted = super.becomeFirstResponder()
        if accepted { focus?.focused(.details) }
        return accepted
    }

    @objc func activate() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [UInt16(36), 49, 76].contains(event.keyCode) { activate() }
        else { super.keyDown(with: event) }
    }
}

/// Shared presentation only. The MB/KB labels use binary divisors as observed in
/// EV-0313/0314 (4,194,304 bytes → 4.00 MB); exact bytes remain available in General.
enum ItemMetadataFormatting {
    static func size(_ bytes: Int64?, isDirectory: Bool = false, isSymbolicLink: Bool = false,
                     includeExactBytes: Bool = false) -> String {
        if isDirectory || isSymbolicLink { return "Not calculated" }
        guard let bytes, bytes >= 0 else { return "Unavailable" }
        let count = bytes.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        let exact = "\(count) \(bytes == 1 ? "byte" : "bytes")"
        guard bytes >= 1024 else { return exact }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = Double(bytes) / 1024
        var unit = 0
        while amount >= 1024, unit < units.count - 1 { amount /= 1024; unit += 1 }
        let scaled = amount.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
            + " " + units[unit]
        return includeExactBytes ? "\(scaled) (\(exact))" : scaled
    }

    static func date(_ date: Date?, includeTimeSeconds: Bool = false) -> String {
        guard let date else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.dateStyle = includeTimeSeconds ? .medium : .short
        formatter.timeStyle = includeTimeSeconds ? .medium : .short
        return formatter.string(from: date)
    }

    static func genericIcon(for item: FileItem) -> NSImage {
        if ExplorerIcons.showsCompressedFolder(item) { return ExplorerIcons.compressedFolder }
        if ExplorerIcons.showsFolder(item) { return ExplorerIcons.folder }
        let type: UTType
        if item.isSymbolicLink { type = .symbolicLink }
        else if item.isDirectory { type = .folder }
        else { type = UTType(filenameExtension: item.url.pathExtension) ?? .data }
        return NSWorkspace.shared.icon(for: type)
    }

    static func sizeExplanation(for item: FileItem) -> String? {
        if item.isSymbolicLink { return "Symbolic-link targets are not scanned for size." }
        if item.isDirectory { return "Folder contents are not scanned for size." }
        return nil
    }
}
