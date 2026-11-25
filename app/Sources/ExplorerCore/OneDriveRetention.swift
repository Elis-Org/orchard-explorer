import AppKit
import Darwin
import Foundation
import Security

public enum OneDriveRetentionAction: Equatable, Sendable { case keep, freeSpace }
public enum OneDriveRetentionPolicy: String, Equatable, Sendable { case none, pinned, unpinned }
public enum OneDriveSyncState: Equatable, Sendable { case running, stopped, unknown }
public enum OneDriveRetentionMode: Equatable, Sendable { case running, stopped }

public struct OneDriveBadgeObservation: Equatable, Sendable {
    public let policy: OneDriveRetentionPolicy
    public let isDataless: Bool
    public init(policy: OneDriveRetentionPolicy, isDataless: Bool) {
        self.policy = policy; self.isDataless = isDataless
    }
}

/// A display-only proof constructed inside the native verifier. Optional loose
/// outcome fields and a success flag are not interchangeable with this binding.
public struct OneDriveVerifiedStatus: Equatable, Sendable {
    public let entry: TransferEntry
    public let sampledVersion: LocalFileStatusVersion
    public let policy: OneDriveRetentionPolicy?
    public let isDataless: Bool?

    init?(entry: TransferEntry, sampledVersion: LocalFileStatusVersion,
          policy: OneDriveRetentionPolicy?, isDataless: Bool?) {
        guard entry.item.identity != nil, entry.item.statusVersion == sampledVersion,
              policy != nil || isDataless != nil else { return nil }
        self.entry = entry; self.sampledVersion = sampledVersion
        self.policy = policy; self.isDataless = isDataless
    }

    public func matches(_ other: TransferEntry) -> Bool {
        entry.item.identity != nil && entry.item.identity == other.item.identity
            && entry.source.directoryIdentity == other.source.directoryIdentity
            && entry.source.directoryURL.absoluteString.utf8.elementsEqual(other.source.directoryURL.absoluteString.utf8)
            && entry.item.url.absoluteString.utf8.elementsEqual(other.item.url.absoluteString.utf8)
            && entry.item.name.utf8.elementsEqual(other.item.name.utf8)
            && other.item.statusVersion == sampledVersion
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.source == rhs.entry.source && lhs.entry.item == rhs.entry.item
            && lhs.sampledVersion == rhs.sampledVersion && lhs.policy == rhs.policy
            && lhs.isDataless == rhs.isDataless
    }
}

public struct OneDriveRetentionOutcome: Equatable, Sendable {
    public let policy: OneDriveRetentionPolicy?
    public let isDataless: Bool?
    public let providerVersion: String
    public let isConfirmed: Bool
    /// The provider accepted this Free request, but its local copy was still resident at the final check.
    public let removalDeferred: Bool
    public let message: String
    public let mode: OneDriveRetentionMode
    public let verifiedStatus: OneDriveVerifiedStatus?
    public init(policy: OneDriveRetentionPolicy?, isDataless: Bool?, providerVersion: String,
                isConfirmed: Bool, message: String, mode: OneDriveRetentionMode = .stopped,
                removalDeferred: Bool = false, verifiedStatus: OneDriveVerifiedStatus? = nil) {
        self.policy = policy; self.isDataless = isDataless; self.providerVersion = providerVersion
        self.isConfirmed = isConfirmed; self.message = message
        self.mode = mode
        self.removalDeferred = removalDeferred
        self.verifiedStatus = verifiedStatus
    }
}

public enum OneDriveRetentionError: Error, Equatable, LocalizedError, Sendable {
    case busy, syncRunning, syncStateUnknown, syncStateChanged, contentInUse, unsupportedTarget, untrustedApplication, staleTarget, uploadUnconfirmed, providerRejected
    case timedOut(setterSubmitted: Bool), cancelled(setterSubmitted: Bool)
    case timedOutAfterClear, cancelledAfterClear
    public var errorDescription: String? {
        switch self {
        case .busy: return "A OneDrive command is still running. Try again when it finishes, or manage this file in Finder."
        case .syncRunning: return "Quit OneDrive to use this action, or use Finder."
        case .syncStateUnknown: return "OneDrive's running state could not be verified. Try again, or manage this file in Finder."
        case .syncStateChanged: return "OneDrive's running state changed during the request. Its result is unconfirmed."
        case .contentInUse: return "Wait for Preview or Download to finish using this file."
        case .unsupportedTarget: return "This action supports one regular OneDrive file."
        case .untrustedApplication: return "The supported signed OneDrive application could not be verified."
        case .staleTarget: return "The file or its folder changed. No retention change was submitted."
        case .uploadUnconfirmed: return "Upload completion and conflict-free state could not be verified. No retention change was submitted."
        case .providerRejected: return "OneDrive did not accept this file or command."
        case .timedOut(let submitted):
            return submitted ? "Stopped waiting for OneDrive. It may still be changing the file; the result is unconfirmed."
                : "Timed out before submitting a retention change. A OneDrive query may still be running."
        case .cancelled(let submitted):
            return submitted ? "Stopped waiting for OneDrive. It may still be changing the file; the result is unconfirmed."
                : "Stopped before submitting a retention change."
        case .timedOutAfterClear:
            return "OneDrive confirmed the file’s unpinned policy. Timed out waiting for local removal; OneDrive may still be changing the file."
        case .cancelledAfterClear:
            return "OneDrive confirmed the file’s unpinned policy. Stopped waiting for local removal; OneDrive may still be changing the file."
        }
    }
}

public protocol OneDriveRetentionProviding: Sendable {
    var syncIsRunning: Bool { get }
    var syncState: OneDriveSyncState { get }
    var isBusy: Bool { get }
    func perform(_ action: OneDriveRetentionAction, on entry: TransferEntry,
                 control: TransferControl) async throws -> OneDriveRetentionOutcome
}

public extension OneDriveRetentionProviding {
    var syncState: OneDriveSyncState { syncIsRunning ? .running : .stopped }
}

/// Local trust and filesystem stamps used to scope a display-only history entry.
public struct OneDrivePolicyHistoryNamespace: Sendable {
    public let root: URL
    public let identity: LocalFileIdentity
    public let providerIdentifier: String
    public let providerVersion: String
    public let providerStamp: String
}

