import ExplorerCore
import Foundation

/// A window-local draft. No filesystem mutation occurs until explicit submission.
/// What a creation draft makes when committed (MAC-025; NATIVE-P18A adds files).
enum NewItemKind: Equatable {
    case folder
    case file(NewFileTemplate)

    var defaultName: String {
        switch self {
        case .folder: "New folder"
        case .file(let template): template.defaultName
        }
    }

    var placeholderKind: String {
        switch self {
        case .folder: "File folder"
        case .file(.bitmapImage): "Bitmap image"
        case .file(.textDocument): "Plain Text Document"
        case .file(.zipArchive): "ZIP archive"
        }
    }

    private var itemDescription: String {
        switch self {
        case .folder: "folder"
        case .file(.bitmapImage): "bitmap image"
        case .file(.textDocument): "text document"
        case .file(.zipArchive): "compressed folder"
        }
    }

    var statusName: String { "New \(itemDescription)" }
    var operationName: String { "Create \(itemDescription)" }
    var accessibilityName: String { "\(statusName) name" }
}

struct NameEditSession: Identifiable {
    let id: UUID
    let tabID: UUID
    let context: ItemOperationContext
    let item: FileItem?
    let rowID: String
    let originalName: String
    let initialSelection: NSRange
    var proposedName: String
    var errorMessage: String?
    var accessIssue: FileAccessContext?
    var isSubmitting = false
    /// Set for creation drafts (`item == nil`).
    let newItemKind: NewItemKind?
    let homeOrigin: HomeOperationOrigin?

    var directoryURL: URL { context.directoryURL }
    /// A creation draft of any kind (historical name: folders came first).
    var isNewFolder: Bool { item == nil }

    init(tabID: UUID, context: FileOperationContext, item: FileItem?, name: String,
         newItemKind: NewItemKind? = nil, homeOrigin: HomeOperationOrigin? = nil) {
        self.init(tabID: tabID, context: .filesystem(context), item: item, name: name,
                  newItemKind: newItemKind, homeOrigin: homeOrigin)
    }

    init(tabID: UUID, context: ItemOperationContext, item: FileItem?, name: String,
         newItemKind: NewItemKind? = nil, homeOrigin: HomeOperationOrigin? = nil) {
        let id = UUID()
        self.id = id
        self.tabID = tabID
        self.context = context
        self.homeOrigin = homeOrigin
        self.item = item
        self.newItemKind = item == nil ? (newItemKind ?? .folder) : nil
        self.originalName = name
        self.proposedName = name
        self.rowID = item?.id ?? context.directoryURL
            .appendingPathComponent(".explorer-draft-" + id.uuidString, isDirectory: true).absoluteString
        let text = name as NSString
        let dot = text.range(of: ".", options: .backwards)
        let isFile = item.map { !$0.isDirectory && !$0.isSymbolicLink }
            ?? (newItemKind.map { $0 != .folder } ?? false)
        let basenameOnly = isFile && !name.hasPrefix(".") && dot.location != NSNotFound && dot.location > 0
        initialSelection = NSRange(location: 0, length: basenameOnly ? dot.location : text.length)
    }

    var placeholder: FileItem? {
        guard isNewFolder, let url = URL(string: rowID) else { return nil }
        let kind = newItemKind ?? .folder
        return FileItem(url: url, name: originalName, isDirectory: kind == .folder, isSymbolicLink: false,
                        size: kind == .folder ? nil : 0, modifiedAt: nil, kind: kind.placeholderKind)
    }
}
