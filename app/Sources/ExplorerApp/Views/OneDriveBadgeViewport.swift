import AppKit
import ExplorerCore

/// Native viewport demand only. Provider work and freshness belong to the Store.
/// A mount keeps its own token so late teardown cannot remove its replacement.
@MainActor
final class OneDriveBadgeViewport: NSObject {
    let owner = UUID()
    private weak var view: NSView?
    private weak var clip: NSClipView?
    private weak var observedWindow: NSWindow?
    private var items: (() -> [FileItem])?
    private var report: ((UUID, [FileItem]) -> Void)?
    private var remove: ((UUID) -> Void)?
    private var generation = 0
    private var scheduled = false
    private var reported = false
    private var lastActive = false

    override init() {
        super.init()
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowsUpdated),
            name: NSApplication.didUpdateNotification, object: nil)
    }

    func update(view: NSView, items: @escaping () -> [FileItem],
                report: @escaping (UUID, [FileItem]) -> Void,
                remove: @escaping (UUID) -> Void) {
        if self.view !== view { invalidate() }
        self.view = view
        self.items = items
        self.report = report
        self.remove = remove
        let nextClip = view.enclosingScrollView?.contentView
        if clip !== nextClip {
            if let clip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) }
            clip = nextClip
            if let clip {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        schedule()
    }

    @objc private func boundsChanged(_ notification: Notification) { schedule() }

    private var isActive: Bool {
        guard let view, let window = view.window else { return false }
        return window.isVisible && !window.isMiniaturized && !NSApp.isHidden && !view.isHiddenOrHasHiddenAncestor
    }

    // Ordering need not emit an occlusion event. AppKit's after-event window
    // update provides a fallback, with work only when displayed state changes.
    @objc private func windowsUpdated(_ notification: Notification) {
        if isActive != lastActive { schedule() }
    }

    func schedule() {
        observeWindow()
        lastActive = isActive
        guard lastActive else {
            if reported { remove?(owner); reported = false }
            return
        }
        guard !scheduled else { return }
        scheduled = true
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            self.scheduled = false
            guard let view = self.view, let window = view.window, window.isVisible, !window.isMiniaturized,
                  !NSApp.isHidden, !view.isHiddenOrHasHiddenAncestor,
                  !view.visibleRect.isEmpty else {
                if self.reported { self.remove?(self.owner); self.reported = false }
                return
            }
            self.reported = true
            self.report?(self.owner, self.items?() ?? [])
        }
    }

    private func observeWindow() {
        let next = view?.window
        guard observedWindow !== next else { return }
        if let observedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow) }
        observedWindow = next
        if let next {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: name, object: next)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing),
                name: NSWindow.willCloseNotification, object: next)
        }
    }

    @objc private func windowClosing(_ notification: Notification) { invalidate() }

    func invalidate() {
        generation &+= 1
        scheduled = false
        if let clip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) }
        if let observedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow) }
        if reported { remove?(owner) }
        reported = false
        lastActive = false
        view = nil; clip = nil; observedWindow = nil; items = nil; report = nil; remove = nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