/// Explicit provider policy only. It never starts/stops the sync app, sends a
/// signal to its children, reads payloads, or equates unpinning with eviction.
public final class OneDriveRetentionService: OneDriveRetentionProviding, @unchecked Sendable {
    public static let shared = OneDriveRetentionService(environment: .live, slot: OneDriveRetentionSlot())
    private let environment: OneDriveRetentionEnvironment
    private let slot: OneDriveRetentionSlot
    private let timeoutSeconds: TimeInterval
    private let passiveTimeoutSeconds: TimeInterval
    private let priorityWaitSeconds: TimeInterval
    private let passiveTrust = OneDrivePassiveTrust()
    // The slot admits at most one native owner and one waiting explicit worker.
    private let worker = DispatchQueue(label: "nativeExplorer.oneDriveRetention", qos: .userInitiated)
    private let passiveWorker = DispatchQueue(label: "nativeExplorer.oneDriveBadges", qos: .utility)

    init(environment: OneDriveRetentionEnvironment, slot: OneDriveRetentionSlot,
         timeoutSeconds: TimeInterval = 60, passiveTimeoutSeconds: TimeInterval = 10,
         priorityWaitSeconds: TimeInterval = 10) {
        self.environment = environment; self.slot = slot; self.timeoutSeconds = timeoutSeconds
        self.passiveTimeoutSeconds = min(10, passiveTimeoutSeconds)
        self.priorityWaitSeconds = min(10, priorityWaitSeconds)
    }
    public var syncState: OneDriveSyncState {
        // Process.run can block before it supplies a PID to register. Absence is
        // not established during this small (or stalled) launch interval.
        if slot.isLaunching { return .unknown }
        return environment.syncState(slot.ownedPIDs)
    }
    public var syncIsRunning: Bool { syncState != .stopped }
    public var isBusy: Bool { slot.isBusy }

    private func operatingMode() throws -> OneDriveRetentionMode {
        switch syncState {
        case .running: return .running
        case .unknown: throw OneDriveRetentionError.syncStateUnknown
        case .stopped: return .stopped
        }
    }

    private func requireMode(_ mode: OneDriveRetentionMode) throws {
        guard try operatingMode() == mode else { throw OneDriveRetentionError.syncStateChanged }
    }

    /// Cheap menu hint, never provider authority. No filesystem or provider I/O.
    public static func isCandidate(_ item: FileItem,
                                   homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        item.availability != .unknown && isBadgeCandidate(item, homeURL: homeURL)
    }

    /// Metadata already captured by the listing/search, not a filesystem probe.
    public static func isBadgeCandidate(_ item: FileItem,
                                        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard item.url.isFileURL, item.isRegularFile == true, !item.isDirectory, !item.isSymbolicLink,
              item.identity?.linkCount == 1,
              item.name == item.url.lastPathComponent, !item.name.contains("\0") else { return false }
        return isBadgeLocation(item.url.deletingLastPathComponent(), homeURL: homeURL)
    }

    public static func isBadgeLocation(_ folder: URL,
                                       homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        accountRoot(in: folder, homeURL: homeURL) != nil
    }

    /// Pure lexical candidate/presentation hint; never provider ownership proof.
    public static func accountRoot(in folder: URL,
                                   homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard folder.isFileURL else { return nil }
        let base = homeURL.standardizedFileURL.appendingPathComponent("Library/CloudStorage").pathComponents
        let path = folder.standardizedFileURL.pathComponents
        guard path.count > base.count, Array(path.prefix(base.count)) == base else { return nil }
        let provider = path[base.count]
        guard provider == "OneDrive" || (provider.hasPrefix("OneDrive-") && provider.count > "OneDrive-".count) else { return nil }
        return homeURL.standardizedFileURL.appendingPathComponent("Library/CloudStorage")
            .appendingPathComponent(provider, isDirectory: true)
    }

