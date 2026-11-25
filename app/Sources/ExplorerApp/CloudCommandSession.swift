import ExplorerCore
import Foundation

enum CloudCommandPhase: Equatable { case waitingForPreview, queued, downloading, verifying, updatingRetention }

struct CloudCommandProgress: Equatable {
    let itemName: String
    let phase: CloudCommandPhase
    var statusText: String {
        switch phase {
        case .waitingForPreview: return "Waiting for Preview…"
        case .queued: return "Waiting to download…"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .updatingRetention: return "Updating offline retention…"
        }
    }
}

struct CloudDownloadAvailability: Equatable {
    let isEnabled: Bool
    let disabledReason: String?
}

/// Native admission is a fact independent of asynchronous UI delivery.
final class CloudCommandExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var nativeStarted: Bool { lock.withLock { started } }
    func record(_ phase: ContentPreparationPhase) {
        if phase == .downloading { lock.withLock { started = true } }
    }
}

/// User intent is independent of passive directory-load epochs and residency.
struct CloudContentOrigin: Equatable {
    let tabID: UUID
    let location: URL
    let searchID: UUID?
    let searchGeneration: UUID?
    let intentID: UUID
    let url: String
    let identity: LocalFileIdentity?
    let context: ItemOperationContext
    var homeGeneration: UUID? = nil

    func replacingEntry(_ entry: ItemOperationEntry) -> Self {
        Self(tabID: tabID, location: location, searchID: searchID, searchGeneration: searchGeneration,
             intentID: intentID, url: entry.item.url.absoluteString, identity: entry.item.identity, context: entry.context,
             homeGeneration: homeGeneration)
    }
}

@MainActor
final class CloudCommandSession {
    let id = UUID()
    let entry: ItemOperationEntry
    var acceptedEntry: ItemOperationEntry
    var origin: CloudContentOrigin
    let deadline: TimeInterval
    let control = TransferControl()
    let execution = CloudCommandExecutionState()
    var phase: CloudCommandPhase = .queued
    var waitingPreviewID: UUID?
    var task: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var lease: (any MaterializedContentLease)?

    init(entry: ItemOperationEntry, origin: CloudContentOrigin, timeout: TimeInterval) {
        self.entry = entry; acceptedEntry = entry; self.origin = origin
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }
    var remaining: TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
    var timeoutNotice: String {
        if lease != nil { return "Downloaded ‘\(entry.item.name)’. The folder could not be refreshed." }
        if waitingPreviewID != nil { return "Timed out waiting for Preview to finish." }
        return execution.nativeStarted ? ItemContentError.downloadTimedOut.localizedDescription
            : "Timed out waiting to start the download."
    }
    func cancel() { task?.cancel(); task = nil; timer?.cancel(); timer = nil; control.cancel() }
    func releaseLease() {
        guard let lease else { return }
        self.lease = nil
        Task { _ = await lease.release() }
    }
    deinit {
        task?.cancel(); timer?.cancel(); control.cancel()
        if let lease { Task { _ = await lease.release() } }
    }
}

/// This object is carried by the ordinary PendingLoad, never a second loader.
/// Receipt ownership is independent of a renderer's lease and ends with this
/// one attempt/refresh. Core invalidation is synchronous and race-safe.
@MainActor
final class CloudContentHandoff {
    enum Owner: Equatable { case preview(UUID), download(UUID) }
    let owner: Owner
    let requestID: UUID
    let request: PreviewRequest
    let origin: CloudContentOrigin
    let receipt: HydrationReconciliationReceipt?
    private(set) var invalidated = false

    init(owner: Owner, requestID: UUID, request: PreviewRequest, origin: CloudContentOrigin,
         receipt: HydrationReconciliationReceipt?) {
        self.owner = owner; self.requestID = requestID; self.request = request
        self.origin = origin; self.receipt = receipt
    }
    func invalidate() { invalidated = true; receipt?.invalidate() }
    func claim(snapshot: DirectorySnapshot) async throws -> VerifiedHydrationTransition? {
        guard !invalidated, let original = request.entry?.physicalEntry,
              snapshot.directoryIdentity == original.source.directoryIdentity else { throw ItemContentError.staleSource }
        if let receipt {
            return try await receipt.claim(requestID: requestID, originalEntry: original, snapshot: snapshot)
        }
        let rows = snapshot.items.filter { $0.url.absoluteString == original.item.url.absoluteString }
        guard rows.count == 1, rows[0].identity == original.item.identity else { throw ItemContentError.staleSource }
        return nil
    }
    deinit { receipt?.invalidate() }
}
