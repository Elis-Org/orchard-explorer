import Darwin
import Foundation

/// Synchronous, thread-scoped metadata inspection. Never await in the body.
struct HydrationMaterializationPolicy: Sendable {
    var get: @Sendable () -> Int32 = {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }
    var set: @Sendable (Int32) -> Int32 = {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, $0)
    }
    var reportFailure: @Sendable (String) -> Void = { NSLog("%@", $0) }

    func disabled<Value>(_ body: (_ restore: () throws -> Void) throws -> Value) throws -> Value {
        let previous = get()
        guard previous >= 0, set(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw ItemContentError.downloadFailed("The file access policy could not be set.")
        }
        var restoreAttempted = false
        func restore() throws {
            guard !restoreAttempted else { return }
            restoreAttempted = true
            let result = set(previous)
            guard result == 0 else {
                reportFailure("Cloud hydration materialization-policy restoration failed: result=\(result), errno=\(errno)")
                throw ItemContentError.downloadFailed("The file access policy could not be restored.")
            }
        }
        let result = Result { try body(restore) }
        if !restoreAttempted { try restore() }
        return try result.get()
    }
}

/// Existing-object authority is confined to one continuously held event-only FD.
/// There is no close method: the last strong reference alone closes the FD.
final class HydrationIdentityAnchor: @unchecked Sendable {
    private let descriptor: Int32
    let originalEntry: TransferEntry
    private let originalIdentity: LocalFileIdentity
    private let resolvedParentURL: URL
    private let access: PhysicalContentAccess
    private let maximumBytes: UInt64
    private let policy: HydrationMaterializationPolicy
    private let contentUse: PhysicalContentUseHold?

    private init(descriptor: Int32, entry: TransferEntry, identity: LocalFileIdentity, resolvedParentURL: URL,
                 access: PhysicalContentAccess, maximumBytes: UInt64,
                 policy: HydrationMaterializationPolicy, contentUse: PhysicalContentUseHold?) {
        self.descriptor = descriptor; originalEntry = entry; originalIdentity = identity
        self.resolvedParentURL = resolvedParentURL
        self.access = access; self.maximumBytes = maximumBytes; self.policy = policy
        self.contentUse = contentUse
    }
    deinit { close(descriptor); withExtendedLifetime(contentUse) {} }

    static func capture(_ entry: TransferEntry, parent: Int32, resolved: URL,
                        access: PhysicalContentAccess, maximumBytes: UInt64,
                        policy: HydrationMaterializationPolicy,
                        contentUse: PhysicalContentUseHold? = nil) throws -> HydrationIdentityAnchor {
        guard let identity = entry.item.identity else { throw ItemContentError.staleSource }
        let descriptor = openat(parent, entry.item.name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ContentFileIO.failure() }
        let anchor = HydrationIdentityAnchor(descriptor: descriptor, entry: entry, identity: identity, resolvedParentURL: resolved,
            access: access, maximumBytes: maximumBytes, policy: policy, contentUse: contentUse)
        let initial = try anchor.sampleVersion(parent: parent, resolved: resolved, dataless: true)
        guard initial.identity == identity else { throw ItemContentError.staleSource }
        return anchor
    }

