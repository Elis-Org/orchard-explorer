import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

/// NATIVE-P21-ICON/ZIPOPS: baseline-compiling behavioral RED coverage. These
/// tests use private pasteboards and disposable synthetic ZIPs; they never open
/// another application or submit a destructive archive operation.
@Suite(.serialized)
@MainActor
struct PreviewZIPFeatureTests {
    // The stored fixture contains inside/nested/archived-note.txt, root-note.txt
    // and an explicit empty directory. All regular payloads are synthetic text.
    static let zipBase64 = "UEsDBBQAAAAAAIMYIlwAAAAAAAAAAAAAAAAHAAAAaW5zaWRlL1BLAwQUAAAAAACDGCJcAAAAAAAAAAAAAAAADgAAAGluc2lkZS9uZXN0ZWQvUEsDBBQAAAAAAIMYIlwEjfnBGAAAABgAAAAfAAAAaW5zaWRlL25lc3RlZC9hcmNoaXZlZC1ub3RlLnR4dFN5bnRoZXRpYyBhcmNoaXZlZCBub3RlLlBLAwQUAAAAAACDGCJcBI35wRgAAAAYAAAADQAAAHJvb3Qtbm90ZS50eHRTeW50aGV0aWMgYXJjaGl2ZWQgbm90ZS5QSwMEFAAAAAAAgxgiXAAAAAAAAAAAAAAAAAYAAABlbXB0eS9QSwECFAAUAAAAAACDGCJcAAAAAAAAAAAAAAAABwAAAAAAAAAAAAAAAAAAAAAAaW5zaWRlL1BLAQIUABQAAAAAAIMYIlwAAAAAAAAAAAAAAAAOAAAAAAAAAAAAAAAAACUAAABpbnNpZGUvbmVzdGVkL1BLAQIUABQAAAAAAIMYIlwEjfnBGAAAABgAAAAfAAAAAAAAAAAAAAAAAFEAAABpbnNpZGUvbmVzdGVkL2FyY2hpdmVkLW5vdGUudHh0UEsBAhQAFAAAAAAAgxgiXASN+cEYAAAAGAAAAA0AAAAAAAAAAAAAAAAApgAAAHJvb3Qtbm90ZS50eHRQSwECFAAUAAAAAACDGCJcAAAAAAAAAAAAAAAABgAAAAAAAAAAAAAAAADpAAAAZW1wdHkvUEsFBgAAAAAFAAUALQEAAA0BAAAAAA=="

    private func withArchive(
        _ body: (ExplorerStore, URL, Data) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewZIPFeature-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Synthetic bundle.zip")
        let original = try #require(Data(base64Encoded: Self.zipBase64))
        try original.write(to: archive)
        let board = NSPasteboard(name: .init("PreviewZIPFeature-\(UUID())"))
        defer { board.releaseGlobally() }
        let location = try ArchiveLocation(archiveURL: archive)
        let store = ExplorerStore(initialURL: location.url, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        let deadline = Date().addingTimeInterval(3)
        while store.activeTab.isLoading || store.activeTab.isRefreshing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(store.activeTab.hasLoaded && !store.activeTab.isLoading && !store.activeTab.isUnavailable)
        try #require(store.activeTab.url == location.url && store.activeTab.archiveRevision != nil)
        try await body(store, archive, original)
    }

    @Test
    func zipIconsShareCompressedFolderArtworkAcrossRowsMetadataAndDrafts() throws {
        let root = URL(fileURLWithPath: "/tmp/preview-zip-icon-model", isDirectory: true)
        func item(_ url: URL, directory: Bool = false, link: Bool = false) -> FileItem {
            FileItem(url: url, name: url.lastPathComponent, isDirectory: directory,
                isSymbolicLink: link, size: nil, modifiedAt: nil, kind: "")
        }
        let physical = item(root.appendingPathComponent("Bundle.zip"))
        let virtual = item(try ArchiveLocation(archiveURL: physical.url, components: ["Nested.zip"]).url)
        let rowIcon = ExplorerIcons.icon(for: physical)
        let metadataIcon = ItemMetadataFormatting.genericIcon(for: physical)
        let virtualIcon = ExplorerIcons.icon(for: virtual)
        let draftIcon = ExplorerIcons.draftIcon(.file(.zipArchive))
        #expect(rowIcon.accessibilityDescription == "Compressed folder")
        #expect(metadataIcon.accessibilityDescription == "Compressed folder")
        #expect(virtualIcon.accessibilityDescription == "Compressed folder")
        #expect(draftIcon.accessibilityDescription == "Compressed folder")
        #expect(rowIcon === metadataIcon && rowIcon === virtualIcon && rowIcon === draftIcon,
                "All existing item presentations share the original compressed-folder artwork")
        #expect(rowIcon !== ExplorerIcons.folder)
        let zipDirectory = item(root.appendingPathComponent("Folder.zip", isDirectory: true), directory: true)
        #expect(ExplorerIcons.icon(for: zipDirectory) === ExplorerIcons.folder)
        #expect(!ExplorerIcons.showsFolder(item(root.appendingPathComponent("Link.zip"), link: true)))
        #expect(ExplorerIcons.icon(for: item(root.appendingPathComponent("Link.zip"), link: true)) !== rowIcon)
    }

