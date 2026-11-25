import Darwin
import Foundation

/// Displayed availability is never an authority to use a path. Content reads
/// always inspect the captured entry again through its anchored parent.
struct PhysicalContentAccess: Sendable {
    let sample: @Sendable (String, Int32) throws -> stat
    let sampleDescriptor: @Sendable (Int32) throws -> stat

    init(sample: @escaping @Sendable (String, Int32) throws -> stat = {
        try ContentFileIO.sample($0, at: $1)
    }, sampleDescriptor: @escaping @Sendable (Int32) throws -> stat = {
        try ContentFileIO.sample($0)
    }) { self.sample = sample; self.sampleDescriptor = sampleDescriptor }

    func inspect(_ entry: TransferEntry, purpose: ContentPurpose,
                 maximumBytes: UInt64?) throws -> PhysicalContentObservation {
        let item = entry.item, context = entry.source
        guard item.url.isFileURL, !item.isSymbolicLink, let identity = item.identity,
              item.name == item.url.lastPathComponent, !item.name.contains("/"),
              item.name != ".", item.name != "..", !item.name.contains("\0"),
              item.url.standardizedFileURL.path.utf8.elementsEqual(
                context.directoryURL.appendingPathComponent(item.name).standardizedFileURL.path.utf8),
              !item.isDirectory || purpose == .transfer || purpose == .clipboardExport else {
            throw ItemContentError.unsupportedType
        }
        return try LocalFileOperations.withParent(context) { parent, resolved in
            let value = try sample(item.name, parent)
            let type = value.st_mode & mode_t(S_IFMT)
            guard LocalFileIdentity.fromStat(value) == identity,
                  (type == mode_t(S_IFREG) && !item.isDirectory)
                    || (type == mode_t(S_IFDIR) && item.isDirectory) else { throw ItemContentError.staleSource }
            let version = try ContentFileVersion(value)
            if let maximumBytes, UInt64(version.size) > maximumBytes { throw ItemContentError.limitExceeded }
            try LocalFileOperations.revalidateRoute(context, resolved: resolved)
            return PhysicalContentObservation(resolvedURL: resolved.appendingPathComponent(item.name),
                version: version, isDataless: value.st_flags & UInt32(SF_DATALESS) != 0)
        }
    }
}

struct PhysicalContentObservation: Sendable {
    let resolvedURL: URL
    let version: ContentFileVersion
    let isDataless: Bool
}

protocol PhysicalFileHydrating: Sendable {
    func prepare(_ entry: TransferEntry, purpose: ContentPurpose, hydrationPolicy: ContentHydrationPolicy,
                 maximumBytes: UInt64, timeoutSeconds: TimeInterval, requestID: UUID, control: TransferControl,
                 onProgress: @escaping @Sendable (ContentPreparationPhase) -> Void) async throws -> PreparedPhysicalContent
}

/// One coordinator belongs to one attempt. Cancellation can race an accessor;
/// callers are released promptly, but the bounded native worker remains occupied
/// until that accessor actually exits. No provider-global download is cancelled.
protocol HydrationCoordinating: Sendable {
    func coordinateReading(at url: URL, accessor: (URL) throws -> Void) throws
    func cancel()
}

final class NativeHydrationCoordinator: HydrationCoordinating, @unchecked Sendable {
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    func coordinateReading(at url: URL, accessor: (URL) throws -> Void) throws {
        var coordinationError: NSError?, accessorError: Error?
        var accessed = false
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { actualURL in
            accessed = true
            do { try accessor(actualURL) } catch { accessorError = error }
        }
        if let accessorError { throw accessorError }
        if let coordinationError { throw coordinationError }
        guard accessed else { throw ItemContentError.downloadFailed("The provider did not make the file available.") }
    }
    func cancel() { coordinator.cancel() }
}

struct LocalPhysicalFileHydrator: PhysicalFileHydrating {
    private let access: PhysicalContentAccess
    private let executor: BlockingIOExecutor?
    private let makeCoordinator: @Sendable () -> any HydrationCoordinating
    private let policy: HydrationMaterializationPolicy

    init(access: PhysicalContentAccess = PhysicalContentAccess(), executor: BlockingIOExecutor? = nil,
         policy: HydrationMaterializationPolicy = HydrationMaterializationPolicy(),
         makeCoordinator: @escaping @Sendable () -> any HydrationCoordinating = { NativeHydrationCoordinator() }) {
        self.access = access; self.executor = executor; self.policy = policy; self.makeCoordinator = makeCoordinator
    }

