import Darwin
import Foundation

public struct RetainedContentArtifact: Codable, Equatable, Sendable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// Owns content cleanup and its durable reporting. A receipt is never cleanup
/// authority; next launch reports retained entries without sweeping them.
public final class ContentLeaseRegistry: @unchecked Sendable {
    public static let shared = ContentLeaseRegistry()
    let rootURL: URL
    private let managedRootPaths: [[String]]
    let limits: ContentLimits
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var reservations: [UUID: UInt64] = [:]
    private var pending = Set<UUID>()
    private var pendingStages: [UUID: ContentOwnedStage] = [:]
    private var records: [UUID: ContentRegisteredLease] = [:]
    private var retained: [RetainedContentArtifact] = []
    private var closing = false

    /// Tests inject a dedicated synthetic root; production uses Application
    /// Support for every owned lease so preservation never needs relocation.
    public convenience init(rootURL: URL? = nil) {
        let selected = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.native-explorer.app/ZIP Content", isDirectory: true)
        self.init(rootURL: selected, limits: ContentLimits(), now: { Date() })
    }

    init(rootURL selected: URL, limits: ContentLimits, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = selected.standardizedFileURL
        let physical = (try? ContentRoot.resolvingForCreation(selected)) ?? selected
        managedRootPaths = [Self.pathComponents(selected), Self.pathComponents(physical)]
        self.limits = limits; self.now = now
    }

    /// Conservative namespace refusal only. It neither samples the candidate
    /// nor grants physical/archive authority. Importers validate/resolve first.
    public func containsManagedURL(_ url: URL) -> Bool {
        guard ArchiveLocation.validPhysicalURL(url) else { return false }
        let components = Self.pathComponents(url)
        return managedRootPaths.contains { root in
            !root.isEmpty && components.count >= root.count && Array(components.prefix(root.count)) == root
        }
    }

    private static func pathComponents(_ url: URL) -> [String] {
        // Conservatively refuse case/canonical-equivalent spellings too, even
        // when a particular volume could distinguish them. No I/O per query.
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            .split(separator: "/").map(String.init)
    }

