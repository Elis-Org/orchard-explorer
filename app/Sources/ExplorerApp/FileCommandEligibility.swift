/// File-list commands require the list's current native focus as well as the
/// command's own current capability. Text-editor routing stays in AppKit views.
struct FileCommandEligibility {
    enum Command { case copy, cut, paste, delete, undo, redo }

    let ownsFileFocus: Bool
    var copy = false
    var cut = false
    var paste = false
    var delete = false
    var undo = false
    var redo = false

    func allows(_ command: Command) -> Bool {
        guard ownsFileFocus else { return false }
        switch command {
        case .copy: return copy
        case .cut: return cut
        case .paste: return paste
        case .delete: return delete
        case .undo: return undo
        case .redo: return redo
        }
    }
}
