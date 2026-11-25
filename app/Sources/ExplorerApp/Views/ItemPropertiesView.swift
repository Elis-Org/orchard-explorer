import ExplorerCore
import SwiftUI

/// FR-PREVIEW-002 / AT-PREVIEW-002 / EV-0277 screenshot + EV-0278 UIA.
/// The native General panel is read-only; Windows attribute editing, application
/// association controls and other tabs are outside this implementation.
struct ItemPropertiesView: View {
    @ObservedObject var model: ItemPropertiesModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14.pt) {
            Text("General").font(.system(size: 13.pt, weight: .semibold))
                .accessibilityIdentifier("properties-general")
            ScrollView {
                VStack(alignment: .leading, spacing: 14.pt) {
                    if let item = model.item {
                        HStack(alignment: .top, spacing: 14.pt) {
                            Image(nsImage: ItemMetadataFormatting.genericIcon(for: item))
                                .resizable().scaledToFit().frame(width: 32.pt, height: 40.pt)
                                .accessibilityHidden(true)
                            Text(item.name).font(.system(size: 13.pt, weight: .medium))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("File name")
                                .accessibilityValue(item.name)
                                .accessibilityIdentifier("properties-name")
                        }
                        Divider()
                        row("Type", item.kind.isEmpty ? "Unavailable" : item.kind, id: "properties-type")
                        row("Location", item.url.deletingLastPathComponent().path, id: "properties-location")
                        row("Size", size(model.metadata?.size, item: item), id: "properties-size")
                        row("Size on disk", size(model.metadata?.allocatedSize, item: item), id: "properties-allocated-size")
                        if let explanation = ItemMetadataFormatting.sizeExplanation(for: item) {
                            Text(explanation).font(.system(size: 10.pt)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        row("Created", date(model.metadata?.createdAt), id: "properties-created")
                        row("Modified", date(model.metadata?.modifiedAt), id: "properties-modified")
                        row("Accessed", date(model.metadata?.accessedAt), id: "properties-accessed")
                    } else if let summary = model.groupSummary {
                        HStack(alignment: .top, spacing: 14.pt) {
                            Image(systemName: "doc.on.doc").font(.system(size: 26.pt)).foregroundStyle(.secondary)
                                .frame(width: 32.pt, height: 40.pt).accessibilityHidden(true)
                            Text(summary.count).font(.system(size: 13.pt, weight: .medium))
                                .accessibilityIdentifier("properties-name")
                        }
                        Divider()
                        row("Type", summary.type, id: "properties-type")
                        row("Location", summary.location, id: "properties-location")
                        row("Size", summary.size, id: "properties-size")
                        if let note = summary.note {
                            Text(note).font(.system(size: 10.pt)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !model.isLoading {
                        Text("No item is open in this window.").foregroundStyle(.secondary)
                    }

                    if model.isLoading {
                        HStack(spacing: 8.pt) {
                            ProgressView().controlSize(.small)
                            Text("Reading properties…").font(.system(size: 11.pt)).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("properties-loading")
                    }
                    if let error = model.errorMessage {
                        VStack(alignment: .leading, spacing: 8.pt) {
                            Label {
                                Text(error).textSelection(.enabled).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            .font(.system(size: 11.pt))
                            .fixedSize(horizontal: false, vertical: true)
                            if model.accessIssue != nil {
                                Button(scaled: "File Access Help…", action: model.showAccessHelp)
                                    .accessibilityIdentifier("properties-access-help")
                            }
                        }
                        .accessibilityIdentifier("properties-error")
                    }
                    if let metadata = model.metadata {
                        Text("Captured \(ItemMetadataFormatting.date(metadata.capturedAt, includeTimeSeconds: true)).")
                            .font(.system(size: 10.pt)).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("properties-captured-at")
                    }
                    Text("This window stays on the item you opened, even when the selection changes. Use Refresh to read its properties again.")
                        .font(.system(size: 10.pt)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("properties-snapshot-scope")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4.pt)
            }
            Divider()
            HStack {
                Button(scaled: "Refresh", action: model.refresh)
                    .disabled(model.isLoading || model.item == nil)
                    .accessibilityIdentifier("properties-refresh")
                Spacer()
                Button(scaled: "Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("properties-close")
            }
        }
        .padding(20.pt)
        // The panel's (screen-capped) minimum size governs; content scrolls (review 8ab56c03 #7).
        .frame(minWidth: 0, idealWidth: 420.pt, maxWidth: .infinity,
               minHeight: 0, idealHeight: 560.pt, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item properties")
        .accessibilityIdentifier("item-properties")
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 12.pt) {
            Text(label).foregroundStyle(.secondary).frame(width: 78.pt, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).help(value)
        }
        .font(.system(size: 12.pt))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func size(_ bytes: Int64?, item: FileItem) -> String {
        if model.isLoading && model.metadata == nil && !item.isDirectory && !item.isSymbolicLink { return "Loading…" }
        return ItemMetadataFormatting.size(bytes, isDirectory: item.isDirectory,
            isSymbolicLink: item.isSymbolicLink, includeExactBytes: true)
    }

    private func date(_ value: Date?) -> String {
        if model.isLoading && model.metadata == nil { return "Loading…" }
        return ItemMetadataFormatting.date(value, includeTimeSeconds: true)
    }
}