    public func retainedArtifacts() async throws -> [RetainedContentArtifact] {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let saved = try self.readReceipts()
            return Self.unique(saved + self.withLock { self.retained })
        }
    }

    public func shutdown() async throws -> [RetainedContentArtifact] {
        let deadline = ContentDeadline(seconds: min(5, limits.shutdownSeconds))
        // Running materializers observe this at every chunk and stop admitting
        // output. The queued shutdown waits for their owned cleanup, not for a
        // cooperative task that has already abandoned its dispatch worker.
        withLock { closing = true }
        return try await BlockingIO.run(on: .content) { _ in
            let ids = self.withLock { Array(self.records.keys) }
            for id in ids { _ = self.clean(id, deadline: deadline) }
            self.withLock {
                for id in self.pending {
                    let url = self.pendingStages[id]?.reportingURL ?? self.rootURL.appendingPathComponent("content-" + id.uuidString, isDirectory: true)
                    self.retained.append(RetainedContentArtifact(url: url, reason: "Content preparation was still in progress at shutdown. Its output was preserved without publication."))
                }
            }
            let report = Self.unique(try self.readReceipts() + self.withLock { self.retained })
            if !report.isEmpty { try self.writeReceipt(report) }
            return report
        }
    }

    func checkOpen() throws {
        guard !withLock({ closing }) else { throw CancellationError() }
    }

    func reserve(_ bytes: UInt64) throws -> UUID {
        try checkOpen()
        guard bytes <= limits.ownedBytes else { throw ItemContentError.limitExceeded }
        if !hasRoom(bytes) {
            let cutoff = now().addingTimeInterval(-limits.retiredSeconds)
            let eligible = withLock {
                records.compactMap { id, record -> UUID? in
                    guard let retiredAt = record.retiredAt, retiredAt <= cutoff else { return nil }
                    return id
                }
            }
            let deadline = ContentDeadline(seconds: min(5, limits.shutdownSeconds))
            for id in eligible {
                _ = clean(id, deadline: deadline)
                if hasRoom(bytes) { break }
            }
        }
        return try withLock {
            guard !closing else { throw CancellationError() }
            let used = reservations.values.reduce(UInt64(0)) { $0 + $1 }
            guard used <= limits.ownedBytes, bytes <= limits.ownedBytes - used else { throw ItemContentError.limitExceeded }
            let id = UUID(); reservations[id] = bytes; pending.insert(id); return id
        }
    }

    private func hasRoom(_ bytes: UInt64) -> Bool {
        withLock {
            let used = reservations.values.reduce(UInt64(0)) { $0 + $1 }
            return used <= limits.ownedBytes && bytes <= limits.ownedBytes - used
        }
    }

    func register(id: UUID, stage: ContentOwnedStage, source: ContentSourceVersion,
                  request: ContentRequest, physical: TransferEntry, bytes: UInt64) throws -> any MaterializedContentLease {
        let record = ContentRegisteredLease(stage: stage, source: source, purpose: request.purpose)
        try withLock {
            guard !closing, reservations[id] != nil else { throw CancellationError() }
            records[id] = record; pending.remove(id); pendingStages.removeValue(forKey: id)
        }
        return OwnedContentLease(registry: self, id: id, fileURL: physical.item.url,
                                 sourceURL: request.source.item.url, archiveRevision: source.archiveRevision,
                                 byteCount: bytes, physicalEntry: physical)
    }

    func trackStage(id: UUID, stage: ContentOwnedStage) throws {
        try withLock {
            guard pending.contains(id) else { throw CancellationError() }
            pendingStages[id] = stage
            guard !closing else { throw CancellationError() }
        }
    }

    func failed(id: UUID, stage: ContentOwnedStage?) {
        // Shutdown may already have reported this in-flight tree. A finishing
        // worker must not delete it after that preservation decision.
        let keep = withLock { closing }
        var report: [RetainedContentArtifact]
        if keep, let stage {
            report = [RetainedContentArtifact(url: stage.reportingURL, reason: "Content preparation stopped during shutdown; its unproven output was preserved.")]
        } else {
            report = stage?.cleanup(deadline: ContentDeadline(seconds: min(5, limits.shutdownSeconds)), deleting: { operation in
                // Closing and each preparatory unlink share one ordering lock.
                // Once shutdown records preservation, no pending worker may
                // pass this gate even if its cleanup began before shutdown.
                try self.withLock {
                    guard !self.closing else { throw CancellationError() }
                    try operation()
                }
            }) ?? []
        }
        if stage == nil {
            // mkdir may have succeeded before the descriptor could be opened.
            // No identity ledger means preserve and report, never path-delete.
            let path = rootURL.appendingPathComponent("content-" + id.uuidString, isDirectory: true)
            var value = stat()
            if lstat(path.path, &value) == 0 {
                report = [RetainedContentArtifact(url: path, reason: "An incomplete content folder could not be identity-verified and was preserved.")]
            }
        }
        withLock {
            pending.remove(id); pendingStages.removeValue(forKey: id)
            if report.isEmpty { reservations.removeValue(forKey: id) }
            retained.append(contentsOf: report)
        }
    }

    func validate(id: UUID) throws {
        guard let record = withLock({ records[id] }) else { throw ItemContentError.staleSource }
        record.operationLock.lock(); defer { record.operationLock.unlock() }
        guard withLock({ records[id] === record && record.retiredAt == nil }) else { throw ItemContentError.staleSource }
        try record.source.validate(); try record.stage.validateContents()
    }

    func release(id: UUID) async -> ContentLeaseReleaseResult {
        let deadline = ContentDeadline(seconds: min(5, limits.shutdownSeconds))
        // Retirement is a state change only; ownership loss must not delete the
        // public clipboard files while another application starts reading them.
        let retirement: ContentLeaseReleaseResult? = withLock {
            guard let record = records[id] else { return ContentLeaseReleaseResult(disposition: .alreadyReleased) }
            if record.purpose == .clipboardExport, !closing {
                if record.retiredAt == nil { record.retiredAt = now() }
                return ContentLeaseReleaseResult(disposition: .retired)
            }
            return nil
        }
        if let retirement { return retirement }
        do {
            // Unstructured (not detached) cleanup does not inherit an already
            // cancelled preview task. Its actual I/O still uses the bounded
            // content lane and must finish before release returns.
            return try await Task {
                try await BlockingIO.run(on: .content) { _ in self.clean(id, deadline: deadline) }
            }.value
        } catch {
            let report = withLock { () -> [RetainedContentArtifact] in
                guard let record = records[id] else { return [] }
                let item = RetainedContentArtifact(url: record.stage.reportingURL, reason: "Cleanup could not finish: \(error.localizedDescription)")
                retained.append(item); return [item]
            }
            return ContentLeaseReleaseResult(disposition: .preserved, preservedURLs: report.map(\.url), warning: error.localizedDescription)
        }
    }

    private func clean(_ id: UUID, deadline: ContentDeadline) -> ContentLeaseReleaseResult {
        guard let record = withLock({ records[id] }) else { return ContentLeaseReleaseResult(disposition: .alreadyReleased) }
        record.operationLock.lock(); defer { record.operationLock.unlock() }
        guard withLock({ records[id] === record }) else { return ContentLeaseReleaseResult(disposition: .alreadyReleased) }
        let report = record.stage.cleanup(deadline: deadline)
        withLock {
            records.removeValue(forKey: id)
            if report.isEmpty { reservations.removeValue(forKey: id) }
            retained.append(contentsOf: report)
        }
        return ContentLeaseReleaseResult(disposition: report.isEmpty ? .released : .preserved,
                                         preservedURLs: report.map(\.url), warning: report.first?.reason)
    }

    private func readReceipts() throws -> [RetainedContentArtifact] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let root = try ContentRoot(rootURL)
        var output: [RetainedContentArtifact] = []
        let names = try ContentFileIO.names(root.fd).filter { $0.hasPrefix("retained-") && $0.hasSuffix(".json") }
        if names.count > 1_024 { return [RetainedContentArtifact(url: root.url, reason: "Additional retained ZIP file reports are present in this folder; no automatic cleanup is performed.")] }
        var bytesRead: Int64 = 0
        for name in names {
            try root.validate()
            let fd = name.withCString { openat(root.fd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard fd >= 0 else { throw ContentFileIO.failure() }
            defer { close(fd) }
            let before = try ContentFileVersion(ContentFileIO.sample(fd))
            guard before.mode & UInt16(S_IFMT) == UInt16(S_IFREG), before.size <= 1_024 * 1_024 else { throw ItemContentError.limitExceeded }
            bytesRead += before.size
            if bytesRead > 4 * 1_024 * 1_024 {
                output.append(RetainedContentArtifact(url: root.url, reason: "Additional retained ZIP file reports are present in this folder; no automatic cleanup is performed."))
                break
            }
            var data = Data(count: Int(before.size))
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = pread(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ItemContentError.staleSource }; offset += count
                }
            }
            guard try ContentFileVersion(ContentFileIO.sample(fd)) == before else { throw ItemContentError.staleSource }
            let values = try JSONDecoder().decode([RetainedContentArtifact].self, from: data)
            guard values.count <= 1_024 else { throw ItemContentError.limitExceeded }
            // Receipts only report. They are never inputs to cleanup or deletion.
            output.append(contentsOf: values)
        }
        return Self.unique(output)
    }

    private func writeReceipt(_ report: [RetainedContentArtifact]) throws {
        let root = try ContentRoot(rootURL)
        var bounded = report
        if bounded.count > 1_024 { bounded = [RetainedContentArtifact(url: root.url, reason: "ZIP content was retained. Inspect this folder; no automatic cleanup is performed.")] }
        var data = try JSONEncoder().encode(bounded)
        if data.count > 1_024 * 1_024 {
            data = try JSONEncoder().encode([RetainedContentArtifact(url: root.url, reason: "ZIP content was retained. The full list exceeded the reporting limit; no automatic cleanup is performed.")])
        }
        let nonce = UUID().uuidString
        let name = ".receipt-" + nonce + ".partial"
        let publishedName = "retained-" + nonce + ".json"
        try root.validate()
        let fd = name.withCString { openat(root.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw ContentFileIO.failure() }
        defer { close(fd) }
        try ContentFileIO.clearACL(fd); try ContentFileIO.write(data, to: fd)
        guard fsync(fd) == 0 else { throw ContentFileIO.failure() }
        try root.validate()
        let status = name.withCString { source in
            publishedName.withCString { destination in
                renameatx_np(root.fd, source, root.fd, destination, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else { throw ContentFileIO.failure() }
        guard fsync(root.fd) == 0 else { throw ContentFileIO.failure() }
    }

    private static func unique(_ values: [RetainedContentArtifact]) -> [RetainedContentArtifact] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.url.absoluteString + "\n" + $0.reason).inserted }
    }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

private final class ContentRegisteredLease {
    let stage: ContentOwnedStage
    let source: ContentSourceVersion
    let purpose: ContentPurpose
    let operationLock = NSLock()
    var retiredAt: Date?
    init(stage: ContentOwnedStage, source: ContentSourceVersion, purpose: ContentPurpose) {
        self.stage = stage; self.source = source; self.purpose = purpose
    }
}

enum ContentSourceVersion: Sendable {
    case physical(TransferEntry, ContentFileVersion)
    case archive(URL, ArchiveRevision)
    var archiveRevision: ArchiveRevision? { if case .archive(_, let revision) = self { return revision }; return nil }
    func validate() throws {
        switch self {
        case .archive(let url, let revision):
            do {
                let reader = try ZIPFileReader(url: url)
                guard reader.revision == revision else { throw ItemContentError.staleSource }
                try reader.validateUnchanged()
            } catch { throw ItemContentError.staleSource }
        case .physical(let entry, let version):
            try LocalFileOperations.withParent(entry.source) { fd, resolved in
                try version.validateCurrent(ContentFileIO.sample(entry.item.name, at: fd))
                try LocalFileOperations.revalidateRoute(entry.source, resolved: resolved)
            }
        }
    }
}

private final class OwnedContentLease: MaterializedContentLease, @unchecked Sendable {
    let registry: ContentLeaseRegistry
    let id: UUID
    let fileURL: URL
    let sourceURL: URL
    let archiveRevision: ArchiveRevision?
    let byteCount: UInt64
    let physicalEntry: TransferEntry
    private let lock = NSLock()
    private var released = false
    init(registry: ContentLeaseRegistry, id: UUID, fileURL: URL, sourceURL: URL,
         archiveRevision: ArchiveRevision?, byteCount: UInt64, physicalEntry: TransferEntry) {
        self.registry = registry; self.id = id; self.fileURL = fileURL; self.sourceURL = sourceURL
        self.archiveRevision = archiveRevision; self.byteCount = byteCount; self.physicalEntry = physicalEntry
    }
    private func isReleased() -> Bool { lock.lock(); defer { lock.unlock() }; return released }
    private func markReleased() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !released else { return false }; released = true; return true
    }
    func validateForUse() async throws {
        guard !isReleased() else { throw ItemContentError.staleSource }
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation(); try self.registry.validate(id: self.id)
        }
    }
    func release() async -> ContentLeaseReleaseResult {
        guard markReleased() else { return ContentLeaseReleaseResult(disposition: .alreadyReleased) }
        return await registry.release(id: id)
    }
}

