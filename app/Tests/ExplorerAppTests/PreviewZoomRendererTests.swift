import AppKit
import ExplorerCore
import Foundation
import SwiftUI
import Testing
@testable import ExplorerApp

private final class PreviewLayoutCountingProvider: ItemContentProviding, @unchecked Sendable {
    private let base = LocalItemContentProvider()
    private let failure: ItemContentError?
    private let lock = NSLock()
    private var count = 0
    init(failure: ItemContentError? = nil) { self.failure = failure }
    var materializations: Int { lock.withLock { count } }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        lock.withLock { count += 1 }
        if let failure { throw failure }
        return try await base.materialize(request, control: control)
    }
}

/// Background-only measurement: this view supplies no minimum size or frame.
private struct PreviewLayoutFrameProbe: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(identifier)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct PreviewLayoutContainer: View {
    let model: ItemPreviewModel
    let focus: ExplorerFocusCoordinator
    let width: CGFloat
    let widthOnly: Bool
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(minWidth: 0, maxWidth: .infinity)
            InspectorDivider(width: width, available: 600, resize: { _ in }).frame(width: 7.pt)
            ItemPreviewView(model: model, focus: focus)
                .background(PreviewLayoutFrameProbe(identifier: "preview-layout-pane"))
                .fixedSize(horizontal: false, vertical: widthOnly)
                .frame(width: width.pt)
                .background(PreviewLayoutFrameProbe(identifier: "preview-layout-allocation"))
        }.frame(width: 1691, height: 709)
    }
}

