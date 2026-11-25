import AppKit
import Testing
@testable import ExplorerApp

@Suite @MainActor struct ApplicationRoutingTests {
    @Test func discoversDefaultTextEditTerminalAndIconsWithoutLaunching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerRouting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let router = LocalApplicationRouter()
        let choices = router.applications(toOpen: file)
        #expect(!choices.isEmpty)
        #expect(choices.filter(\.isDefault).count == 1)
        #expect(choices.first?.isDefault == true)
        #expect(Set(choices.map(\.url)).count == choices.count)
        #expect(choices.contains { Bundle(url: $0.url)?.bundleIdentifier == "com.apple.TextEdit" })
        let terminal = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal"))
        let icon = router.icon(forApplicationAt: terminal)
        #expect(icon.size.width > 0 && icon.size.height > 0)
        #expect(!icon.representations.isEmpty)
    }
}
