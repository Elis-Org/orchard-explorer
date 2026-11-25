import ExplorerCore
import Foundation

/// Window-local transfer presentation. `totalItems`/`completedItems` refer to
/// selected top-level items; counted totals and processed values follow MAC-069.
struct TransferSession: Identifiable {
    let id: UUID
    let kind: TransferKind
    var sourceURLs: [URL]
    let destinationURL: URL
    let totalItems: Int
    var operationLabel: String? = nil
    var isPreparing = false
    var isCounting = false
    var completedItems = 0
    var skippedItems = 0
    var currentName = ""
    /// Cumulative bytes/entries within the current top-level item.
    var bytesCopied: Int64 = 0
    var currentEntries = 0
    var phase = TransferPhase.copying
    /// A same-volume move item is one rename on the single mutation lane and is
    /// never paused inside it (Phase 7); copies and cross-volume moves are.
    var currentItemPausable = true
    var isPaused = false
    var isCancelling = false
    var conflictName: String?
    /// NATIVE-P16 / MAC-070: both versions shown while a conflict awaits a choice.
    var conflict: TransferConflictInfo?
    var replacedItems = 0
    /// nil until counting completes, or when totals are unknown.
    var totals: TransferTotals?
    /// Set when an item proved larger than counted; totals then stay unknown
    /// (indeterminate) rather than ending early or moving backwards (MAC-069).
    var totalsChanged = false
    var currentEntryIndex = 0
    /// Finished (completed or skipped) top-level items' contribution to the
    /// percent basis. Skipped items count here but never as measured data.
    var processedEntries = 0
    var processedBytes: Int64 = 0
    /// Bytes actually copied by finished items; the only input to speed (MAC-069).
    var measuredBytes: Int64 = 0
    var rate = TransferRateEstimator()

    var doneBytes: Int64 { processedBytes + bytesCopied }
    var doneEntries: Int { processedEntries + currentEntries }
    var measuredDoneBytes: Int64 { measuredBytes + bytesCopied }
    /// The current item is committed (published); a pause applies to the next item.
    var isFinishingItem: Bool { phase != .copying }

    /// Percent basis: bytes when the counted byte total is positive, otherwise
    /// entries; nil when totals are unknown. Finished items (copied, renamed or
    /// skipped) contribute their counted totals, so the basis stays consistent.
    var fraction: Double? {
        guard let totals else { return nil }
        if totals.bytes > 0 { return min(1, Double(doneBytes) / Double(totals.bytes)) }
        guard totals.items > 0 else { return nil }
        return min(1, Double(doneEntries) / Double(totals.items))
    }

    var remainingBytes: Int64? { totals.map { max(0, $0.bytes - doneBytes) } }
    var remainingEntries: Int? { totals.map { max(0, $0.items - doneEntries) } }

    /// Only with known totals and a fresh measured speed (MAC-069).
    func secondsRemaining(at now: TimeInterval) -> Double? {
        guard !isPaused, phase == .copying, let remaining = remainingBytes, remaining > 0,
              let speed = rate.bytesPerSecond(at: now), speed > 0 else { return nil }
        return Double(remaining) / speed
    }

    /// Pause/Cancel apply while data is being copied or renamed; removal of
    /// originals after publication is neither pausable nor cancellable (MAC-068).
    var canPause: Bool {
        !isPreparing && !isCounting && !isCancelling && conflictName == nil && phase == .copying && currentItemPausable
    }
    var canCancel: Bool { !isCancelling && phase == .copying }
}

/// Bytes per second over the most recent five seconds of unpaused time; no
/// value until two seconds have been measured (MAC-069).
struct TransferRateEstimator {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var pausedSince: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    static let window: TimeInterval = 5
    static let minimumSpan: TimeInterval = 2

    mutating func record(bytes: Int64, at now: TimeInterval) {
        guard pausedSince == nil else { return }
        let active = now - pausedTotal
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((active, bytes))
        // Strict window (MAC-069): no sample older than five seconds of active time.
        while let first = samples.first, active - first.time > Self.window, samples.count > 1 { samples.removeFirst() }
    }

    mutating func pause(at now: TimeInterval) { if pausedSince == nil { pausedSince = now } }
    mutating func resume(at now: TimeInterval) {
        if let since = pausedSince { pausedTotal += now - since }
        pausedSince = nil
    }

    /// nil while paused, before two seconds of measurement, or when the newest
    /// sample is older than the window (a stall) — never a stale figure.
    func bytesPerSecond(at now: TimeInterval) -> Double? {
        guard pausedSince == nil, let first = samples.first, let last = samples.last,
              (now - pausedTotal) - last.time <= Self.window,
              last.time - first.time >= Self.minimumSpan, last.bytes > first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }
}

