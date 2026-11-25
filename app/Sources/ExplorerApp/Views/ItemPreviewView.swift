import AppKit
import ExplorerCore
import QuickLookUI
import SwiftUI

struct ItemPreviewView: View {
    @ObservedObject var model: ItemPreviewModel
    let focus: ExplorerFocusCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview").font(.system(size: 13.pt, weight: .semibold)).padding(14.pt)
            PreviewRenderer(model: model, focus: focus)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview pane")
        .accessibilityIdentifier("item-preview-pane")
    }
}

private final class PreviewQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
}

final class PreviewHostView: NSView {
    weak var focus: ExplorerFocusCoordinator?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focus?.focused(.details) }
        return result
    }
}

/// AppKit owns accepted content. Invalidation is synchronous through the model's
/// callback, so SwiftUI scheduling cannot keep an old renderer alive on selection.
struct PreviewRenderer: NSViewRepresentable {
    @ObservedObject var model: ItemPreviewModel
    let focus: ExplorerFocusCoordinator
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.setAccessibilityIdentifier("preview-content")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        context.coordinator.attach(view, focus: focus)
        return view
    }
    func updateNSView(_ view: PreviewHostView, context: Context) {
        context.coordinator.update(model.state)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewHostView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: PreviewHostView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject {
        private let id = UUID()
        private let model: ItemPreviewModel
        private weak var host: PreviewHostView?
        private let ownership = PreviewPresentationOwner()
        private var quickLook: QLPreviewView?
        private var item: PreviewQuickLookItem?
        private var textView: NSTextView?
        private var zoom: PreviewZoomController?
        private var shownState: PreviewState?
        init(model: ItemPreviewModel) { self.model = model; super.init() }
        func attach(_ host: PreviewHostView, focus: ExplorerFocusCoordinator) {
            self.host = host; host.focus = focus
            model.registerRenderer(id: id) { [weak self] in self?.clear() }
            focus.register(.details, owner: host) { [weak self, weak host] in
                guard let host, !host.isHiddenOrHasHiddenAncestor else { return false }
                return host.window?.makeFirstResponder((self?.textView as NSResponder?) ?? host) == true
            }
        }
        func update(_ state: PreviewState) {
            guard state != shownState, let host else { return }
            clear()
            shownState = state
            switch state {
            case .ready(let id):
                guard let presentation = model.takePresentation(id) else { return }
                ownership.accept(presentation) { [weak self] in self?.stopAndDetach() }
                let title = NSTextField(labelWithString: presentation.title)
                title.font = .systemFont(ofSize: 12.pt, weight: .semibold)
                title.lineBreakMode = .byTruncatingMiddle
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                title.setAccessibilityIdentifier("preview-item-name")
                switch presentation.content {
                case .text(let value, let truncated):
                    let scroll = NSScrollView()
                    scroll.hasVerticalScroller = true
                    scroll.drawsBackground = false
                    let text = NSTextView()
                    text.isEditable = false; text.isSelectable = true
                    text.isRichText = false; text.importsGraphics = false
                    text.drawsBackground = false
                    text.textColor = .textColor
                    let baseSize = 12.pt
                    text.font = .monospacedSystemFont(ofSize: baseSize, weight: .regular)
                    text.string = value
                    text.isVerticallyResizable = true; text.isHorizontallyResizable = false
                    text.autoresizingMask = [.width]
                    text.textContainer?.widthTracksTextView = true
                    text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                    text.textContainerInset = NSSize(width: 10.pt, height: 10.pt)
                    text.minSize = .zero
                    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    text.setAccessibilityIdentifier("preview-text")
                    scroll.documentView = text
                    textView = text
                    let note = truncated ? NSTextField(labelWithString: "Showing the first 1 MiB.") : nil
                    note?.setAccessibilityIdentifier("preview-truncated")
                    let zoom = PreviewZoomController(fitsRaster: false) {
                        [weak text] requestedScale, controller in
                        let scale = requestedScale ?? 1
                        text?.font = .monospacedSystemFont(ofSize: baseSize * scale, weight: .regular)
                        controller.update(scale: scale, resetIsRedundant: scale == 1)
                    }
                    self.zoom = zoom
                    install(title: title, zoomRow: zoom.row, body: scroll, footer: note, in: host)
                case .raster(let image):
                    let raster = PreviewRasterView(image: image)
                    let zoom = PreviewZoomController(fitsRaster: true) {
                        [weak raster] scale, _ in raster?.setScale(scale)
                    }
                    raster.onScaleChange = { [weak zoom] scale, fitting in
                        zoom?.update(scale: scale, resetIsRedundant: fitting)
                    }
                    self.zoom = zoom
                    install(title: title, zoomRow: zoom.row, body: raster, footer: nil, in: host)
                case .quickLook:
                    guard presentation.lease.fileURL.isFileURL,
                          let view = QLPreviewView(frame: .zero, style: .compact) else {
                        model.rendererFailed(id, message: "This file could not be presented."); return
                    }
                    view.autostarts = false
                    let item = PreviewQuickLookItem(url: presentation.lease.fileURL, title: presentation.title)
                    self.item = item; quickLook = view
                    let note = presentation.zoomUnavailable
                        ? NSTextField(wrappingLabelWithString: "Zoom is unavailable for this preview.") : nil
                    note?.font = .systemFont(ofSize: 11.pt)
                    note?.textColor = .secondaryLabelColor
                    note?.setAccessibilityIdentifier("preview-zoom-unavailable")
                    install(title: title, body: view, footer: note, in: host)
                    view.previewItem = item
                }
            case .empty: message("Select a file to preview.", in: host)
            case .multiple, .unsupported: message("No preview available.", in: host)
            case .downloading: message("Downloading…", in: host, downloading: true)
            case .preparing: message("Preparing preview…", in: host)
            case .failed(let error):
                message(model.canRetry ? "Couldn’t download this file. \(error)" : "Couldn’t preview this file. \(error)",
                    in: host, retry: model.canRetry)
            }
        }
        private func install(title: NSView, zoomRow: NSView? = nil, body: NSView, footer: NSView?, in host: NSView) {
            let stack = NSStackView(views: [title] + (zoomRow.map { [$0] } ?? []) + [body] + (footer.map { [$0] } ?? []))
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8.pt
            stack.translatesAutoresizingMaskIntoConstraints = false
            body.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12.pt),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12.pt),
                stack.topAnchor.constraint(equalTo: host.topAnchor),
                stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12.pt),
                title.widthAnchor.constraint(equalTo: stack.widthAnchor),
                body.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            title.setContentHuggingPriority(.required, for: .vertical)
            footer?.setContentHuggingPriority(.required, for: .vertical)
            footer?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        private func message(_ text: String, in host: NSView, retry: Bool = false, downloading: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12.pt)
            label.setAccessibilityIdentifier("preview-message")
            var views: [NSView] = [label]
            if downloading {
                let progress = NSProgressIndicator()
                progress.style = .spinning; progress.isIndeterminate = true
                progress.setAccessibilityIdentifier("preview-download-progress")
                progress.startAnimation(nil)
                views.insert(progress, at: 0)
            }
            if retry {
                let button = NSButton(title: "Retry", target: self, action: #selector(retryDownload(_:)))
                button.bezelStyle = .rounded
                button.setAccessibilityIdentifier("preview-retry")
                views.append(button)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12.pt
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20.pt),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20.pt),
                stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                label.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        @objc private func retryDownload(_ sender: NSButton) { model.retry() }
        func clear() {
            if ownership.clear() == nil { stopAndDetach() }
        }
        private func stopAndDetach() {
            // Keep focus in the visible pane when replacing its focused content.
            // A full pane detach hands owned focus to the list before cleanup;
            // unrelated list/address focus must never be moved by invalidation.
            if let host, let window = host.window, let responder = window.firstResponder as? NSView,
               responder !== host, responder.isDescendant(of: host) {
                _ = window.makeFirstResponder(host)
            }
            // close() is terminal and stops Quick Look before its file can be retired.
            quickLook?.autostarts = false
            quickLook?.close()
            quickLook?.removeFromSuperview()
            quickLook = nil; item = nil; textView = nil
            zoom?.invalidate()
            zoom = nil
            host?.subviews.forEach { $0.removeFromSuperview() }
            shownState = nil
        }
        func detach() {
            if let host {
                if let responder = host.window?.firstResponder as? NSView,
                   responder === host || responder.isDescendant(of: host) { _ = host.focus?.focus(.list) }
                host.focus?.unregister(.details, owner: host)
            }
            model.unregisterRenderer(id: id)
            clear()
            host = nil
        }
    }
}

struct InspectorDivider: NSViewRepresentable {
    let width: CGFloat
    let available: CGFloat
    let resize: (CGFloat) -> Void
    func makeNSView(context: Context) -> InspectorDividerView { InspectorDividerView() }
    func updateNSView(_ view: InspectorDividerView, context: Context) {
        view.width = width; view.available = available; view.resize = resize
    }
}

final class InspectorDividerView: NSView {
    var width: CGFloat = 300
    var available: CGFloat = 600
    var resize: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 300
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize inspector pane")
        setAccessibilityIdentifier("inspector-pane-divider")
    }
    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x; startWidth = width }
    override func mouseDragged(with event: NSEvent) {
        change(startWidth + (startX - event.locationInWindow.x) / ExplorerScale.factor)
    }
    private func change(_ proposed: CGFloat) { resize?(max(220, min(600, available, proposed))) }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(width)) }
    override func accessibilityPerformIncrement() -> Bool { change(width + 20); return true }
    override func accessibilityPerformDecrement() -> Bool { change(width - 20); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { change(width + 20) }
        else if event.keyCode == 124 { change(width - 20) }
        else { super.keyDown(with: event) }
    }
}
