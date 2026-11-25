import AppKit
import Combine

/// FR-SEL-005 / AT-SEL-005 / EV-0440. The Windows trace establishes the visible
/// cycle; its UIA focused_element stayed Address Bar, so it is not an AX oracle.
@MainActor
enum ExplorerFocusRegion: CaseIterable, Hashable {
    case list, header, status, tabs, sidebar, details
}

/// One registry per window. Entries never retain their NSView owner. Registration
/// actions must also capture their view/coordinator weakly, as the native adapters do.
@MainActor
final class ExplorerFocusCoordinator: ObservableObject {
    @Published private(set) var currentRegion: ExplorerFocusRegion?

    private final class Registration {
        weak var owner: NSView?
        let action: () -> Bool

        init(owner: NSView, action: @escaping () -> Bool) {
            self.owner = owner
            self.action = action
        }
    }

    private var registrations: [ExplorerFocusRegion: Registration] = [:]
    private final class ContentFocusHandoff {
        weak var window: NSWindow?
        weak var responder: NSResponder?
        weak var owner: NSView?
        weak var outgoingListOwner: NSView?

        init(window: NSWindow, responder: NSResponder, owner: NSView, outgoingListOwner: NSView) {
            self.window = window
            self.responder = responder
            self.owner = owner
            self.outgoingListOwner = outgoingListOwner
        }
    }
    private var pendingContentFocus: ContentFocusHandoff?

    /// A layout replacement may remove the focused table or its header. Remember
    /// only actual content focus, never a historical cycle position or an editor.
    func prepareContentReplacementFocus() {
        pendingContentFocus = nil
        guard let region = inferredRegion(), region == .list || region == .header,
              let owner = registrations[region]?.owner, let window = owner.window,
              let responder = window.firstResponder, !(responder is NSTextView) else { return }
        pendingContentFocus = ContentFocusHandoff(
            window: window, responder: responder, owner: owner,
            outgoingListOwner: registrations[.list]?.owner ?? owner)
    }

    /// Called after registration and attachment. A late callback from a replaced
    /// view cannot consume the request or steal focus from a new user destination.
    func restorePendingContentFocus(owner: NSView) {
        guard let pending = pendingContentFocus else { return }
        guard let originalWindow = pending.window else { pendingContentFocus = nil; return }
        guard registrations[.list]?.owner === owner else { return }
        // The outgoing view can lay out before its replacement registers. Keep
        // that callback from consuming the request, including header focus where
        // the original focused owner is a different view from the outgoing list.
        guard owner !== pending.outgoingListOwner else { return }
        guard let window = owner.window else { return }
        guard window === originalWindow else { pendingContentFocus = nil; return }
        guard isAvailable(owner) else { return }

        let responder = window.firstResponder
        let originalContentStillFocused: Bool
        if let view = responder as? NSView, let previousOwner = pending.owner {
            originalContentStillFocused = view === previousOwner || view.isDescendant(of: previousOwner)
        } else { originalContentStillFocused = false }
        let replacementAlreadyFocused: Bool
        if let view = responder as? NSView {
            replacementAlreadyFocused = view === owner || view.isDescendant(of: owner)
        } else { replacementAlreadyFocused = false }
        let canRestore = !(responder is NSTextView) && (
            responder == nil || responder === window || responder === pending.responder
                || originalContentStillFocused || replacementAlreadyFocused)
        // Clear before dispatch, including a refused attempt, so later lifecycle
        // callbacks cannot move focus after the user chooses another control.
        pendingContentFocus = nil
        guard canRestore else { return }
        _ = focus(.list)
    }

    func register(_ region: ExplorerFocusRegion, owner: NSView, action: @escaping () -> Bool) {
        registrations[region] = Registration(owner: owner, action: action)
    }

    func unregister(_ region: ExplorerFocusRegion, owner: NSView) {
        // A dismantled older representable must not remove its replacement.
        guard registrations[region]?.owner === owner else { return }
        registrations.removeValue(forKey: region)
        if currentRegion == region { currentRegion = nil }
    }

    func focused(_ region: ExplorerFocusRegion) {
        if currentRegion != region { currentRegion = region }
    }

    @discardableResult
    func focus(_ region: ExplorerFocusRegion) -> Bool {
        guard let registration = registrations[region], let owner = registration.owner,
              isAvailable(owner), registration.action() else { return false }
        focused(region)
        return true
    }

    /// Selects the next mounted, visible region whose native focus action succeeds.
    /// If focus is outside registered regions, continue the last cycle position;
    /// a new window without a position starts at the list (sidebar in reverse).
    @discardableResult
    func cycle(backwards: Bool = false) -> Bool {
        registrations = registrations.filter { $0.value.owner != nil }
        let regions = ExplorerFocusRegion.allCases
        let current = inferredRegion() ?? currentRegion
        let step = backwards ? -1 : 1
        let start = current.flatMap { regions.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
        for offset in 1...regions.count {
            let index = (start + step * offset + regions.count * 2) % regions.count
            let region = regions[index]
            if focus(region) { return true }
        }
        return false
    }

    private func isAvailable(_ view: NSView) -> Bool {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor,
              !view.bounds.isEmpty else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return true
    }

    /// MAC-074: the region that owns keyboard focus now, if any.
    var liveRegion: ExplorerFocusRegion? { inferredRegion() }

    private func inferredRegion() -> ExplorerFocusRegion? {
        // Choose the closest registered ancestor, not dictionary order. In
        // particular, a header registered inside a list container wins over it.
        var best: (region: ExplorerFocusRegion, distance: Int)?
        for region in ExplorerFocusRegion.allCases {
            guard let owner = registrations[region]?.owner, isAvailable(owner),
                  let responder = owner.window?.firstResponder as? NSView else { continue }
            var candidate: NSView? = responder
            var distance = 0
            while let view = candidate {
                if view === owner {
                    if best == nil || distance < best!.distance { best = (region, distance) }
                    break
                }
                distance += 1
                candidate = view.superview
            }
        }
        return best?.region
    }
}
