import SwiftUI
import UniformTypeIdentifiers

struct ShortcutSheet: View {
    @ObservedObject var store: ExplorerStore
    let draft: ShortcutDraft
    @FocusState private var focusedField: Field?
    @StateObject private var picker = ShortcutPickerPresentation()

    private enum Field: Hashable { case target, name }

    var body: some View {
        let namesTarget = draft.target != nil
        VStack(alignment: .leading, spacing: 12.pt) {
            Text(namesTarget ? "Name the Shortcut" : "Create Shortcut")
                .font(.system(size: 15.pt, weight: .semibold))
            if namesTarget {
                Text("Enter a name for the shortcut.")
                TextField("Shortcut name", text: Binding(get: { draft.name }, set: {
                    store.updateShortcutName($0, draftID: draft.id)
                }))
                .accessibilityIdentifier("shortcut-name-field")
                .focused($focusedField, equals: .name)
                .disabled(draft.isWorking)
            } else {
                Text("Enter a local file or folder path, or browse for a target.")
                HStack {
                    TextField("Target path", text: Binding(get: { draft.targetText }, set: {
                        store.updateShortcutTarget($0, draftID: draft.id)
                    }))
                    .accessibilityIdentifier("shortcut-target-field")
                    .focused($focusedField, equals: .target)
                    Button(scaled: "Browse…") { picker.isPresented = true }
                        .accessibilityIdentifier("shortcut-browse")
                }
                .disabled(draft.isWorking)
            }
            if let error = draft.errorMessage {
                Text(error).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shortcut-error")
            }
            HStack {
                Button(scaled: "Cancel", action: store.cancelShortcutDraft)
                    .disabled(namesTarget && draft.isWorking)
                    .accessibilityIdentifier("shortcut-cancel")
                Spacer()
                if namesTarget {
                    Button(scaled: "Back", action: store.backShortcutDraft)
                        .disabled(draft.isWorking)
                        .accessibilityIdentifier("shortcut-back")
                    Button(scaled: "Finish", action: store.finishShortcutDraft)
                        .disabled(!draft.canFinish)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("shortcut-finish")
                } else {
                    Button(scaled: "Next", action: store.advanceShortcutDraft)
                        .disabled(!draft.canAdvance)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("shortcut-next")
                }
            }
        }
        .padding(24.pt)
        .frame(width: 460.pt)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(namesTarget ? "shortcut-name-sheet" : "shortcut-target-sheet")
        .onChange(of: namesTarget, initial: true) { _, namesTarget in
            focusedField = namesTarget ? .name : .target
        }
        .onExitCommand(perform: store.cancelShortcutDraft)
        .fileImporter(isPresented: $picker.isPresented, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result {
                store.updateShortcutTarget(url.path, draftID: draft.id)
            }
        }
    }
}

/// The Command Line Tools build uses a property-wrapper-backed presentation.
private final class ShortcutPickerPresentation: ObservableObject {
    @Published var isPresented = false
}
