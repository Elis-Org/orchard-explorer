import AppKit
import SwiftUI
import ExplorerCore
import UniformTypeIdentifiers

/// G3 / MAC-074: one interface scale for every point size, font size, icon size
/// and layout breakpoint. 1.0 reproduces the geometry used since Phase 1
/// (reference raster pixels of the 150%-profile Windows VM taken as points);
/// 1.5 matches that VM as Parallels shows it on a 3840-point-wide display, where
/// each VM pixel spans 1.5 points. Hairline dividers stay one point.
enum ExplorerScale {
    static let presets: [CGFloat] = [1, 1.25, 1.5, 1.75, 2]
    static let defaultsKey = "nativeExplorer.interfaceScale"
    static let defaultFactor: CGFloat = 1.5

    /// Set at launch and when the user picks a preset; read when views are built.
    /// Tests that construct views directly see the reference geometry (1.0).
    nonisolated(unsafe) static var factor: CGFloat = 1

    static func stored(in defaults: UserDefaults) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultFactor }
        let value = CGFloat(defaults.double(forKey: defaultsKey))
        return presets.contains(value) ? value : defaultFactor
    }

    /// Native controls (buttons, pop-ups, fields) grow with the text they hold.
    static var controlSize: ControlSize { factor >= 1.5 ? .extraLarge : factor >= 1.25 ? .large : .regular }

    /// A content size at the interface scale, kept within the screen (MAC-074).
    static func fittingContentSize(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        fittingContentSize(size, visible: (screen ?? NSScreen.main)?.visibleFrame.size)
    }

    /// Leaves room for the panel's title bar; panels scroll their own content.
    static func fittingContentSize(_ size: NSSize, visible: NSSize?) -> NSSize {
        guard let visible else { return size }
        return NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height - 40))
    }

    static func title(for factor: CGFloat) -> String { "\(Int((factor * 100).rounded()))%" }
}

extension BinaryInteger {
    /// A reference-geometry point value at the current interface scale.
    var pt: CGFloat { CGFloat(self) * ExplorerScale.factor }
}

extension Double {
    var pt: CGFloat { CGFloat(self) * ExplorerScale.factor }
}

extension CGFloat {
    var pt: CGFloat { self * ExplorerScale.factor }
}

extension Button where Label == Text {
    /// A titled button whose title follows the interface scale; native push
    /// buttons otherwise keep the control font of their control size (MAC-074).
    init(scaled title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title).font(.system(size: 12.pt)) }
    }
}
