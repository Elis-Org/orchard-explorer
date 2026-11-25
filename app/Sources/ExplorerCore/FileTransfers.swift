import Darwin
import Foundation

public enum TransferKind: Equatable, Sendable { case copy, move }

/// `finalizing` begins at exclusive publication: the item is committed and no
/// longer pausable or cancellable; a cross-volume move then removes originals.
public enum TransferPhase: Equatable, Sendable { case copying, finalizing, removingOriginals }

/// Cumulative within one top-level item: copied regular-file bytes and entries
/// (files, folders and links) fully copied so far (MAC-069).
public struct TransferProgress: Sendable {
    public let currentName: String
    public let bytesCopied: Int64
    public let itemsCompleted: Int
    public let phase: TransferPhase
    public init(currentName: String, bytesCopied: Int64, itemsCompleted: Int = 0, phase: TransferPhase = .copying) {
        self.currentName = currentName
        self.bytesCopied = bytesCopied
        self.itemsCompleted = itemsCompleted
        self.phase = phase
    }
}

/// A cooperative gate for blocking worker threads, never for the main thread.
/// Native calls finish their current callback chunk before observing cancellation.
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    public init() {}
    public func pause() { condition.lock(); if !cancelled { paused = true }; condition.unlock() }
    public func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    public func cancel() { condition.lock(); cancelled = true; paused = false; condition.broadcast(); condition.unlock() }
    public func checkpoint() throws {
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let cancelled = cancelled
        condition.unlock()
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}

public protocol FileTransferring: Sendable {
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult
    /// NATIVE-P16 / MAC-071: replace the compared existing entry named `name`.
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, replacing target: ReplacementTarget?, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult
}

public extension FileTransferring {
    /// Services without replacement support refuse Replace and never overwrite.
    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, replacing target: ReplacementTarget?, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        guard target == nil else {
            throw FileOperationError.unsupported("Replace is not available for this transfer. No files were changed.")
        }
        return try await transfer(item, from: from, to: to, name: name, kind: kind, control: control, onProgress: onProgress)
    }
}

/// MAC-072: Replace retired the existing item but could not publish or restore
/// it; its Trash receipt lets the user restore it from Recently Trashed.
public struct ReplacementRecoveryError: LocalizedError, Sendable {
    public let receipt: TrashReceipt
    public let cause: String
    public let accessFailure: FileAccessFailure?
    public init(receipt: TrashReceipt, cause: String, accessFailure: FileAccessFailure? = nil) {
        self.receipt = receipt
        self.cause = cause
        self.accessFailure = accessFailure
    }
    public var errorDescription: String? {
        "Replace failed after the existing “\(receipt.original.name)” was moved to the Trash, and it could not be put back automatically. It is in the Trash at \(receipt.trashed.url.path); use Recently Trashed to restore it. \(cause)"
    }
}

/// MAC-071/072: Replace stopped because moving the existing item to the Trash
/// did not produce a verified receipt. Nothing was published in its place and
/// the incoming item is unchanged; the outcome and any known Trash location are
/// reported instead of advertising Recently Trashed.
public enum ReplacementTrashError: LocalizedError, Sendable {
    /// The exact item was put back under its name: nothing was replaced.
    case putBack(name: String, detail: String)
    case unverified(name: String, trashLocation: URL?, detail: String, accessFailure: FileAccessFailure? = nil)
    case uncertain(name: String, detail: String, accessFailure: FileAccessFailure?)

    public var accessFailure: FileAccessFailure? {
        switch self {
        case .putBack: return nil
        case let .unverified(_, _, _, failure), let .uncertain(_, _, failure): return failure
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .putBack(name, detail):
            return "Replace stopped: the system did not return a verifiable Trash location for the existing “\(name)”, so it was put back and nothing was replaced. \(detail)"
        case let .unverified(name, location, detail, _):
            let place = location.map { " at \($0.path)" } ?? ""
            return "Replace stopped: the existing “\(name)” was moved to the Trash\(place), but its location could not be verified, so it is not listed in Recently Trashed. The incoming item was not put in its place and is unchanged; restore the existing item from the Trash if needed. \(detail)"
        case let .uncertain(name, detail, _):
            return "Replace stopped: moving the existing “\(name)” to the Trash reported an error and it may already be in the Trash. The incoming item was not put in its place and is unchanged; check the destination and the Trash. \(detail)"
        }
    }
}

/// Test seams around Replace's retirement of the compared item.
struct ReplacementHooks: Sendable {
    var beforeTrash: (@Sendable (TransferControl) throws -> Void)?
    var trash: (@Sendable (FileItem, FileOperationContext, BlockingIOCancellation?) throws -> TrashResult)?
    var afterTrash: (@Sendable (URL) throws -> Void)?
}

public enum FileTransferError: LocalizedError, Sendable {
    case cleanupFailed(cause: String, stagingURL: URL, accessFailure: FileAccessFailure? = nil)
    public var errorDescription: String? {
        switch self {
        case let .cleanupFailed(cause, stagingURL, _):
            return "\(cause) Unpublished staging could not be safely removed. Inspect its original location, which may have moved: \(stagingURL.path)."
        }
    }
}

/// FR-FILE-003/004/014/015 / EV-0252, EV-0255, EV-0102 / corresponding ATs.
/// One top-level item per call. Recursive copy never follows symlinks or crosses
/// a mounted filesystem. Native metadata copying is best effort; symlinks preserve
/// target text, not all link metadata. This is not a File Provider exclusion test.
/// NATIVE-P15 / MAC-066/067: a cross-device Move is a verified copy followed by
/// ledger-checked removal of the original; it never reports a copy as a move.
public struct LocalFileTransfers: FileTransferring {
    private let afterCommit: (@Sendable (URL) -> Void)?
    private let afterSourceUnlink: (@Sendable (String) -> Void)?
    private let hooks: ReplacementHooks
    public init() { afterCommit = nil; afterSourceUnlink = nil; hooks = ReplacementHooks() }
    init(afterCommit: @escaping @Sendable (URL) -> Void) {
        self.afterCommit = afterCommit; afterSourceUnlink = nil; hooks = ReplacementHooks()
    }
    /// Test seam: runs after each original entry this transfer unlinks.
    init(afterSourceUnlink: @escaping @Sendable (String) -> Void) {
        afterCommit = nil
        self.afterSourceUnlink = afterSourceUnlink
        hooks = ReplacementHooks()
    }
    /// Test seam: runs after Replace trashed the existing item and immediately
    /// before publication; a thrown error is handled as a publication failure.
    init(afterReplacementRetired: @escaping @Sendable (URL) throws -> Void) {
        self.init(replacementHooks: ReplacementHooks(afterTrash: afterReplacementRetired))
    }
    init(replacementHooks: ReplacementHooks) {
        afterCommit = nil; afterSourceUnlink = nil
        hooks = replacementHooks
    }

