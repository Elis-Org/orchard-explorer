import Darwin
import Foundation

/// NATIVE-P21 content access is separate from virtual browsing and mutation.
public enum ContentPurpose: Sendable {
    case preview, download, externalOpen, transfer, clipboardExport
}

public enum ContentHydrationPolicy: Equatable, Sendable { case whenNeeded, residentOnly }

public enum CloudDownloadPolicy {
    public static let maximumBytes: UInt64 = 1_073_741_824
    public static let timeoutSeconds: TimeInterval = 120
}

public enum ContentPreparationPhase: Equatable, Sendable {
    case queued, downloading, preparing
}

public struct ContentRequest: Sendable {
    public let source: ItemOperationEntry
    public let purpose: ContentPurpose
    public let requestID: UUID
    public let hydrationPolicy: ContentHydrationPolicy
    public let hydrationTimeoutSeconds: TimeInterval?
    public let onProgress: (@Sendable (ContentPreparationPhase) -> Void)?
    public init(source: ItemOperationEntry, purpose: ContentPurpose,
                requestID: UUID = UUID(), hydrationPolicy: ContentHydrationPolicy = .whenNeeded,
                hydrationTimeoutSeconds: TimeInterval? = nil,
                onProgress: (@Sendable (ContentPreparationPhase) -> Void)? = nil) {
        self.source = source
        self.purpose = purpose
        self.requestID = requestID; self.hydrationPolicy = hydrationPolicy
        self.hydrationTimeoutSeconds = hydrationTimeoutSeconds
        self.onProgress = onProgress
    }
}

public protocol MaterializedContentLease: AnyObject, Sendable {
    var fileURL: URL { get }
    var sourceURL: URL { get }
    var archiveRevision: ArchiveRevision? { get }
    var byteCount: UInt64 { get }
    /// Releasing a borrowed lease never modifies or removes the file at fileURL.
    var isBorrowed: Bool { get }
    /// Real export identity only; never permission to remove the logical source.
    var physicalEntry: TransferEntry { get }
    var originalPhysicalEntry: TransferEntry? { get }
    var hydrationReconciliation: HydrationReconciliationReceipt? { get }
    func validateForUse() async throws
    @discardableResult func release() async -> ContentLeaseReleaseResult
}

public extension MaterializedContentLease {
    var isBorrowed: Bool { false }
    var originalPhysicalEntry: TransferEntry? { isBorrowed ? physicalEntry : nil }
    var hydrationReconciliation: HydrationReconciliationReceipt? { nil }
}

public struct ContentLeaseReleaseResult: Sendable {
    public let disposition: ContentLeaseDisposition
    public let preservedURLs: [URL]
    public let warning: String?
    public init(disposition: ContentLeaseDisposition, preservedURLs: [URL] = [], warning: String? = nil) {
        self.disposition = disposition
        self.preservedURLs = preservedURLs
        self.warning = warning
    }
}

public enum ContentLeaseDisposition: Equatable, Sendable {
    case released, retired, preserved, alreadyReleased
}

public protocol ItemContentProviding: Sendable {
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease
}

public enum ItemContentError: Error, LocalizedError, Equatable, Sendable {
    case staleSource, unsupportedType, corruptContent, limitExceeded, deadlineExceeded
    case cloudNotDownloaded, downloadFailed(String), downloadTimedOut, downloadQueueTimedOut
    public var errorDescription: String? {
        switch self {
        case .staleSource: return "The selected item changed. Refresh and try again."
        case .unsupportedType: return "This item cannot be materialized."
        case .corruptContent: return "The ZIP member failed content verification."
        case .limitExceeded: return "The content exceeds the supported resource limits."
        case .deadlineExceeded: return "Content preparation exceeded its time limit."
        case .cloudNotDownloaded: return "This file is stored in the cloud and has not been downloaded."
        case .downloadFailed(let message): return "The file could not be downloaded. \(message)"
        case .downloadTimedOut: return "The download took too long. Check your connection and try again."
        case .downloadQueueTimedOut: return "Timed out waiting to start the download."
        }
    }
}