    /// Display history is scoped to the currently observed physical OneDrive root and signed app.
    /// This metadata read never reserves the provider command slot.
    public func policyHistoryNamespace(for root: URL) async -> OneDrivePolicyHistoryNamespace? {
        guard Self.accountRoot(in: root, homeURL: environment.homeURL)?.absoluteString == root.absoluteString else { return nil }
        return try? await BlockingIO.run(on: .read) { [self] _ in
            guard root.resolvingSymlinksInPath().path == root.path else { throw OneDriveRetentionError.staleTarget }
            let values = try root.resourceValues(forKeys: [.volumeIsLocalKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.volumeIsLocal == true, values.isDirectory == true, values.isSymbolicLink == false,
                  let identity = try LocalFileIdentity.read(at: root, ifLocal: true) else {
                throw OneDriveRetentionError.staleTarget
            }
            let app = try passiveTrust.application(in: environment)
            guard !app.version.isEmpty, !app.stamp.isEmpty,
                  try LocalFileIdentity.read(at: root, ifLocal: true) == identity else { throw OneDriveRetentionError.staleTarget }
            return OneDrivePolicyHistoryNamespace(root: root, identity: identity, providerIdentifier: "com.microsoft.OneDrive",
                                                  providerVersion: app.version, providerStamp: app.stamp)
        }
    }

    public func perform(_ action: OneDriveRetentionAction, on entry: TransferEntry,
                        control: TransferControl) async throws -> OneDriveRetentionOutcome {
        try Task.checkCancellation()
        guard slot.reserveExplicit() else { throw OneDriveRetentionError.busy }
        let attempt = OneDriveRetentionAttempt(control: control)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                attempt.install(continuation, timeoutSeconds: timeoutSeconds)
                // The worker owns the reservation even if its waiter stops before
                // this closure starts, or a native child outlives the UI deadline.
                worker.async { [self] in
                    let result = Result {
                        try slot.enterExplicit(waitSeconds: priorityWaitSeconds, checkpoint: { try attempt.checkpoint(control) })
                        return try execute(action, entry: entry, control: control, attempt: attempt)
                    }
                    slot.releaseExplicit()
                    attempt.finish(result)
                }
            }
        }, onCancel: { attempt.cancel() })
    }

    /// Read-only policy evidence, never action authority. No content or upload
    /// metadata reads, no sync-client shutdown requirement, and no passive queue.
    public func badgeObservation(for entry: TransferEntry) async throws -> OneDriveBadgeObservation {
        try Task.checkCancellation()
        guard slot.acquirePassive() else { throw OneDriveBadgeReadError.busy }
        let control = TransferControl()
        let attempt = OneDriveRetentionAttempt(control: control)
        let value: OneDriveRetentionOutcome
        do {
            value = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    attempt.install(continuation, timeoutSeconds: passiveTimeoutSeconds)
                    passiveWorker.async { [self] in
                        let result = Result { try executeBadge(entry, control: control, attempt: attempt) }
                        slot.releasePassive()
                        attempt.finish(result)
                    }
                }
            }, onCancel: { attempt.cancel() })
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw OneDriveBadgeReadError.classify(error)
        }
        try Task.checkCancellation()
        guard let policy = value.policy, let isDataless = value.isDataless else {
            throw OneDriveBadgeReadError.incompatibleResponse
        }
        return .init(policy: policy, isDataless: isDataless)
    }

    private func executeBadge(_ entry: TransferEntry, control: TransferControl,
                              attempt: OneDriveRetentionAttempt) throws -> OneDriveRetentionOutcome {
        try attempt.checkpoint(control)
        guard Self.isBadgeCandidate(entry.item, homeURL: environment.homeURL) else {
            throw OneDriveRetentionError.unsupportedTarget
        }
        let target = try OneDriveRetentionTarget(entry)
        guard target.matchesListedStatusVersion else { throw OneDriveRetentionError.staleTarget }
        _ = try target.readResidency()
        let application = try passiveTrust.application(in: environment)
        try attempt.checkpoint(control)
        let transcript = try environment.run(application, .query, target.url.path, attempt, control, slot, {
            guard try self.passiveTrust.application(in: self.environment) == application else {
                throw OneDriveRetentionError.untrustedApplication
            }
            _ = try target.readResidency()
            try attempt.checkpoint(control)
        })
        defer { if let pid = transcript.ownedPID { slot.child(pid, started: false) } }
        try attempt.checkpoint(control)
        guard try passiveTrust.application(in: environment) == application else {
            throw OneDriveRetentionError.untrustedApplication
        }
        let isDataless = try target.readResidency()
        try attempt.checkpoint(control)
        switch OneDriveRetentionTranscript.query(transcript) {
        case .policy(let policy):
            return .init(policy: policy, isDataless: isDataless, providerVersion: application.version,
                         isConfirmed: true, message: "OneDrive file policy observed.")
        case .rejected: throw OneDriveBadgeReadError.itemRejected
        case .unknown, .accepted: throw OneDriveBadgeReadError.incompatibleResponse
        }
    }

    private func execute(_ action: OneDriveRetentionAction, entry: TransferEntry,
                         control: TransferControl, attempt: OneDriveRetentionAttempt) throws -> OneDriveRetentionOutcome {
        let contentTarget = PhysicalContentTarget(entry)
        var application: OneDriveRetentionApplication?
        var last: OneDriveRetentionObservation?
        var mode = OneDriveRetentionMode.stopped
        var verifiedUnpinned = false
        var evictionAttempted = false
        func unconfirmed(_ message: String, policy: OneDriveRetentionPolicy? = nil,
                         availability: Bool? = nil) -> OneDriveRetentionOutcome {
            let prefix = verifiedUnpinned ? "OneDrive confirmed the file’s unpinned policy. " : ""
            return .init(policy: policy, isDataless: availability, providerVersion: application?.version ?? "Unknown",
                         isConfirmed: false, message: prefix + message, mode: mode)
        }
        do {
            try attempt.checkpoint(control)
            mode = try operatingMode()
            guard !PhysicalContentUse.shared.isInUse(of: contentTarget) else { throw OneDriveRetentionError.contentInUse }
            application = try environment.verifyApplication()
            guard Self.isCandidate(entry.item, homeURL: environment.homeURL) else { throw OneDriveRetentionError.unsupportedTarget }
            let target = try OneDriveRetentionTarget(entry)
            let capturedMode = mode
            let checkpoint: @Sendable () throws -> Void = { [self] in
                try attempt.checkpoint(control)
                try requireMode(capturedMode)
                guard !PhysicalContentUse.shared.isInUse(of: contentTarget) else { throw OneDriveRetentionError.contentInUse }
                _ = try target.sample()
                try attempt.checkpoint(control)
            }
            func verifyApplication() throws -> OneDriveRetentionApplication {
                guard let captured = application, try environment.verifyApplication() == captured else {
                    throw OneDriveRetentionError.untrustedApplication
                }
                return captured
            }
            func inspect(_ needsUpload: Bool = false) throws {
                try checkpoint()
                let observation = try environment.inspect(target, needsUpload)
                try checkpoint()
                last = observation
                if needsUpload, !observation.safeToEvict { throw OneDriveRetentionError.uploadUnconfirmed }
            }
            func run(_ command: OneDriveRetentionCommand) throws -> OneDriveRetentionTranscript {
                try checkpoint()
                let captured = try verifyApplication()
                // No pathname operation claims atomic authority over the provider's
                // later lookup. Each next phase still requires the original version.
                try checkpoint()
                let result = try environment.run(captured, command, target.url.path, attempt, control, slot, { [self] in
                    try checkpoint()
                    if capturedMode == .running && command == .freeSpace {
                        // The signed /unpin request can evict before the child process returns.
                        guard try environment.inspect(target, true).safeToEvict else {
                            throw OneDriveRetentionError.uploadUnconfirmed
                        }
                        guard try environment.verifyApplication() == captured else {
                            throw OneDriveRetentionError.untrustedApplication
                        }
                        try checkpoint()
                    }
                })
                defer { if let pid = result.ownedPID { slot.child(pid, started: false) } }
                try checkpoint()
                return result
            }
            func query() throws -> OneDriveRetentionPolicy? {
                let transcript = try run(.query)
                try inspect()
                switch OneDriveRetentionTranscript.query(transcript) {
                case .policy(let policy): return policy
                case .rejected: throw OneDriveRetentionError.providerRejected
                default: return nil
                }
            }
            func confirmed(_ policy: OneDriveRetentionPolicy) throws -> OneDriveRetentionOutcome {
                try checkpoint()
                return .init(policy: policy, isDataless: last?.isDataless, providerVersion: application!.version,
                             isConfirmed: true, message: "OneDrive retention policy and availability observed.", mode: mode,
                             verifiedStatus: target.verifiedStatus(policy: policy, expectedDataless: last?.isDataless))
            }
            func accepted(_ transcript: OneDriveRetentionTranscript) -> Bool {
                OneDriveRetentionTranscript.setter(transcript) == .accepted
            }
            try inspect()
            guard var policy = try query() else {
                return unconfirmed("OneDrive's file policy could not be confirmed. No retention change was submitted.")
            }
            if mode == .stopped || action == .keep {
                // Running Keep is idempotent; the established stopped path keeps
                // its existing explicit /pin and /unpin behavior.
                if mode == .running, policy == .pinned { return try confirmed(policy) }
                try inspect(action == .freeSpace)
                let setter = try run(action == .keep ? .keep : .freeSpace)
                guard accepted(setter) else {
                    return unconfirmed("OneDrive did not confirm acceptance of the submitted retention request. No further change was attempted.")
                }
                guard let observed = try query() else {
                    return unconfirmed("The retention request was submitted, but its resulting policy could not be confirmed.")
                }
                let desired: OneDriveRetentionPolicy = action == .keep ? .pinned : .unpinned
                guard observed == desired else {
                    return unconfirmed("OneDrive has not confirmed the requested retention policy.",
                                       policy: observed, availability: last?.isDataless)
                }
                return try confirmed(observed)
            }

            if policy != .pinned, last?.isDataless == true { return try confirmed(policy) }
            if policy != .unpinned {
                let request = try run(.freeSpace)
                guard accepted(request) else {
                    return unconfirmed("OneDrive did not confirm acceptance of the online-only request. Local removal is unconfirmed.")
                }
                guard let observed = try query(), observed == .unpinned else {
                    return unconfirmed("OneDrive’s unpinned policy could not be confirmed after the request. Local removal is unconfirmed.")
                }
                try attempt.recordVerifiedUnpinned(control: control)
                verifiedUnpinned = true
                policy = observed
            }
            // The provider may leave the original file resident after accepting /unpin.
            for evictionIndex in 0...OneDriveEvictionFailure.retryDelays.count {
                if evictionIndex > 0 {
                    // Only a definite synchronous lock refusal reaches this path.
                    // Never repeat a setter or adopt a replacement while waiting.
                    try environment.waitAfterBusy(OneDriveEvictionFailure.retryDelays[evictionIndex - 1], attempt, control)
                    try checkpoint()
                    guard let observed = try query() else {
                        return unconfirmed("The file’s unpinned policy could not be reconfirmed. No further local-removal request was made.")
                    }
                    guard observed == .unpinned else {
                        let message = observed == .pinned ? "The file was pinned again." : "The file’s OneDrive policy changed."
                        return unconfirmed(message + " No further local-removal request was made.",
                                           policy: observed, availability: last?.isDataless)
                    }
                    policy = observed
                }
                if last?.isDataless == true { return try confirmed(policy) }
                try inspect(true)
                if last?.isDataless == true { return try confirmed(policy) }
                _ = try verifyApplication()
                try checkpoint()
                do {
                    // Every invocation has independent admission. Even a throwing
                    // call may have submitted a side effect. No coordinator or
                    // leaf FD spans this call, and the worker still owns its slot.
                    try attempt.submitEviction(control: control) {
                        evictionAttempted = true
                        try environment.evict(target.url)
                    }
                    break
                } catch {
                    let failure = OneDriveEvictionFailure(error)
                    failure.trace(attempt: evictionIndex + 1)
                    try checkpoint()
                    if failure.isRetryable, evictionIndex < OneDriveEvictionFailure.retryDelays.count { continue }
                    if failure.isRetryable && verifiedUnpinned {
                        // File Provider can finish the original request while APFS is returning EBUSY.
                        // query() also resamples the original file's residency after reading its policy.
                        guard let current = try query(), let observation = last else {
                            return unconfirmed("The current policy and local removal could not be reconfirmed.")
                        }
                        guard current == .unpinned else {
                            return unconfirmed("The file’s OneDrive policy changed. Local removal is unconfirmed.",
                                               policy: current, availability: observation.isDataless)
                        }
                        if observation.isDataless { return try confirmed(current) }
                        try checkpoint()
                        return .init(
                            policy: current, isDataless: false, providerVersion: application?.version ?? "Unknown",
                            isConfirmed: false, message: "OneDrive has unpinned this file. It is still on this device. " +
                                "OneDrive may finish removing the local copy in the background.",
                            mode: mode, removalDeferred: true,
                            verifiedStatus: target.verifiedStatus(policy: current, expectedDataless: false)
                        )
                    }
                    if failure.isLockRefusal {
                        return unconfirmed("macOS reported that the local copy was busy. Local removal is unconfirmed.")
                    }
                    throw error
                }
            }
            try checkpoint()
            guard let observed = try query() else {
                return unconfirmed("Local removal was requested, but its resulting policy and availability are unconfirmed.")
            }
            guard observed == .unpinned, last?.isDataless == true else {
                return unconfirmed("Local removal is unconfirmed; local contents may still be present.",
                                   policy: observed, availability: last?.isDataless)
            }
            return try confirmed(observed)
        } catch {
            if attempt.setterSubmitted {
                if error is CancellationError { throw attempt.cancellationError }
                if error as? OneDriveRetentionError == .staleTarget || error is FileOperationError {
                    return unconfirmed("The retention request was submitted, but the file changed during the request. Refresh to observe its current policy and availability.")
                }
                if error as? OneDriveRetentionError == .syncStateChanged {
                    return unconfirmed("OneDrive's running state changed during the request; its result is unconfirmed.")
                }
                if error as? OneDriveRetentionError == .syncStateUnknown {
                    return unconfirmed("OneDrive's running state could not be verified after the request; its result is unconfirmed.")
                }
                if verifiedUnpinned, error as? OneDriveRetentionError == .uploadUnconfirmed {
                    return unconfirmed("Upload completion and conflict-free state could not be reconfirmed. " +
                                       (evictionAttempted ? "No further local-removal request was made." : "No additional local-removal request was made."))
                }
                return unconfirmed("The retention request was submitted, but its result could not be verified. " + error.localizedDescription)
            }
            if error is FileOperationError { throw OneDriveRetentionError.staleTarget }
            throw error
        }
    }

}

