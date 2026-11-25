import AppKit
@testable import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor ResponsivenessBadgeReader {
    private(set) var calls: [String] = []
    private var pending: [Int: CheckedContinuation<OneDriveBadgeObservation, Error>] = [:]
    private var stopped = false

    func read(_ entry: TransferEntry) async throws -> OneDriveBadgeObservation {
        guard !stopped else { throw CancellationError() }
        let index = calls.count
        calls.append(entry.item.id)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finishNext(_ observation: OneDriveBadgeObservation) {
        guard let index = pending.keys.min() else { return }
        pending.removeValue(forKey: index)?.resume(returning: observation)
    }

    func stop() {
        stopped = true
        let outstanding = Array(pending.values)
        pending.removeAll()
        for continuation in outstanding { continuation.resume(throwing: CancellationError()) }
    }
}

private final class ResponsivenessRowBackdrop: NSView {
    var selected = false

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.controlBackgroundColor : .white).setFill()
        dirtyRect.fill()
        if selected {
            (dark ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.80, green: 0.91, blue: 0.996, alpha: 1)).setFill()
            dirtyRect.fill()
        }
    }
}

/// CSR-01 and CSR-04 regressions use the released public/internal seams so the
/// baseline can fail on behavior before the snapshot/scheduler refactor exists.
@Suite(.serialized)
@MainActor
struct CloudStatusResponsivenessTests {
    private let folder = URL(fileURLWithPath: "/Test/OneDrive/Responsiveness/")

    private func entry(_ index: Int) -> TransferEntry {
        let name = "status-\(index).txt"
        let item = FileItem(url: folder.appendingPathComponent(name), name: name,
            isDirectory: false, isSymbolicLink: false, size: 200,
            modifiedAt: Date(timeIntervalSince1970: 1), kind: "Text document",
            identity: .init(device: 1, inode: UInt64(1_000 + index), birthSeconds: 1, birthNanoseconds: 1),
            availability: .availableLocally, isRegularFile: true,
            statusVersion: .init(size: 200, modificationSeconds: 1, modificationNanoseconds: 1))
        return TransferEntry(source: .init(directoryURL: folder,
            directoryIdentity: .init(device: 1, inode: 900, birthSeconds: 1, birthNanoseconds: 1)), item: item)
    }

    private func until(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func residentWithoutPolicyRendersFactualAccessibleStateImmediately() throws {
        let presentation = try #require(CloudStatusPresentation(availability: .availableLocally,
            oneDriveCandidate: true))
        let cell = CloudStatusCellView(frame: NSRect(x: 0, y: 0, width: 70, height: 26))
        cell.configure(presentation)