    func sampleVersion(parent: Int32, resolved: URL, dataless: Bool = false) throws -> ContentFileVersion {
        try withExtendedLifetime(self) {
            guard resolved.path.utf8.elementsEqual(resolvedParentURL.path.utf8) else { throw ItemContentError.staleSource }
            let parentValue = try ContentFileIO.sample(parent)
            guard LocalFileIdentity.fromStat(parentValue) == originalEntry.source.directoryIdentity,
                  parentValue.st_flags & UInt32(SF_DATALESS) == 0 else { throw ItemContentError.staleSource }
            let first = try ContentFileVersion(access.sampleDescriptor(descriptor))
            let path = try ContentFileVersion(access.sample(originalEntry.item.name, parent))
            let second = try ContentFileVersion(access.sampleDescriptor(descriptor))
            guard first.identity.device == originalIdentity.device,
                  first.identity.inode == originalIdentity.inode,
                  first == path, first == second,
                  first.mode & UInt16(S_IFMT) == UInt16(S_IFREG), first.links == 1 else {
                throw ItemContentError.staleSource
            }
            // Route refusal takes precedence over residency or size classification.
            // A held descriptor can survive a moved-and-redirected parent.
            do { try LocalFileOperations.revalidateRoute(originalEntry.source, resolved: resolved) }
            catch { throw ItemContentError.staleSource }
            guard UInt64(first.size) <= maximumBytes else { throw ItemContentError.limitExceeded }
            let isDataless = first.flags & UInt32(SF_DATALESS) != 0
            if dataless { guard isDataless else { throw ItemContentError.staleSource } }
            else { guard !isDataless else { throw ItemContentError.cloudNotDownloaded } }
            return first
        }
    }

    func validate(_ version: ContentFileVersion) throws {
        try withExtendedLifetime(self) {
            try policy.disabled { _ in
                try LocalFileOperations.withParent(originalEntry.source) { parent, resolved in
                    guard try sampleVersion(parent: parent, resolved: resolved) == version else {
                        throw ItemContentError.staleSource
                    }
                }
            }
        }
    }

    func prepared(version: ContentFileVersion, requestID: UUID) -> PreparedPhysicalContent {
        let old = originalEntry.item
        let item = FileItem(url: old.url, name: old.name, isDirectory: old.isDirectory,
            isSymbolicLink: old.isSymbolicLink, size: version.size,
            modifiedAt: Date(timeIntervalSince1970: Double(version.modifiedSeconds) + Double(version.modifiedNanoseconds) / 1e9),
            kind: old.kind, identity: version.identity, archiveRevision: old.archiveRevision,
            availability: old.availability == .unknown ? .unknown : .availableLocally,
            isRegularFile: old.isRegularFile,
            statusVersion: LocalFileStatusVersion(size: version.size, modificationSeconds: version.modifiedSeconds,
                                                 modificationNanoseconds: version.modifiedNanoseconds),
            isDataless: version.flags & UInt32(SF_DATALESS) != 0)
        let accepted = TransferEntry(source: originalEntry.source, item: item)
        let receipt = version.identity != originalIdentity
            ? HydrationReconciliationReceipt(requestID: requestID, anchor: self, acceptedEntry: accepted, version: version) : nil
        return PreparedPhysicalContent(originalEntry: originalEntry, physicalEntry: accepted,
            version: version, anchor: self, reconciliation: receipt)
    }
}

struct PreparedPhysicalContent: Sendable {
    let originalEntry: TransferEntry
    let physicalEntry: TransferEntry
    let version: ContentFileVersion
    let anchor: HydrationIdentityAnchor?
    let reconciliation: HydrationReconciliationReceipt?

    init(resident entry: TransferEntry, observation: PhysicalContentObservation) {
        originalEntry = entry; physicalEntry = entry; version = observation.version
        anchor = nil; reconciliation = nil
    }
    fileprivate init(originalEntry: TransferEntry, physicalEntry: TransferEntry, version: ContentFileVersion,
                     anchor: HydrationIdentityAnchor, reconciliation: HydrationReconciliationReceipt?) {
        self.originalEntry = originalEntry; self.physicalEntry = physicalEntry; self.version = version
        self.anchor = anchor; self.reconciliation = reconciliation
    }
}

/// A one-use proof for the originating store's ordinary metadata refresh.
/// Invalidating drops this owner's reference, never an in-flight syscall's FD.
public final class HydrationReconciliationReceipt: @unchecked Sendable {
    public let requestID: UUID
    public let originalEntry: TransferEntry
    private let acceptedEntry: TransferEntry
    private let version: ContentFileVersion
    private let lock = NSLock()
    private enum State { case ready, claiming, consumed }
    private var state = State.ready
    private var anchor: HydrationIdentityAnchor?