/// Closed error allowlist for the observed synchronous eviction refusal. The
/// diagnostic never contains localized descriptions, arbitrary domains or paths.
struct OneDriveEvictionFailure {
    static let retryDelays: [TimeInterval] = [2, 6]
    let isRetryable: Bool
    let isLockRefusal: Bool
    let diagnostic: String

    init(_ error: Error) {
        let root = error as NSError
        var nodes: [NSError] = [], seen = Set<ObjectIdentifier>()
        var current: NSError? = root
        var validChain = true
        while let node = current {
            guard nodes.count < 4, seen.insert(ObjectIdentifier(node)).inserted else {
                validChain = false; break
            }
            nodes.append(node)
            // Presence itself is outside the approved single-cause contract,
            // including an empty, malformed, single-entry or mixed array.
            if node.userInfo[NSMultipleUnderlyingErrorsKey] != nil { validChain = false }
            if let cause = node.userInfo[NSUnderlyingErrorKey] {
                guard let cause = cause as? Error else { validChain = false; break }
                current = cause as NSError
            } else { current = nil }
        }
        func posixBusy(_ node: NSError) -> Bool { node.domain == NSPOSIXErrorDomain && node.code == Int(EBUSY) }
        let cocoaLock = root.domain == NSCocoaErrorDomain && root.code == NSFileLockingError
        isLockRefusal = cocoaLock || posixBusy(root)
        isRetryable = validChain && ((nodes.count == 1 && isLockRefusal) ||
                                     (nodes.count == 2 && cocoaLock && posixBusy(nodes[1])))
        let chain = nodes.map { node in
            let domain = node.domain == NSCocoaErrorDomain ? "cocoa" : node.domain == NSPOSIXErrorDomain ? "posix" : "other"
            return "\(domain):\(node.code)"
        }.joined(separator: ">")
        diagnostic = "chain=\(chain) singleCause=\(validChain) retryable=\(isRetryable)"
    }