    /// Component raster evidence only: this does not establish Windows fidelity
    /// or replace captures of the real app. No global appearance is changed.
    @Test
    func compressedFolderRendersAtSupportedSizesAndAppearances() throws {
        let output: URL?
        if let path = ProcessInfo.processInfo.environment["MAXPLORER_ICON_EVIDENCE_DIR"] {
            try #require(path.hasPrefix("/"), "The explicitly supplied evidence directory must be absolute")
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            try #require(values.isDirectory == true && values.isSymbolicLink != true)
            try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                "Evidence must use a fresh, empty run directory")
            output = directory
        } else { output = nil }
        for (label, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for selected in [false, true] {
                for size in [16, 20, 32, 48, 256] {
                    let folder = try raster(ExplorerIcons.folder, size: size, appearance: appearance, selected: selected)
                    let zip = try raster(ExplorerIcons.compressedFolder, size: size, appearance: appearance, selected: selected)
                    #expect(folder != zip, "The zipper must remain represented at every supported component scale")
                    if let output {
                        for (kind, data) in [("folder", folder), ("zip", zip)] {
                            let name = "\(kind)-\(label)-\(selected ? "selected" : "normal")-\(size).png"
                            try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
                        }
                    }
                }
            }
        }
    }

    private func raster(_ image: NSImage, size: Int, appearance: NSAppearance, selected: Bool) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: CGFloat(size), height: CGFloat(size))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        appearance.performAsCurrentDrawingAppearance {
            (selected ? NSColor.selectedControlColor : NSColor.textBackgroundColor).setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        context.flushGraphics()
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == size && decoded.pixelsHigh == size)
        return data
    }

    @Test
    func archiveSelectionEnablesSupportedCommandsWithoutPhysicalCapabilities() async throws {
        try await withArchive { store, archive, original in
            let file = try #require(store.activeTab.items.first { $0.name == "root-note.txt" })
            let folder = try #require(store.activeTab.items.first { $0.name == "inside" })
            store.setSelection([file.id], focusedID: file.id)
            #expect(store.canOpenSelection)
            #expect(store.canCopySelection)
            #expect(store.canRenameSelection, "Archive Rename is the explicitly requested native extension")
            #expect(!store.canCreateFolder && !store.canCompressSelection && !store.canMakeAliases)
            #expect(!store.canTrashSelection && !store.canShareSelection && !store.canRevealInFinder)
            #expect(!store.canOpenInTerminal(folder) && !store.canOpenCurrentFolderInTerminal)
            #expect(store.fileDragEntries(itemIDs: [file.id]) == nil)
            #expect(store.fileDropBinding(destinationURL: folder.url) == nil)
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test(arguments: ["root-note.txt", "inside"])
    func archiveRenameBeginsInlineDraftWithoutMutatingArchive(_ name: String) async throws {
        try await withArchive { store, archive, original in
            let item = try #require(store.activeTab.items.first { $0.name == name })
            store.setSelection([item.id], focusedID: item.id)
            let selection = store.currentSelection
            store.beginRename()
            let edit = try #require(store.nameEdit, "Archive file and subtree Rename must use the inline editor")
            #expect(edit.item == item && edit.directoryURL == store.activeTab.url)
            #expect(edit.originalName == item.name && edit.proposedName == item.name)
            #expect(store.currentSelection == selection && !store.isPerformingOperation)
            #expect(!store.canUndoRename)
            store.updateProposedName("Renamed" + (item.isDirectory ? "" : ".txt"), sessionID: edit.id)
            store.cancelNameEdit(sessionID: edit.id)
            #expect(store.nameEdit == nil && store.currentSelection == selection)
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test
    func physicalClipboardCanPasteIntoArchive() async throws {
        try await withArchive { store, archive, original in
            let parent = archive.deletingLastPathComponent()
            let sourceURL = parent.appendingPathComponent("incoming.txt")
            let bytes = Data("Synthetic physical source for ZIP paste.\n".utf8)
            try bytes.write(to: sourceURL)
            let snapshot = try await LocalDirectoryLoader().snapshot(of: parent, showHidden: false)
            let source = try #require(snapshot.items.first { $0.url == sourceURL })
            let identity = try #require(snapshot.directoryIdentity)
            store.clipboard.capture(items: [source],
                source: FileOperationContext(directoryURL: parent, directoryIdentity: identity), kind: .copy)
            try #require(store.clipboard.payload != nil && store.clipboard.hasTransferCandidate)
            #expect(store.canPaste, "A physical source can be added to the current archive")
            #expect(!store.canCreateFolder, "Paste availability must not enable New Folder")
            #expect(try Data(contentsOf: archive) == original)
            #expect(try Data(contentsOf: sourceURL) == bytes)
        }
    }
}
