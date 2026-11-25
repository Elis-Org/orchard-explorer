/// UI-VIEW-003 / FR-VIEW-001/008/010 / EV-0304–0337.
/// The numbers follow the captured Windows layout shortcut order. View choices
/// are session state; this type does not imply folder or process persistence.
public enum FolderViewMode: Int, CaseIterable, Sendable {
    case extraLargeIcons = 1
    case largeIcons
    case mediumIcons
    case smallIcons
    case list
    case details
    case tiles
    case content

    public var title: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }
}