    func trace(attempt: Int) {
        guard ProcessInfo.processInfo.environment["MAXPLORER_RETENTION_GATE_TRACE"] == "1" else { return }
        try? FileHandle.standardError.write(contentsOf: Data("Maxplorer retention eviction: attempt=\(attempt) \(diagnostic)\n".utf8))
    }
}

enum OneDriveRetentionCommand: Equatable, Sendable {
    case query, keep, freeSpace
    var argument: String { switch self { case .query: "/getpin"; case .keep: "/pin"; case .freeSpace: "/unpin" } }
}

struct OneDriveRetentionTranscript: Sendable {
    let exitCode: Int32, stdout: Data, stderr: Data
    var truncated = false
    var ownedPID: Int32? = nil
    enum Classification: Equatable { case policy(OneDriveRetentionPolicy), accepted, rejected, unknown }
    static func query(_ value: Self) -> Classification { classify(value, query: true) }
    static func setter(_ value: Self) -> Classification { classify(value, query: false) }
    private static func classify(_ value: Self, query: Bool) -> Classification {
        guard !value.truncated, value.stdout.count + value.stderr.count <= 16_384,
              let out = String(data: value.stdout, encoding: .utf8), let err = String(data: value.stderr, encoding: .utf8) else { return .unknown }
        if ["Failed operation=", "no configured scope owns path", "Pin command: cannot resolve input="].contains(where: { out.contains($0) || err.contains($0) }) { return .rejected }
        guard value.exitCode == 1, out.isEmpty, err.hasSuffix("\n") else { return .unknown }
        var lines = err.components(separatedBy: "\n"); lines.removeLast()
        guard lines.count == (query ? 2 : 1) else { return .unknown }
        let prefix = "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3} OneDrive\\[[0-9]+:[0-9]+\\] "
        var messages: [String] = []
        for line in lines {
            guard let range = line.range(of: prefix, options: .regularExpression) else { return .unknown }
            messages.append(String(line[range.upperBound...]))
        }
        guard messages[0] == "Init preferences from: UBF8T346G9.OneDriveStandaloneSuite" else { return .unknown }
        if !query { return .accepted }
        switch messages[1] {
        case "pin state=None": return .policy(.none)
        case "pin state=Pinned": return .policy(.pinned)
        case "pin state=Unpinned": return .policy(.unpinned)
        default: return .unknown
        }
    }
}

struct OneDriveRetentionApplication: Equatable, Sendable {
    let executableURL: URL, version: String, stamp: String
}
struct OneDriveRetentionObservation: Sendable {
    let isDataless: Bool, safeToEvict: Bool
    static func uploadIsSafe(_ values: [URLResourceKey: Any]) -> Bool {
        (values[.ubiquitousItemIsUploadedKey] as? NSNumber)?.boolValue == true
            && (values[.ubiquitousItemIsUploadingKey] as? NSNumber)?.boolValue == false
            && (values[.ubiquitousItemHasUnresolvedConflictsKey] as? NSNumber)?.boolValue == false
            && values[.ubiquitousItemUploadingErrorKey] == nil && values[.ubiquitousItemDownloadingErrorKey] == nil
    }
}

struct OneDriveRetentionEnvironment: Sendable {
    let homeURL: URL
    let verifyApplication: @Sendable () throws -> OneDriveRetentionApplication
    let syncState: @Sendable (Set<Int32>) -> OneDriveSyncState
    let inspect: @Sendable (OneDriveRetentionTarget, Bool) throws -> OneDriveRetentionObservation
    let run: @Sendable (OneDriveRetentionApplication, OneDriveRetentionCommand, String,
                       OneDriveRetentionAttempt, TransferControl, OneDriveRetentionSlot,
                       @Sendable () throws -> Void) throws -> OneDriveRetentionTranscript
    var applicationStamp: (@Sendable () throws -> String)? = nil
    var evict: @Sendable (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }
    var waitAfterBusy: @Sendable (TimeInterval, OneDriveRetentionAttempt, TransferControl) throws -> Void = {
        try $1.waitAfterBusy(seconds: $0, control: $2)
    }
    static let live = Self(homeURL: FileManager.default.homeDirectoryForCurrentUser,
        verifyApplication: { try verifiedApplication() },
        syncState: { OneDriveSyncGate.live.state(excluding: $0) },
        inspect: { try $0.inspect(uploadMetadata: $1) }, run: {
            try OneDriveRetentionProcess.run($0, $1, $2, $3, $4, $5, $6)
        }, applicationStamp: { try trustedInputsStamp() })

    /// Fixed physical signing inputs. Metadata changes invalidate the session
    /// cache; this is only a passive optimization, never mutation authorization.
    private static func trustedInputsStamp() throws -> String {
        let root = URL(fileURLWithPath: "/Applications/OneDrive.app", isDirectory: true)
        let paths = ["", "Contents", "Contents/MacOS", "Contents/_CodeSignature",
                     "Contents/Info.plist", "Contents/_CodeSignature/CodeResources", "Contents/MacOS/OneDrive"]
        return try paths.enumerated().map { index, relative in
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            var value = stat()
            guard url.resolvingSymlinksInPath().path == url.path, lstat(url.path, &value) == 0,
                  value.st_mode & mode_t(S_IFMT) == mode_t(index < 4 ? S_IFDIR : S_IFREG),
                  let identity = LocalFileIdentity.fromStat(value) else {
                throw OneDriveRetentionError.untrustedApplication
            }
            return "\(relative):\(identity.device):\(identity.inode):\(identity.birthSeconds):\(identity.birthNanoseconds):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec):\(value.st_mode):\(value.st_nlink):\(value.st_uid):\(value.st_gid):\(value.st_flags)"
        }.joined(separator: "|")
    }

