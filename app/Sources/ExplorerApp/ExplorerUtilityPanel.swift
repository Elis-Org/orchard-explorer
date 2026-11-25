import AppKit

/// A key inspector must terminate file-action lookup before AppKit falls back
/// to the main browser window. Text responders earlier in this panel's chain
/// retain their native editing commands.
@MainActor
final class ExplorerUtilityPanel: NSPanel {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { true }

    @objc func copy(_ sender: Any?) {}
    @objc func cut(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}
    @objc func moveToTrash(_ sender: Any?) {}
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}
    override func selectAll(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)),
             #selector(moveToTrash(_:)), #selector(undo(_:)), #selector(redo(_:)),
             #selector(selectAll(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