enum TransferConflictChoice: Sendable { case replace, skip, keepBoth, cancel }

/// MAC-070/071/073: the incoming item (as captured) and the existing item (read
/// no-follow when the conflict is presented). No contents are compared.
struct TransferConflictInfo: Sendable {
    let name: String
    let incoming: FileItem
    let incomingLocation: URL
    let destinationLocation: URL
    var existing: ConflictEntry?
    var archiveExisting: FileItem?
    var archiveTarget: ArchiveReplacementTarget?
    var inspectionError: String?
    var changedSinceCompared = false
    /// The writer found a folder or other non-replaceable item on either side.
    var replaceRefused = false

    /// Replace only non-folders on both sides (folders are never merged), and
    /// never an item onto itself.
    var canReplace: Bool {
        if let archiveExisting {
            return !replaceRefused && archiveTarget != nil && !archiveExisting.isDirectory
                && !archiveExisting.isSymbolicLink && !incoming.isDirectory && !incoming.isSymbolicLink
        }
        guard !replaceRefused, let existing, existing.target.isReplaceable,
              existing.target.identity != incoming.identity else { return false }
        return !incoming.isDirectory || incoming.isSymbolicLink
    }

    var replaceUnavailableReason: String? {
        guard !canReplace else { return nil }
        if existing == nil && archiveExisting == nil { return "The existing item couldn't be read, so it can't be replaced." }
        if existing?.target.identity == incoming.identity { return "This is the same item." }
        return "Folders can't be replaced or merged."
    }

    var existingKind: String? { archiveExisting?.kind ?? existing?.kindDescription }
    var existingSize: Int64? { archiveExisting?.size ?? existing?.size }
    var existingModified: Date? { archiveExisting?.modifiedAt ?? existing?.modifiedAt }
    var hasComparedEntry: Bool { existing != nil || archiveExisting != nil }
}

func transferCopyName(for item: FileItem, attempt: Int) -> String {
    transferName(for: item, suffix: attempt == 1 ? " - Copy" : " - Copy (\(attempt))")
}

private func transferName(for item: FileItem, suffix: String) -> String {
    let name = item.name as NSString
    let ext = !item.isDirectory && !item.isSymbolicLink && !item.name.hasPrefix(".") ? name.pathExtension : ""
    let stem = ext.isEmpty ? item.name : name.deletingPathExtension
    return stem + suffix + (ext.isEmpty ? "" : "." + ext)
}

/// Naming state only: callers retain conflict inspection, replacement authority,
/// cancellation and publication. The two modes preserve existing route policy.
struct TransferConflictNaming: Sendable {
    enum Mode: Sendable { case physical, archive }
    private let item: FileItem
    private let mode: Mode
    private var usesCopySuffix = false
    private(set) var name: String
    private(set) var attempt = 0

    init(item: FileItem, mode: Mode) {
        self.item = item
        self.mode = mode
        name = item.name
    }

    /// Only ordinary physical collisions automatically advance after Keep Both.
    /// A changed/refused replacement must be inspected again by the caller.
    mutating func advanceAfterCollision() -> Bool {
        guard mode == .physical, attempt > 0, attempt < 10_000 else { return false }
        advance()
        return true
    }

    mutating func keepBoth(sameItem: Bool = false) throws {
        if mode == .archive, attempt >= 10_000 { throw ArchiveOperationError.collision(name) }
        // The initial inspected conflict chooses the style. Later candidates
        // can identify unrelated items without changing a same-item Copy name.
        if attempt == 0 { usesCopySuffix = mode == .archive || sameItem }
        // Physical transfers historically permit an explicit choice after the
        // automatic threshold. Do not silently turn it into the ZIP hard limit.
        advance()
    }

    private mutating func advance() {
        attempt += 1
        name = usesCopySuffix ? transferCopyName(for: item, attempt: attempt)
            : transferName(for: item, suffix: " (\(attempt + 1))")
    }
}

/// Awaits one conflict inspection on the main actor, or abandons it at once on
/// Cancel; a late result is discarded. The read lane abandons the blocking call.
@MainActor
final class ConflictInspectionWaiter {
    private var continuation: CheckedContinuation<Result<ConflictEntry, Error>, Never>?
    private var task: Task<Void, Never>?
    private var finished = false

    func run(_ body: @escaping @Sendable () async throws -> ConflictEntry) async -> Result<ConflictEntry, Error> {
        await withCheckedContinuation { continuation in
            if finished { continuation.resume(returning: .failure(CancellationError())); return }
            self.continuation = continuation
            task = Task { @MainActor [weak self] in
                let result: Result<ConflictEntry, Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                self?.finish(result)
            }
        }
    }

    func abandon() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ConflictEntry, Error>) {
        finished = true
        continuation?.resume(returning: result)
        continuation = nil
    }
}
