import Foundation

/// UI-SHELL-002 / EV-0372 / AT-UISHELL-002: sampled widths constrain outcomes,
/// but these breakpoints are explicit macOS choices, not measured Windows thresholds.
struct ExplorerLayout {
    enum CommandMode { case full, compact, minimal }
    let width: CGFloat
    /// MAC-074: breakpoints and widths are reference geometry at this scale.
    var scale: CGFloat = ExplorerScale.factor
    /// The width in reference-geometry units.
    private var unit: CGFloat { width / scale }
    var showsSidebar: Bool { unit >= 300 }
    var sidebarWidth: CGFloat { (unit >= 600 ? 312 : 239) * scale }
    var showsAddress: Bool { unit >= 300 }
    /// Full eligibility still requires the command bar content to fit.
    var commandMode: CommandMode { unit >= 700 ? .full : unit >= 300 ? .compact : .minimal }
    var navigationButtonWidth: CGFloat { min(48, max(40, unit / 4)) * scale }
    var detailsPaneWidth: CGFloat { 300 * scale }
    var canShowDetailsPane: Bool { unit >= 900 }
    /// Status text shortens and the search field moves into a popover below these widths.
    var showsFullSelectionStatus: Bool { unit >= 500 }
    var showsInlineSearch: Bool { unit >= 600 }
    var showsSecondViewButton: Bool { unit >= 300 }
}
