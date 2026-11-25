import AppKit

/// MAC-079 (amends MAC-036) — FR-FILE-005 / EV-0444–0448 / AT-FILE-005.
///
/// When a file list is the key handler, Delete (⌫), Forward Delete (⌦, fn-⌫) and
/// Command-Delete move the selection to the Trash, as Windows Delete recycles it.
/// Shift+Delete — Windows' permanent delete (FR-FILE-006/021) — never deletes
/// anything here; it explains that only the Trash is available (permanent deletion
/// stays in roadmap Phase 29). An auto-repeated key is consumed and ignored, so a
/// held key cannot trash a later selection. Text fields (rename editor, address
/// bar, search) handle their own keys and never reach this routing.
enum FileListDeleteKey: Equatable {
    case trash
    case permanentUnavailable
    case ignoredRepeat

    /// nil when the event is not a file-list delete key (other keys, or modifier
    /// combinations such as Option-Delete that keep their previous behavior).
    init?(_ event: NSEvent) {
        guard event.type == .keyDown, event.keyCode == 51 || event.keyCode == 117 else { return nil }
        let intent: FileListDeleteKey
        switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
        case [], [.command]: intent = .trash
        case [.shift]: intent = .permanentUnavailable
        default: return nil
        }
        self = event.isARepeat ? .ignoredRepeat : intent
    }

    /// The repeat guarantee also covers the menu route: ⌘⌫ is a main-menu key
    /// equivalent and reaches `moveToTrash:` before the list's `keyDown`. A Trash
    /// action whose triggering event is an auto-repeated key-down is ignored
    /// (review a6fd3c08 finding 1). Mouse-chosen menu items are unaffected.
    static func isAutoRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}