    fileprivate init(requestID: UUID, anchor: HydrationIdentityAnchor,
                     acceptedEntry: TransferEntry, version: ContentFileVersion) {
        self.requestID = requestID; self.anchor = anchor; originalEntry = anchor.originalEntry
        self.acceptedEntry = acceptedEntry; self.version = version
    }
    public func invalidate() { withLock { state = .consumed; anchor = nil } }

    public func claim(requestID: UUID, originalEntry: TransferEntry,
                      snapshot: DirectorySnapshot) async throws -> VerifiedHydrationTransition {
        let held: HydrationIdentityAnchor = try withLock {
            guard state == .ready, let held = anchor else { throw ItemContentError.staleSource }
            state = .claiming
            return held
        }
        do {
            guard requestID == self.requestID,
                  Self.sameOrigin(originalEntry, self.originalEntry) else { throw ItemContentError.staleSource }
            let accepted = acceptedEntry, version = version
            let row = try await BlockingIO.run(on: .read) { cancellation in
                try cancellation.checkCancellation()
                guard snapshot.directoryIdentity == originalEntry.source.directoryIdentity else { throw ItemContentError.staleSource }
                let rows = snapshot.items.filter { $0.url.absoluteString.utf8.elementsEqual(originalEntry.item.url.absoluteString.utf8) }
                guard rows.count == 1, let row = rows.first, row.identity == accepted.item.identity,
                      row.size == version.size, !row.isDirectory, !row.isSymbolicLink,
                      row.archiveRevision == nil, row.isRegularFile != false else { throw ItemContentError.staleSource }
                let stamp = LocalFileStatusVersion(size: version.size, modificationSeconds: version.modifiedSeconds,
                                                   modificationNanoseconds: version.modifiedNanoseconds)
                if let listed = row.statusVersion, listed != stamp { throw ItemContentError.staleSource }
                try held.validate(version)
                try cancellation.checkCancellation()
                // The accepted refreshed row remains the sole store admission
                // path. Legacy unstamped snapshots gain only the held version
                // just validated above; contradictory captured stamps refuse it.
                return FileItem(url: row.url, name: row.name, isDirectory: row.isDirectory,
                    isSymbolicLink: row.isSymbolicLink, size: row.size, modifiedAt: row.modifiedAt,
                    kind: row.kind, identity: row.identity, archiveRevision: row.archiveRevision,
                    availability: row.availability, isRegularFile: row.isRegularFile, statusVersion: stamp)
            }
            try Task.checkCancellation()
            return try withLock {
                guard state == .claiming else { throw ItemContentError.staleSource }
                state = .consumed; anchor = nil
                return VerifiedHydrationTransition(requestID: requestID, originalEntry: self.originalEntry,
                    acceptedEntry: accepted, refreshedItem: row, anchor: held)
            }
        } catch { invalidate(); throw error }
    }

    private static func sameOrigin(_ lhs: TransferEntry, _ rhs: TransferEntry) -> Bool {
        lhs.source == rhs.source && lhs.item.url.absoluteString.utf8.elementsEqual(rhs.item.url.absoluteString.utf8)
            && lhs.item.name == rhs.item.name && lhs.item.identity != nil && lhs.item.identity == rhs.item.identity
    }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

/// Only a successful claim creates this value. Keep it through the atomic store
/// commit so descriptor ownership cannot disappear between validation and use.
public struct VerifiedHydrationTransition: Sendable {
    public let requestID: UUID
    public let originalEntry: TransferEntry
    public let acceptedEntry: TransferEntry
    public let refreshedItem: FileItem
    private let anchor: HydrationIdentityAnchor
    fileprivate init(requestID: UUID, originalEntry: TransferEntry, acceptedEntry: TransferEntry,
                     refreshedItem: FileItem, anchor: HydrationIdentityAnchor) {
        self.requestID = requestID; self.originalEntry = originalEntry; self.acceptedEntry = acceptedEntry
        self.refreshedItem = refreshedItem; self.anchor = anchor
    }
}
