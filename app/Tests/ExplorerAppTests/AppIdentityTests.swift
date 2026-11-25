import AppKit
import Foundation
import Testing
@testable import ExplorerApp

/// MAC-080/081: the bundle presents Maxplorer with its own icon, while the bundle
/// identifier stays unchanged so existing preferences and pins carry over.
@Suite struct AppIdentityTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    @Test func infoPlistPresentsMaxplorerAndKeepsTheBundleIdentifier() throws {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == AppIdentity.name)
        #expect(plist["CFBundleDisplayName"] as? String == AppIdentity.name)
        #expect(plist["CFBundleExecutable"] as? String == "Maxplorer")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["CFBundleIdentifier"] as? String == "dev.native-explorer.app", "unchanged: preferences and pins carry over")
    }

    @Test func iconContainsEveryMacSize() throws {
        let url = Self.resources.appendingPathComponent("AppIcon.icns")
        let image = try #require(NSImage(contentsOf: url))
        let pixels = Set(image.representations.map(\.pixelsWide))
        for size in [16, 32, 64, 128, 256, 512, 1024] { #expect(pixels.contains(size), "\(size) px representation") }
    }
}
