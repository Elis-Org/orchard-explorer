import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

/// FR-PREVIEW-002/003 / EV-0277/0278, EV-0313/0314 / AT-PREVIEW-002/003.
/// Native presentation/focus assertions; no filesystem reads or writes.
@Suite(.serialized)
@MainActor
final class ItemMetadataPresentationTests {
    @Test
    func binarySizeLabelsMatchReferenceAndGeneralIncludesExactBytes() {
        #expect(ItemMetadataFormatting.size(4_194_304) == "4.00 MB")
        #expect(ItemMetadataFormatting.size(4_194_304, includeExactBytes: true) == "4.00 MB (4,194,304 bytes)")
        #expect(ItemMetadataFormatting.size(24) == "24 bytes")
        #expect(ItemMetadataFormatting.size(24, includeExactBytes: true) == "24 bytes")
        #expect(ItemMetadataFormatting.size(1) == "1 byte")
    }

    @Test
    func zeroUnknownAndUncalculatedSizesRemainDistinct() {
        #expect(ItemMetadataFormatting.size(0) == "0 bytes")
        #expect(ItemMetadataFormatting.size(0, includeExactBytes: true) == "0 bytes")
        #expect(ItemMetadataFormatting.size(nil) == "Unavailable")
        #expect(ItemMetadataFormatting.size(-1) == "Unavailable")
        #expect(ItemMetadataFormatting.size(nil, isDirectory: true) == "Not calculated")
        #expect(ItemMetadataFormatting.size(4096, isDirectory: true) == "Not calculated")
        #expect(ItemMetadataFormatting.size(nil, isSymbolicLink: true) == "Not calculated")
        #expect(ItemMetadataFormatting.size(24, isSymbolicLink: true) == "Not calculated")
        #expect(ItemMetadataFormatting.date(nil) == "Unavailable")
    }

    @Test
    func disabledNativePropertiesButtonRefusesFocusAndActivation() throws {
        let window = makeWindow()
        defer { window.close() }
        let button = DetailsPanePropertiesButton(frame: NSRect(x: 10, y: 10, width: 112, height: 30))
        window.contentView?.addSubview(button)
        var activations = 0
        button.onActivate = { activations += 1 }
        button.isEnabled = false
        #expect(!button.acceptsFirstResponder)
        #expect(!button.becomeFirstResponder())
        button.keyDown(with: try returnKey(in: window))
        button.activate()
        #expect(activations == 0)
    }

    @Test
    func mountedButtonRegistersDetailsFocusAndReturnOpensSelectedProperties() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection
        var shown: [String] = []
        fixture.store.onShowProperties = { shown.append($0.id) }
        fixture.button.isHidden = true
        #expect(!fixture.store.focus.focus(.details))
        fixture.button.isHidden = false
        fixture.button.isEnabled = false
        #expect(!fixture.store.focus.focus(.details))
        fixture.button.isEnabled = true
        #expect(fixture.store.focus.focus(.details))
        #expect(fixture.window.firstResponder === fixture.button)
        #expect(fixture.store.focus.currentRegion == .details)
        fixture.button.keyDown(with: try returnKey(in: fixture.window))
        #expect(shown == fixture.store.detailSelection.map(\.id))
        #expect(fixture.store.activeTab.selection == selection)
    }

    @Test
    func removingFocusedDetailsButtonReturnsFocusToListAndUnregisters() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let selection = fixture.store.activeTab.selection
        #expect(fixture.store.focus.focus(.details))
        #expect(fixture.window.firstResponder === fixture.button)
        fixture.host.rootView = AnyView(EmptyView())
        fixture.host.layoutSubtreeIfNeeded()
        try await waitUntil { fixture.button.window == nil }
        #expect(fixture.window.firstResponder === fixture.list)
        #expect(fixture.store.focus.currentRegion == .list)
        #expect(!fixture.store.focus.focus(.details))
        #expect(fixture.store.activeTab.selection == selection)
    }

    @Test
    func removingUnfocusedDetailsButtonDoesNotStealAnotherControlsFocus() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let other = MetadataFocusView(frame: NSRect(x: 10, y: 120, width: 150, height: 30))
        fixture.window.contentView?.addSubview(other)
        #expect(fixture.window.makeFirstResponder(other))
        let selection = fixture.store.activeTab.selection
        fixture.host.rootView = AnyView(EmptyView())
        fixture.host.layoutSubtreeIfNeeded()
        try await waitUntil { fixture.button.window == nil }
        #expect(fixture.window.firstResponder === other)
        #expect(!fixture.store.focus.focus(.details))
        #expect(fixture.store.activeTab.selection == selection)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func returnKey(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private func makeFixture() async throws -> MetadataPresentationFixture {
        let root = URL(fileURLWithPath: "/tmp/explorer-metadata-presentation-\(UUID().uuidString)", isDirectory: true)
        let store = ExplorerStore(initialURL: root, loader: MetadataPresentationLoader(), homeURL: root)
        try await waitUntil { !store.activeTab.isLoading }
        let item = try #require(store.activeTab.items.first)
        store.setSelection([item.id], focusedID: item.id)
        let window = makeWindow()
        let list = ExplorerTableView(frame: NSRect(x: 10, y: 10, width: 250, height: 90))
        list.focusCoordinator = store.focus
        window.contentView?.addSubview(list)
        store.focus.register(.list, owner: list) { [weak list] in
            guard let list else { return false }
            return list.window?.makeFirstResponder(list) == true
        }
        let host = NSHostingView(rootView: AnyView(DetailsPropertiesButton(store: store).frame(width: 112, height: 30)))
        host.frame = NSRect(x: 300, y: 20, width: 140, height: 50)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await waitUntil { self.detailsButton(in: host) != nil }
        let button = try #require(detailsButton(in: host))
        return MetadataPresentationFixture(store: store, window: window, list: list, host: host, button: button)
    }

    private func detailsButton(in view: NSView) -> DetailsPanePropertiesButton? {
        if let button = view as? DetailsPanePropertiesButton { return button }
        return view.subviews.lazy.compactMap { self.detailsButton(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor
private struct MetadataPresentationFixture {
    let store: ExplorerStore
    let window: NSWindow
    let list: ExplorerTableView
    let host: NSHostingView<AnyView>
    let button: DetailsPanePropertiesButton

    func close() {
        window.makeFirstResponder(nil)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        store.focus.unregister(.list, owner: list)
        store.cancelLoads()
        window.close()
    }
}

@MainActor
private final class MetadataFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct MetadataPresentationLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        [FileItem(url: url.appendingPathComponent("sample.bin"), name: "sample.bin",
                  isDirectory: false, isSymbolicLink: false, size: 4_194_304, modifiedAt: nil, kind: "Data")]
    }
}
