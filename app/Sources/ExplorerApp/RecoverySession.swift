import ExplorerCore
import Foundation

/// Native batch state for FR-FILE-005 / EV-0448 / AT-FILE-005.
/// Cancel stops between system Trash calls; it never rolls back a completed call.
struct TrashProgress: Identifiable {
    let id = UUID()
    let totalItems: Int
    var completedItems = 0
    var currentName = ""
    var isCancelling = false
}

/// NATIVE-P18A: a running Compress to ▸ command (MAC-078).
struct ArchiveProgress: Identifiable {
    let id = UUID()
    let itemCount: Int
    let format: ArchiveFormat
    let firstName: String
    var isCancelling = false
}

/// One verified rename in this window, not a general filesystem undo stack.
/// FR-FILE-011 / EV-0240 / AT-FILE-011.
struct RenameRecovery {
    let context: FileOperationContext
    let originalName: String
    let renamedName: String
    var currentItem: FileItem
    var isUndone = false

    init?(context: FileOperationContext, original: FileItem, renamedName: String, result: FileOperationResult) {
        guard !original.name.utf8.elementsEqual(renamedName.utf8),
              let identity = result.identity, identity == original.identity else { return nil }
        self.context = context
        self.originalName = original.name
        self.renamedName = renamedName
        currentItem = Self.item(original, at: result.url, name: renamedName, identity: identity)
    }

    mutating func record(_ result: FileOperationResult, undone: Bool) -> Bool {
        guard let identity = result.identity, identity == currentItem.identity else { return false }
        currentItem = Self.item(currentItem, at: result.url,
                                name: undone ? originalName : renamedName, identity: identity)
        isUndone = undone
        return true
    }

    private static func item(_ item: FileItem, at url: URL, name: String, identity: LocalFileIdentity) -> FileItem {
        FileItem(url: url, name: name, isDirectory: item.isDirectory, isSymbolicLink: item.isSymbolicLink,
                 size: item.size, modifiedAt: item.modifiedAt, kind: item.kind, identity: identity)
    }
}
