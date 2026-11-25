import AppKit

/// Shared by the AppKit address bar and SwiftUI search field. The dark lift is
/// a native adaptation; the Windows reference currently measures light colors.
enum NavigationFieldSurface {
    static let color = NSColor(name: "ExplorerNavigationField") { appearance in
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
            return .controlBackgroundColor
        }

        var surface = NSColor.controlBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            surface = (NSColor.controlBackgroundColor.blended(
                withFraction: 0.08, of: .labelColor
            ) ?? .controlBackgroundColor).withAlphaComponent(1)
        }
        return surface
    }
}