    private static func verifiedApplication() throws -> OneDriveRetentionApplication {
        let bundle = URL(fileURLWithPath: "/Applications/OneDrive.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/OneDrive")
        guard bundle.resolvingSymlinksInPath().path == bundle.path,
              executable.resolvingSymlinksInPath().path == executable.path,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.microsoft.OneDrive",
              info["CFBundleExecutable"] as? String == "OneDrive",
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty, version.count <= 64,
              let build = info["CFBundleVersion"] as? String, !build.isEmpty, build.count <= 64 else {
            throw OneDriveRetentionError.untrustedApplication
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.microsoft.OneDrive\" and certificate leaf[subject.OU] = \"UBF8T346G9\""
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw OneDriveRetentionError.untrustedApplication
        }
        var value = stat()
        guard lstat(executable.path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              let identity = LocalFileIdentity.fromStat(value) else { throw OneDriveRetentionError.untrustedApplication }
        let stamp = "\(identity.device):\(identity.inode):\(identity.birthSeconds):\(identity.birthNanoseconds):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        return .init(executableURL: executable, version: "\(version) (\(build))", stamp: stamp)
    }
}

private final class OneDrivePassiveTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (stamp: String, application: OneDriveRetentionApplication)?
    func application(in environment: OneDriveRetentionEnvironment) throws -> OneDriveRetentionApplication {
        try lock.withLock {
            do {
                guard let stamp = environment.applicationStamp else { return try environment.verifyApplication() }
                let before = try stamp()
                if let cached, cached.stamp == before { return cached.application }
                cached = nil
                let verified = try environment.verifyApplication()
                guard try stamp() == before else { throw OneDriveRetentionError.untrustedApplication }
                let application = OneDriveRetentionApplication(executableURL: verified.executableURL,
                    version: verified.version, stamp: verified.stamp + "|" + before)
                cached = (before, application)
                return application
            } catch {
                cached = nil
                throw OneDriveRetentionError.untrustedApplication
            }
        }
    }
}

/// AppKit positives remain useful, but its negative result is not proof that a
/// background client is absent. Each decision takes a fresh public kernel census.
struct OneDriveSyncGate: Sendable {
    enum Decision: String, Sendable {
        case appkitRunning = "appkit-running", kernelRunning = "kernel-running"
        case kernelStopped = "kernel-stopped", unknown
    }
    let appKitPIDs: @Sendable () -> Set<Int32>
    let census: OneDriveProcessCensus
    let trace: @Sendable (Decision) -> Void
    static let live = Self(appKitPIDs: {
        Set(["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"].flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { !$0.isTerminated }.map(\.processIdentifier)
        })
    }, census: .live, trace: { decision in
        guard ProcessInfo.processInfo.environment["MAXPLORER_RETENTION_GATE_TRACE"] == "1" else { return }
        let line = Data("Maxplorer retention gate: \(decision.rawValue)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: line)
    })
    func state(excluding ownedPIDs: Set<Int32>) -> OneDriveSyncState {
        if appKitPIDs().contains(where: { !ownedPIDs.contains($0) }) {
            trace(.appkitRunning); return .running
        }
        let state = census.state(excluding: ownedPIDs)
        switch state {
        case .running: trace(.kernelRunning)
        case .stopped: trace(.kernelStopped)
        case .unknown: trace(.unknown)
        }
        return state
    }
}

struct OneDriveProcessCensus: Sendable {
    // 65,536 current-user records is a generous finite ceiling, not an estimate
    // of normal process count. Allocation follows the kernel hint plus 64 rows.
    static let maximumRecords = 65_536
    let read: @Sendable (UnsafeMutableRawPointer?, inout Int) -> Int32
    static let live = Self(read: { buffer, bytes in
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(geteuid())]
        return sysctl(&mib, 4, buffer, &bytes, nil, 0) == 0 ? 0 : errno
    })
    func state(excluding ownedPIDs: Set<Int32>) -> OneDriveSyncState {
        let stride = MemoryLayout<kinfo_proc>.stride
        let ceiling = Self.maximumRecords * stride
        for _ in 0..<3 {
            var bytes = 0
            let sizing = read(nil, &bytes)
            if sizing == ENOMEM { continue }
            guard sizing == 0, bytes > 0, bytes <= ceiling, bytes % stride == 0 else { return .unknown }
            var records = [kinfo_proc](repeating: kinfo_proc(), count: min(Self.maximumRecords, bytes / stride + 64))
            let capacity = records.count * stride
            bytes = capacity
            let result = records.withUnsafeMutableBytes { read($0.baseAddress, &bytes) }
            if result == ENOMEM { continue }
            guard result == 0, bytes > 0, bytes <= capacity, bytes % stride == 0 else { return .unknown }
            for var record in records.prefix(bytes / stride) {
                guard !ownedPIDs.contains(record.kp_proc.p_pid) else { continue }
                let matches = withUnsafeBytes(of: &record.kp_proc.p_comm) {
                    $0.prefix(9).elementsEqual([79, 110, 101, 68, 114, 105, 118, 101, 0])
                }
                // Zombies still block; only explicit ownership can exclude a PID.
                if matches { return .running }
            }
            return .stopped
        }
        return .unknown
    }
}

/// Parent anchoring supports validation, not atomic authority over the external
/// CLI pathname. No target descriptor is held during provider eviction.
private struct OneDriveRetentionVersion: Equatable {
    let identity: LocalFileIdentity
    let mode: mode_t, size: off_t, uid: uid_t, gid: gid_t
    let modifiedSeconds: Int, modifiedNanoseconds: Int
    var statusVersion: LocalFileStatusVersion {
        .init(size: Int64(size), modificationSeconds: Int64(modifiedSeconds),
              modificationNanoseconds: Int64(modifiedNanoseconds))
    }
    init(_ value: stat) throws {
        guard let identity = LocalFileIdentity.fromStat(value), value.st_nlink == 1,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size >= 0 else {
            throw OneDriveRetentionError.staleTarget
        }
        self.identity = identity; mode = value.st_mode; size = value.st_size
        uid = value.st_uid; gid = value.st_gid
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        // ctime/flags can change when pinning/evicting. Content version, owner,
        // permissions, links and captured object identity never get resealed.
    }
}