public struct LocalItemContentProvider: ItemContentProviding {
    private let registry: ContentLeaseRegistry
    private let originObserver: (@Sendable (Int32, ZIPOriginAttributes) throws -> Void)?
    private let maximumOriginBytes: Int
    private let physicalAccess: PhysicalContentAccess
    private let hydrator: any PhysicalFileHydrating
    public init(registry: ContentLeaseRegistry = .shared) {
        self.registry = registry
        originObserver = nil; maximumOriginBytes = 64 * 1_024 * 1_024
        physicalAccess = PhysicalContentAccess(); hydrator = LocalPhysicalFileHydrator()
    }
    init(registry: ContentLeaseRegistry, maximumOriginBytes: Int = 64 * 1_024 * 1_024,
         originObserver: @escaping @Sendable (Int32, ZIPOriginAttributes) throws -> Void) {
        self.registry = registry; self.originObserver = originObserver; self.maximumOriginBytes = maximumOriginBytes
        physicalAccess = PhysicalContentAccess(); hydrator = LocalPhysicalFileHydrator()
    }
    init(registry: ContentLeaseRegistry, physicalAccess: PhysicalContentAccess,
         hydrator: any PhysicalFileHydrating) {
        self.registry = registry; self.physicalAccess = physicalAccess; self.hydrator = hydrator
        originObserver = nil; maximumOriginBytes = 64 * 1_024 * 1_024
    }