    public func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                         name: String, kind: TransferKind, control: TransferControl,
                         onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        try await transfer(item, from: from, to: to, name: name, kind: kind, replacing: nil, control: control,
                           onProgress: onProgress)
    }

    public func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                         name: String, kind: TransferKind, replacing target: ReplacementTarget?, control: TransferControl,
                         onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        try Task.checkCancellation()
        // Only a same-device rename is a short mutation. Copies and cross-volume
        // moves stream data and must not occupy the single mutation lane.
        let sameDevice = from.directoryIdentity.device == to.directoryIdentity.device
            && item.identity?.device == to.directoryIdentity.device
        let lane: BlockingIOLane = kind == .move && sameDevice ? .mutation : .copy
        return try await BlockingIO.run(on: lane, onCancel: { control.cancel() }) { cancellation in
            try cancellation.checkCancellation()
            try control.checkpoint()
            try LocalFileOperations.validateName(name)
            try LocalFileOperations.validateName(item.name)
            try LocalFileOperations.validateURL(item.url)
            guard item.name == item.url.lastPathComponent,
                  item.url.deletingLastPathComponent().standardizedFileURL.path == from.directoryURL.standardizedFileURL.path,
                  let expected = item.identity else { throw FileOperationError.staleSource }
            return try LocalFileOperations.withParent(from) { sourceFD, sourceRoot in
                try LocalFileOperations.withParent(to) { destinationFD, destinationRoot in
                    let capabilities = try destinationRoot.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
                    guard capabilities.volumeSupportsExclusiveRenaming == true else {
                        throw FileOperationError.unsupported("The destination does not advertise exclusive publication support.")
                    }
                    let source = try TransferIO.entry(item.name, at: sourceFD)
                    guard LocalFileIdentity.fromStat(source) == expected else { throw FileOperationError.staleSource }
                    try TransferIO.validateNode(source)
                    if let target {
                        try Self.verifyReplacement(target, name: name, at: destinationFD, source: source)
                    } else {
                        try TransferIO.checkDestination(name, at: destinationFD, source: expected, kind: kind)
                    }
                    if TransferIO.type(source) == S_IFDIR {
                        let sourcePath = sourceRoot.appendingPathComponent(item.name, isDirectory: true).path
                        guard destinationRoot.path != sourcePath, !destinationRoot.path.hasPrefix(sourcePath + "/") else {
                            throw FileOperationError.unsupported("A folder cannot be transferred into itself or its descendants.")
                        }
                        try TransferIO.rejectDescendant(destinationFD, of: expected)
                    }
                    try LocalFileOperations.revalidateRoute(from, resolved: sourceRoot)
                    try LocalFileOperations.revalidateRoute(to, resolved: destinationRoot)
                    onProgress(TransferProgress(currentName: item.name, bytesCopied: 0))
                    let destination = to.directoryURL.appendingPathComponent(name, isDirectory: item.url.hasDirectoryPath)
                    let sourceDevice = UInt64(UInt32(bitPattern: source.st_dev))
                    let removesSource = kind == .move
                        && !(sourceDevice == to.directoryIdentity.device && from.directoryIdentity.device == to.directoryIdentity.device)
                    if removesSource {
                        guard sourceDevice == from.directoryIdentity.device else {
                            throw FileOperationError.unsupported("A mounted volume root cannot be moved. No files were changed.")
                        }
                        var filesystem = statfs()
                        guard fstatfs(sourceFD, &filesystem) == 0 else {
                            throw LocalFileOperations.failure(errno, operation: "Inspect source volume", name: item.name)
                        }
                        guard filesystem.f_flags & UInt32(MNT_RDONLY) == 0 else {
                            throw FileOperationError.unsupported("The source volume is read-only, so the original cannot be removed. Use Copy instead. No files were changed.")
                        }
                    }
                    if kind == .move && !removesSource {
                        try LocalFileOperations.revalidateRoute(from, resolved: sourceRoot)
                        try LocalFileOperations.revalidateRoute(to, resolved: destinationRoot)
                        guard try LocalFileOperations.identity(of: item.name, in: sourceFD) == expected else { throw FileOperationError.staleSource }
                        try control.checkpoint()
                        let replaced = try target.map {
                            try retire($0, name: name, in: to, at: destinationFD, source: source, control: control,
                                       cancellation: cancellation, onProgress: onProgress,
                                       committed: TransferProgress(currentName: item.name, bytesCopied: 0, phase: .finalizing))
                        }
                        if let replaced {
                            do {
                                try hooks.afterTrash?(destination)
                                // Retirement took time: the rename must still move the
                                // exact source that was checked (review d0a87c9e #3).
                                try LocalFileOperations.revalidateRoute(from, resolved: sourceRoot)
                                let current = try TransferIO.entry(item.name, at: sourceFD)
                                guard LocalFileIdentity.fromStat(current) == expected,
                                      TransferIO.type(current) == TransferIO.type(source) else { throw FileOperationError.staleSource }
                            } catch { try Self.putBack(replaced, after: error); throw error }
                        }
                        let result = item.name.withCString { old in name.withCString { new in
                            renameatx_np(sourceFD, old, destinationFD, new, UInt32(RENAME_EXCL))
                        } }
                        guard result == 0 else {
                            let failure = LocalFileOperations.failure(errno, operation: "Move", name: name)
                            if let replaced { try Self.putBack(replaced, after: failure) }
                            throw failure
                        }
                        onProgress(TransferProgress(currentName: item.name, bytesCopied: 0, itemsCompleted: 1, phase: .finalizing))
                        afterCommit?(destination)
                        let moved = LocalFileOperations.committedResult(at: destination, name: name, descriptor: destinationFD,
                            context: to, resolved: destinationRoot, expected: expected, operation: "The item was moved")
                        // A same-volume move is one rename and counts as one entry (MAC-069).
                        return FileOperationResult(url: moved.url, identity: moved.identity, warning: moved.warning,
                            accessFailure: moved.accessFailure, transferredBytes: 0, transferredEntries: 1,
                            replacedReceipt: replaced)
                    }

                    let staging = try OwnedTransferStage(parent: destinationFD, parentURL: to.directoryURL)
                    let worker: TransferCopyWorker
                    do {
                        worker = TransferCopyWorker(stage: staging, sourceDevice: source.st_dev,
                                                        forbiddenDirectories: [to.directoryIdentity, staging.identity],
                                                        control: control, onProgress: onProgress)
                        try worker.copy(sourceParent: sourceFD, sourceName: item.name, destinationParent: staging.descriptor,
                                        destinationName: "payload", relative: ["payload"], expected: expected, depth: 0)
                        try LocalFileOperations.revalidateRoute(from, resolved: sourceRoot)
                        try LocalFileOperations.revalidateRoute(to, resolved: destinationRoot)
                        guard try LocalFileOperations.identity(of: item.name, in: sourceFD) == expected else { throw FileOperationError.staleSource }
                        let copiedIdentity = try staging.verifiedIdentity(["payload"], parent: staging.descriptor, name: "payload")
                        try control.checkpoint()
                        // MAC-071/072: retire the compared existing item to the Trash
                        // only now, immediately before the exclusive publication.
                        let replaced = try target.map {
                            try retire($0, name: name, in: to, at: destinationFD, source: source, control: control,
                                       cancellation: cancellation, onProgress: onProgress,
                                       committed: TransferProgress(currentName: item.name, bytesCopied: worker.bytesCopied,
                                                                   itemsCompleted: worker.itemsCompleted, phase: .finalizing))
                        }
                        if let replaced {
                            do { try hooks.afterTrash?(destination) }
                            catch { try Self.putBack(replaced, after: error); throw error }
                        }
                        let published = name.withCString { renameatx_np(staging.descriptor, "payload", destinationFD, $0, UInt32(RENAME_EXCL)) }
                        guard published == 0 else {
                            let failure = LocalFileOperations.failure(errno, operation: "Publish copy", name: name)
                            if let replaced { try Self.putBack(replaced, after: failure) }
                            throw failure
                        }
                        // No thrown error or cancellation may turn this completed rename into retryable failure.
                        // The item is committed: announce the non-pausable phase at once (MAC-068).
                        onProgress(TransferProgress(currentName: item.name, bytesCopied: worker.bytesCopied,
                                                    itemsCompleted: worker.itemsCompleted, phase: .finalizing))
                        afterCommit?(destination)
                        let metadataWarning = staging.finalizePublished(name: name, parent: destinationFD)
                        let verified = LocalFileOperations.committedResult(at: destination, name: name, descriptor: destinationFD,
                            context: to, resolved: destinationRoot, expected: copiedIdentity, operation: "The item was copied")
                        let cleanupWarning = staging.cleanupAfterPublication()
                        let warning = [metadataWarning?.message, verified.warning, cleanupWarning?.message]
                            .compactMap { $0 }.joined(separator: " ")
                        var accessFailure = FileAccessFailure.preferred(verified.accessFailure,
                            FileAccessFailure.preferred(metadataWarning?.accessFailure, cleanupWarning?.accessFailure))
                        var retention: String?
                        var cause: SourceRetentionCause?
                        // Destination-side failures are attributed to the destination folder.
                        var failureLocation: URL? = accessFailure == nil ? nil : to.directoryURL
                        if removesSource {
                            // MAC-066/067: the copy is committed. Verification and removal are
                            // separate, revalidated steps; any failure keeps the original and never throws.
                            let kept = "The original was kept in \(from.directoryURL.path)"
                            if metadataWarning != nil {
                                retention = "\(kept) because its permissions or file flags could not be fully reproduced at the destination."
                                cause = .metadataNotPreserved
                            } else if verified.warning != nil || verified.identity != copiedIdentity {
                                retention = "\(kept) because the published copy could not be verified."
                                cause = .destinationNotVerified
                            } else {
                                var verifiedTree = false
                                do {
                                    // Every copied entry must still be present, unchanged, in the
                                    // published tree before any original is removed (MAC-067).
                                    try staging.verifyPublished(name: name, parent: destinationFD, relative: ["payload"],
                                                                sourceLedger: worker.ledger)
                                    verifiedTree = true
                                } catch {
                                    retention = "\(kept) because the published copy could not be verified. \(error.localizedDescription)"
                                    cause = .destinationNotVerified
                                    if let failure = FileAccessFailure.classify(error) {
                                        (accessFailure, failureLocation) = Self.selectAccessFailure(failure, at: to.directoryURL,
                                            current: accessFailure, currentLocation: failureLocation)
                                    }
                                }
                                if verifiedTree {
                                    onProgress(TransferProgress(currentName: item.name, bytesCopied: worker.bytesCopied,
                                                                itemsCompleted: worker.itemsCompleted, phase: .removingOriginals))
                                    do {
                                        try LocalFileOperations.revalidateRoute(from, resolved: sourceRoot)
                                        try SourceRemoval(ledger: worker.ledger, afterUnlink: afterSourceUnlink)
                                            .remove(item.name, parent: sourceFD, relative: ["payload"])
                                    } catch {
                                        retention = "\(kept) because it could not be completely removed after a verified copy. \(error.localizedDescription)"
                                        cause = .originalNotRemovable
                                        if let failure = FileAccessFailure.classify(error) {
                                            (accessFailure, failureLocation) = Self.selectAccessFailure(failure, at: from.directoryURL,
                                                current: accessFailure, currentLocation: failureLocation)
                                        }
                                    }
                                }
                            }
                        }
                        return FileOperationResult(url: verified.url, identity: verified.identity, warning: warning.isEmpty ? nil : warning,
                            accessFailure: accessFailure, sourceRetention: retention,
                            retainedOriginalLocation: retention == nil ? nil : from.directoryURL,
                            sourceRetentionCause: cause, accessFailureLocation: failureLocation,
                            transferredBytes: worker.bytesCopied, transferredEntries: worker.itemsCompleted,
                            replacedReceipt: replaced)
                    } catch {
                        let operationError = error
                        do { try staging.removeUnpublished() }
                        catch {
                            let cleanup = FileTransferError.cleanupFailed(cause: operationError.localizedDescription, stagingURL: staging.url,
                                accessFailure: FileAccessFailure.preferred(FileAccessFailure.classify(operationError), FileAccessFailure.classify(error)))
                            // The receipt must survive a cleanup failure (review d0a87c9e #2).
                            if let recovery = operationError as? ReplacementRecoveryError {
                                throw ReplacementRecoveryError(receipt: recovery.receipt,
                                    cause: "\(recovery.cause) Unpublished staging could not be safely removed. Inspect its original location, which may have moved: \(staging.url.path).",
                                    accessFailure: FileAccessFailure.preferred(recovery.accessFailure, FileAccessFailure.classify(error)))
                            }
                            throw cleanup
                        }
                        throw operationError
                    }
                }
            }
        }
    }
}

