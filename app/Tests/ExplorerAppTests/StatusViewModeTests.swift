import AppKit
import SwiftUI
import Testing
@testable import ExplorerApp
import ExplorerCore

private actor StatusModeDriver: DirectoryListing, FileRecovering {
    private(set) var reads = 0
    private(set) var trashCalls = 0
    private var pendingTrash: CheckedContinuation<TrashResult, Error>?
    private var closed = false

    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard !closed else { throw CancellationError() }
        reads += 1
        let identity = LocalFileIdentity(device: 1, inode: 100, birthSeconds: 1, birthNanoseconds: 0)
        let item = FileItem(url: url.appendingPathComponent("sample.txt"), name: "sample.txt",
            isDirectory: false, isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text Document",
            identity: LocalFileIdentity(device: 1, inode: 101, birthSeconds: 1, birthNanoseconds: 0))
        return DirectorySnapshot(items: [item], directoryIdentity: identity)
    }
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pendingTrash = $0; trashCalls += 1 }
    }
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("This fixture never restores an item.")
    }
    func releaseTrash() {
        let call = pendingTrash; pendingTrash = nil
        call?.resume(throwing: CancellationError())
    }
    func shutdown() { closed = true; releaseTrash() }
}

@MainActor
private final class StatusContentFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class StatusModeFixture {
    let driver = StatusModeDriver()
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerStatusViewModeTests-\(UUID())"))
    let store: ExplorerStore
    let window: NSWindow
    let content: StatusContentFocusView
    let host: NSHostingView<AnyView>

    init() {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/explorer-status-view-mode-model", isDirectory: true)
        store = ExplorerStore(initialURL: root, loader: driver, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board), recovery: driver)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content = StatusContentFocusView(frame: NSRect(x: 20, y: 80, width: 260, height: 100))
        let currentStore = store
        host = NSHostingView(rootView: AnyView(HStack(spacing: 0) {
            StatusViewButton(store: currentStore, mode: .details, registersFocusStop: true)
                .frame(width: 28, height: 26)
            StatusViewButton(store: currentStore, mode: .largeIcons, registersFocusStop: false)
                .frame(width: 28, height: 26)
        }))
        host.frame = NSRect(x: 20, y: 20, width: 80, height: 30)
        window.contentView?.addSubview(content)
        window.contentView?.addSubview(host)
        let list = content
        store.focus.register(.list, owner: list) { [weak list] in
            guard let list else { return false }
            return list.window?.makeFirstResponder(list) == true
        }
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.makeFirstResponder(nil)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        store.focus.unregister(.list, owner: content)
        store.cancelLoads(); store.cancelTrash()
        Task { await driver.shutdown() }
        board.releaseGlobally()
        window.close()
    }
}