final class BorrowedContentLease: MaterializedContentLease, @unchecked Sendable {
    let isBorrowed = true
    let fileURL: URL
    let sourceURL: URL
    let archiveRevision: ArchiveRevision? = nil
    let byteCount: UInt64
    let physicalEntry: TransferEntry
    let originalPhysicalEntry: TransferEntry?
    private let source: ContentSourceVersion
    private let version: ContentFileVersion
    private let lock = NSLock()
    private var released = false
    private var anchor: HydrationIdentityAnchor?
    private var reconciliation: HydrationReconciliationReceipt?
    var hydrationReconciliation: HydrationReconciliationReceipt? {
        lock.lock(); defer { lock.unlock() }; return reconciliation
    }
    init(entry: TransferEntry, version: ContentFileVersion, originalEntry: TransferEntry? = nil,
         anchor: HydrationIdentityAnchor? = nil, reconciliation: HydrationReconciliationReceipt? = nil) {
        fileURL = entry.item.url; sourceURL = (originalEntry ?? entry).item.url; byteCount = UInt64(version.size)
        physicalEntry = entry; originalPhysicalEntry = originalEntry ?? entry; source = .physical(entry, version)
        self.version = version; self.anchor = anchor; self.reconciliation = reconciliation
    }
    private func isReleased() -> Bool { lock.lock(); defer { lock.unlock() }; return released }
    private func markReleased() -> Bool {
        lock.lock(); defer { lock.unlock() }; guard !released else { return false }
        released = true; anchor = nil; reconciliation = nil; return true
    }
    private func validationAnchor() throws -> HydrationIdentityAnchor? {
        lock.lock(); defer { lock.unlock() }
        guard !released else { throw ItemContentError.staleSource }; return anchor
    }
    func validateForUse() async throws {
        let held = try validationAnchor()
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            if let held { try held.validate(self.version) }
            else { try self.source.validate() }
            try cancellation.checkCancellation()
        }
        guard !isReleased() else { throw ItemContentError.staleSource }
    }
    func release() async -> ContentLeaseReleaseResult {
        ContentLeaseReleaseResult(disposition: markReleased() ? .released : .alreadyReleased)
    }
}
