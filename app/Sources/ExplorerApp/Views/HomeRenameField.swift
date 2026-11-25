import AppKit
import SwiftUI

/// Home rows may belong to more than one group. Both occurrences edit the
/// same physical file using one window-owned draft and the standard name field.
@MainActor
struct HomeRenameField: NSViewRepresentable {
    let store: ExplorerStore
    let edit: NameEditSession

    func makeNSView(context: Context) -> NameEditorTextField { NameEditorTextField() }

    func updateNSView(_ field: NameEditorTextField, context: Context) {
        let id = edit.id
        field.onProposalChange = { store.updateProposedName($0, sessionID: id) }
        field.onCommit = { store.commitNameEdit(sessionID: id) }
        field.onCancel = { store.cancelNameEdit(sessionID: id) }
        if field.sessionID != id {
            DispatchQueue.main.async { [weak field] in
                guard let field, store.nameEdit?.id == id else { return }
                field.beginSession(id: id, name: edit.proposedName, selection: edit.initialSelection)
                field.setAccessibilityIdentifier("home-rename-name")
                field.setAccessibilityLabel(edit.originalName)
            }
        } else { field.updateSession(proposedName: edit.proposedName, isSubmitting: edit.isSubmitting) }
    }
}