/// Native status-control coverage for FR-VIEW-001/008/010 and FR-SEL-005.
/// EV-0304–0337 and EV-0440 provide layout/visible focus context; this suite
/// tests AppKit controls and handoff policy, not screenshot or Windows AX parity.
@Suite(.serialized)
@MainActor
final class StatusViewModeTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Status view buttons did not settle before the bounded deadline")
    }
    private func button(_ identifier: String, in view: NSView) -> DetailsStatusButton? {
        if let candidate = view as? DetailsStatusButton,
           candidate.accessibilityIdentifier() == identifier { return candidate }
        return view.subviews.lazy.compactMap { self.button(identifier, in: $0) }.first
    }
    private func makeFixture() async throws -> (StatusModeFixture, DetailsStatusButton, DetailsStatusButton) {
        let fixture = StatusModeFixture()
        try await waitUntil {
            !fixture.store.activeTab.isLoading
                && self.button("details-view-button", in: fixture.host) != nil
                && self.button("large-icons-view-button", in: fixture.host) != nil
        }
        let selected = try #require(fixture.store.activeTab.items.first)
        fixture.store.setSelection([selected.id], focusedID: selected.id, anchorID: selected.id)
        return (fixture, try #require(button("details-view-button", in: fixture.host)),
                try #require(button("large-icons-view-button", in: fixture.host)))
    }
    private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        let characters = code == 49 ? " " : "\r"
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test
    func mountedButtonsReflectTheStoreModeAndExposeItsSelectedState() async throws {
        let (fixture, details, large) = try await makeFixture()
        defer { fixture.close() }
        try await waitUntil { details.state == .on && large.state == .off }
        #expect(details.accessibilityLabel() == "Details view, selected")
        #expect(large.accessibilityLabel() == "Large icons view")
        fixture.store.setViewMode(.largeIcons)
        try await waitUntil { details.state == .off && large.state == .on }
        #expect(large.accessibilityLabel() == "Large icons view, selected")
        fixture.store.setViewMode(.tiles)
        try await waitUntil { details.state == .off && large.state == .off }
        #expect(details.isEnabled && large.isEnabled)
        #expect(details.accessibilityLabel() == "Details view")
        #expect(large.accessibilityLabel() == "Large icons view")
        #expect(await fixture.driver.reads == 1)
    }

    @Test
    func clickingAndKeyboardActivationSelectModesWithoutChangingTheFileSelection() async throws {
        let (fixture, details, large) = try await makeFixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection, history = fixture.store.activeTab.history
        large.performClick(nil)
        try await waitUntil { fixture.store.activeTab.viewMode == .largeIcons && large.state == .on && details.state == .off }
        #expect(fixture.window.firstResponder === large)
        details.keyDown(with: try key(36, in: fixture.window))
        try await waitUntil { fixture.store.activeTab.viewMode == .details && details.state == .on }
        large.keyDown(with: try key(49, in: fixture.window))
        try await waitUntil { fixture.store.activeTab.viewMode == .largeIcons && large.state == .on }
        #expect(fixture.store.activeTab.selection == selection && fixture.store.activeTab.history == history)
        #expect(await fixture.driver.reads == 1)
    }

    @Test
    func clickingTheAlreadySelectedModeDoesNotLeaveItsToggleOff() async throws {
        let (fixture, details, large) = try await makeFixture()
        defer { fixture.close() }
        try await waitUntil { details.state == .on }
        details.performClick(nil)
        try await waitUntil { details.state == .on }
        #expect(fixture.store.activeTab.viewMode == .details)
        large.performClick(nil)
        try await waitUntil { fixture.store.activeTab.viewMode == .largeIcons && large.state == .on }
        large.performClick(nil)
        try await waitUntil { large.state == .on }
        #expect(fixture.store.activeTab.viewMode == .largeIcons)
        #expect(await fixture.driver.reads == 1)
    }

    @Test(arguments: ["draft", "mutation"])
    func disabledButtonsCannotActivateOrStealFocusDuringProtectedWork(_ state: String) async throws {
        let (fixture, details, large) = try await makeFixture()
        defer { fixture.close() }
        let store = fixture.store
        if state == "draft" {
            store.beginRename()
            let draft = try #require(store.nameEdit)
            store.updateProposedName("unfinished.txt", sessionID: draft.id)
        } else {
            store.trashSelection()
            try await waitUntil { await fixture.driver.trashCalls == 1 }
            #expect(store.nameEdit == nil && store.isPerformingOperation)
        }
        try await waitUntil { !details.isEnabled && !large.isEnabled }
        #expect(fixture.window.makeFirstResponder(fixture.content))
        let selection = store.activeTab.selection
        #expect(!store.focus.focus(.status))
        large.performClick(nil)
        large.keyDown(with: try key(36, in: fixture.window))
        large.activate()
        details.keyDown(with: try key(49, in: fixture.window))
        #expect(store.activeTab.viewMode == .details && details.state == .on && large.state == .off)
        #expect(fixture.window.firstResponder === fixture.content)
        #expect(store.activeTab.selection == selection)
        #expect(await fixture.driver.reads == 1)
        if state == "draft" {
            #expect(store.nameEdit?.proposedName == "unfinished.txt")
            store.cancelNameEdit()
        } else {
            #expect(store.isPerformingOperation && store.trashProgress?.isCancelling == false)
            await fixture.driver.releaseTrash()
            try await waitUntil { !store.isPerformingOperation }
        }
        try await waitUntil { details.isEnabled && large.isEnabled }
        large.performClick(nil)
        try await waitUntil { store.activeTab.viewMode == .largeIcons && large.state == .on }
    }

    @Test
    func statusActivationKeepsItsFocusWhenContentIsReplaced() async throws {
        let (fixture, _, large) = try await makeFixture()
        defer { fixture.close() }
        #expect(fixture.store.focus.focus(.list))
        #expect(fixture.window.firstResponder === fixture.content)
        large.performClick(nil)
        try await waitUntil { fixture.store.activeTab.viewMode == .largeIcons && large.state == .on }
        #expect(fixture.window.firstResponder === large && fixture.store.focus.currentRegion == .status)
        let replacement = StatusContentFocusView(frame: fixture.content.frame)
        fixture.content.removeFromSuperview()
        fixture.window.contentView?.addSubview(replacement)
        fixture.store.focus.register(.list, owner: replacement) { [weak replacement] in
            guard let replacement else { return false }
            return replacement.window?.makeFirstResponder(replacement) == true
        }
        defer { fixture.store.focus.unregister(.list, owner: replacement) }
        // This is the same attachment callback used by the native content adapters.
        fixture.store.focus.restorePendingContentFocus(owner: replacement)
        #expect(fixture.window.firstResponder === large && fixture.store.focus.currentRegion == .status)
        #expect(fixture.store.activeTab.selection.selectedIDs.count == 1)
    }
}
