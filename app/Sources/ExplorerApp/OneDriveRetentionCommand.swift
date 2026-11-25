import ExplorerCore
import Foundation

/// A notice follows the original physical version across passive residency
/// changes. It owns no file handle and grants no permission for another action.
struct DeferredOneDriveRemoval {
    let origin: CloudContentOrigin
    let entry: TransferEntry
    let noticeGeneration: UUID
    let notice: String

    func matches(_ candidate: TransferEntry) -> Bool {
        candidate.source == entry.source && candidate.item.url == entry.item.url
            && candidate.item.identity == entry.item.identity
            && candidate.item.size == entry.item.size && candidate.item.modifiedAt == entry.item.modifiedAt
            && candidate.item.statusVersion == entry.item.statusVersion
    }
}

@MainActor
final class OneDriveRetentionCommand {
    let id = UUID()
    let action: OneDriveRetentionAction
    let entry: ItemOperationEntry
    let origin: CloudContentOrigin
    let control = TransferControl()
    var task: Task<Void, Never>?
    var statusToken: OneDriveStatusRequestToken?

    init(action: OneDriveRetentionAction, entry: ItemOperationEntry, origin: CloudContentOrigin) {
        self.action = action; self.entry = entry; self.origin = origin
    }
    func cancel() { control.cancel(); task?.cancel(); task = nil }
    deinit {
        control.cancel(); task?.cancel()
        let reservationID = id
        Task { @MainActor in OneDriveRetentionActivity.shared.finish(reservationID) }
    }

    static let stoppedNotice = "Stopped waiting for the OneDrive command. It may still finish."
    static func onlineOnlyNotice(name: String) -> String { "‘\(name)’ is online-only." }
    static func notice(_ outcome: OneDriveRetentionOutcome, action: OneDriveRetentionAction, name: String) -> String {
        guard outcome.isConfirmed else { return outcome.message }
        switch (action, outcome.mode) {
        case (.keep, _):
            guard outcome.policy == .pinned else { return outcome.message }
        case (.freeSpace, .stopped):
            guard outcome.policy == .unpinned else { return outcome.message }
        case (.freeSpace, .running):
            guard (outcome.policy == OneDriveRetentionPolicy.none || outcome.policy == .unpinned),
                  outcome.isDataless == true else { return outcome.message }
            return onlineOnlyNotice(name: name)
        }
        switch (action, outcome.isDataless) {
        case (.keep, false?): return "Always kept on this device: ‘\(name)’."
        case (.keep, true?): return "Pinned ‘\(name)’. Local contents are not downloaded yet."
        case (.keep, nil): return "Pinned ‘\(name)’. Local availability is unconfirmed."
        case (.freeSpace, false?): return "Released offline retention for ‘\(name)’. Local contents are still present."
        case (.freeSpace, true?): return "Released offline retention for ‘\(name)’. Local contents were removed."
        case (.freeSpace, nil): return "Released offline retention for ‘\(name)’. Local availability is unconfirmed."
        }
    }
}

/// One explicit retention command across windows. This closes the gap before
/// native admission; the backend remains authoritative until its child exits.
/// Stores are weakly observed, as with archive mutation notifications.
@MainActor
final class OneDriveRetentionActivity {
    static let shared = OneDriveRetentionActivity()
    private struct Observer { weak var store: ExplorerStore? }
    private struct Reservation {
        let id: UUID
        let target: PhysicalContentTarget
        let provider: any OneDriveRetentionProviding
    }
    private var observers: [Observer] = []
    private var reservation: Reservation?
    private var completion: Task<Void, Never>?

    func observe(_ store: ExplorerStore) {
        observers.removeAll { $0.store == nil }
        observers.append(Observer(store: store))
    }
    var isBusy: Bool { reservation != nil }
    func blocks(_ target: PhysicalContentTarget) -> Bool { reservation?.target.conflicts(with: target) == true }
    func hasContentUse(of target: PhysicalContentTarget) -> Bool {
        PhysicalContentUse.shared.isInUse(of: target)
            || observers.contains { $0.store?.hasContentUseForRetention(of: target) == true }
    }
    func begin(_ command: OneDriveRetentionCommand, provider: any OneDriveRetentionProviding) -> Bool {
        guard let entry = command.entry.physicalEntry else { return false }
        let target = PhysicalContentTarget(entry)
        guard reservation == nil, !provider.isBusy, !hasContentUse(of: target) else { return false }
        reservation = Reservation(id: command.id, target: target, provider: provider)
        OneDriveBadgeCache.shared.retentionChanged(target: target, isBusy: true)
        command.statusToken = OneDriveBadgeCache.shared.beginOperation(for: entry)
        for observer in observers { observer.store?.retentionActivityChanged(blocking: target) }
        return true
    }
    func finish(_ id: UUID) {
        guard let current = reservation, current.id == id else { return }
        completion?.cancel()
        if !current.provider.isBusy { release(id); return }
        // Cancelling the UI waiter never releases a still-running native child.
        completion = Task { [weak self] in
            while current.provider.isBusy {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            self?.release(id)
        }
    }
    private func release(_ id: UUID) {
        guard let finished = reservation, finished.id == id else { return }
        reservation = nil; completion = nil
        OneDriveBadgeCache.shared.retentionChanged(target: finished.target, isBusy: false)
        observers.removeAll { $0.store == nil }
        for observer in observers { observer.store?.retentionActivityChanged(blocking: nil) }
    }
}
