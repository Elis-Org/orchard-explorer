import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// G3 / MAC-074/075: interface scale and Explorer folder icon. These are model
/// and rendering checks; they never change the process-wide scale, so parallel
/// tests keep the reference geometry (1.0).
@MainActor
struct InterfaceScaleTests {
    @Test
    func storedScaleDefaultsTo150PercentAndAcceptsOnlyPresets() throws {
        let suite = "ExplorerScaleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ExplorerScale.stored(in: defaults) == 1.5)
        defaults.set(1.25, forKey: ExplorerScale.defaultsKey)
        #expect(ExplorerScale.stored(in: defaults) == 1.25)
        defaults.set(3.0, forKey: ExplorerScale.defaultsKey)
        #expect(ExplorerScale.stored(in: defaults) == 1.5, "Unknown values fall back to the default")
        #expect(ExplorerScale.presets.map(ExplorerScale.title(for:)) == ["100%", "125%", "150%", "175%", "200%"])
    }

    @Test
    func layoutBreakpointsAndWidthsScaleTogether() {
        // At 150% every MAC-018 breakpoint is 1.5× wider and every width 1.5× larger.
        #expect(!ExplorerLayout(width: 449, scale: 1.5).showsSidebar)
        let narrow = ExplorerLayout(width: 450, scale: 1.5)
        #expect(narrow.showsSidebar && narrow.sidebarWidth == 239 * 1.5 && narrow.commandMode == .compact)
        let full = ExplorerLayout(width: 1050, scale: 1.5)
        #expect(full.sidebarWidth == 312 * 1.5 && full.commandMode == .full && full.showsInlineSearch)
        #expect(full.navigationButtonWidth == 48 * 1.5 && full.detailsPaneWidth == 450)
        #expect(!ExplorerLayout(width: 1349, scale: 1.5).canShowDetailsPane)
        #expect(ExplorerLayout(width: 1350, scale: 1.5).canShowDetailsPane)
        #expect(!ExplorerLayout(width: 749, scale: 1.5).showsFullSelectionStatus)
        // The reference scale keeps the original thresholds.
        #expect(ExplorerLayout(width: 300, scale: 1).showsSidebar && ExplorerLayout(width: 600, scale: 1).sidebarWidth == 312)
    }

    @Test
    func breadcrumbCountAndCollectionMetricsScale() {
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 839, scale: 1.5) == 3)
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 840, scale: 1.5) == 5)
        #expect(NativeAddressBar.visibleBreadcrumbCount(width: 560, scale: 1) == 5)
        let reference = CollectionGeometry.referenceMetrics(for: .largeIcons)
        let scaled = CollectionGeometry.metrics(for: .largeIcons, scale: 1.5)
        #expect(scaled.itemSize == NSSize(width: reference.itemSize.width * 1.5, height: reference.itemSize.height * 1.5))
        #expect(scaled.iconSide == reference.iconSide * 1.5 && scaled.verticalSpacing == reference.verticalSpacing * 1.5)
    }

    @Test
    func onlyOrdinaryFoldersUseTheExplorerFolderIcon() {
        func item(_ name: String, directory: Bool, link: Bool = false) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/explorer-icon-model/\(name)", isDirectory: directory), name: name,
                     isDirectory: directory, isSymbolicLink: link, size: nil, modifiedAt: nil, kind: "")
        }
        #expect(ExplorerIcons.showsFolder(item("Reports", directory: true)))
        #expect(ExplorerIcons.showsFolder(item("v1.2", directory: true)), "An unknown extension is still a folder")
        #expect(!ExplorerIcons.showsFolder(item("Explorer.app", directory: true)), "Packages keep their own icon")
        #expect(!ExplorerIcons.showsFolder(item("Link", directory: true, link: true)))
        #expect(!ExplorerIcons.showsFolder(item("notes.txt", directory: false)))
        #expect(ItemMetadataFormatting.genericIcon(for: item("Reports", directory: true)) === ExplorerIcons.folder)
    }

    @Test
    func folderIconIsYellowAndResolutionIndependent() throws {
        for side in [16, 48, 256] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            ExplorerIcons.folder.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            // The front panel's centre is warm yellow; the corners stay transparent.
            let centre = try #require(bitmap.colorAt(x: side / 2, y: side * 6 / 10)?.usingColorSpace(.sRGB))
            #expect(centre.redComponent > 0.9 && centre.greenComponent > 0.65 && centre.blueComponent < 0.45,
                    "Centre at \(side) px: \(centre)")
            #expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.05)
        }
    }

    /// Review 7a1a7cf8 #6: at 200% the File Access panel (1120 × 1280) is capped to
    /// a Retina work area (e.g. 1728 × 1080); its content scrolls.
    @Test
    func utilityPanelsAreCappedToTheVisibleScreen() {
        #expect(ExplorerScale.fittingContentSize(NSSize(width: 1120, height: 1280), visible: NSSize(width: 1728, height: 1080))
                == NSSize(width: 1120, height: 1040))
        #expect(ExplorerScale.fittingContentSize(NSSize(width: 560, height: 640), visible: NSSize(width: 3840, height: 2135))
                == NSSize(width: 560, height: 640))
        #expect(ExplorerScale.fittingContentSize(NSSize(width: 560, height: 640), visible: nil) == NSSize(width: 560, height: 640))
    }

    /// Review 7a1a7cf8 #2: a rebuilt search field keeps an unsubmitted draft.
    @Test
    func rebuiltSearchFieldKeepsAnUnsubmittedDraft() {
        let draft = SearchFieldDraft()
        draft.synchronize(committed: "", context: "A:", force: false)
        #expect(draft.text.isEmpty)
        draft.text = "quarterly rep"
        draft.synchronize(committed: "", context: "A:", force: false)
        #expect(draft.text == "quarterly rep", "Rebuild keeps the typed, unsubmitted query")
        // Review 8ab56c03 #8: a field that reappears in another tab never inherits the draft.
        draft.synchronize(committed: "", context: "B:", force: false)
        #expect(draft.text.isEmpty)
        draft.synchronize(committed: "report", context: "B:s1", force: true)
        #expect(draft.text == "report", "A submitted search or tab change adopts the committed query")
        draft.synchronize(committed: "report", context: "B:s1", force: false)
        #expect(draft.text == "report")
    }

    /// Review 7a1a7cf8 #3: user-set Details widths are kept in reference points.
    @Test
    func resizedDetailsColumnsAreRememberedInReferencePoints() {
        let store = ExplorerStore(initialURL: URL(fileURLWithPath: "/tmp/explorer-scale-model", isDirectory: true),
                                  loader: StaticListing())
        let coordinator = DetailsTableView.Coordinator(store: store)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 333
        coordinator.tableViewColumnDidResize(Notification(name: NSTableView.columnDidResizeNotification,
                                                          object: nil, userInfo: ["NSTableColumn": column]))
        #expect(store.detailsColumnWidths["name"] == 333 / ExplorerScale.factor)
        #expect(store.sidebarModel === store.sidebarModel, "One sidebar model per window survives rebuilds")
        store.cancelLoads()
    }
}

private struct StaticListing: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        DirectorySnapshot(items: [], directoryIdentity: nil)
    }
}