/// PZ-01: native component coverage. Real app input and pixels are validated separately.
@Suite(.serialized)
@MainActor
struct PreviewZoomRendererTests {
    @Test
    func longTitleStaysWithinHostedPaneAtSupportedWidths() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewLayout-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "cloud-probe-3bd8b834cd5949239da1cc19cfe0e69a-metadata.txt"
        let text = String(repeating: "Synthetic preview layout content.\n", count: 20)
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let item = try #require(snapshot.items.first { $0.name == name })
        let source = FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity))
        let provider = PreviewLayoutCountingProvider()
        let model = ItemPreviewModel(provider: provider)
        model.show(PreviewRequest(tabID: UUID(), generation: nil, searchGeneration: nil, items: [item],
            entry: ItemOperationEntry(TransferEntry(source: source, item: item))))
        let deadline = Date().addingTimeInterval(3)
        while model.state == .preparing, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard case .ready(let presentationID) = model.state else { throw RendererTestError.previewNotReady(model.state) }
        try #require(provider.materializations == 1, "Setup must prepare exactly one real local presentation")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1691, height: 709),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.show(nil) }
        do {
            let savedScale = ExplorerScale.factor
            ExplorerScale.factor = 1.5
            defer { ExplorerScale.factor = savedScale }
            // A wider host is essential: the real defect is a child overflowing
            // its fixed frame, rather than a window whose content sets its size.
            let view = HStack(spacing: 0) {
                Color.clear.frame(minWidth: 0, maxWidth: .infinity)
                InspectorDivider(width: 300, available: 600, resize: { _ in }).frame(width: 7.pt)
                ItemPreviewView(model: model, focus: ExplorerFocusCoordinator())
                    .background(PreviewLayoutFrameProbe(identifier: "preview-layout-pane"))
                    .frame(width: 300.pt)
                    .background(PreviewLayoutFrameProbe(identifier: "preview-layout-allocation"))
            }.frame(width: 1691, height: 709)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            // Synchronous native layout only: no activation, run-loop pumping,
            // Task suspension or UI input while the shared scale is changed.
            host.layoutSubtreeIfNeeded()
            let content = try #require(find("preview-content", in: host) as? PreviewHostView)
            content.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            let pane = try #require(find("preview-layout-pane", in: host))
            let allocation = try #require(find("preview-layout-allocation", in: host))
            let divider = try #require(find("inspector-pane-divider", in: host))
            let title = try #require(find("preview-item-name", in: host) as? NSTextField)
            let textView = try #require(find("preview-text", in: host) as? NSTextView)
            let viewport = try #require(textView.enclosingScrollView?.contentView)
            let allocated = allocation.convert(allocation.bounds, to: host)
            let dividerFrame = divider.convert(divider.bounds, to: host)
            let measured = [("pane", pane), ("content", content), ("title", title), ("viewport", viewport)]
                .map { ($0.0, $0.1.convert($0.1.bounds, to: host)) }
            for rect in [host.bounds, allocated, dividerFrame] + measured.map(\.1) {
                try #require(rect.width.isFinite && rect.height.isFinite && rect.minX.isFinite && rect.minY.isFinite
                    && rect.width > 0 && rect.height > 0, "Setup requires settled, positive native geometry")
            }
            try #require(abs(allocated.width - 450) <= 1 && abs(allocated.minX - dividerFrame.maxX) <= 1,
                "Setup must reproduce the fixed 300-unit pane at scale 1.5")
            try #require(title.stringValue == name && textView.string == text,
                "Setup must render the actual long-name local presentation")
            print("D05 hosted layout allocation=\(allocated), divider=\(dividerFrame), measured=\(measured)")
            for (label, rect) in measured {
                #expect(allocated.insetBy(dx: -1, dy: -1).contains(rect),
                    "\(label) must remain inside the allocated inspector pane")
            }
            #expect(model.state == .ready(presentationID))
            #expect(provider.materializations == 1)
        }
        // Keep the host alive until after restoring scale, so teardown cannot
        // hide a delayed, unwanted preparation caused by native layout.
        await Task.yield()
        #expect(provider.materializations == 1)
        #expect(model.state == .ready(presentationID))
    }

    @Test(arguments: ["text", "text-width-only", "raster", "retry"], [1.0, 1.5])
    func hostedPreviewShapesRemainContainedWhenResized(kind: String, scale: Double) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewLayoutSweep-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "cloud-probe-3bd8b834cd5949239da1cc19cfe0e69a-metadata." + (kind == "raster" ? "png" : "txt")
        if kind == "raster" {
            let context = try #require(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try #require(context.makeImage())
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: root.appendingPathComponent(name))
        } else {
            try Data(String(repeating: "Synthetic preview resize text.\n", count: 20).utf8).write(to: root.appendingPathComponent(name))
        }
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let item = try #require(snapshot.items.first { $0.name == name })
        let source = FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity))
        let provider = PreviewLayoutCountingProvider(failure: kind == "retry"
            ? .downloadFailed("The synthetic provider is unavailable. Try again when the connection is restored.") : nil)
        let model = ItemPreviewModel(provider: provider)
        model.show(PreviewRequest(tabID: UUID(), generation: nil, searchGeneration: nil, items: [item],
            entry: ItemOperationEntry(TransferEntry(source: source, item: item))))
        let deadline = Date().addingTimeInterval(3)
        while model.state == .preparing || model.state == .downloading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        if kind == "retry" {
            guard case .failed = model.state else { throw RendererTestError.previewNotReady(model.state) }
            try #require(model.canRetry)
        } else {
            guard case .ready = model.state else { throw RendererTestError.previewNotReady(model.state) }
        }
        let initialState = model.state
        try #require(provider.materializations == 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1691, height: 709),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.show(nil) }
        do {
            let savedScale = ExplorerScale.factor
            ExplorerScale.factor = CGFloat(scale)
            defer { ExplorerScale.factor = savedScale }
            let focus = ExplorerFocusCoordinator(), widthOnly = kind == "text-width-only"
            let host = NSHostingView(rootView: PreviewLayoutContainer(model: model, focus: focus, width: 300, widthOnly: widthOnly))
            window.contentView = host
            var originalContent: PreviewHostView?, originalText: NSTextView?
            for width in [CGFloat(300), 220, 420, 300] {
                host.rootView = PreviewLayoutContainer(model: model, focus: focus, width: width, widthOnly: widthOnly)
                host.layoutSubtreeIfNeeded()
                let content = try #require(find("preview-content", in: host) as? PreviewHostView)
                content.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()
                let allocation = try #require(find("preview-layout-allocation", in: host))
                let pane = try #require(find("preview-layout-pane", in: host))
                let divider = try #require(find("inspector-pane-divider", in: host))
                let allocated = allocation.convert(allocation.bounds, to: host)
                let dividerFrame = divider.convert(divider.bounds, to: host)
                try #require(abs(allocated.width - width.pt) <= 1 && abs(allocated.minX - dividerFrame.maxX) <= 1)
                var measured: [(String, NSView)] = [("pane", pane), ("content", content)]
                if let originalContent { #expect(content === originalContent) }
                else { originalContent = content }
                if kind == "retry" {
                    let message = try #require(find("preview-message", in: host) as? NSTextField)
                    let retry = try #require(find("preview-retry", in: host) as? NSButton)
                    #expect(message.stringValue.contains("synthetic provider") && retry.isEnabled)
                    measured += [("message", message), ("Retry", retry)]
                } else {
                    let title = try #require(find("preview-item-name", in: host) as? NSTextField)
                    #expect(title.stringValue == name)
                    measured.append(("title", title))
                    for identifier in ["preview-zoom-out", "preview-zoom-level", "preview-zoom-in", "preview-zoom-reset"] {
                        measured.append((identifier, try #require(find(identifier, in: host))))
                    }
                    let zoom = try #require(find("preview-zoom-in", in: host)?.superview)
                    measured.append(("zoom row", zoom))
                    if kind == "raster" {
                        let scroll = try #require(find("preview-raster-scroll", in: host) as? NSScrollView)
                        measured.append(("raster viewport", scroll.contentView))
                    } else {
                        let text = try #require(find("preview-text", in: host) as? NSTextView)
                        if let originalText { #expect(text === originalText) }
                        else { originalText = text; text.setSelectedRange(NSRange(location: 2, length: 5)) }
                        #expect(text.selectedRange() == NSRange(location: 2, length: 5))
                        measured.append(("text viewport", try #require(text.enclosingScrollView?.contentView)))
                    }
                }
                for (label, view) in measured {
                    let rect = view.convert(view.bounds, to: host)
                    try #require(rect.width.isFinite && rect.height.isFinite && rect.minX.isFinite && rect.minY.isFinite
                        && rect.width > 0 && rect.height >= 0, "Native geometry must be settled")
                    if widthOnly {
                        // An unspecified ideal height may collapse a scroll viewport;
                        // the finite proposed width must still be respected.
                        #expect(rect.minX >= allocated.minX - 1 && rect.maxX <= allocated.maxX + 1,
                            "\(kind), scale \(scale), width \(width): \(label) exceeds the finite width")
                    } else {
                        #expect(rect.height > 0 && allocated.insetBy(dx: -1, dy: -1).contains(rect),
                            "\(kind), scale \(scale), width \(width): \(label) exceeds the allocated pane")
                    }
                }
                #expect(model.state == initialState && provider.materializations == 1)
            }
        }
        await Task.yield()
        #expect(model.state == initialState && provider.materializations == 1)
    }

    @Test
    func nativeTextButtonsChangeFontAndResetOnlyTheCurrentPresentation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewZoom-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["First.txt", "Second.txt"] {
            try Data("Synthetic text for preview zoom.".utf8).write(to: root.appendingPathComponent(name))
        }
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let source = FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity))
        let model = ItemPreviewModel()
        let host = PreviewHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        let focus = ExplorerFocusCoordinator()
        let coordinator = PreviewRenderer.Coordinator(model: model)
        coordinator.attach(host, focus: focus)
        defer { coordinator.detach(); model.show(nil) }

        func select(_ name: String) async throws -> NSTextView {
            let item = try #require(snapshot.items.first { $0.name == name })
            model.show(PreviewRequest(tabID: UUID(), generation: nil, searchGeneration: nil,
                items: [item], entry: ItemOperationEntry(TransferEntry(source: source, item: item))))
            let deadline = Date().addingTimeInterval(3)
            while model.state == .preparing, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            guard case .ready = model.state else { throw RendererTestError.previewNotReady(model.state) }
            coordinator.update(model.state)
            return try #require(find("preview-text", in: host) as? NSTextView)
        }

        let firstText = try await select("First.txt")
        let baseSize = try #require(firstText.font?.pointSize)
        let plus = try #require(find("preview-zoom-in", in: host) as? NSButton)
        let minus = try #require(find("preview-zoom-out", in: host) as? NSButton)
        let reset = try #require(find("preview-zoom-reset", in: host) as? NSButton)
        let level = try #require(find("preview-zoom-level", in: host) as? NSTextField)
        #expect(plus.accessibilityLabel() == "Zoom in")
        #expect(minus.accessibilityLabel() == "Zoom out")
        #expect(reset.accessibilityLabel() == "Reset zoom")
        #expect(level.stringValue == "100%" && !reset.isEnabled)
        firstText.setSelectedRange(NSRange(location: 2, length: 5))
        plus.performClick(nil)
        let increased = try #require(firstText.font?.pointSize)
        #expect(increased > baseSize && level.stringValue != "100%")
        #expect(firstText.selectedRange() == NSRange(location: 2, length: 5))
        #expect(firstText.isSelectable && !firstText.isEditable && firstText.textContainer?.widthTracksTextView == true)
        coordinator.update(model.state)
        #expect(find("preview-zoom-in", in: host) === plus)
        #expect(firstText.font?.pointSize == increased)
        reset.performClick(nil)
        #expect(firstText.font?.pointSize == baseSize && level.stringValue == "100%" && !reset.isEnabled)
        plus.performClick(nil)

        let secondText = try await select("Second.txt")
        let secondPlus = try #require(find("preview-zoom-in", in: host) as? NSButton)
        #expect(secondPlus !== plus && plus.target == nil)
        plus.performClick(nil)
        #expect(secondText.font?.pointSize == baseSize)
        secondPlus.performClick(nil)
        #expect(secondText.font?.pointSize == increased)
        model.show(nil)
        #expect(find("preview-zoom-in", in: host) == nil && secondPlus.target == nil)
    }

    @Test
    func rasterButtonsFitResizeAndPanOnBothAxes() throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 1_200, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let raster = PreviewRasterView(image: image)
        let zoom = PreviewZoomController(fitsRaster: true) {
            [weak raster] scale, _ in raster?.setScale(scale)
        }
        raster.onScaleChange = { [weak zoom] scale, fitting in
            zoom?.update(scale: scale, resetIsRedundant: fitting)
        }
        let plus = try #require(find("preview-zoom-in", in: zoom.row) as? NSButton)
        let minus = try #require(find("preview-zoom-out", in: zoom.row) as? NSButton)
        let fit = try #require(find("preview-zoom-reset", in: zoom.row) as? NSButton)
        let scroll = try #require(find("preview-raster-scroll", in: raster) as? NSScrollView)
        let document = try #require(find("preview-raster", in: scroll) as? NSImageView)
        let clip = scroll.contentView
        let imageSize = NSSize(width: 1_200, height: 800)
        #expect(document.frame.size == imageSize)
        #expect(scroll.hasHorizontalScroller && scroll.hasVerticalScroller && !scroll.allowsMagnification)
        #expect(fit.accessibilityLabel() == "Fit to pane")

        func resize(_ width: CGFloat, _ height: CGFloat) {
            raster.setFrameSize(NSSize(width: width, height: height))
            raster.layout()
        }
        func expectedFit() -> CGFloat {
            min(1, clip.frame.width / imageSize.width, clip.frame.height / imageSize.height)
        }
        func pan(to point: NSPoint) {
            let requested = NSRect(origin: point, size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(requested).origin)
            scroll.reflectScrolledClipView(clip)
        }

        resize(320, 260)
        #expect(abs(scroll.magnification - expectedFit()) < 0.0001 && !fit.isEnabled)
        #expect(abs(clip.bounds.midX - 600) < 1 && abs(clip.bounds.midY - 400) < 1)
        plus.performClick(nil)
        #expect(scroll.magnification == 0.5 && fit.isEnabled)
        pan(to: NSPoint(x: 100, y: 80))
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        resize(400, 290)
        #expect(scroll.magnification == 0.5)
        #expect(abs(clip.bounds.midX - center.x) < 2 && abs(clip.bounds.midY - center.y) < 2)

        pan(to: NSPoint(x: 2_000, y: 2_000))
        #expect(abs(clip.bounds.maxX - imageSize.width) < 2)
        #expect(abs(clip.bounds.maxY - imageSize.height) < 2)
        pan(to: NSPoint(x: -2_000, y: -2_000))
        #expect(abs(clip.bounds.minX) < 2 && abs(clip.bounds.minY) < 2)
        for _ in 0..<12 { plus.performClick(nil) }
        #expect(scroll.magnification == 4 && !plus.isEnabled)
        for _ in 0..<12 { minus.performClick(nil) }
        #expect(scroll.magnification == 0.125 && !minus.isEnabled)

        fit.performClick(nil)
        let fitted = scroll.magnification
        #expect(abs(fitted - expectedFit()) < 0.0001 && !fit.isEnabled)
        resize(110, 260)
        #expect(abs(scroll.magnification - expectedFit()) < 0.0001 && scroll.magnification < 0.125)
        #expect(!minus.isEnabled && plus.isEnabled)
        plus.performClick(nil)
        #expect(scroll.magnification == 0.125)
        fit.performClick(nil)
        resize(1_400, 1_000)
        #expect(scroll.magnification == 1)
        #expect(abs(clip.bounds.midX - 600) < 1 && abs(clip.bounds.midY - 400) < 1)
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { find(identifier, in: $0) }.first
    }

    private enum RendererTestError: Error {
        case previewNotReady(PreviewState)
    }
}
