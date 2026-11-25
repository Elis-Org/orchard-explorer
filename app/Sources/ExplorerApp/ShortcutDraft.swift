import ExplorerCore
import Foundation

/// ND-NEW-05: the store owns the two-step draft and its original destination.
struct ShortcutDraft: Identifiable {
    let id = UUID()
    let tabID: UUID
    let destination: FileOperationContext
    var targetText = ""
    var target: ShortcutTarget?
    var name = ""
    var errorMessage: String?
    var isWorking = false

    var canAdvance: Bool {
        !isWorking && !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFinish: Bool { !isWorking && target != nil && !name.isEmpty }
}