    @discardableResult
    func prepare(_ entry: TransferEntry, purpose: ContentPurpose = .preview,
                 hydrationPolicy: ContentHydrationPolicy = .whenNeeded,
                 maximumBytes: UInt64, timeoutSeconds: TimeInterval, requestID: UUID = UUID(),
                 control: TransferControl,
                 onProgress: @escaping @Sendable (ContentPreparationPhase) -> Void) async throws -> PreparedPhysicalContent {
        guard purpose == .preview || purpose == .download else { throw ItemContentError.unsupportedType }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw ItemContentError.downloadQueueTimedOut }
        let seconds = min(timeoutSeconds, CloudDownloadPolicy.timeoutSeconds)
        // Captured by the actual blocking closures, so a cancelled caller cannot
        // erase the use while native coordination or metadata work still runs.
        let contentUse = PhysicalContentUse.shared.retain(PhysicalContentTarget(entry))
        let deadline = ContinuousClock.now + .seconds(seconds), attempt = HydrationAttemptState()
        do {
            let result = try await withThrowingTaskGroup(of: PreparedPhysicalContent.self) { group in
                group.addTask {
                    // Local previews never queue behind a network materializer.
                    let observation = try await run(on: .read, onCancel: { control.cancel() }) { cancellation in
                        defer { withExtendedLifetime(contentUse) {} }
                        try cancellation.checkCancellation(); try control.checkpoint()
                        return try policy.disabled { _ in
                            try access.inspect(entry, purpose: purpose, maximumBytes: maximumBytes)
                        }
                    }
                    try Task.checkCancellation()
                    if !observation.isDataless { return PreparedPhysicalContent(resident: entry, observation: observation) }
                    guard hydrationPolicy == .whenNeeded else { throw ItemContentError.cloudNotDownloaded }
                    let coordinator = makeCoordinator()
                    onProgress(purpose == .download ? .queued : .downloading)
                    return try await run(on: purpose == .download ? .explicitHydration : .hydration,
                                         onCancel: { coordinator.cancel(); control.cancel() }) { cancellation in
                        defer { withExtendedLifetime(contentUse) {} }
                        func checkpoint() throws {
                            try cancellation.checkCancellation(); try control.checkpoint()
                        }
                        do {
                            return try policy.disabled { restore in
                                try checkpoint()
                                // Capture only after queue admission, under a nonmaterializing policy.
                                let current = try access.inspect(entry, purpose: purpose, maximumBytes: maximumBytes)
                                guard current.resolvedURL.path.utf8.elementsEqual(observation.resolvedURL.path.utf8) else {
                                    throw ItemContentError.staleSource
                                }
                                if !current.isDataless { return PreparedPhysicalContent(resident: entry, observation: current) }
                                return try LocalFileOperations.withParent(entry.source) { parent, resolved in
                                    let anchor = try HydrationIdentityAnchor.capture(entry, parent: parent, resolved: resolved,
                                        access: access, maximumBytes: maximumBytes, policy: policy, contentUse: contentUse)
                                    try restore()
                                    try checkpoint()
                                    attempt.start()
                                    if purpose == .download { onProgress(.downloading) }
                                    var accepted: ContentFileVersion?
                                    try coordinator.coordinateReading(at: current.resolvedURL) { actualURL in
                                        try checkpoint()
                                        guard actualURL.isFileURL,
                                              actualURL.path.utf8.elementsEqual(current.resolvedURL.path.utf8), accepted == nil else {
                                            throw ItemContentError.staleSource
                                        }
                                        accepted = try anchor.sampleVersion(parent: parent, resolved: resolved)
                                        try checkpoint()
                                    }
                                    try checkpoint()
                                    guard let accepted else { throw ItemContentError.cloudNotDownloaded }
                                    let sealed = try policy.disabled { _ in
                                        try anchor.sampleVersion(parent: parent, resolved: resolved)
                                    }
                                    guard sealed == accepted else { throw ItemContentError.staleSource }
                                    try checkpoint()
                                    return anchor.prepared(version: sealed, requestID: requestID)
                                }
                            }
                        } catch {
                            try cancellation.checkCancellation()
                            if error is CancellationError || error is ItemContentError || error is FileOperationError { throw error }
                            throw ItemContentError.downloadFailed(error.localizedDescription)
                        }
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw attempt.started ? ItemContentError.downloadTimedOut : ItemContentError.downloadQueueTimedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
            try Task.checkCancellation()
            if attempt.started { onProgress(.preparing) }
            return result
        } catch { try Task.checkCancellation(); throw error }
    }

    private func run<Value: Sendable>(on lane: BlockingIOLane,
                                     onCancel: @escaping @Sendable () -> Void,
                                     operation: @escaping @Sendable (BlockingIOCancellation) throws -> Value) async throws -> Value {
        if let executor { return try await executor.run(on: lane, onCancel: onCancel, operation) }
        return try await BlockingIO.run(on: lane, onCancel: onCancel, operation)
    }
}

private final class HydrationAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    func start() { lock.lock(); didStart = true; lock.unlock() }
}
