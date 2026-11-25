import AppKit
import Testing
@testable import ExplorerApp

/// MAC-045/046: utility panels isolate file commands from the main browser.
/// Native boundary/first-responder resolution only; the CLI test host has no
/// application key/main windows. Actual targetless menu routing is desktop-tested.
/// No filesystem or system clipboard writes.
@Suite(.serialized)
@MainActor
final class UtilityPanelResponderTests {
    private let actions = ["copy:", "cut:", "paste:", "moveToTrash:", "selectAll:", "undo:", "redo:"]

    @Test(arguments: [false, true])
    func bothInspectorsTerminateFileActionsAtPanelBoundary(fileAccess: Bool) throws {
        _ = NSApplication.shared
        let controller: NSWindowController = fileAccess ? FileAccessWindowController() : ItemPropertiesWindowController()
        let panel = try #require(controller.window as? ExplorerUtilityPanel)
        defer { controller.close() }
        #expect(!panel.canBecomeMain)
        #expect(panel.canBecomeKey)
        for name in actions {
            let selector = NSSelectorFromString(name)
            let menu = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            let target = NSApp.target(forAction: selector, to: panel, from: menu) as AnyObject?
            #expect(target === panel, "\(name) must have a handler at the utility panel boundary")
            #expect(!panel.validateUserInterfaceItem(menu))
            #expect(panel.tryToPerform(selector, with: menu))
        }
    }

    @Test
    func nativeTextEditorStillOwnsEditingCommandsBeforePanel() throws {
        _ = NSApplication.shared
        let panel = ExplorerUtilityPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.string = "Disposable metadata text"
        text.isEditable = false
        text.isSelectable = true
        text.setSelectedRange(NSRange(location: 0, length: 10))
        panel.contentView = text
        defer { panel.close() }
        #expect(panel.makeFirstResponder(text))
        for name in ["copy:", "selectAll:"] {
            let target = NSApp.target(forAction: NSSelectorFromString(name), to: panel.firstResponder, from: nil) as AnyObject?
            #expect(target === text)
        }
        // Resolve Copy without performing it: the user's pasteboard is untouched.
        #expect(text.tryToPerform(#selector(NSTextView.selectAll(_:)), with: nil))
        #expect(text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count))
    }
}
