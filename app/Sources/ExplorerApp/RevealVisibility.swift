import AppKit
import ExplorerCore

/// MAC-REVEAL-VIS-001: a committed external request, independent of selection
/// change notifications. The nonce distinguishes repeated requests for one file.
struct RevealVisibilityRequest: Equatable {
    let id = UUID()
    let tabID: UUID
    let location: URL
    let itemID: String
    let itemIdentity: LocalFileIdentity?
    let directoryIdentity: LocalFileIdentity?
    let selectedIDs: Set<String>

    init(tab: BrowserTab, item: FileItem) {
        tabID = tab.id
        location = tab.url
        itemID = item.id
        itemIdentity = item.identity
        directoryIdentity = tab.directoryIdentity
        selectedIDs = tab.selection.selectedIDs
    }

    func matches(_ tab: BrowserTab) -> Bool {
        tab.id == tabID && tab.url == location && tab.search == nil && !tab.isUnavailable
            && tab.directoryIdentity == directoryIdentity
            && tab.selection.selectedIDs == selectedIDs && tab.selection.focusedID == itemID
            && tab.items.contains { $0.id == itemID && $0.identity == itemIdentity }
    }
}

/// Older queued mode/scale restoration must not overwrite an external reveal,
/// even if its request was consumed before the restoration callback executes.
struct ViewportRestorationGuard {
    private let tabID: UUID
    private let location: URL
    private let searchID: UUID?
    private let mode: FolderViewMode
    private let revealGeneration: UUID?
    private let hadPendingReveal: Bool

    @MainActor init(store: ExplorerStore) {
        tabID = store.activeTabID
        location = store.activeTab.url
        searchID = store.activeSearch?.id
        mode = store.activeTab.viewMode
        revealGeneration = store.activeTab.revealVisibilityGeneration
        hadPendingReveal = store.activeTab.revealVisibilityRequest != nil
    }

    @MainActor func allowsRestoration(in store: ExplorerStore) -> Bool {
        !hadPendingReveal && store.activeTabID == tabID && store.activeTab.url == location
            && store.activeSearch?.id == searchID
            && store.activeTab.viewMode == mode
            && store.activeTab.revealVisibilityGeneration == revealGeneration
            && store.activeTab.revealVisibilityRequest == nil
    }
}

/// Coalesces native update/attachment/layout callbacks. Not-ready views retain
/// intent; one ready attempt consumes it regardless of the geometry diagnostic.
@MainActor
final class RevealVisibilityCoordinator {
    enum Attempt {
        case notReady
        case attempted(visible: Bool)
    }

    private weak var store: ExplorerStore?
    private weak var view: NSView?
    private var tabID: UUID?
    private var location: URL?
    private var requestID: UUID?
    private var mode: FolderViewMode?
    private var renderedItems: [FileItem] = []
    private var attempt: ((String) -> Attempt)?
    private var generation = 0
    private var isScheduled = false
    private var isAttempting = false
    private(set) var lastAttemptWasVisible: Bool?

    func update(store: ExplorerStore, view: NSView, attempt: @escaping (String) -> Attempt) {
        self.store = store
        self.view = view
        tabID = store.activeTabID
        location = store.activeTab.url
        requestID = store.pendingRevealVisibility?.id
        mode = store.activeTab.viewMode
        // Ordinary updates do not need another sort or a retained row snapshot.
        renderedItems = requestID == nil ? [] : store.displayedItems
        self.attempt = attempt
        generation &+= 1
        schedule()
    }

    func schedule() {
        guard !isScheduled, !isAttempting, let requestID,
              store?.pendingRevealVisibility?.id == requestID else { return }
        isScheduled = true
        let scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            guard self.generation == scheduledGeneration else { self.schedule(); return }
            self.performAttempt()
        }
    }

    func invalidate() {
        generation &+= 1
        store = nil
        view = nil
        requestID = nil
        renderedItems = []
        attempt = nil
    }

    private func performAttempt() {
        guard let store, let view, view.window != nil,
              store.activeTabID == tabID, store.activeTab.url == location,
              store.activeTab.viewMode == mode, store.displayedItems == renderedItems,
              let request = store.pendingRevealVisibility, request.id == requestID,
              let attempt else { return }
        isAttempting = true
        defer { isAttempting = false }
        switch attempt(request.itemID) {
        case .notReady:
            break // Only a later native lifecycle event may try again.
        case .attempted(let visible):
            lastAttemptWasVisible = visible
            store.acknowledgeRevealVisibility(request)
        }
    }
}

enum RevealVisibilityGeometry {
    static func viewport(in clip: NSClipView) -> NSRect {
        let bounds = clip.bounds, insets = clip.contentInsets
        return NSRect(x: bounds.minX + insets.left, y: bounds.minY + insets.top,
                      width: bounds.width - insets.left - insets.right,
                      height: bounds.height - insets.top - insets.bottom)
    }

    static func isVisible(_ target: NSRect, in viewport: NSRect) -> Bool {
        guard !target.isEmpty, !viewport.isEmpty else { return false }
        let tolerance = viewport.insetBy(dx: -1, dy: -1)
        let horizontal = target.width <= viewport.width
            ? target.minX >= tolerance.minX && target.maxX <= tolerance.maxX
            : target.maxX > viewport.minX && target.minX < viewport.maxX
        let vertical = target.height <= viewport.height
            ? target.minY >= tolerance.minY && target.maxY <= tolerance.maxY
            : target.maxY > viewport.minY && target.minY < viewport.maxY
        return horizontal && vertical
    }
}
