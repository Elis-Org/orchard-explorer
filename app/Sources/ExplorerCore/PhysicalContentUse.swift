import Foundation

/// Captured conflict scope only; this never grants access or reconciles identity.
/// Directory aliases can spell one live file differently. Parent and leaf-name
/// agreement limit inode-reuse ambiguity; birth is omitted here because cloud
/// hydration can change it while the same descriptor remains owned.
public struct PhysicalContentTarget: Sendable {
    private struct Object: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        init(_ identity: LocalFileIdentity) { device = identity.device; inode = identity.inode }
    }
    private let path: String
    private let name: String
    private let object: Object?
    private let parent: Object?

    public init(_ entry: TransferEntry) {
        self.init(url: entry.item.url, identity: entry.item.identity, parentIdentity: entry.source.directoryIdentity)
    }
    init(url: URL, identity: LocalFileIdentity? = nil, parentIdentity: LocalFileIdentity? = nil) {
        path = url.standardizedFileURL.absoluteString
        name = url.lastPathComponent
        object = identity.map(Object.init); parent = parentIdentity.map(Object.init)
    }
    public func conflicts(with other: Self) -> Bool {
        // A pending pathname operation also protects that lexical route if its
        // current row is unknown or has been replaced. It grants no authority.
        if path == other.path { return true }
        guard name == other.name, let object, let otherObject = other.object, object == otherObject,
              let parent, let otherParent = other.parent else { return false }
        return parent == otherParent
    }
}

/// A lifetime fact, not an operation queue. Retention must wait for actual
/// physical preparation and lease cleanup even after their UI waiter disappears.
public final class PhysicalContentUse: @unchecked Sendable {
    public static let shared = PhysicalContentUse()
    private let lock = NSLock()
    private var owners: [UUID: PhysicalContentTarget] = [:]
    public func isInUse(of target: PhysicalContentTarget) -> Bool {
        lock.withLock { owners.values.contains { $0.conflicts(with: target) } }
    }
    public func isInUse(of url: URL) -> Bool { isInUse(of: PhysicalContentTarget(url: url)) }
    func retain(_ url: URL) -> PhysicalContentUseHold {
        retain(PhysicalContentTarget(url: url))
    }
    func retain(_ target: PhysicalContentTarget) -> PhysicalContentUseHold {
        let id = UUID()
        lock.withLock { owners[id] = target }
        return PhysicalContentUseHold { [self] in
            lock.withLock { _ = owners.removeValue(forKey: id) }
        }
    }
}

final class PhysicalContentUseHold: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable () -> Void)?
    init(finish: @escaping @Sendable () -> Void) { self.finish = finish }
    func end() {
        let action = lock.withLock { let action = finish; finish = nil; return action }
        action?()
    }
    deinit { end() }
}

/// Installed once by the store for both production and injected providers. A
/// returned lease takes ownership of the same fact; no UI lifetime is involved.
public struct RetentionAwareContentProvider: ItemContentProviding {
    private let base: any ItemContentProviding
    public init(base: any ItemContentProviding) { self.base = base }
    public func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        guard case .filesystem(let parent) = request.source.context,
              request.purpose == .preview || request.purpose == .download else {
            return try await base.materialize(request, control: control)
        }
        let hold = PhysicalContentUse.shared.retain(PhysicalContentTarget(TransferEntry(source: parent, item: request.source.item)))
        do {
            try Task.checkCancellation(); try control.checkpoint()
            let lease = try await base.materialize(request, control: control)
            return RetentionAwareContentLease(base: lease, hold: hold)
        } catch { hold.end(); throw error }
    }
}

private final class RetentionAwareContentLease: MaterializedContentLease, @unchecked Sendable {
    private let base: any MaterializedContentLease
    private let hold: PhysicalContentUseHold
    private let lock = NSLock()
    private var cleanup: Task<ContentLeaseReleaseResult, Never>?
    init(base: any MaterializedContentLease, hold: PhysicalContentUseHold) { self.base = base; self.hold = hold }
    var fileURL: URL { base.fileURL }
    var sourceURL: URL { base.sourceURL }
    var archiveRevision: ArchiveRevision? { base.archiveRevision }
    var byteCount: UInt64 { base.byteCount }
    var isBorrowed: Bool { base.isBorrowed }
    var physicalEntry: TransferEntry { base.physicalEntry }
    var originalPhysicalEntry: TransferEntry? { base.originalPhysicalEntry }
    var hydrationReconciliation: HydrationReconciliationReceipt? { base.hydrationReconciliation }
    func validateForUse() async throws { try await base.validateForUse() }
    func release() async -> ContentLeaseReleaseResult {
        let work = lock.withLock { () -> Task<ContentLeaseReleaseResult, Never> in
            if let cleanup { return cleanup }
            let base = base, hold = hold
            let work = Task { let result = await base.release(); hold.end(); return result }
            cleanup = work; return work
        }
        return await work.value
    }
    deinit {
        if cleanup == nil {
            let base = base, hold = hold
            Task { _ = await base.release(); hold.end() }
        }
    }
}
