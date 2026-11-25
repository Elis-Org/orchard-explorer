import AppKit
import SwiftUI
import Testing
@testable import ExplorerApp

/// Component rendering only. Command-bar accessibility and actual appearance
/// are verified separately in the fixed preview/operation UI scenarios.
@Suite(.serialized)
@MainActor
struct ChromeAppearanceTests {
    @Test(arguments: [false, true], [false, true])
    func hostedButtonAndMenuDimTheirLabelExactlyOnce(menu: Bool, disabled: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(control(menu: menu, disabled: disabled)
            .frame(width: 100, height: 80).background(Color.white)))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 80)
        window.contentView = host
        defer { host.rootView = AnyView(EmptyView()); window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let actual = try blueContrast(in: host)

        // A standalone label supplies an independent compositing reference in
        // the same native color space. It does not use the application style.
        host.rootView = AnyView(sample.opacity(disabled ? 0.38 : 1)
            .frame(width: 100, height: 80).background(Color.white))
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let expected = try blueContrast(in: host)
        #expect(expected > 0.1, "The synthetic color patch must actually render")
        #expect(abs(actual - expected) < 0.035, "Disabled chrome must neither retain full color nor attenuate twice")
    }

    private var sample: some View {
        Rectangle().fill(Color(red: 0, green: 0, blue: 1)).frame(width: 24, height: 24)
    }

    @ViewBuilder
    private func control(menu: Bool, disabled: Bool) -> some View {
        if menu {
            Menu { Button("Synthetic item") {} } label: { sample }
                .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden)
                .disabled(disabled).accessibilityLabel("Chrome sample")
        } else {
            Button {} label: { sample }
                .buttonStyle(ChromeButtonStyle()).disabled(disabled).accessibilityLabel("Chrome sample")
        }
    }

    private func blueContrast(in view: NSView) throws -> CGFloat {
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var maximum: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                maximum = max(maximum, color.blueComponent - (color.redComponent + color.greenComponent) / 2)
            }
        }
        return maximum
    }
}