extension LocalFileTransfers {
    static func directoryNames(in descriptor: Int32, checkpoint: () throws -> Void = {}) throws -> [String] {
        var names: [String] = []
        do {
            try DescriptorIO.forEachDirectoryEntry(in: descriptor, checkpoint: checkpoint) { names.append($0) }
        } catch DescriptorIO.DirectoryEntryError.invalidUTF8 {
            throw FileOperationError.unsupported("A filename is not valid UTF-8 and cannot be copied safely.")
        }
        return names
    }

    /// MAC-071/073: Replace applies only to the exact compared non-folder entry.
    static func verifyReplacement(_ target: ReplacementTarget, name: String, at destination: Int32, source: stat) throws {
        guard target.name == name else { throw TransferReplacementError.destinationChanged(name) }
        var value = stat()
        guard name.withCString({ fstatat(destination, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { throw TransferReplacementError.destinationChanged(name) }
            throw LocalFileOperations.failure(errno, operation: "Inspect existing item", name: name)
        }
        guard target.matches(value) else { throw TransferReplacementError.destinationChanged(name) }
        let sourceType = source.st_mode & mode_t(S_IFMT)
        guard target.isReplaceable, sourceType == mode_t(S_IFREG) || sourceType == mode_t(S_IFLNK) else {
            throw TransferReplacementError.notReplaceable(name)
        }
        guard LocalFileIdentity.fromStat(value) != LocalFileIdentity.fromStat(source) else {
            throw FileOperationError.unsupported("The source and destination identify the same item.")
        }
    }

    /// Recheck the compared entry, honour a last cancellation request, announce
    /// the uninterruptible phase, then move the entry to the Trash through the
    /// identity-checked recovery service. Returns only with a verified receipt;
    /// otherwise nothing is published (MAC-071/072, review d0a87c9e #1/#4).
    func retire(_ target: ReplacementTarget, name: String, in context: FileOperationContext,
                at destination: Int32, source: stat, control: TransferControl, cancellation: BlockingIOCancellation,
                onProgress: @Sendable (TransferProgress) -> Void, committed: TransferProgress) throws -> TrashReceipt {
        // A pause may block here; the compared item is verified only afterwards,
        // so an edit made while paused needs a fresh decision (review 55b3f24a #7).
        try hooks.beforeTrash?(control)
        try control.checkpoint()
        try cancellation.checkCancellation()
        try Self.verifyReplacement(target, name: name, at: destination, source: source)
        // From here the item is committed: Trash, then publish or restore.
        onProgress(committed)
        let isLink = target.fileType == UInt16(S_IFLNK)
        let existing = FileItem(url: context.directoryURL.appendingPathComponent(name), name: name,
            isDirectory: false, isSymbolicLink: isLink, size: isLink ? nil : target.size,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(target.modifiedSeconds)
                             + TimeInterval(target.modifiedNanoseconds) / 1_000_000_000),
            kind: isLink ? "Symbolic link" : "Replaced item", identity: target.identity)
        let result: TrashResult
        do {
            if let trash = hooks.trash { result = try trash(existing, context, nil) }
            else { result = try LocalFileRecovery().trashNow(existing, in: context, cancellation: nil) }
        } catch let FileRecoveryError.outcomeUncertain(detail, accessFailure) {
            throw ReplacementTrashError.uncertain(name: name, detail: detail, accessFailure: accessFailure)
        }
        guard let receipt = result.receipt else {
            // MAC-072/MAC-032: no verified receipt. Put the exact item back if the
            // reported location still holds it; otherwise report what is known.
            if let location = result.trashedURL, Self.putBackUnverified(location, expected: target.identity,
                                                                        name: name, at: destination) {
                // The Trash warning's recovery instructions no longer apply (review 062c7093 #10).
                throw ReplacementTrashError.putBack(name: name, detail: "")
            }
            throw ReplacementTrashError.unverified(name: name, trashLocation: result.trashedURL,
                                                   detail: result.warning ?? "", accessFailure: result.accessFailure)
        }
        return receipt
    }

    /// Exclusive, identity-checked rename of a just-trashed item back to its name.
    /// Path-based on the Trash side, like the native Trash call itself (MAC-032).
    static func putBackUnverified(_ location: URL, expected: LocalFileIdentity, name: String, at destination: Int32) -> Bool {
        var value = stat()
        guard location.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0,
              LocalFileIdentity.fromStat(value) == expected else { return false }
        return location.withUnsafeFileSystemRepresentation { old in
            name.withCString { renameatx_np(AT_FDCWD, old!, destination, $0, UInt32(RENAME_EXCL)) }
        } == 0
    }

    /// MAC-072: publication failed after the existing item was trashed.
    static func putBack(_ receipt: TrashReceipt, after failure: Error) throws {
        do { try LocalFileRecovery.restoreNow(receipt) }
        catch {
            throw ReplacementRecoveryError(receipt: receipt, cause: failure.localizedDescription,
                accessFailure: FileAccessFailure.preferred(FileAccessFailure.classify(failure), FileAccessFailure.classify(error)))
        }
    }

    /// Keeps the selected access failure and the place it happened together, so
    /// Access Help never pairs one failure with another's location (f7716cbf).
    static func selectAccessFailure(_ new: FileAccessFailure?, at location: URL,
                                    current: FileAccessFailure?, currentLocation: URL?) -> (FileAccessFailure?, URL?) {
        guard let new else { return (current, currentLocation) }
        let selected = FileAccessFailure.preferred(current, new)
        if current == nil || (selected == new && selected != current) { return (selected, location) }
        return (selected, currentLocation)
    }
}

private enum TransferIO {
    static let deferredFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    static func type(_ value: stat) -> mode_t { value.st_mode & mode_t(S_IFMT) }
    static func validateNode(_ value: stat) throws {
        guard value.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw FileOperationError.unsupported("Dataless placeholder items are not supported by this transfer service.")
        }
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type(value)) else {
            throw FileOperationError.unsupported("Only regular files, folders, packages and symbolic links can be transferred.")
        }
    }
    static func entry(_ name: String, at parent: Int32) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Inspect source", name: name)
        }
        return value
    }
    static func descriptorStat(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw LocalFileOperations.failure(errno, operation: "Inspect open item", name: "") }
        return value
    }
    static func openEntry(_ name: String, at parent: Int32, flags: Int32, expected: stat) throws -> Int32 {
        let fd = name.withCString { openat(parent, $0, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw LocalFileOperations.failure(errno, operation: "Open source", name: name) }
        do {
            let actual = try descriptorStat(fd)
            guard LocalFileIdentity.fromStat(actual) == LocalFileIdentity.fromStat(expected), type(actual) == type(expected) else {
                throw FileOperationError.staleSource
            }
            try validateNode(actual)
            var filesystem = statfs()
            guard fstatfs(fd, &filesystem) == 0 else {
                throw LocalFileOperations.failure(errno, operation: "Inspect source filesystem", name: name)
            }
            guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw FileOperationError.unsupported("Transfer sources must remain on confirmed local filesystems.")
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func checkDestination(_ name: String, at parent: Int32, source: LocalFileIdentity, kind: TransferKind) throws {
        var value = stat()
        let result = name.withCString { fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result == 0 {
            if kind == .move, LocalFileIdentity.fromStat(value) == source {
                throw FileOperationError.unsupported("The source and destination identify the same item.")
            }
            throw FileOperationError.collision(name)
        }
        guard errno == ENOENT else { throw LocalFileOperations.failure(errno, operation: "Inspect destination", name: name) }
    }
    static func rejectDescendant(_ destination: Int32, of source: LocalFileIdentity) throws {
        var current = dup(destination)
        guard current >= 0 else { throw POSIXError(.EBADF) }
        defer { close(current) }
        for _ in 0..<1024 {
            let identity = LocalFileIdentity.fromStat(try descriptorStat(current))
            guard let identity else { throw FileOperationError.unsupported("Could not verify destination ancestry.") }
            if identity == source { throw FileOperationError.unsupported("A folder cannot be transferred into its own subtree.") }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let parentIdentity: LocalFileIdentity?
            do { parentIdentity = LocalFileIdentity.fromStat(try descriptorStat(parent)) }
            catch { close(parent); throw error }
            if identity == parentIdentity { close(parent); return }
            close(current)
            current = parent
        }
        throw FileOperationError.unsupported("Destination ancestry exceeds the supported verification depth.")
    }
    static func unchanged(_ before: stat, _ after: stat) -> Bool {
        LocalFileIdentity.fromStat(before) == LocalFileIdentity.fromStat(after)
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}

/// Source ACL storage is independent of the source object. It owns no file
/// descriptor and is released with this one top-level copy's existing ledger.
final class DeferredCopyMetadata {
    let accessControl: acl_t
    let restrictiveFlags: UInt32
    var mode: mode_t?

    init(source: Int32, flags: UInt32) throws {
        if let acl = acl_get_fd_np(source, ACL_TYPE_EXTENDED) {
            accessControl = acl
        } else {
            // On the target APFS, no extended ACL is ENOENT even while fstat
            // confirms this continuously held source descriptor still exists.
            let code = errno
            guard code == ENOENT || code == ENOTSUP || code == EOPNOTSUPP else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            _ = try TransferIO.descriptorStat(source)
            guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
            accessControl = empty
        }
        restrictiveFlags = flags & TransferIO.deferredFlags
    }
    deinit { acl_free(UnsafeMutableRawPointer(accessControl)) }

    static func clearAccessControl(_ descriptor: Int32) throws {
        try DescriptorIO.clearExtendedACL(descriptor)
    }

    func apply(to descriptor: Int32) throws {
        guard let mode else { throw FileOperationError.staleSource }
        // Publication begins owner-only. Install access restrictions before mode
        // bits can grant group/other access; failure leaves the restrictive mode.
        if acl_set_fd_np(descriptor, accessControl, ACL_TYPE_EXTENDED) != 0 {
            let code = errno
            guard code == ENOTSUP || code == EOPNOTSUPP else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var entry: acl_entry_t?
            // Both native capture and acl_init produce valid ACLs. On Darwin,
            // acl_get_entry returns 0 when an entry exists, -1 for an empty ACL.
            guard acl_get_entry(accessControl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else {
                throw FileOperationError.unsupported("The destination cannot preserve the source access control list.")
            }
        }
        guard fchmod(descriptor, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let current = try TransferIO.descriptorStat(descriptor)
        let flags = (current.st_flags & ~TransferIO.deferredFlags) | restrictiveFlags
        if flags != current.st_flags, fchflags(descriptor, flags) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// The byte-keyed identity ledger is limited to this one owned staging tree. It
/// lets cancellation refuse deletion of injected/replaced entries instead of following them.
private final class OwnedTransferStage {
    let descriptor: Int32
    let parent: Int32
    let name: String
    let url: URL
    let identity: LocalFileIdentity
    private struct Entry {
        var identity: LocalFileIdentity
        var metadata: DeferredCopyMetadata?
    }
    private var owned: [[Data]: Entry] = [:]

    init(parent: Int32, parentURL: URL) throws {
        self.parent = parent
        name = ".explorer-transfer-" + UUID().uuidString
        url = parentURL.appendingPathComponent(name, isDirectory: true)
        guard name.withCString({ mkdirat(parent, $0, mode_t(0o700)) }) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Create transfer staging", name: name)
        }
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            let failure = LocalFileOperations.failure(errno, operation: "Open newly created staging folder", name: name)
            throw FileTransferError.cleanupFailed(cause: failure.localizedDescription, stagingURL: url,
                accessFailure: FileAccessFailure.classify(failure))
        }
        do {
            guard let sampled = LocalFileIdentity.fromStat(try TransferIO.descriptorStat(fd)) else {
                throw FileOperationError.unsupported("Could not identify the staging folder.")
            }
            guard try LocalFileOperations.identity(of: name, in: parent) == sampled else {
                throw FileOperationError.staleParent
            }
            // This exclusive, identity-checked container is private staging;
            // inherited ACLs must not grant access or prevent owned cleanup.
            try DeferredCopyMetadata.clearAccessControl(fd)
            guard fchmod(fd, mode_t(0o700)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            descriptor = fd
            identity = sampled
        } catch {
            close(fd)
            throw FileTransferError.cleanupFailed(cause: "Could not prepare the staging folder. \(error.localizedDescription)", stagingURL: url,
                accessFailure: FileAccessFailure.classify(error))
        }
    }
    deinit { close(descriptor) }
    func record(_ relative: [String], parent: Int32, name: String) throws {
        owned[relative.map { Data($0.utf8) }] = Entry(identity: try LocalFileOperations.identity(of: name, in: parent))
    }
    func verifiedIdentity(_ relative: [String], parent: Int32, name: String) throws -> LocalFileIdentity {
        guard let expected = owned[relative.map({ Data($0.utf8) })]?.identity,
              try LocalFileOperations.identity(of: name, in: parent) == expected else { throw FileOperationError.staleSource }
        return expected
    }
    func reconcileCopiedMetadata(_ relative: [String], parent: Int32, name: String, descriptor: Int32) throws {
        let key = relative.map { Data($0.utf8) }
        guard let original = owned[key]?.identity else { throw FileOperationError.staleSource }
        owned[key]?.identity = try LocalFileIdentity.afterMetadataCopy(of: original, descriptor: descriptor,
                                                                       parent: parent, name: name)
    }
    func prepareMetadata(_ metadata: DeferredCopyMetadata, relative: [String], parent: Int32,
                         name: String, descriptor: Int32) throws {
        // Always run after native copying, including its error/cancel return.
        // Reconcile the held object's changed birth time before cleanup can need it.
        try reconcileCopiedMetadata(relative, parent: parent, name: name, descriptor: descriptor)
        let value = try TransferIO.descriptorStat(descriptor)
        metadata.mode = value.st_mode & mode_t(0o7777)
        owned[relative.map { Data($0.utf8) }]?.metadata = metadata
        if value.st_flags & TransferIO.deferredFlags != 0 {
            guard fchflags(descriptor, value.st_flags & ~TransferIO.deferredFlags) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try DeferredCopyMetadata.clearAccessControl(descriptor)
        // A source may be readable through its ACL despite restrictive mode bits.
        // Keep owned staging traversable until final ACL/mode installation.
        let ownerAccess = TransferIO.type(value) == S_IFDIR ? mode_t(0o700) : mode_t(0o600)
        guard fchmod(descriptor, ownerAccess) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = try verifiedIdentity(relative, parent: parent, name: name)
    }
    /// MAC-067: before removing any original, every entry the copy published must
    /// still be the owned object with the original's type and size.
    func verifyPublished(name: String, parent: Int32, relative: [String], sourceLedger: [[Data]: stat]) throws {
        var children: [[Data]: [String]] = [:]
        for key in sourceLedger.keys where key.count > 1 {
            children[Array(key.dropLast()), default: []].append(String(decoding: key.last!, as: UTF8.self))
        }
        try verify(name, parent: parent, relative: relative, sourceLedger: sourceLedger, children: children)
    }

    private func verify(_ name: String, parent: Int32, relative: [String], sourceLedger: [[Data]: stat],
                        children: [[Data]: [String]]) throws {
        let key = relative.map { Data($0.utf8) }
        guard let source = sourceLedger[key], let expected = owned[key]?.identity else {
            throw FileOperationError.unsupported("The published copy does not account for “\(name)”.")
        }
        let current: stat
        do { current = try TransferIO.entry(name, at: parent) }
        catch {
            guard FileAccessFailure.isMissingLocation(error) else { throw error }
            throw FileOperationError.unsupported("The published copy of “\(name)” is missing.")
        }
        guard LocalFileIdentity.fromStat(current) == expected, TransferIO.type(current) == TransferIO.type(source) else {
            throw FileOperationError.unsupported("The published copy of “\(name)” changed after publication.")
        }
        switch TransferIO.type(current) {
        case mode_t(S_IFREG), mode_t(S_IFLNK):
            guard current.st_size == source.st_size else {
                throw FileOperationError.unsupported("The published copy of “\(name)” does not have the original's size.")
            }
        case mode_t(S_IFDIR):
            let fd = try TransferIO.openEntry(name, at: parent, flags: O_RDONLY | O_DIRECTORY, expected: current)
            defer { close(fd) }
            for child in children[key] ?? [] {
                try verify(child, parent: fd, relative: relative + [child], sourceLedger: sourceLedger, children: children)
            }
        default:
            throw FileOperationError.unsupported("The published copy of “\(name)” has an unsupported type.")
        }
    }

    func finalizePublished(name: String, parent: Int32) -> (message: String, accessFailure: FileAccessFailure?)? {
        var warnings = FinalizationWarnings()
        do {
            try finalize(name, parent: parent, relative: ["payload"], warnings: &warnings)
        } catch {
            warnings.record(error)
        }
        guard warnings.count > 0 else { return nil }
        return ("The copy completed, but permissions or file flags need attention for \(warnings.count) item(s). \(warnings.first ?? "")", warnings.accessFailure)
    }
    private struct FinalizationWarnings {
        var count = 0
        var first: String?
        var accessFailure: FileAccessFailure?
        mutating func record(_ message: String) { count += 1; if first == nil { first = message } }
        mutating func record(_ error: Error) {
            record(error.localizedDescription)
            accessFailure = FileAccessFailure.preferred(accessFailure, FileAccessFailure.classify(error))
        }
    }
    private func finalize(_ name: String, parent: Int32, relative: [String], warnings: inout FinalizationWarnings) throws {
        let expected = try verifiedIdentity(relative, parent: parent, name: name)
        let value = try TransferIO.entry(name, at: parent)
        guard LocalFileIdentity.fromStat(value) == expected else { throw FileOperationError.staleSource }
        let isDirectory = TransferIO.type(value) == S_IFDIR
        guard isDirectory || TransferIO.type(value) == S_IFREG else { return }
        let fd = try TransferIO.openEntry(name, at: parent, flags: O_RDONLY | (isDirectory ? O_DIRECTORY : 0), expected: value)
        defer { close(fd) }
        if isDirectory {
            for child in try LocalFileTransfers.directoryNames(in: fd) {
                let childRelative = relative + [child]
                guard owned[childRelative.map { Data($0.utf8) }] != nil else {
                    warnings.record("An item added after publication was left untouched.")
                    continue
                }
                do { try finalize(child, parent: fd, relative: childRelative, warnings: &warnings) }
                catch { warnings.record(error) }
            }
        }
        // Never mutate a replacement pathname. The live descriptor also remains
        // bound to the recorded object if a rename races after this last check.
        _ = try verifiedIdentity(relative, parent: parent, name: name)
        try owned[relative.map { Data($0.utf8) }]?.metadata?.apply(to: fd)
    }
    func removeUnpublished() throws {
        guard try LocalFileOperations.identity(of: name, in: parent) == identity else { throw FileOperationError.staleParent }
        guard LocalFileIdentity.fromStat(try TransferIO.descriptorStat(descriptor)) == identity else { throw FileOperationError.staleParent }
        try DeferredCopyMetadata.clearAccessControl(descriptor)
        for child in try LocalFileTransfers.directoryNames(in: descriptor) { try remove(child, parent: descriptor, relative: [child]) }
        try removeContainer()
    }
    func cleanupAfterPublication() -> (message: String, accessFailure: FileAccessFailure?)? {
        do { try removeContainer(); return nil }
        catch {
            return ("The copy completed, but removal of its staging folder could not be verified. Its original location was \(url.path).",
                    FileAccessFailure.classify(error))
        }
    }
    private func removeContainer() throws {
        guard try LocalFileOperations.identity(of: name, in: parent) == identity else { throw FileOperationError.staleParent }
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func remove(_ name: String, parent: Int32, relative: [String]) throws {
        let value = try TransferIO.entry(name, at: parent)
        guard let expected = owned[relative.map({ Data($0.utf8) })]?.identity, LocalFileIdentity.fromStat(value) == expected else {
            throw FileOperationError.staleSource
        }
        let isDirectory = TransferIO.type(value) == S_IFDIR
        if isDirectory || TransferIO.type(value) == S_IFREG {
            let fd = try TransferIO.openEntry(name, at: parent, flags: O_RDONLY | (isDirectory ? O_DIRECTORY : 0), expected: value)
            defer { close(fd) }
            // Only our identity-verified, unpublished copies are adjusted for cleanup.
            if value.st_flags & TransferIO.deferredFlags != 0 {
                guard fchflags(fd, value.st_flags & ~TransferIO.deferredFlags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            try DeferredCopyMetadata.clearAccessControl(fd)
            if isDirectory {
                guard fchmod(fd, mode_t(0o700)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                for child in try LocalFileTransfers.directoryNames(in: fd) { try remove(child, parent: fd, relative: relative + [child]) }
            }
        }
        guard try LocalFileOperations.identity(of: name, in: parent) == expected else { throw FileOperationError.staleSource }
        guard name.withCString({ unlinkat(parent, $0, isDirectory ? AT_REMOVEDIR : 0) }) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private final class TransferCopyWorker {
    let stage: OwnedTransferStage
    let sourceDevice: dev_t
    let forbiddenDirectories: Set<LocalFileIdentity>
    let control: TransferControl
    let onProgress: @Sendable (TransferProgress) -> Void
    var bytesCopied: Int64 = 0
    /// Entries fully copied so far, and their source stat at copy time (MAC-066).
    var itemsCompleted = 0
    var ledger: [[Data]: stat] = [:]
    private var lastItemEmission: UInt64 = 0
    var directories: Set<LocalFileIdentity> = []

    init(stage: OwnedTransferStage, sourceDevice: dev_t, forbiddenDirectories: Set<LocalFileIdentity>, control: TransferControl,
         onProgress: @escaping @Sendable (TransferProgress) -> Void) {
        self.stage = stage; self.sourceDevice = sourceDevice; self.forbiddenDirectories = forbiddenDirectories
        self.control = control; self.onProgress = onProgress
    }

    func copy(sourceParent: Int32, sourceName: String, destinationParent: Int32, destinationName: String,
              relative: [String], expected: LocalFileIdentity?, depth: Int) throws {
        try control.checkpoint()
        guard depth < 256 else { throw FileOperationError.unsupported("The folder tree exceeds the supported copy depth.") }
        let source = try TransferIO.entry(sourceName, at: sourceParent)
        try TransferIO.validateNode(source)
        guard source.st_dev == sourceDevice else { throw FileOperationError.unsupported("Copying across a nested mount is not supported.") }
        guard let identity = LocalFileIdentity.fromStat(source), expected == nil || identity == expected else { throw FileOperationError.staleSource }
        if TransferIO.type(source) == S_IFDIR, forbiddenDirectories.contains(identity) {
            throw FileOperationError.unsupported("The source tree now contains the destination or transfer staging folder.")
        }
        switch TransferIO.type(source) {
        case mode_t(S_IFLNK):
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = sourceName.withCString { readlinkat(sourceParent, $0, &target, target.count - 1) }
            guard length >= 0 else { throw LocalFileOperations.failure(errno, operation: "Read symbolic link", name: sourceName) }
            guard length < target.count - 1 else { throw FileOperationError.unsupported("The symbolic-link target could not be read completely.") }
            target[length] = 0
            let result = destinationName.withCString { name in target.withUnsafeBufferPointer { symlinkat($0.baseAddress!, destinationParent, name) } }
            guard result == 0 else { throw LocalFileOperations.failure(errno, operation: "Copy symbolic link", name: sourceName) }
            try stage.record(relative, parent: destinationParent, name: destinationName)
        case mode_t(S_IFREG), mode_t(S_IFDIR):
            let isDirectory = TransferIO.type(source) == S_IFDIR
            if isDirectory, !directories.insert(identity).inserted { throw FileOperationError.unsupported("A repeated directory identity prevents safe recursive copying.") }
            let sourceFD = try TransferIO.openEntry(sourceName, at: sourceParent,
                flags: O_RDONLY | (isDirectory ? O_DIRECTORY : 0), expected: source)
            defer { close(sourceFD) }
            let deferredMetadata = try DeferredCopyMetadata(source: sourceFD, flags: source.st_flags)
            let destinationFD: Int32
            if isDirectory {
                guard destinationName.withCString({ mkdirat(destinationParent, $0, mode_t(0o700)) }) == 0 else {
                    throw LocalFileOperations.failure(errno, operation: "Copy folder", name: sourceName)
                }
                try stage.record(relative, parent: destinationParent, name: destinationName)
                destinationFD = destinationName.withCString { openat(destinationParent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            } else {
                destinationFD = destinationName.withCString { openat(destinationParent, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
                if destinationFD >= 0 {
                    do { try stage.record(relative, parent: destinationParent, name: destinationName) }
                    catch { close(destinationFD); throw error }
                }
            }
            guard destinationFD >= 0 else { throw LocalFileOperations.failure(errno, operation: "Create staged item", name: sourceName) }
            defer { close(destinationFD) }
            let ownedIdentity = try stage.verifiedIdentity(relative, parent: destinationParent, name: destinationName)
            guard LocalFileIdentity.fromStat(try TransferIO.descriptorStat(destinationFD)) == ownedIdentity else {
                throw FileOperationError.staleSource
            }
            if isDirectory {
                for child in try LocalFileTransfers.directoryNames(in: sourceFD, checkpoint: control.checkpoint) {
                    try copy(sourceParent: sourceFD, sourceName: child, destinationParent: destinationFD,
                             destinationName: child, relative: relative + [child], expected: nil, depth: depth + 1)
                }
            }
            var copyFailure: Error?
            do {
                try copyNative(sourceFD: sourceFD, destinationFD: destinationFD, name: sourceName,
                               flags: copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | (isDirectory ? 0 : COPYFILE_DATA)), hasData: !isDirectory)
                // Verified content length is a precondition for publication and
                // for removing an original after a cross-volume move.
                if !isDirectory, try TransferIO.descriptorStat(destinationFD).st_size != source.st_size {
                    throw FileOperationError.unsupported("The copy of “\(sourceName)” does not have the original's size.")
                }
            } catch { copyFailure = error }
            // Native STAT may already have changed birth time or flags even when
            // cancellation/error interrupted another part of the native call.
            try stage.prepareMetadata(deferredMetadata, relative: relative, parent: destinationParent,
                                      name: destinationName, descriptor: destinationFD)
            if let copyFailure { throw copyFailure }
            guard TransferIO.unchanged(source, try TransferIO.descriptorStat(sourceFD)) else { throw FileOperationError.staleSource }
        default: throw FileOperationError.unsupported("Unsupported transfer item.")
        }
        guard TransferIO.unchanged(source, try TransferIO.entry(sourceName, at: sourceParent)) else { throw FileOperationError.staleSource }
        ledger[relative.map { Data($0.utf8) }] = source
        itemsCompleted += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if depth == 0 || now - lastItemEmission >= 50_000_000 {
            lastItemEmission = now
            onProgress(TransferProgress(currentName: sourceName, bytesCopied: bytesCopied, itemsCompleted: itemsCompleted))
        }
        try control.checkpoint()
    }

    private func copyNative(sourceFD: Int32, destinationFD: Int32, name: String,
                            flags: copyfile_flags_t, hasData: Bool) throws {
        try control.checkpoint()
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = NativeCopyProgress(control: control, name: name, base: bytesCopied, items: itemsCompleted,
                                         onProgress: onProgress)
        let callback: copyfile_callback_t = { what, stage, state, _, _, raw in
            guard let raw else { return COPYFILE_QUIT }
            let context = Unmanaged<NativeCopyProgress>.fromOpaque(raw).takeUnretainedValue()
            do {
                if stage == COPYFILE_ERR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try context.control.checkpoint()
                if what == COPYFILE_COPY_DATA && (stage == COPYFILE_PROGRESS || stage == COPYFILE_FINISH) {
                    var copied: off_t = 0
                    guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else { throw POSIXError(.EIO) }
                    context.emit(Int64(copied), force: stage == COPYFILE_FINISH)
                }
                try context.control.checkpoint()
                return COPYFILE_CONTINUE
            } catch { context.error = error; return COPYFILE_QUIT }
        }
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0 else { throw POSIXError(.EINVAL) }
        let result = withExtendedLifetime(context) { fcopyfile(sourceFD, destinationFD, state, flags) }
        if let error = context.error { throw error }
        guard result == 0 else { throw LocalFileOperations.failure(errno, operation: "Copy file data and metadata", name: name) }
        if hasData {
            var copied: off_t = 0
            guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else { throw POSIXError(.EIO) }
            bytesCopied += Int64(copied)
            context.emit(Int64(copied), force: true)
        }
        try control.checkpoint()
    }
}

private final class NativeCopyProgress {
    let control: TransferControl
    let name: String
    let base: Int64
    let items: Int
    let onProgress: @Sendable (TransferProgress) -> Void
    var error: Error?
    private var lastEmission: UInt64 = 0
    private var lastBytes: Int64?
    init(control: TransferControl, name: String, base: Int64, items: Int,
         onProgress: @escaping @Sendable (TransferProgress) -> Void) {
        self.control = control; self.name = name; self.base = base; self.items = items; self.onProgress = onProgress
    }
    func emit(_ copied: Int64, force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastBytes != copied,
              force || lastBytes == nil || now - lastEmission >= 50_000_000 else { return }
        lastBytes = copied
        lastEmission = now
        onProgress(TransferProgress(currentName: name, bytesCopied: base + copied, itemsCompleted: items))
    }
}

/// MAC-067: removes only the original entries this transfer copied, depth
/// first and descriptor-relative, never following links or altering source
/// permissions, flags or ACLs. Any mismatch or error stops removal; the caller
/// reports the original as kept. Identity is rechecked immediately before each
/// unlink (Darwin has no funlinkat), leaving only that narrow documented window.
private final class SourceRemoval {
    private let ledger: [[Data]: stat]
    /// For a hard-linked inode whose earlier name this removal unlinked: the
    /// exact inode state sampled through a held descriptor right after that
    /// unlink. Later names must match it exactly (including status time).
    private var afterOwnUnlink: [LocalFileIdentity: stat] = [:]
    /// Inodes whose state could not be attributed to this removal; never removed.
    private var unattributable: Set<LocalFileIdentity> = []
    private let afterUnlink: (@Sendable (String) -> Void)?
    init(ledger: [[Data]: stat], afterUnlink: (@Sendable (String) -> Void)? = nil) {
        self.ledger = ledger
        self.afterUnlink = afterUnlink
    }

    func remove(_ name: String, parent: Int32, relative: [String]) throws {
        let key = relative.map { Data($0.utf8) }
        guard let recorded = ledger[key], let identity = LocalFileIdentity.fromStat(recorded) else {
            throw FileOperationError.unsupported("“\(name)” was not part of the completed copy.")
        }
        let current = try TransferIO.entry(name, at: parent)
        guard LocalFileIdentity.fromStat(current) == identity, TransferIO.type(current) == TransferIO.type(recorded) else {
            throw FileOperationError.unsupported("“\(name)” was replaced after it was copied.")
        }
        // Folders are checked before their own contents are removed, so any
        // change (including xattrs/tags) was external, not caused by this removal.
        let expected = afterOwnUnlink[identity] ?? recorded
        guard !unattributable.contains(identity), TransferIO.unchanged(expected, current),
              current.st_nlink == expected.st_nlink else {
            throw FileOperationError.unsupported("“\(name)” changed after it was copied.")
        }
        let isDirectory = TransferIO.type(current) == S_IFDIR
        if isDirectory {
            let fd = try TransferIO.openEntry(name, at: parent, flags: O_RDONLY | O_DIRECTORY, expected: current)
            defer { close(fd) }
            let children = try LocalFileTransfers.directoryNames(in: fd)
            if let added = children.first(where: { ledger[(relative + [$0]).map { Data($0.utf8) }] == nil }) {
                throw FileOperationError.unsupported("“\(added)” was added to “\(name)” after the copy began.")
            }
            for child in children { try remove(child, parent: fd, relative: relative + [child]) }
        }
        // A hard-linked regular file is held open so the inode's exact state after
        // this removal's own unlink can be sampled for its remaining names.
        var held: Int32 = -1
        if TransferIO.type(current) == S_IFREG, current.st_nlink > 1 {
            held = try TransferIO.openEntry(name, at: parent, flags: O_RDONLY, expected: current)
        }
        defer { if held >= 0 { close(held) } }
        guard LocalFileIdentity.fromStat(try TransferIO.entry(name, at: parent)) == identity else {
            throw FileOperationError.unsupported("“\(name)” was replaced after it was copied.")
        }
        guard name.withCString({ unlinkat(parent, $0, isDirectory ? AT_REMOVEDIR : 0) }) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Remove original", name: name)
        }
        if held >= 0 {
            // Sample before any test seam runs: only self-caused changes are attributed.
            var after = stat()
            if fstat(held, &after) == 0, LocalFileIdentity.fromStat(after) == identity,
               after.st_size == expected.st_size,
               after.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec,
               after.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec,
               after.st_nlink == expected.st_nlink - 1 {
                afterOwnUnlink[identity] = after
            } else {
                unattributable.insert(identity)
            }
        }
        afterUnlink?(name)
    }
}
