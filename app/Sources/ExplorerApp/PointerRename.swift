import AppKit
import ExplorerCore

/// FR-FILE-022/026–032, FR-NAV-011/012 / EV-0501, EV-0508, EV-0552, EV-0561,
/// EV-0641/0642 / AT-FILE-022/026–032, AT-NAV-011/012 — MAC-076.
///
/// A delayed second-click rename candidate, kept separate from native click
/// classification (`NSEvent.clickCount`) and from active editing. The candidate
/// is armed only after a qualifying single click on an item that was already the
/// sole selection; it fires after the user's double-click interval unless any
/// interruption cancels it, and the store revalidates the target before editing.
/// The delay is a Mac adaptation: the Windows 500 ms / 515 ms samples bound
/// observed outcomes, not a universal threshold.
@MainActor
final class PointerRenameIntent {
    struct Target: Equatable {
        let tabID: UUID
        let directoryURL: URL
        let itemID: String
        let identity: LocalFileIdentity?
        var archiveRevision: ArchiveRevision? = nil
    }

    /// Schedules `work` after `delay` seconds and returns a cancel action.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> (() -> Void)

    static let systemScheduler: Scheduler = { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    private(set) var target: Target?
    private var generation = 0
    private var cancelScheduled: (() -> Void)?
    private let schedule: Scheduler
    private let delay: @MainActor () -> TimeInterval

    init(schedule: Scheduler? = nil,
         delay: @escaping @MainActor () -> TimeInterval = { NSEvent.doubleClickInterval }) {
        // Resolved here, not as a default argument (evaluated outside the main actor).
        self.schedule = schedule ?? Self.systemScheduler
        self.delay = delay
    }

    var isPending: Bool { target != nil }

    func arm(_ target: Target, fire: @escaping @MainActor (Target) -> Void) {
        cancel()
        generation &+= 1
        let token = generation
        self.target = target
        cancelScheduled = schedule(max(0, delay())) { [weak self] in
            // An old callback can never act for a newer or cancelled candidate.
            guard let self, self.generation == token, let armed = self.target, armed == target else { return }
            self.target = nil
            self.cancelScheduled = nil
            fire(armed)
        }
    }

    func cancel() {
        generation &+= 1
        cancelScheduled?()
        cancelScheduled = nil
        target = nil
    }
}