        #expect(presentation.label == "Available locally. Keep status not yet checked.")
        #expect(cell.accessibilityValue() as? String == presentation.label)
        #expect(cell.toolTip == presentation.label)
        #expect(!cell.badge.isHidden && cell.badge.presentation != .downloading)
        #expect(cell.badge.hitTest(.zero) == nil, "Status must not intercept row interaction")
    }

    @Test func currentResidencySurvivesLossOfKeepConfirmation() throws {
        _ = NSApplication.shared
        let date = Date(timeIntervalSince1970: 1_000)
        let statuses: [(OneDriveStatusFreshness, OneDriveRetentionPolicy?, String)] = [
            (.unknown, nil, "Available locally. Keep status not yet checked."),
            (.fresh, .unpinned, "Available locally. Always keep is off."),
            (.stale, .unpinned, "Available locally. Keep status needs checking."),
            (.unavailable, nil, "Available locally. Keep status verification unavailable.")
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for selected in [false, true] {
                var reference: NSBitmapImageRep?
                for (freshness, policy, label) in statuses {
                    let snapshot = OneDriveStatusSnapshot(availability: .availableLocally, policy: policy,
                        freshness: freshness, confirmedAt: policy == nil ? nil : date, generation: 1)
                    let value = try #require(CloudStatusPresentation(availability: .availableLocally,
                        oneDriveCandidate: true, snapshot: snapshot))
                    #expect(value.label == label)
                    let bitmap = try render(value, appearance: appearance, selected: selected)
                    if let reference {
                        #expect(bitmap.tiffRepresentation == reference.tiffRepresentation,
                            "Unchecked, confirmed non-pinned, stale and unavailable resident rows must all show the same outlined check")
                    } else { reference = bitmap }
                }
            }
        }
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: true)
        #expect(CloudStatusPresentation(availability: .onlineOnly, oneDriveCandidate: true,
            observation: pinned)?.label == "Always keep enabled. Visible contents online-only.")
    }

    @Test(arguments: [false, true])
    func sameVersionResidentSearchSampleSupersedesAnOlderCloud(verified: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Residency-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.txt")
        try Data("synthetic".utf8).write(to: url)
        let parentSample = try LocalFileIdentity.read(at: folder, ifLocal: true)
        let parent = try #require(parentSample)
        let item = LocalDirectoryLoader.sample(for: url, displayedIn: folder, supportsLocalIdentity: true,
            readCloudMetadata: false).item
        try #require(item.availability == .unknown && item.identity != nil && item.statusVersion != nil)
        let previous = FileItem(url: url, name: item.name, isDirectory: false, isSymbolicLink: false,
            size: item.size, modifiedAt: item.modifiedAt, kind: item.kind, identity: item.identity,
            availability: .onlineOnly, isRegularFile: true, statusVersion: item.statusVersion)
        let origin = FileOperationContext(directoryURL: folder, directoryIdentity: parent)
        let dataless = TransferEntry(source: origin, item: previous), resident = TransferEntry(source: origin, item: item)
        let reader = ResponsivenessBadgeReader()
        let cache = OneDriveBadgeCache(debounce: .zero) { try await reader.read($0) }
        let owner = UUID(), scope = OneDriveBadgeCache.Scope(tab: UUID(), folder: folder, load: nil, searchGeneration: UUID())
        defer { cache.remove(owner); Task { await reader.stop() } }
        cache.mergeListing([dataless], startedAt: cache.beginListingSnapshot(for: folder))
        cache.update(owner, scope: scope, entries: [dataless], mergeEntries: false, changed: {})
        try #require(await until { await reader.calls.count == 1 })
        if verified {
            await reader.finishNext(.init(policy: .unpinned, isDataless: true))
            try #require(await until { cache.snapshot(for: dataless)?.freshness == .fresh })
        }
        cache.mergeListing([resident], startedAt: cache.beginListingSnapshot(for: folder))
        let current = try #require(cache.snapshot(for: resident))
        #expect(current.availability == (verified ? .availableLocally : .unknown),
            "A newer no-follow resident sample disproves an old cloud. A local badge still needs cloud membership evidence.")
        if verified { #expect(current.freshness == .stale) }
        else { #expect(current.policy == nil) }
    }

    @Test func mixedPinsPreserveVisibleResidencyAndHaveDistinctQualifiers() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for selected in [false, true] {
                var rasters = [Data]()
                // Anti-aliased neutral ink inherits some selection blue. A
                // cloud uses the actual saturated stroke in this appearance.
                let cloud = try render(.onlineOnly, appearance: appearance, selected: selected)
                var cloudInk = try color(cloud, x: 0, y: 0)
                for y in 0..<cloud.pixelsHigh {
                    for x in 0..<cloud.pixelsWide {
                        let c = try color(cloud, x: x, y: y)
                        if c.blueComponent - c.redComponent > cloudInk.blueComponent - cloudInk.redComponent { cloudInk = c }
                    }
                }
                for availability in [FileAvailability.availableLocally, .onlineOnly, .unknown] {
                    for keep in [CloudStatusPresentation.Keep.unchecked, .confirmed(.pinned), .lastKnown(.pinned)] {
                        let bitmap = try render(.oneDrive(availability, keep), appearance: appearance, selected: selected)
                        let image = try #require(bitmap.representation(using: .png, properties: [:]))
                        #expect(!rasters.contains(image), "Each combination should have a distinct 16-point glyph")
                        rasters.append(image)
                        let background = try color(bitmap, x: 0, y: 0)
                        var visible = 0, green = 0, blue = 0, rightQualifier = 0
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                let c = try color(bitmap, x: x, y: y)
                                guard contrast(c, background) >= 2.1 else { continue }
                                visible += 1
                                if c.greenComponent > c.redComponent + 0.08 && c.greenComponent > c.blueComponent + 0.08 { green += 1 }
                                let blueDistance = max(abs(c.redComponent - cloudInk.redComponent),
                                    abs(c.greenComponent - cloudInk.greenComponent), abs(c.blueComponent - cloudInk.blueComponent))
                                if blueDistance < 0.10 { blue += 1 }
                                let glyphX = (CGFloat(x) + 0.5) * 32 / CGFloat(bitmap.pixelsWide) - 8
                                if glyphX > 14.25 { rightQualifier += 1 }
                            }
                        }
                        #expect(visible >= 4, "Every OneDrive status has a visible mark")
                        if availability == .onlineOnly { #expect(blue >= 3, "The cloud remains visible even with a pin qualifier") }
                        if availability == .availableLocally { #expect(green >= 3, "The current local contents retain a green check") }
                        if availability == .unknown { #expect(green == 0 && blue == 0) }
                        if availability == .unknown && keep == .confirmed(.pinned) {
                            #expect(rightQualifier > 0, "The pin needs a visible backed question-mark qualifier beyond its right edge")
                        }
                    }
                }
            }
        }
    }

    @Test func captureMixedStatusGlyphsAtNativeSize() throws {
        guard let path = ProcessInfo.processInfo.environment["MAXPLORER_ONEDRIVE_MIXED_GLYPH_DIR"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(folder.path == path && values.isDirectory == true && values.isSymbolicLink == false)
        let states: [CloudStatusPresentation] = [
            .oneDrive(.availableLocally, .unchecked), .oneDrive(.availableLocally, .confirmed(.pinned)),
            .oneDrive(.availableLocally, .lastKnown(.pinned)), .oneDrive(.onlineOnly, .unchecked),
            .oneDrive(.onlineOnly, .confirmed(.pinned)), .oneDrive(.onlineOnly, .lastKnown(.pinned)),
            .oneDrive(.unknown, .unchecked), .oneDrive(.unknown, .confirmed(.pinned)), .oneDrive(.unknown, .lastKnown(.pinned))
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for selected in [false, true] {
                let sheet = ResponsivenessRowBackdrop(frame: NSRect(x: 0, y: 0, width: CGFloat(24 * states.count), height: 26))
                sheet.selected = selected
                sheet.appearance = try #require(NSAppearance(named: appearance))
                for (index, state) in states.enumerated() {
                    let badge = CloudStatusBadgeView()
                    badge.frame = NSRect(x: CGFloat(4 + index * 24), y: 5, width: 16, height: 16)
                    badge.configure(state)
                    sheet.addSubview(badge)
                }
                sheet.layoutSubtreeIfNeeded()
                let bitmap = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
                sheet.cacheDisplay(in: sheet.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("mixed-\(name)-\(selected ? "selected" : "normal").png"),
                              options: .withoutOverwriting)
            }
        }
    }

    @Test func newlyVisibleUnknownRowPrecedesRoutineStaleRefresh() async throws {
        let reader = ResponsivenessBadgeReader(), owner = UUID(), tab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.stop() } }
        let old = entry(1), incoming = entry(2)
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        func demand(_ entries: [TransferEntry]) {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                entries: entries, changed: {})
        }
        demand([old])
        try #require(await until { await reader.calls.count == 1 })
        await reader.finishNext(pinned)
        try #require(await until { cache.observation(for: old) == pinned })

        clock += 301
        demand([old, incoming])
        try #require(await until { await reader.calls.count == 2 })
        let calls = await reader.calls
        #expect(calls == [old.item.id, incoming.item.id],
            "A newly visible row needs its first answer before an old row's routine recheck")
    }

    @Test func routineRefreshUsesOnlyTwoInitialStartsAtFrozenTime() async throws {
        let reader = ResponsivenessBadgeReader(), owner = UUID(), tab = UUID()
        var clock: TimeInterval = 100
        let cache = OneDriveBadgeCache(debounce: .zero, now: { clock }) { try await reader.read($0) }
        defer { cache.remove(owner); Task { await reader.stop() } }
        let rows = (10..<14).map(entry)
        let pinned = OneDriveBadgeObservation(policy: .pinned, isDataless: false)
        var observations = 0
        func demand() {
            cache.update(owner, scope: .init(tab: tab, folder: folder, load: UUID(), searchGeneration: nil),
                entries: rows, changed: {}, observed: { _, _ in observations += 1 })
        }
        demand()
        for index in 0..<4 {
            try #require(await until { await reader.calls.count == index + 1 })
            await reader.finishNext(pinned)
            try #require(await until { observations == index + 1 })
        }

        clock += 301
        demand()
        for index in 4..<6 {
            try #require(await until { await reader.calls.count == index + 1 })
            await reader.finishNext(pinned)
            try #require(await until { observations == index + 1 })
        }
        // Only let the cache's dispatch hop run; injected time stays frozen, so
        // neither the global nor routine bucket can earn additional tokens.
        demand()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await reader.calls.count == 6,
            "Four cold reads followed by two routine reads must exhaust the shared routine burst allowance")
    }

    private func render(_ presentation: CloudStatusPresentation, appearance: NSAppearance.Name,
                        selected: Bool) throws -> NSBitmapImageRep {
        let backdrop = ResponsivenessRowBackdrop(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        backdrop.appearance = try #require(NSAppearance(named: appearance))
        backdrop.selected = selected
        let badge = CloudStatusBadgeView()
        badge.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        badge.configure(presentation)
        backdrop.addSubview(badge)
        backdrop.layoutSubtreeIfNeeded()
        let bitmap = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let lhs = luminance(first), rhs = luminance(second)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}
