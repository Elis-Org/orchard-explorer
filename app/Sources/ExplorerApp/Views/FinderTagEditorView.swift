import SwiftUI

@MainActor
struct FinderTagEditorView: View {
    @ObservedObject var editor: FinderTagEditor
    let apply: () -> Void
    let cancel: () -> Void
    @FocusState private var searching: Bool
    @StateObject private var catalog = FinderTagCatalogState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10.pt) {
            Text("Tags").font(.system(size: 17.pt, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(editor.targets.count == 1 ? editor.targets[0].url.lastPathComponent : "\(editor.targets.count) items")
                .lineLimit(2).accessibilityIdentifier("finder-tag-target")
            TextField("Find or create a tag", text: $editor.query).textFieldStyle(.roundedBorder)
                .focused($searching).disabled(editor.isLoading || editor.submitted)
                .accessibilityIdentifier("finder-tag-search")
            if editor.isLoading {
                ProgressView("Reading Finder tags…")
            } else {
                let names = editor.names(including: catalog.optionNames())
                let shown = names.filter { editor.query.isEmpty || $0.localizedCaseInsensitiveContains(editor.query) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2.pt) {
                        ForEach(shown, id: \.self) { name in option(name) }
                        if !editor.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !names.contains(editor.query) {
                            Button("Create “\(editor.query)”") {
                                editor.toggle(editor.query)
                                editor.query = ""
                            }.accessibilityIdentifier("finder-tag-create")
                        }
                        if names.isEmpty && editor.query.isEmpty {
                            Text("Type a name to add a tag.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80.pt, idealHeight: 175.pt, maxHeight: 220.pt)
                .disabled(editor.submitted)
                if let message = catalog.availabilityMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            if editor.originChanged {
                Text("The selection changed. Close this editor and choose the items again.")
            }
            if !editor.failures.isEmpty || !editor.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4.pt) {
                        ForEach(editor.targets, id: \.url) { target in
                            if let issue = editor.failures[target.url] ?? editor.warnings[target.url] {
                                Text("\(target.url.path) — \(issue)").textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 76.pt).accessibilityIdentifier("finder-tag-issues")
            }
            HStack {
                if editor.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Saving tags… \(editor.completed) of \(editor.targets.count)")
                }
                Spacer()
                Button(editor.submitted ? "Close" : "Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction).disabled(editor.isApplying)
                    .accessibilityIdentifier("finder-tag-cancel")
                Button(editor.submitted && !editor.isApplying ? "Retry" : "Apply", action: apply)
                    .keyboardShortcut(.defaultAction).disabled(!editor.canApply)
                    .accessibilityIdentifier("finder-tag-apply")
            }
        }
        .padding(20.pt).frame(width: 400.pt)
        .accessibilityElement(children: .contain).accessibilityIdentifier("finder-tag-editor")
        .onAppear { searching = true }
        .task { await catalog.observeIndex() }
        .task(id: catalog.refreshRequest) { await catalog.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            catalog.refreshRequest = UUID()
        }
    }

    private func option(_ name: String) -> some View {
        let state = editor.state(for: name)
        let index = catalog.labelIndex(for: name)
        let symbol = switch state {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
        return Button { editor.toggle(name) } label: {
            HStack(spacing: 8.pt) {
                Image(systemName: symbol).accessibilityHidden(true)
                FinderTagMark(index: index)
                Text(name)
                Spacer()
            }
            .padding(.vertical, 3.pt).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name).accessibilityValue(state.rawValue)
        .help(FinderTagMark.description(for: index))
        .accessibilityIdentifier("finder-tag-option")
    }
}