final class OneDriveRetentionTarget: @unchecked Sendable {
    let entry: TransferEntry, url: URL
    private let parent: Int32, resolved: URL
    private let version: OneDriveRetentionVersion
    var matchesListedStatusVersion: Bool { entry.item.statusVersion == version.statusVersion }

    /// Proof reuse is an optimization. A stale/missing listed stamp or failed
    /// final sample declines it without changing the established action result.
    func verifiedStatus(policy: OneDriveRetentionPolicy, expectedDataless: Bool?) -> OneDriveVerifiedStatus? {
        guard matchesListedStatusVersion, let expectedDataless,
              let actual = try? sample(), actual == expectedDataless else { return nil }
        return OneDriveVerifiedStatus(entry: entry, sampledVersion: version.statusVersion,
                                      policy: policy, isDataless: actual)
    }
    init(_ entry: TransferEntry) throws {
        self.entry = entry
        var heldForFailure: Int32 = -1
        let captured: (Int32, URL, OneDriveRetentionVersion)
        do {
            captured = try HydrationMaterializationPolicy().disabled { _ in
                try LocalFileOperations.withParent(entry.source) { parent, resolved -> (Int32, URL, OneDriveRetentionVersion) in
                    // Display URLs can use Foundation's /var spelling while
                    // the anchored directory preserves realpath's /private/var.
                    // Compare captured display routes here; revalidateRoute()
                    // separately binds that route to this resolved parent.
                    guard entry.item.url.standardizedFileURL.path.utf8.elementsEqual(
                            entry.source.directoryURL.appendingPathComponent(entry.item.name).standardizedFileURL.path.utf8),
                          !entry.item.name.contains("/"), !entry.item.name.contains("\0"),
                          entry.item.name != ".", entry.item.name != ".." else { throw OneDriveRetentionError.staleTarget }
                    let file = try ContentFileIO.sample(entry.item.name, at: parent)
                    let version = try OneDriveRetentionVersion(file)
                    guard version.identity == entry.item.identity else { throw OneDriveRetentionError.staleTarget }
                    let held = fcntl(parent, F_DUPFD_CLOEXEC, 0)
                    guard held >= 0 else { throw LocalFileOperations.failure(errno, operation: "Hold folder", name: entry.item.name) }
                    heldForFailure = held
                    return (held, resolved, version)
                }
            }
        } catch {
            // Policy restoration can throw after dup succeeded, before this
            // object owns its descriptor. Preserve that failure without a leak.
            if heldForFailure >= 0 { close(heldForFailure) }
            throw error
        }
        parent = captured.0; resolved = captured.1; version = captured.2
        url = captured.1.appendingPathComponent(entry.item.name)
    }
    deinit { close(parent) }
    func sample() throws -> Bool {
        try HydrationMaterializationPolicy().disabled { _ in
            do { return try anchoredResidency() }
            catch { throw OneDriveRetentionError.staleTarget }
        }
    }

    /// Passive callers distinguish an identity change from a metadata read failure.
    func readResidency() throws -> Bool {
        try HydrationMaterializationPolicy().disabled { _ in try anchoredResidency() }
    }

    private func anchoredResidency() throws -> Bool {
        try LocalFileOperations.revalidateRoute(entry.source, resolved: resolved)
        let folder = try ContentFileIO.sample(parent), file = try ContentFileIO.sample(entry.item.name, at: parent)
        guard LocalFileIdentity.fromStat(folder) == entry.source.directoryIdentity,
              LocalFileIdentity.fromStat(file) == entry.item.identity, file.st_nlink == 1,
              file.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), file.st_size >= 0,
              try OneDriveRetentionVersion(file) == version else {
            throw OneDriveRetentionError.staleTarget
        }
        try LocalFileOperations.revalidateRoute(entry.source, resolved: resolved)
        return file.st_flags & UInt32(SF_DATALESS) != 0
    }
    func inspect(uploadMetadata: Bool) throws -> OneDriveRetentionObservation {
        try HydrationMaterializationPolicy().disabled { _ in
            _ = try sample()
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?, result: Result<OneDriveRetentionObservation, Error>?
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges, .immediatelyAvailableMetadataOnly], error: &coordinationError) { actual in
                result = Result {
                    guard actual.path.utf8.elementsEqual(url.path.utf8) else { throw OneDriveRetentionError.staleTarget }
                    _ = try sample()
                    var safe = false
                    if uploadMetadata {
                        var fresh = actual; fresh.removeAllCachedResourceValues()
                        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey]
                        let values = try fresh.resourceValues(forKeys: keys).allValues
                        safe = OneDriveRetentionObservation.uploadIsSafe(values)
                    }
                    return .init(isDataless: try sample(), safeToEvict: safe)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw OneDriveRetentionError.staleTarget }
            return try result.get()
        }
    }
}

final class OneDriveRetentionSlot: @unchecked Sendable {
    private let condition = NSCondition()
    private var passive = false, explicit = false, explicitEntered = false, launching = false
    private var children = Set<Int32>()
    var isBusy: Bool { condition.lock(); defer { condition.unlock() }; return explicit }
    var isLaunching: Bool { condition.lock(); defer { condition.unlock() }; return launching }
    var ownedPIDs: Set<Int32> { condition.lock(); defer { condition.unlock() }; return children }
    func reserveExplicit() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !explicit else { return false }; explicit = true; return true
    }
    func enterExplicit(waitSeconds: TimeInterval, checkpoint: () throws -> Void) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, waitSeconds)
        while true {
            try checkpoint()
            condition.lock()
            if !passive { explicitEntered = true; condition.unlock(); return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { condition.unlock(); throw OneDriveRetentionError.busy }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.025, remaining)))
            condition.unlock()
        }
    }
    func releaseExplicit() {
        condition.lock(); defer { condition.unlock() }
        // A timed-out pending action must not clear the passive child's PID.
        if explicitEntered { children.removeAll(); launching = false }
        explicit = false; explicitEntered = false; condition.broadcast()
    }
    func acquirePassive() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !passive, !explicit else { return false }; passive = true; return true
    }
    func releasePassive() {
        condition.lock(); defer { condition.unlock() }
        passive = false; children.removeAll(); launching = false; condition.broadcast()
    }
    func beginLaunch() { condition.lock(); launching = true; condition.unlock() }
    func endLaunch() { condition.lock(); launching = false; condition.unlock() }
    func child(_ pid: Int32, started: Bool) {
        condition.lock(); defer { condition.unlock() }
        if started { children.insert(pid) } else { children.remove(pid) }
    }
}

