import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// MAC-ADDRESS-FUP-003. Hosted native geometry and dispatch, not desktop
/// keyboard replay or Windows fidelity. Every panel belongs to this fixture.
@Suite(.serialized)
@MainActor
final class AddressSuggestionPanelTests {
    enum Content: CaseIterable { case error, history, children }

    @Test(arguments: Content.allCases)
    func settledLongContentFitsOwnerScreenAndPopupViewport(_ content: Content) async throws {
        let fixture = try PopupFixture()
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        // Reconcile the completed listing before opening a children popup;
        // that first update deliberately invalidates an older child listing.
        fixture.view.synchronize()
        let screen = try #require(fixture.window.screen)
        #expect(fixture.window.makeFirstResponder(fixture.prior))
        switch content {
        case .error:
            let text = try fixture.beginEditing()
            let draft = fixture.root.appendingPathComponent("Missing directory").path + "/"
            text.insertText(draft, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
            try await waitUntil { !fixture.store.address.isLoading && fixture.store.address.errorMessage != nil }
        case .history:
            for url in fixture.children { fixture.store.address.recordSuccessfulSubmission(url) }
            try fixture.press("Recent addresses")
        case .children:
            try fixture.press("Subfolders of \(fixture.store.activeTab.url.lastPathComponent)")
            try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        }
        fixture.view.synchronize()
        let panel = try #require(fixture.view.suggestionPanel)
        try #require(panel.parent === fixture.window)
        let initialFrame = panel.frame
        let expectedWidth = min(max(260.pt, fixture.view.bounds.width),
                                fixture.window.frame.intersection(screen.visibleFrame).width)
        let responder = fixture.window.firstResponder
        let text = fixture.store.address.text
        let generation = fixture.store.address.requestID
        let statusFields = panel.contentView?.subviews.compactMap { $0 as? NSTextField } ?? []
        let status = try #require(statusFields.first)
        let statusText = status.stringValue
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.display()
        let owner = fixture.window.frame.intersection(screen.visibleFrame)
        print("ADDRESS_POPUP_GEOMETRY content=\(content) preferredWidth=\(max(260.pt, fixture.view.bounds.width)) expectedWidth=\(expectedWidth) initial=\(NSStringFromRect(initialFrame)) settled=\(NSStringFromRect(panel.frame)) statusIntrinsic=\(status.intrinsicContentSize.width) column=\(panel.table.tableColumns.first?.width ?? -1)")
        #expect(abs(panel.frame.width - expectedWidth) < 1)
        #expect(panel.frame.minX >= owner.minX && panel.frame.maxX <= owner.maxX)
        #expect(panel.frame.minY >= screen.visibleFrame.minY && panel.frame.maxY <= screen.visibleFrame.maxY)
        let contentView = try #require(panel.contentView)
        let statusFrame = contentView.convert(status.bounds, from: status)
        #expect(statusFrame.width > 0 && statusFrame.height > 0)
        #expect(contentView.bounds.contains(statusFrame))
        #expect(status.stringValue == statusText && status.accessibilityLabel() == statusText && status.toolTip == statusText)
        #expect(status.contentCompressionResistancePriority(for: .horizontal).rawValue < 500)
        let scroll = try #require(panel.table.enclosingScrollView)
        let scrollFrame = contentView.convert(scroll.bounds, from: scroll)
        #expect(contentView.bounds.contains(scrollFrame))
        #expect(panel.table.frame.width <= scroll.contentSize.width + 1)
        #expect((panel.table.tableColumns.first?.width ?? .infinity) <= scroll.contentSize.width + 1)
        for row in 0..<min(panel.table.numberOfRows, 2) {
            let cell = try #require(panel.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let label = try #require(cell.textField)
            #expect(label.contentCompressionResistancePriority(for: .horizontal).rawValue < 500)
            #expect(cell.bounds.contains(cell.convert(label.bounds, from: label)))
            let fullPath = BrowsingPresentation.path(fixture.store.address.suggestions[row])
            #expect(label.accessibilityLabel() == fullPath && label.toolTip == fullPath)
        }
        #expect(fixture.window.firstResponder === responder)
        #expect(fixture.store.address.text == text && fixture.store.address.requestID == generation)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(fixture.view.handlePopupCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(fixture.view.suggestionPanel == nil && panel.parent == nil)
    }

    @Test
    func placementUsesBelowAboveAndLargerAvailableSide() throws {
        let owner = NSRect(x: 100, y: 0, width: 500, height: 600)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let below = try #require(AddressSuggestionPanel.placementFrame(
            addressFrame: NSRect(x: 150, y: 400, width: 250, height: 30), preferredLeadingX: 150,
            ownerFrame: owner, visibleScreen: screen, preferredHeight: 100, scale: 1))
        #expect(below == NSRect(x: 150, y: 298, width: 260, height: 100))
        let above = try #require(AddressSuggestionPanel.placementFrame(
            addressFrame: NSRect(x: 150, y: 20, width: 250, height: 30), preferredLeadingX: 590,
            ownerFrame: owner, visibleScreen: screen, preferredHeight: 100, scale: 1))
        #expect(above == NSRect(x: 340, y: 52, width: 260, height: 100))
        let constrained = try #require(AddressSuggestionPanel.placementFrame(
            addressFrame: NSRect(x: 150, y: 50, width: 250, height: 20), preferredLeadingX: 150,
            ownerFrame: owner, visibleScreen: NSRect(x: 0, y: 0, width: 800, height: 200),
            preferredHeight: 238, scale: 1))
        #expect(constrained == NSRect(x: 150, y: 72, width: 260, height: 128))
    }

    @Test
    func placementHandlesNegativeOriginsOffscreenOwnersAndInsufficientChrome() throws {
        let screen = NSRect(x: -1000, y: -800, width: 1000, height: 800)
        let frame = try #require(AddressSuggestionPanel.placementFrame(
            addressFrame: NSRect(x: -1050, y: -250, width: 240, height: 30), preferredLeadingX: -1050,
            ownerFrame: NSRect(x: -1100, y: -500, width: 200, height: 300), visibleScreen: screen,
            preferredHeight: 100, scale: 1))
        #expect(frame == NSRect(x: -1000, y: -352, width: 100, height: 100))
        let bar = NSRect(x: 0, y: 20, width: 100, height: 20)
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        for owner in [NSRect(x: 0, y: 0, width: 19, height: 600), .null, .infinite,
                      NSRect(x: 900, y: 0, width: 200, height: 600),
                      NSRect(x: 0, y: 0, width: -200, height: 600)] {
            #expect(AddressSuggestionPanel.placementFrame(addressFrame: bar, preferredLeadingX: 0,
                ownerFrame: owner, visibleScreen: visible, preferredHeight: 100, scale: 1) == nil)
        }
        #expect(AddressSuggestionPanel.placementFrame(addressFrame: bar, preferredLeadingX: 0,
            ownerFrame: visible, visibleScreen: NSRect(x: 0, y: 0, width: 800, height: 60),
            preferredHeight: 100, scale: 1) == nil)
    }

    @Test
    func noFitPopupCannotHighlightOrActivateInvisibleCompletionAndEscapeCancels() async throws {
        let fixture = try PopupFixture()
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + "/Long"
        text.insertText(draft, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        // A real borderless owner can be narrower than the existing content
        // chrome. Do not substitute a fake NSScreen or override native focus.
        fixture.window.setContentSize(NSSize(width: 10.pt, height: 500))
        let screen = try #require(fixture.window.screen)
        try #require(fixture.window.frame.intersection(screen.visibleFrame).width < 20.pt)
        fixture.view.synchronize()
        let generation = fixture.store.address.requestID
        let suggestions = fixture.store.address.suggestions
        let history = fixture.store.activeTab.history
        let selectedRange = text.selectedRange()
        #expect(fixture.view.suggestionPanel == nil)
        #expect(fixture.window.childWindows?.isEmpty ?? true)
        #expect(fixture.store.address.isEditing && fixture.store.address.text == draft)
        #expect(fixture.window.firstResponder === text && fixture.view.editor.currentEditor() === text)
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.insertTab(_:))] {
            _ = fixture.view.control(fixture.view.editor, textView: text, doCommandBy: selector)
            #expect(fixture.store.address.highlightedIndex == nil)
            #expect(fixture.store.address.requestID == generation && fixture.store.address.suggestions == suggestions)
            #expect(fixture.store.address.text == draft && fixture.store.address.isEditing)
            #expect(fixture.store.activeTab.url == fixture.root && fixture.store.activeTab.history == history)
            #expect(fixture.window.firstResponder === text && text.selectedRange() == selectedRange)
            #expect(fixture.view.suggestionPanel == nil)
        }
        #expect(fixture.view.control(fixture.view.editor, textView: text,
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!fixture.store.address.isEditing && fixture.store.address.presentation == nil)
        #expect(fixture.view.suggestionPanel == nil)
    }

    // ND-ADDR-01 and M4. A highlight from an earlier visible layout
    // cannot turn the typed draft into a folder selection after resize.
    @Test
    func returnInNoFitLayoutSubmitsLiteralDraftInsteadOfHiddenHighlight() async throws {
        let fixture = try PopupFixture()
        defer { fixture.close() }
        try await waitUntil { !fixture.store.activeTab.isLoading }
        let text = try fixture.beginEditing()
        let draft = fixture.root.path + "/"
        text.insertText(draft, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        try await waitUntil { !fixture.store.address.isLoading && !fixture.store.address.suggestions.isEmpty }
        fixture.view.synchronize()
        try #require(fixture.view.suggestionPanel != nil)
        #expect(fixture.view.control(fixture.view.editor, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:))))
        try #require(fixture.store.address.highlightedIndex == 0)
        fixture.window.setContentSize(NSSize(width: 10.pt, height: 500))
        fixture.view.synchronize()
        try #require(fixture.view.suggestionPanel == nil)
        #expect(fixture.view.control(fixture.view.editor, textView: text, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(fixture.store.address.text == draft)
        #expect(fixture.view.control(fixture.view.editor, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!fixture.store.address.isEditing)
        try await waitUntil { !fixture.store.address.recentAddresses.isEmpty }
        #expect(fixture.store.activeTab.url == fixture.root)
        #expect(fixture.store.address.recentAddresses == [fixture.root])
    }

    enum PendingCompletion: CaseIterable { case debounce, providerLoading }

    @Test(arguments: PendingCompletion.allCases)
    func returnDuringPendingCompletionOpensTheTypedDocument(_ phase: PendingCompletion) async throws {
        let suggester = PopupPendingSuggester()
        let fixture = try PopupFixture(addressSuggester: suggester)
        defer { fixture.close() }
        let router = ZIPAppRouter()
        fixture.store.applications = router
        let document = fixture.root.appendingPathComponent("Synthetic Document.txt")
        try Data("Benign test document".utf8).write(to: document)
        try await waitUntil { !fixture.store.activeTab.isLoading }
        let history = fixture.store.activeTab.history
        let text = try fixture.beginEditing()
        // For debounce, keep insertion and Return in the same main-actor turn.
        // For loading, observe provider entry and hold its result past Return.
        text.insertText(document.path, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        if phase == .providerLoading {
            let deadline = Date().addingTimeInterval(3)
            while !(await suggester.started), Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(await suggester.started)
        }
        try #require(fixture.store.address.isLoading && fixture.store.address.suggestions.isEmpty)
        #expect(fixture.view.control(fixture.view.editor, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitUntil { router.opened.count == 1 }
        #expect(router.opened.map(\.path) == [document.path])
        #expect(fixture.store.activeTab.url == fixture.root && fixture.store.activeTab.history == history)
        #expect(!fixture.store.address.isEditing)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

private actor PopupPendingSuggester: FolderSuggesting {
    private(set) var started = false

    func folders(in directory: URL, prefix: String, showHidden: Bool) async throws -> FolderSuggestions {
        started = true
        try await Task.sleep(for: .seconds(30))
        return FolderSuggestions(urls: [], isTruncated: false)
    }
}

@MainActor
private final class PopupFixture {
    let root: URL
    let children: [URL]
    let store: ExplorerStore
    let window: NSWindow
    let view: NativeAddressBar
    let prior = PopupFocusView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
    let pasteboard: NSPasteboard

    init(addressSuggester: (any FolderSuggesting)? = nil) throws {
        _ = NSApplication.shared
        let ownedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-popup-\(UUID().uuidString)", isDirectory: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: ownedRoot) } }
        root = ownedRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let name = "Long " + String(repeating: "café 日本語 ", count: 8)
        children = [root.appendingPathComponent(name + "One", isDirectory: true),
                    root.appendingPathComponent(name + "Two", isDirectory: true)]
        for child in children { try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false) }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("popup-ui-tests-\(UUID().uuidString)"))
        store = ExplorerStore(tab: BrowserTab(url: root), homeURL: root,
                              clipboard: TransferClipboard(pasteboard: pasteboard), addressSuggester: addressSuggester)
        window = NSWindow(contentRect: NSRect(x: 30, y: 60, width: 640, height: 500),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        view = NativeAddressBar(store: store)
        defer {
            if !completed {
                view.tearDown(); store.cancelLoads(); window.close(); pasteboard.releaseGlobally()
            }
        }
        view.frame = NSRect(x: 300, y: 450, width: 264, height: 32)
        window.contentView?.addSubview(prior)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        let screen = try #require(window.screen)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 60))
        view.layoutSubtreeIfNeeded()
        completed = true
    }

    func press(_ label: String) throws {
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(view).compactMap { $0 as? AddressActionButton }
        let button = try #require(buttons.first { $0.accessibilityLabel() == label })
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    }

    func beginEditing() throws -> NSTextView {
        #expect(window.makeFirstResponder(prior))
        store.requestAddressEditing()
        view.synchronize()
        return try #require(view.editor.currentEditor() as? NSTextView)
    }

    func close() {
        view.tearDown()
        store.cancelLoads()
        window.close()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PopupFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
