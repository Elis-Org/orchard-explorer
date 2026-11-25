import AppKit
import ExplorerCore
import SwiftUI
import Testing
@testable import ExplorerApp

private struct CloudStatusEmptyLoader: DirectoryListing {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
}

private final class CloudStatusEvidenceView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class CloudStatusFocusSentinel: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class CloudStatusContrastBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // A selection-like backdrop exposes a transparent interior in either appearance.
        NSColor(srgbRed: 0.12, green: 0.29, blue: 0.52, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

private final class CloudStatusRowBackdrop: NSView {
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.controlBackgroundColor : .white).setFill()
        dirtyRect.fill()
        if selected {
            // The ordinary Details/collection selection palette, composited over the row.
            (dark ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.80, green: 0.91, blue: 0.996, alpha: 1)).setFill()
            dirtyRect.fill()
        }
    }
}

@Suite(.serialized)
@MainActor
struct CloudStatusViewTests {
    private func item(_ availability: FileAvailability) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/cloud-status/An example document with a long name.txt"),
            name: "An example document with a long name.txt", isDirectory: false,
            isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text document",
            availability: availability)
    }

    @Test func availabilityHasFactualAccessibleLabelsAndUnknownIsBlank() {
        #expect(CloudStatusPresentation(availability: .unknown) == nil)
        #expect(CloudStatusPresentation(availability: .onlineOnly)?.label == "Online-only")
        #expect(CloudStatusPresentation(availability: .availableLocally)?.label == "Available locally")
        #expect(CloudStatusPresentation(availability: .onlineOnly, isDownloading: true)?.label == "Downloading")
        let badge = CloudStatusBadgeView()
        badge.configure(.onlineOnly)
        #expect(!badge.isHidden && badge.toolTip == "Online-only")
        #expect(badge.hitTest(.zero) == nil, "The row retains selection and drag hit testing")
        badge.configure(nil)
        #expect(badge.isHidden && badge.toolTip == nil)
    }

    @Test func residentCheckBadgeHasPaleInteriorInBothAppearances() throws {
        _ = NSApplication.shared
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let backdrop = CloudStatusContrastBackdrop(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            backdrop.appearance = try #require(NSAppearance(named: appearanceName))
            let badge = CloudStatusBadgeView()
            badge.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
            badge.configure(.oneDrive(.availableLocally, .confirmed(.unpinned)))
            backdrop.addSubview(badge)
            backdrop.layoutSubtreeIfNeeded()
            let bitmap = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)

            var interiorPixels = 0
            var palePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let pointX = (CGFloat(x) + 0.5) * backdrop.bounds.width / CGFloat(bitmap.pixelsWide)
                    let pointY = (CGFloat(y) + 0.5) * backdrop.bounds.height / CGFloat(bitmap.pixelsHigh)
                    let dx = pointX - 16, dy = pointY - 16
                    // Sample a broad central region, allowing arbitrary tick geometry,
                    // anti-aliasing, backing scale and a custom or symbol-based renderer.
                    guard dx * dx + dy * dy <= 16 else { continue }
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    interiorPixels += 1
                    if color.alphaComponent > 0.9 && color.redComponent > 0.72
                        && color.greenComponent > 0.72 && color.blueComponent > 0.72 {
                        palePixels += 1
                    }
                }
            }
            #expect(interiorPixels > 0)
            #expect(Double(palePixels) / Double(max(1, interiorPixels)) > 0.35,
                "The resident outline/check needs a pale interior over selected rows in \(appearanceName.rawValue), not the row showing through.")
            #expect(badge.hitTest(.zero) == nil)
        }
    }

    @Test func cloudOutlineHasNoPaleHaloAndContrastsWithThemedSelection() throws {
        _ = NSApplication.shared
        let backdrop = CloudStatusRowBackdrop(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let badge = CloudStatusBadgeView()
        badge.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        badge.configure(.onlineOnly)
        backdrop.addSubview(badge)
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            backdrop.appearance = try #require(NSAppearance(named: appearanceName))
            for selected in [false, true] {
                backdrop.selected = selected
                backdrop.needsDisplay = true
                backdrop.layoutSubtreeIfNeeded()
                let bitmap = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                let background = luminance(try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)))
                var palePixels = 0, contrastingBluePixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let px = (CGFloat(x) + 0.5) * 32 / CGFloat(bitmap.pixelsWide)
                        let py = (CGFloat(y) + 0.5) * 32 / CGFloat(bitmap.pixelsHigh)
                        guard px >= 8, px < 24, py >= 8, py < 24 else { continue }
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.72 {
                            palePixels += 1
                        }
                        let foreground = luminance(color)
                        let contrast = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                        if color.blueComponent > color.redComponent + 0.12,
                           color.blueComponent > color.greenComponent + 0.06, contrast >= 3 {
                            contrastingBluePixels += 1
                        }
                    }
                }
                #expect(contrastingBluePixels >= 8,
                    "The blue outline needs visible 3:1 stroke pixels in \(appearanceName.rawValue), selected=\(selected)")
                if appearanceName == .darkAqua {
                    #expect(palePixels == 0, "The cloud must not gain a second pale outline on dark rows, selected=\(selected)")
                }
            }
        }
    }

    @Test func unrelatedLocalAvailabilityKeepsLegacySystemSymbolInBothAppearances() throws {
        _ = NSApplication.shared
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let actual = CloudStatusRowBackdrop(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            let reference = CloudStatusRowBackdrop(frame: actual.frame)
            actual.appearance = appearance; reference.appearance = appearance
            let badge = CloudStatusBadgeView()
            badge.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
            badge.configure(CloudStatusPresentation(availability: .availableLocally))
            actual.addSubview(badge)
            let legacy = NSImageView(frame: badge.frame)
            legacy.imageScaling = .scaleProportionallyUpOrDown
            legacy.image = try #require(NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil))
            legacy.contentTintColor = .systemGreen
            reference.addSubview(legacy)
            for selected in [false, true] {
                actual.selected = selected; reference.selected = selected
                actual.needsDisplay = true; reference.needsDisplay = true
                actual.layoutSubtreeIfNeeded(); reference.layoutSubtreeIfNeeded()
                let rendered = try #require(actual.bitmapImageRepForCachingDisplay(in: actual.bounds))
                let expected = try #require(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
                actual.cacheDisplay(in: actual.bounds, to: rendered)
                reference.cacheDisplay(in: reference.bounds, to: expected)
                try #require(rendered.pixelsWide == expected.pixelsWide && rendered.pixelsHigh == expected.pixelsHigh)
                var differences = 0
                for y in 0..<rendered.pixelsHigh {
                    for x in 0..<rendered.pixelsWide {
                        let lhs = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let rhs = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        if max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                               abs(lhs.blueComponent - rhs.blueComponent)) > 0.02 { differences += 1 }
                    }
                }
                #expect(Double(differences) / Double(rendered.pixelsWide * rendered.pixelsHigh) <= 0.01,
                    "Non-OneDrive local availability preserves systemGreen checkmark.circle in \(appearanceName.rawValue), selected=\(selected)")
                #expect(badge.toolTip == "Available locally" && badge.hitTest(.zero) == nil)
            }
        }
    }

    @Test func collectionBadgesFitEveryModeAndResetWithoutChangingNames() {
        for mode in FolderViewMode.allCases where mode != .details {
            let view = ExplorerCollectionItemView()
            view.frame = NSRect(origin: .zero, size: CollectionGeometry.metrics(for: mode).itemSize)
            let value = item(.onlineOnly)
            view.configure(item: value, mode: mode)
            view.layoutSubtreeIfNeeded()
            #expect(!view.cloudBadge.isHidden)
            #expect(view.nameField.stringValue == value.name)
            #expect(!view.cloudBadge.frame.intersects(view.nameField.frame))
            #expect(view.bounds.contains(view.cloudBadge.frame))
            #expect((view.accessibilityValue() as? String)?.contains("Online-only") == true)
            let originalName = view.nameField
            view.updateCloudStatus(.downloading)
            #expect(view.nameField === originalName)
            #expect((view.accessibilityValue() as? String)?.contains("Downloading") == true)
            for status in [CloudStatusPresentation.oneDrive(.availableLocally, .confirmed(.unpinned)), .oneDrive(.availableLocally, .confirmed(.pinned)),
                           .oneDrive(.onlineOnly, .confirmed(.pinned)), .oneDrive(.availableLocally, .unchecked)] {
                view.updateCloudStatus(status)
                view.layoutSubtreeIfNeeded()
                #expect(view.cloudBadge.toolTip == status.label)
                #expect((view.accessibilityValue() as? String)?.contains("Status: \(status.label)") == true)
                #expect(view.nameField === originalName && view.nameField.stringValue == value.name)
                #expect(view.bounds.contains(view.cloudBadge.frame))
                #expect(!view.cloudBadge.frame.intersects(view.nameField.frame))
            }
            view.reset()
            #expect(view.cloudBadge.isHidden && view.cloudBadge.toolTip == nil)
            view.configure(item: item(.unknown), mode: mode)
            #expect(view.cloudBadge.isHidden)
            #expect((view.accessibilityValue() as? String)?.contains("Online-only") != true)
        }
    }

    @Test func policyLabelsKeepResidencyAndDownloadIndependent() {
        #expect(CloudStatusPresentation(availability: .availableLocally, oneDriveCandidate: true) == .oneDrive(.availableLocally, .unchecked))
        #expect(CloudStatusPresentation(availability: .onlineOnly, oneDriveCandidate: true) == .oneDrive(.onlineOnly, .unchecked))
        #expect(CloudStatusPresentation(availability: .unknown, oneDriveCandidate: true) == .oneDrive(.unknown, .unchecked))
        #expect(CloudStatusPresentation(availability: .availableLocally, isDownloading: true,
            oneDriveCandidate: true) == .downloading)
        #expect(CloudStatusPresentation.oneDrive(.availableLocally, .confirmed(.unpinned)).label == "Available locally. Always keep is off.")
        #expect(CloudStatusPresentation.oneDrive(.availableLocally, .confirmed(.pinned)).label == "Always keep on this device. Available locally.")
        #expect(CloudStatusPresentation.oneDrive(.onlineOnly, .confirmed(.pinned)).label.contains("online-only"))
        for policy in [OneDriveRetentionPolicy.none, .unpinned] {
            #expect(CloudStatusPresentation(availability: .unknown, oneDriveCandidate: true,
                observation: OneDriveBadgeObservation(policy: policy, isDataless: false)) == .oneDrive(.availableLocally, .confirmed(policy)))
            #expect(CloudStatusPresentation(availability: .availableLocally, oneDriveCandidate: true,
                observation: OneDriveBadgeObservation(policy: policy, isDataless: true)) == .oneDrive(.onlineOnly, .confirmed(policy)))
        }
        for dataless in [false, true] {
            let observation = OneDriveBadgeObservation(policy: .pinned, isDataless: dataless)
            #expect(CloudStatusPresentation(availability: .unknown, oneDriveCandidate: true,
                observation: observation) == .oneDrive(dataless ? .onlineOnly : .availableLocally, .confirmed(.pinned)))
            #expect(CloudStatusPresentation(availability: .availableLocally, isDownloading: true,
                oneDriveCandidate: true, observation: observation) == .downloading)
            #expect(CloudStatusPresentation(availability: .availableLocally,
                observation: observation) == .availableLocally, "An observation must not mark an unrelated file pinned")
        }
        let cell = CloudStatusCellView(frame: NSRect(x: 0, y: 0, width: 70, height: 26))
        cell.configure(.oneDrive(.availableLocally, .unchecked))
        #expect(cell.accessibilityValue() as? String == "Available locally. Keep status not yet checked.")
        #expect(cell.toolTip == (cell.accessibilityValue() as? String))
        #expect(cell.badge.presentation == .oneDrive(.availableLocally, .unchecked))
        #expect(cell.badge.hitTest(.zero) == nil)
    }

    @Test func snapshotPresentationKeepsPolicyFreshnessResidencyAndDownloadIndependent() {
        let availabilities: [FileAvailability] = [.unknown, .availableLocally, .onlineOnly]
        let policies: [OneDriveRetentionPolicy?] = [nil, .some(.none), .some(.unpinned), .some(.pinned)]
        let freshnessValues: [OneDriveStatusFreshness] = [.unknown, .fresh, .stale, .unavailable]
        for freshness in freshnessValues {
            for policy in policies {
                let keep: CloudStatusPresentation.Keep
                switch (freshness, policy) {
                case (.unavailable, _): keep = .unavailable(lastKnown: policy, reason: nil)
                case let (.fresh, .some(current)): keep = .confirmed(current)
                case let (_, .some(previous)): keep = .lastKnown(previous)
                case (_, nil): keep = .unchecked
                }
                for availability in availabilities {
                    let snapshot = OneDriveStatusSnapshot(availability: availability, policy: policy,
                        freshness: freshness, confirmedAt: Date(timeIntervalSince1970: 1_000),
                        confirmationElapsed: 100, staleAfter: 1_900, generation: 1)
                    // Deliberately contradict the old listing: snapshot residency owns
                    // this display, including unknown, and never falls back to old data.
                    let oldAvailability: FileAvailability = availability == .availableLocally ? .onlineOnly : .availableLocally
                    for downloading in [false, true] {
                        let presentation = CloudStatusPresentation(availability: oldAvailability,
                            isDownloading: downloading, oneDriveCandidate: true, snapshot: snapshot)
                        #expect(presentation == (downloading ? .downloading : .oneDrive(availability, keep)),
                            "policy=\(String(describing: policy)), freshness=\(freshness), residency=\(availability), downloading=\(downloading)")
                        if !downloading, availability == .unknown, let presentation {
                            #expect(presentation.label.lowercased().contains("local availability unknown"),
                                "Policy evidence must not turn unknown residency into a resident claim")
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [FileAvailability.unknown, .availableLocally, .onlineOnly])
    func coldPolicyFailureExposesUnavailableVerificationWithoutInventingResidency(_ availability: FileAvailability) throws {
        let snapshot = OneDriveStatusSnapshot(availability: availability, policy: nil,
            freshness: .unavailable, generation: 1)
        let previousAvailability: FileAvailability = availability == .availableLocally ? .onlineOnly : .availableLocally
        let presentation = try #require(CloudStatusPresentation(availability: previousAvailability,
            oneDriveCandidate: true, snapshot: snapshot))
        let expectedLabel: String
        switch availability {
        case .unknown: expectedLabel = "Local availability unknown. Keep status verification unavailable."
        case .availableLocally: expectedLabel = "Available locally. Keep status verification unavailable."
        case .onlineOnly: expectedLabel = "Visible contents online-only. Keep status verification unavailable."
        }
        #expect(presentation == .oneDrive(availability, .unavailable(lastKnown: nil, reason: nil)))
        #expect(presentation.label == expectedLabel)
        let cell = CloudStatusCellView(frame: NSRect(x: 0, y: 0, width: 70, height: 26))
        cell.configure(presentation)
        #expect(cell.accessibilityValue() as? String == expectedLabel)
        #expect(cell.accessibilityHelp() == expectedLabel)
        #expect(cell.toolTip == expectedLabel)
        #expect(cell.badge.presentation != .downloading)
    }

    @Test func ambiguousSearchHitWaitsForPerItemEvidence() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/OneDrive-Unmanaged-Negative-Control")
        let url = folder.appendingPathComponent("synthetic.txt")
        let item = FileItem(url: url, name: url.lastPathComponent, isDirectory: false, isSymbolicLink: false,
            size: 200, modifiedAt: nil, kind: "Text", identity: .init(device: 1, inode: 3, birthSeconds: 1, birthNanoseconds: 1),
            availability: .unknown, isRegularFile: true, statusVersion: .init(size: 200, modificationSeconds: 1, modificationNanoseconds: 0))
        #expect(OneDriveRetentionService.isBadgeCandidate(item), "A candidate may schedule a guarded visible lookup")
        #expect(CloudStatusPresentation.forItem(item) == nil)
        let rejected = OneDriveStatusSnapshot(availability: .unknown, policy: nil, freshness: .unavailable, generation: 1)
        #expect(CloudStatusPresentation.forItem(item, snapshot: rejected) == nil)
        let verified = OneDriveStatusSnapshot(availability: .availableLocally, policy: .pinned, freshness: .fresh, generation: 1)
        #expect(CloudStatusPresentation.forItem(item, snapshot: verified) == .oneDrive(.availableLocally, .confirmed(.pinned)))
        let cell = ExplorerCollectionItemView()
        cell.configure(item: item, mode: .largeIcons, cloudStatus: (nil, nil))
        #expect(cell.cloudBadge.isHidden && cell.accessibilityHelp() == nil)
        let unavailable = CloudStatusPresentation.oneDrive(.unknown, .unavailable(lastKnown: .pinned, reason: .itemUnavailable))
        cell.updateCloudStatus(unavailable)
        #expect(cell.accessibilityHelp()?.contains("The file could not be inspected.") == true)
        #expect((cell.accessibilityValue() as? String)?.contains("Last known: Always keep enabled.") == true)
        let refusal = OneDriveStatusSnapshot(availability: .availableLocally, policy: .pinned, freshness: .unavailable,
            failureReason: .staleTarget, repeatedTargetRefusal: true, generation: 1)
        let refused = CloudStatusPresentation.forItem(item, snapshot: refusal)
        #expect(refused?.label.contains("The file changed again during verification.") == true)
        #expect(refused?.label.contains("Last known: Always keep enabled.") == true)
    }

    @Test func confirmationTimeDoesNotChangeSemanticAccessibilityValue() {
        for freshness in [OneDriveStatusFreshness.fresh, .stale, .unavailable] {
            var first = OneDriveStatusSnapshot(availability: .availableLocally, policy: .pinned,
                freshness: freshness, confirmedAt: Date(timeIntervalSince1970: 1_000),
                confirmationElapsed: 100, staleAfter: 1_900, generation: 1)
            let initial = CloudStatusPresentation(availability: .availableLocally, oneDriveCandidate: true, snapshot: first)
            let cell = CloudStatusCellView(frame: NSRect(x: 0, y: 0, width: 70, height: 26))
            cell.configure(initial, checkedAt: first.confirmedAt)
            let previousValue = cell.accessibilityValue() as? String
            let previousLabel = cell.accessibilityLabel()
            let previousHelp = cell.accessibilityHelp()
            let previousFrame = cell.frame
            cell.badge.needsDisplay = false
            first.confirmedAt = Date(timeIntervalSince1970: 2_000)
            first.confirmationElapsed = 400
            first.staleAfter = 2_200
            let next = CloudStatusPresentation(availability: .availableLocally, oneDriveCandidate: true, snapshot: first)
            cell.configure(next, checkedAt: first.confirmedAt)
            #expect(initial == next, "Only check time changed; the row's semantic presentation did not")
            #expect(cell.accessibilityValue() as? String == previousValue)
            #expect(cell.accessibilityLabel() == previousLabel)
            #expect(cell.accessibilityHelp() != previousHelp)
            #expect(cell.accessibilityHelp() == next?.help(checkedAt: first.confirmedAt))
            #expect(cell.toolTip == cell.accessibilityHelp() && cell.badge.toolTip == cell.toolTip)
            #expect(!cell.badge.needsDisplay, "Help-only refresh does not invalidate badge drawing")
            #expect(cell.frame == previousFrame)
            cell.configure(next)
            #expect(cell.accessibilityHelp() == next?.label, "Absent proof date removes older check-time help")
            #expect(!cell.badge.needsDisplay)
        }
    }

    @Test func collectionConfirmationHelpChangesWithoutRedrawingOrChangingSelection() {
        let view = ExplorerCollectionItemView()
        view.frame = NSRect(origin: .zero, size: CollectionGeometry.metrics(for: .largeIcons).itemSize)
        view.configure(item: item(.availableLocally), mode: .largeIcons)
        let status = CloudStatusPresentation.oneDrive(.availableLocally, .confirmed(.pinned))
        view.updateCloudStatus(status, checkedAt: Date(timeIntervalSince1970: 1_000))
        view.applyState(selected: true, focused: true, hasKeyboardFocus: true)
        view.layoutSubtreeIfNeeded()
        let previousValue = view.accessibilityValue() as? String
        let previousLabel = view.accessibilityLabel()
        let previousHelp = view.accessibilityHelp()
        let previousFrame = view.frame
        let previousNameFrame = view.nameField.frame
        view.cloudBadge.needsDisplay = false
        view.needsLayout = false
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        view.updateCloudStatus(status, checkedAt: checkedAt)
        #expect(view.accessibilityValue() as? String == previousValue)
        #expect(view.accessibilityLabel() == previousLabel)
        #expect(view.accessibilityHelp() != previousHelp)
        #expect(view.accessibilityHelp() == status.help(checkedAt: checkedAt))
        #expect(view.cloudBadge.toolTip == view.accessibilityHelp())
        #expect(!view.cloudBadge.needsDisplay && !view.needsLayout)
        #expect(view.isAccessibilitySelected())
        #expect(view.frame == previousFrame && view.nameField.frame == previousNameFrame)
        view.updateCloudStatus(status)
        #expect(view.accessibilityHelp() == status.label && view.cloudBadge.toolTip == status.label)
        #expect(!view.cloudBadge.needsDisplay)
        view.reset()
        #expect(view.accessibilityHelp() == nil && view.cloudBadge.toolTip == nil)
    }

    @Test func pinAndUnpinnedGlyphContrastSurvivesMountedAppearanceChange() throws {
        _ = NSApplication.shared
        let backdrop = CloudStatusContrastBackdrop(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let badge = CloudStatusBadgeView()
        badge.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        backdrop.addSubview(badge)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            backdrop.appearance = try #require(NSAppearance(named: appearanceName))
            for status in [CloudStatusPresentation.oneDrive(.availableLocally, .unchecked),
                           .oneDrive(.availableLocally, .confirmed(.unpinned)), .oneDrive(.availableLocally, .confirmed(.pinned))] {
                badge.configure(status)
                backdrop.layoutSubtreeIfNeeded()
                let bitmap = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                var greens: [CGFloat] = [], lights: [CGFloat] = []
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let px = (CGFloat(x) + 0.5) * 32 / CGFloat(bitmap.pixelsWide) - 16
                        let py = (CGFloat(y) + 0.5) * 32 / CGFloat(bitmap.pixelsHigh) - 16
                        guard px * px + py * py <= 30 else { continue }
                        let c = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
                        if c.greenComponent > c.redComponent + 0.08 && c.greenComponent > c.blueComponent + 0.08 { greens.append(luminance) }
                        if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.85 { lights.append(luminance) }
                    }
                }
                let green = try #require(greens.min(), "A visible green disk/outline in \(appearanceName.rawValue)")
                let light = try #require(lights.max(), "A visible pale interior or white tick in \(appearanceName.rawValue)")
                #expect((light + 0.05) / (green + 0.05) >= 3, "Tick and disk contrast must be at least 3:1")
            }

        }
    }

    @Test func reusedRowDoesNotCarryDownloadingToAnotherFile() {
        let view = ExplorerCollectionItemView()
        view.frame = NSRect(origin: .zero, size: CollectionGeometry.metrics(for: .largeIcons).itemSize)
        view.configure(item: item(.onlineOnly), mode: .largeIcons)
        view.updateCloudStatus(.downloading)
        #expect((view.accessibilityValue() as? String)?.contains("Downloading") == true)
        let next = FileItem(url: URL(fileURLWithPath: "/tmp/cloud-status/another.txt"), name: "another.txt",
            isDirectory: false, isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text",
            availability: .availableLocally, isRegularFile: true)
        view.configure(item: next, mode: .largeIcons)
        #expect(view.nameField.stringValue == next.name)
        #expect((view.accessibilityValue() as? String)?.contains("Available locally") == true)
        #expect((view.accessibilityValue() as? String)?.contains("Downloading") != true)
        view.updateCloudStatus(nil)
        #expect(view.cloudBadge.isHidden && view.cloudBadge.toolTip == nil)
    }

    @Test func nonmodalCommandPhaseUpdatesPreserveContentFocus() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440.pt, height: 130.pt),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.makeFirstResponder(nil); window.close() }
        let sentinel = CloudStatusFocusSentinel(frame: NSRect(x: 0, y: 90.pt, width: 200.pt, height: 20.pt))
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: 440.pt, height: 80.pt)
        window.contentView?.addSubview(sentinel); window.contentView?.addSubview(host)
        #expect(window.makeFirstResponder(sentinel))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            for phase in [CloudCommandPhase.waitingForPreview, .queued, .downloading, .verifying, .updatingRetention] {
                let progress = CloudCommandProgress(itemName: "A long synthetic cloud document.txt", phase: phase)
                host.rootView = AnyView(CloudCommandProgressRow(progress: progress, cancel: {}).frame(width: 440.pt))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height > 0 && host.fittingSize.height <= 80.pt)
                #expect(window.firstResponder === sentinel, "A command status update must not take content focus")
            }
        }
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === sentinel)
    }

    @Test func conditionalColumnsPreserveHeadingFocusAndRememberWidths() {
        let root = URL(fileURLWithPath: "/tmp/cloud-status-columns-\(UUID().uuidString)")
        let store = ExplorerStore(initialURL: root, loader: CloudStatusEmptyLoader(), homeURL: root, observer: nil)
        defer { store.cancelLoads() }
        let coordinator = DetailsTableView.Coordinator(store: store)
        let table = ExplorerTableView()
        let header = ExplorerTableHeaderView(frame: .zero)
        table.headerView = header
        for (key, title, _) in DetailsTableView.Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = title
            table.addTableColumn(column)
        }
        coordinator.table = table
        header.focusedColumn = 3
        store.detailsColumnWidths[DetailsTableView.Coordinator.cloudStatusColumnID.rawValue] = 98
        coordinator.synchronizeConditionalColumns(searching: true, cloudStatus: true)
        #expect(table.tableColumns.map(\.title) == ["Name", "Status", "Folder", "Date modified", "Type", "Size"])
        #expect(table.tableColumns[header.focusedColumn].title == "Size")
        #expect(table.tableColumns[1].width == 98.pt)
        coordinator.synchronizeConditionalColumns(searching: true, cloudStatus: true)
        #expect(table.tableColumns.count == 6)
        coordinator.synchronizeConditionalColumns(searching: false, cloudStatus: true)
        #expect(table.tableColumns[header.focusedColumn].title == "Size")
        header.focusedColumn = 1
        coordinator.synchronizeConditionalColumns(searching: false, cloudStatus: false)
        #expect(table.tableColumns.count == 4)
        #expect(table.tableColumns.indices.contains(header.focusedColumn))
        #expect(SortKey(rawValue: DetailsTableView.Coordinator.cloudStatusColumnID.rawValue) == nil)
    }

    /// Optional production-view raster evidence, distinct from release-app UI.
    @Test func renderAvailabilityInAllCollectionModes() throws {
        guard let path = ProcessInfo.processInfo.environment["MAXPLORER_CLOUD_BADGE_EVIDENCE_DIR"] else { return }
        try #require(path.hasPrefix("/"))
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(values.isDirectory == true && values.isSymbolicLink != true)
        try #require(FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        _ = NSApplication.shared
        let modes: [(FolderViewMode, CGFloat)] = [(.extraLargeIcons, 205), (.largeIcons, 145),
            (.mediumIcons, 110), (.smallIcons, 36), (.list, 36), (.tiles, 72), (.content, 80)]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let sheet = CloudStatusEvidenceView(frame: NSRect(x: 0, y: 0, width: 985.pt, height: 760.pt))
            sheet.appearance = try #require(NSAppearance(named: appearanceName))
            var y: CGFloat = 10
            for (mode, height) in modes {
                for (column, status) in [CloudStatusPresentation.onlineOnly, .oneDrive(.availableLocally, .confirmed(.unpinned)),
                                        .oneDrive(.availableLocally, .confirmed(.pinned))].enumerated() {
                    let cell = ExplorerCollectionItemView()
                    let size = CollectionGeometry.metrics(for: mode).itemSize
                    cell.frame = NSRect(origin: NSPoint(x: CGFloat(column) * 325.pt + 5.pt, y: y.pt), size: size)
                    let value = FileItem(url: URL(fileURLWithPath: "/tmp/cloud-status/\(mode.title).txt"),
                        name: "\(mode.title) example document.txt", isDirectory: false, isSymbolicLink: false,
                        size: 24, modifiedAt: nil, kind: "Text document",
                        availability: status == .onlineOnly ? .onlineOnly : .availableLocally)
                    cell.configure(item: value, mode: mode)
                    cell.updateCloudStatus(status)
                    sheet.addSubview(cell)
                }
                y += height + 4
            }
            sheet.layoutSubtreeIfNeeded()
            let bitmap = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
            sheet.cacheDisplay(in: sheet.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("availability-\(name).png"), options: .withoutOverwriting)
        }
    }
}