final class OneDriveRetentionAttempt: @unchecked Sendable {
    private let lock = NSLock(), control: TransferControl
    private var continuation: CheckedContinuation<OneDriveRetentionOutcome, Error>?
    private var result: Result<OneDriveRetentionOutcome, Error>?
    private var timer: DispatchSourceTimer?
    private var submitted = false, launching = false, verifiedUnpinned = false
    var setterSubmitted: Bool { lock.withLock { submitted } }
    var cancellationError: OneDriveRetentionError {
        lock.withLock { verifiedUnpinned ? .cancelledAfterClear : .cancelled(setterSubmitted: submitted || launching) }
    }
    init(control: TransferControl) { self.control = control }
    static func boundedTimeout(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0.001, min(seconds, 60)) : 60
    }
    func install(_ continuation: CheckedContinuation<OneDriveRetentionOutcome, Error>, timeoutSeconds: TimeInterval) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        self.timer = timer
        timer.schedule(deadline: .now() + Self.boundedTimeout(timeoutSeconds))
        timer.setEventHandler { [weak self] in self?.timeout() }
        timer.resume(); lock.unlock()
    }
    func finish(_ value: Result<OneDriveRetentionOutcome, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiter = continuation; continuation = nil
        let timer = timer; self.timer = nil; lock.unlock()
        timer?.cancel(); waiter?.resume(with: value)
    }
    func cancel() { stop(timedOut: false) }
    private func timeout() { stop(timedOut: true) }
    private func stop(timedOut: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let mayHaveSubmitted = submitted || launching
        let error: OneDriveRetentionError
        if verifiedUnpinned { error = timedOut ? .timedOutAfterClear : .cancelledAfterClear }
        else { error = timedOut ? .timedOut(setterSubmitted: mayHaveSubmitted) : .cancelled(setterSubmitted: mayHaveSubmitted) }
        let value: Result<OneDriveRetentionOutcome, Error> = .failure(error)
        result = value; let waiter = continuation; continuation = nil
        let timer = timer; self.timer = nil; lock.unlock()
        control.cancel(); timer?.cancel(); waiter?.resume(with: value)
    }
    func checkpoint(_ control: TransferControl) throws {
        try control.checkpoint()
        if lock.withLock({ result != nil }) { throw CancellationError() }
    }
    func observeCancellation() {
        do { try control.checkpoint() } catch { cancel() }
    }
    func waitAfterBusy(seconds: TimeInterval, control: TransferControl) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            try checkpoint(control)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(0.025, remaining))
        }
    }
    /// OS process creation can block. A stopped waiter remains conservative
    /// while launch is unresolved, without holding this lock across spawn.
    /// A known launch failure is distinct from successful native submission.
    func submit(_ command: OneDriveRetentionCommand, control: TransferControl, launch: () throws -> Void) throws {
        try control.checkpoint()
        lock.lock()
        guard result == nil else { lock.unlock(); throw CancellationError() }
        if command != .query { launching = true }
        lock.unlock()
        do {
            try launch()
            if command != .query { lock.withLock { submitted = true; launching = false } }
        } catch {
            // A later failed launch must never erase an earlier submitted mutation.
            if command != .query { lock.withLock { launching = false } }
            throw error
        }
    }

    func submitEviction(control: TransferControl, operation: () throws -> Void) throws {
        try control.checkpoint()
        lock.lock()
        guard result == nil else { lock.unlock(); throw CancellationError() }
        // Foundation may submit work before throwing. Once entered, ownership and
        // uncertainty remain until actual return, independently of the UI waiter.
        submitted = true
        lock.unlock()
        try operation()
    }

    func recordVerifiedUnpinned(control: TransferControl) throws {
        try control.checkpoint()
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { throw CancellationError() }
        verifiedUnpinned = true
    }
}

enum OneDriveRetentionProcess {
    static func run(_ application: OneDriveRetentionApplication, _ command: OneDriveRetentionCommand,
                    _ path: String, _ attempt: OneDriveRetentionAttempt, _ control: TransferControl,
                    _ slot: OneDriveRetentionSlot, _ beforeLaunch: @Sendable () throws -> Void) throws -> OneDriveRetentionTranscript {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = application.executableURL; process.arguments = [command.argument, path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; process.environment = environment
        let outFD = output.fileHandleForReading.fileDescriptor, errFD = errors.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw OneDriveRetentionError.providerRejected }
        }
        try beforeLaunch()
        // Admission rechecks cancellation after the final provider/content guard.
        try attempt.submit(command, control: control) {
            slot.beginLaunch()
            defer { slot.endLaunch() }
            try process.run()
            slot.child(process.processIdentifier, started: true)
        }
        let pid = process.processIdentifier
        let observedStart = ProcessInfo.processInfo.systemUptime
        var stdout = Data(), stderr = Data(), truncated = false, capturedCount = 0
        func drain(_ fd: Int32, _ destination: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            // A noisy process cannot monopolize the deadline/cancellation poll.
            for _ in 0..<32 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; if errno != EAGAIN { truncated = true }; return }
                if count == 0 { return }
                let remaining = max(0, 16_384 - capturedCount), kept = min(remaining, count)
                destination.append(contentsOf: buffer.prefix(kept)); capturedCount += kept
                if count > remaining { truncated = true }
            }
        }
        repeat {
            drain(outFD, &stdout); drain(errFD, &stderr)
            attempt.observeCancellation()
            if process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        } while process.isRunning
        process.waitUntilExit()
        if command == .query, environment["MAXPLORER_CLOUD_STATUS_TRACE"] == "1" {
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - observedStart) * 1_000)
            let message = "maxplorer-cloud-cache ownedQueryMilliseconds=\(milliseconds)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
        // The child has actually exited. Drain remaining buffered diagnostics;
        // inherited pipe writers never extend reservation ownership indefinitely.
        drain(outFD, &stdout); drain(errFD, &stderr)
        // Keep the owned PID excluded through the caller's immediate runtime
        // recheck; it removes this PID afterwards, even on a refused outcome.
        return .init(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr,
                     truncated: truncated, ownedPID: pid)
    }
}
