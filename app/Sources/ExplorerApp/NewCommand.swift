import ExplorerCore

/// ND-NEW-01: one ordered catalog for all New surfaces.
enum NewCommand: String, CaseIterable {
    case folder, shortcut, bitmapImage, textDocument, zipArchive

    var title: String {
        switch self {
        case .folder: "Folder"
        case .shortcut: "Shortcut"
        case .bitmapImage: "Bitmap image"
        case .textDocument: "Text Document"
        case .zipArchive: "Compressed (zipped) Folder"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .shortcut: "arrow.up.right.square"
        case .bitmapImage: "photo"
        case .textDocument: "doc.text"
        case .zipArchive: "archivebox"
        }
    }

    var inlineKind: NewItemKind? {
        switch self {
        case .folder: .folder
        case .shortcut: nil
        case .bitmapImage: .file(.bitmapImage)
        case .textDocument: .file(.textDocument)
        case .zipArchive: .file(.zipArchive)
        }
    }
}