    public func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        let isDownload = request.purpose == .download
        if isDownload, case .archive = request.source.context { throw ItemContentError.unsupportedType }
        let defaultSeconds = isDownload ? min(registry.limits.downloadSeconds, CloudDownloadPolicy.timeoutSeconds)
                                        : registry.limits.hydrationSeconds
        let requestedSeconds = request.hydrationTimeoutSeconds ?? defaultSeconds
        if request.purpose == .preview || isDownload {
            guard requestedSeconds.isFinite, requestedSeconds > 0 else { throw ItemContentError.downloadQueueTimedOut }
        }
        let downloadDeadline = isDownload ? ContentDeadline(seconds: min(requestedSeconds, defaultSeconds)) : nil
        let maximumBytes: UInt64? = isDownload ? min(registry.limits.downloadBytes, CloudDownloadPolicy.maximumBytes)
            : request.purpose == .preview ? registry.limits.previewBytes : nil
        if isDownload {
            guard let size = request.source.item.size, size >= 0 else { throw ItemContentError.unsupportedType }
            guard UInt64(size) <= maximumBytes! else { throw ItemContentError.limitExceeded }
        }
        var preparation: PreparedPhysicalContent?
        if request.purpose == .preview || isDownload, case .filesystem(let context) = request.source.context {
            try registry.checkOpen()
            preparation = try await hydrator.prepare(TransferEntry(source: context, item: request.source.item),
                purpose: request.purpose, hydrationPolicy: request.hydrationPolicy, maximumBytes: maximumBytes!,
                timeoutSeconds: downloadDeadline?.remainingSeconds ?? min(requestedSeconds, defaultSeconds),
                requestID: request.requestID, control: control, onProgress: { request.onProgress?($0) })
            try Task.checkCancellation()
        }
        // Explicit Download keeps one budget through inspection, queueing and borrow.
        // Preview rendering retains its separate, existing content deadline.
        let prepared = preparation
        let deadline = downloadDeadline ?? ContentDeadline(seconds: request.purpose == .preview ? registry.limits.previewSeconds : registry.limits.operationSeconds)
        return try await BlockingIO.run(on: .content, onCancel: { control.cancel() }) { cancellation in
            func checkpoint() throws {
                try cancellation.checkCancellation(); try deadline.check(); try self.registry.checkOpen()
                try control.checkpoint(); try deadline.check()
            }
            try checkpoint()
            switch request.source.context {
            case .filesystem(let context):
                return try self.borrow(request, context: context, prepared: prepared,
                                       maximumBytes: maximumBytes, checkpoint: checkpoint)
            case .archive(let context):
                return try self.extract(request, context: context, checkpoint: checkpoint)
            }
        }
    }

    private func borrow(_ request: ContentRequest, context: FileOperationContext,
                        prepared: PreparedPhysicalContent?, maximumBytes: UInt64?,
                        checkpoint: () throws -> Void) throws -> any MaterializedContentLease {
        try checkpoint()
        if let prepared, let anchor = prepared.anchor {
            try anchor.validate(prepared.version)
            if let maximumBytes, UInt64(prepared.version.size) > maximumBytes { throw ItemContentError.limitExceeded }
            try checkpoint()
            return BorrowedContentLease(entry: prepared.physicalEntry, version: prepared.version,
                originalEntry: prepared.originalEntry, anchor: anchor, reconciliation: prepared.reconciliation)
        }
        let entry = TransferEntry(source: context, item: request.source.item)
        let observation = try physicalAccess.inspect(entry, purpose: request.purpose,
            maximumBytes: maximumBytes)
        guard !observation.isDataless else { throw ItemContentError.cloudNotDownloaded }
        try checkpoint()
        return BorrowedContentLease(entry: entry, version: observation.version)
    }

    private func extract(_ request: ContentRequest, context: ArchiveOperationContext,
                         checkpoint: @escaping () throws -> Void) throws -> any MaterializedContentLease {
        let item = request.source.item
        guard let location = ArchiveLocation(url: item.url), !location.components.isEmpty,
              location.archiveURL.path.utf8.elementsEqual(context.location.archiveURL.path.utf8),
              location.parentURL.absoluteString == context.location.url.absoluteString,
              item.archiveRevision == context.revision, item.identity == nil else { throw ItemContentError.staleSource }
        let reader: ZIPFileReader
        do { reader = try ZIPFileReader(url: location.archiveURL) }
        catch { throw ItemContentError.staleSource }
        guard reader.revision == context.revision else { throw ItemContentError.staleSource }
        guard reader.length <= registry.limits.archiveBytes else { throw ItemContentError.limitExceeded }
        try checkpoint()
        let manifest = try ZIPArchiveManifest.read(from: reader, checkpoint: checkpoint)
        let selection = try manifest.selection(at: location)
        guard selection.isDirectory == item.isDirectory,
              !selection.isDirectory || request.purpose == .transfer || request.purpose == .clipboardExport else { throw ItemContentError.unsupportedType }
        var total: UInt64 = 0
        for record in selection.records {
            guard record.kind == .directory || record.kind == .file else { throw ItemContentError.unsupportedType }
            if record.kind == .file {
                guard record.flags & 0x2041 == 0, record.method == 0 || record.method == 8 else { throw ItemContentError.unsupportedType }
                guard record.uncompressedSize <= registry.limits.memberBytes,
                      request.purpose != .preview || record.uncompressedSize <= registry.limits.previewBytes else { throw ItemContentError.limitExceeded }
                let sum = total.addingReportingOverflow(record.uncompressedSize)
                guard !sum.overflow, sum.partialValue <= registry.limits.transactionBytes else { throw ItemContentError.limitExceeded }
                total = sum.partialValue
            }
        }
        let originBudget = ZIPOriginBudget(maximumTotalBytes: maximumOriginBytes)
        let companionIndex = try ZIPOriginCompanionIndex(manifest: manifest)
        var companions: [Data: ZIPCentralRecord] = [:], companionBytes: UInt64 = 0
        for components in selection.directories.map(\.components) + selection.records.filter({ $0.kind == .file }).map(\.components) {
            try checkpoint()
            let key = ZIPArchiveManifest.pathKey(components)
            guard companions[key] == nil, let companion = try companionIndex.companion(for: components) else { continue }
            guard companion.kind == .file, companion.flags & 0x2041 == 0,
                  companion.method == 0 || companion.method == 8 else { throw ItemContentError.unsupportedType }
            guard companion.uncompressedSize <= UInt64(originBudget.maximumCompanionBytes) else { throw ItemContentError.limitExceeded }
            let sum = companionBytes.addingReportingOverflow(companion.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= UInt64(max(0, maximumOriginBytes)) else { throw ItemContentError.limitExceeded }
            companionBytes = sum.partialValue; companions[key] = companion
        }
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader,
            scope: .content(recordIDs: Set(selection.records.map(\.id) + companions.values.map(\.id))), checkpoint: checkpoint)
        let outerOrigin = try reader.originAttributes(budget: originBudget)
        let reservation = total.addingReportingOverflow(companionBytes)
        guard !reservation.overflow, reservation.partialValue <= registry.limits.transactionBytes else { throw ItemContentError.limitExceeded }
        try checkpoint()
        let root = try ContentRoot(registry.rootURL)
        try ContentFileIO.requireAvailableSpace(reservation.partialValue, at: root.fd)
        let caseSensitive = try root.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        guard let caseSensitive else { throw ItemContentError.unsupportedType }
        let baseCount = selection.components.count - 1
        func relative(_ components: [String]) -> [String] { Array(components.dropFirst(baseCount)) }
        let paths = selection.directories.map { relative($0.components) } + selection.records.filter { $0.kind == .file }.map { relative($0.components) }
        try Self.validateExportNames(paths, caseSensitive: caseSensitive)
        let id = try registry.reserve(reservation.partialValue)
        var stage: ContentOwnedStage?
        do {
            let owned = try ContentOwnedStage(root: root, id: id); stage = owned
            try registry.trackStage(id: id, stage: owned)
            var memberOrigins: [Data: ZIPOriginAttributes] = [:]
            for (key, companion) in companions {
                try checkpoint()
                guard let range = layout.records[companion.id] else { throw ItemContentError.corruptContent }
                let count = Int(companion.uncompressedSize)
                try originBudget.charge(count)
                var data = Data(); data.reserveCapacity(count)
                _ = try ZIPContentExtraction.extract(record: companion, layout: range, reader: reader,
                    maximumBytes: UInt64(originBudget.maximumCompanionBytes), checkpoint: checkpoint, consume: { data.append($0) })
                // The shared boundary validates the complete origin-only bytes
                // before native UNPACK, whose destination is anonymous scratch.
                memberOrigins[key] = try ZIPMemberOrigins.unpack(data, scratchDirectory: owned.fd,
                    budget: originBudget, checkpoint: checkpoint)
            }
            func applyOrigin(to fd: Int32, components: [String]) throws -> ZIPOriginAttributes {
                // Test observation/failure injection happens before the single
                // native application. No raw writer follows the OS result.
                try originObserver?(fd, outerOrigin); try checkpoint()
                return try ZIPMemberOrigins.apply(member: memberOrigins[ZIPArchiveManifest.pathKey(components)],
                    outer: outerOrigin, to: fd, scratchDirectory: owned.fd, budget: originBudget, checkpoint: checkpoint)
            }
            for directory in selection.directories.sorted(by: { $0.components.count < $1.components.count }) {
                try checkpoint(); let fd = try owned.create(relative(directory.components), directory: true); close(fd)
            }
            for record in selection.records where record.kind == .file {
                try checkpoint()
                guard let range = layout.records[record.id] else { throw ItemContentError.corruptContent }
                let components = relative(record.components)
                let fd = try owned.create(components, directory: false)
                do {
                    let digest = try ZIPContentExtraction.extract(record: record, layout: range, reader: reader,
                        destination: fd, maximumBytes: registry.limits.memberBytes, checkpoint: checkpoint)
                    let mode: UInt16 = request.purpose == .externalOpen ? 0o444 : request.purpose == .preview ? 0o600 : (range.unixPermissions ?? 0o644) & 0o777
                    let actualOrigin = try applyOrigin(to: fd, components: record.components)
                    try ContentFileIO.applyMetadata(fd, mode: mode, modifiedAt: range.modifiedAt)
                    try owned.seal(components, fd: fd, digest: digest, reconcilingMetadata: true)
                    guard try ZIPMemberOrigins.capture(from: fd, budget: originBudget) == actualOrigin else { throw ItemContentError.staleSource }
                    close(fd)
                } catch {
                    // The never-published partial output is sampled after our
                    // writer stops; cleanup still checks its recorded identity.
                    try? owned.seal(components, fd: fd, digest: nil, reconcilingMetadata: true)
                    close(fd); throw error
                }
            }
            // Directory metadata is last: creating children changes timestamps.
            for directory in selection.directories.sorted(by: { $0.components.count > $1.components.count }) {
                try checkpoint()
                let components = relative(directory.components)
                try owned.parent(of: components) { parent, name in
                    let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    guard fd >= 0 else { throw ContentFileIO.failure() }
                    defer { close(fd) }
                    guard LocalFileIdentity.fromStat(try ContentFileIO.sample(fd)) == owned.nodes[ContentOwnedStage.key(components)]?.version.identity else { throw ItemContentError.staleSource }
                    // Repeated explicit directory records follow the manifest's
                    // first-record metadata policy. Use its fully validated UT
                    // timestamp rather than the browsing-only DOS projection.
                    let modifiedAt: Date?
                    if let first = directory.recordIDs.first {
                        guard let validated = layout.records[first] else { throw ItemContentError.corruptContent }
                        modifiedAt = validated.modifiedAt
                    } else { modifiedAt = directory.modifiedAt }
                    let actualOrigin = try applyOrigin(to: fd, components: directory.components)
                    try ContentFileIO.applyMetadata(fd, mode: (directory.unixPermissions ?? 0o755) & 0o777,
                                                    modifiedAt: modifiedAt)
                    try owned.seal(components, fd: fd, digest: nil, reconcilingMetadata: true)
                    guard try ZIPMemberOrigins.capture(from: fd, budget: originBudget) == actualOrigin else { throw ItemContentError.staleSource }
                }
            }
            try checkpoint()
            do { try reader.validateUnchanged() } catch { throw ItemContentError.staleSource }
            try owned.validateContents()
            guard let basename = location.components.last else { throw ItemContentError.unsupportedType }
            let value = try ContentFileIO.sample(basename, at: owned.fd)
            guard let identity = LocalFileIdentity.fromStat(value) else { throw ItemContentError.staleSource }
            let url = owned.url.appendingPathComponent(basename, isDirectory: selection.isDirectory)
            let metadata = FileMetadata(stat: value, capturedAt: Date())
            let physicalItem = FileItem(url: url, name: basename, isDirectory: selection.isDirectory, isSymbolicLink: false,
                size: metadata.size, modifiedAt: metadata.modifiedAt, kind: selection.isDirectory ? "File folder" : "File", identity: identity)
            let physical = TransferEntry(source: FileOperationContext(directoryURL: owned.url, directoryIdentity: owned.identity), item: physicalItem)
            try checkpoint()
            return try registry.register(id: id, stage: owned, source: .archive(location.archiveURL, context.revision),
                                         request: request, physical: physical, bytes: total)
        } catch { registry.failed(id: id, stage: stage); throw error }
    }

    static func validateExportNames(_ paths: [[String]], caseSensitive: Bool) throws {
        var seen = Set<Data>()
        for path in paths {
            guard !path.isEmpty, path.allSatisfy(ArchiveLocation.validComponent) else { throw ItemContentError.unsupportedType }
            let normalized = path.map { component -> String in
                let value = component.precomposedStringWithCanonicalMapping
                return caseSensitive ? value : value.lowercased()
            }.joined(separator: "/")
            guard seen.insert(Data(normalized.utf8)).inserted else { throw ItemContentError.unsupportedType }
        }
    }
}
