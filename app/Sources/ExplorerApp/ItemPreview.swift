import AppKit
import Combine
import ExplorerCore
import UniformTypeIdentifiers

enum InspectorPaneMode: Equatable { case none, details, preview }

struct InspectorPaneState: Equatable {
    private(set) var mode: InspectorPaneMode = .none
    private(set) var lastMode: InspectorPaneMode = .details
    private(set) var width: CGFloat = 300
    mutating func toggle(_ requested: InspectorPaneMode) {
        guard requested != .none else { mode = .none; return }
        lastMode = requested
        mode = mode == requested ? .none : requested
    }
    mutating func toggleLast() { toggle(lastMode) }
    mutating func resize(to width: CGFloat, available: CGFloat) {
        self.width = max(220, min(600, available, width))
    }
}

struct PreviewRequest: Equatable {
    let tabID: UUID
    let generation: UUID?
    let searchGeneration: UUID?
    let items: [FileItem]
    let entry: ItemOperationEntry?
    var searchSessionID: UUID? = nil
    var hydrationPolicy: ContentHydrationPolicy = .whenNeeded
    var homeGeneration: UUID? = nil
    /// A Home selection may exist before its single physical entry is available.
    var placeholder: PreviewState? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabID == rhs.tabID && lhs.generation == rhs.generation
            && lhs.searchGeneration == rhs.searchGeneration && lhs.items == rhs.items
            && lhs.searchSessionID == rhs.searchSessionID
            && lhs.hydrationPolicy == rhs.hydrationPolicy
            && lhs.homeGeneration == rhs.homeGeneration && lhs.placeholder == rhs.placeholder
            && lhs.entry?.item == rhs.entry?.item && lhs.entry?.context == rhs.entry?.context
    }
}

struct PreviewAttempt {
    let id: UUID
    let request: PreviewRequest
}
struct PreviewHydrationPrepared {
    let attempt: PreviewAttempt
    let receipt: HydrationReconciliationReceipt?
}
struct PreviewAttemptEnded {
    enum Outcome { case completed, failed, cancelled }
    let attempt: PreviewAttempt
    let outcome: Outcome
    let refreshMetadata: Bool
}
struct PreviewRetryIntent {
    let attemptID: UUID
    let request: PreviewRequest
}

enum PreviewState: Equatable {
    case empty, multiple, unsupported, downloading, preparing, ready(UUID), failed(String)
}

@MainActor
final class PreviewPresentation {
    enum Content { case text(String, truncated: Bool), quickLook, raster(CGImage) }
    let id = UUID()
    let title: String
    let content: Content
    let lease: any MaterializedContentLease
    let zoomUnavailable: Bool
    init(title: String, content: Content, lease: any MaterializedContentLease, zoomUnavailable: Bool = false) {
        self.title = title; self.content = content; self.lease = lease
        self.zoomUnavailable = zoomUnavailable
    }
}

/// The renderer's single cleanup owner. The stop/detach action is synchronous;
/// only after it returns may background cleanup inspect or remove the file.
@MainActor
final class PreviewPresentationOwner {
    private var presentation: PreviewPresentation?
    private var stopAndDetach: (() -> Void)?
    func accept(_ presentation: PreviewPresentation, stopAndDetach: @escaping () -> Void) {
        clear()
        self.presentation = presentation
        self.stopAndDetach = stopAndDetach
    }
    @discardableResult
    func clear() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        self.presentation = nil
        let stop = stopAndDetach; stopAndDetach = nil
        stop?()
        return Task { _ = await presentation.lease.release() }
    }
}

/// The request owns a pending lease until takePresentation hands
/// it to a renderer; clearing this model must never release an accepted lease.
@MainActor
final class ItemPreviewModel: ObservableObject {
    @Published private(set) var state: PreviewState = .empty
    private let provider: any ItemContentProviding
    private let rasterProvider: any PreviewRasterPreparing
    private var isPreparingRaster = false
    private var request: PreviewRequest?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var control: TransferControl?
    private var pending: PreviewPresentation?
    private var renderer: (id: UUID, invalidate: () -> Void)?
    /// Every failed cloud attempt survives metadata-only refreshes of this source.
    /// Epochs and availability are deliberately excluded; neither is identity.
    private struct SourceKey: Equatable {
        let tabID: UUID
        let searchSessionID: UUID?
        let homeGeneration: UUID?
        let url: String
        let identity: LocalFileIdentity?
        let context: ItemOperationContext
        init?(_ request: PreviewRequest?) {
            guard let request, request.items.count == 1, let entry = request.entry else { return nil }
            tabID = request.tabID; searchSessionID = request.searchSessionID
            homeGeneration = request.homeGeneration
            url = entry.item.url.absoluteString; identity = entry.item.identity; context = entry.context
        }
    }
    private var failedAttempt: (sourceKey: SourceKey, retryableDownload: Bool)?
    private var cloudAttempt: (request: PreviewRequest, needsMetadataRefresh: Bool)?
    var onCloudAttemptStarted: ((PreviewAttempt) -> Void)?
    var onHydrationPrepared: ((PreviewHydrationPrepared) -> Void)?
    var onCloudAttemptEnded: ((PreviewAttemptEnded) -> Void)?
    var onRetryRequested: ((PreviewRetryIntent) -> Void)?
    var admittedRequest: PreviewRequest? { request }
    var activeCloudAttempt: PreviewAttempt? { cloudAttempt.map { PreviewAttempt(id: generation, request: $0.request) } }
    private var usesCloudLifecycle: Bool {
        guard let attempt = cloudAttempt else { return false }
        return attempt.needsMetadataRefresh || (attempt.request.entry?.item.availability ?? .unknown) != .unknown
    }
    func hasAcceptedPresentation(for attemptID: UUID) -> Bool {
        guard generation == attemptID, case .ready = state else { return false }
        return pending == nil && task == nil && cloudAttempt == nil
    }
    func isCurrent(_ intent: PreviewRetryIntent) -> Bool {
        canRetry && generation == intent.attemptID && request == intent.request
    }
    var canRetry: Bool { failedAttempt?.retryableDownload == true }
    var downloadingItemID: String? {
        guard state == .downloading else { return nil }
        return cloudAttempt?.request.entry?.item.id
    }
    func blocksAutomaticRefresh(tabID: UUID) -> Bool {
        usesCloudLifecycle && cloudAttempt?.request.tabID == tabID
    }
    init(provider: any ItemContentProviding = LocalItemContentProvider(),
         rasterProvider: any PreviewRasterPreparing = PreviewRasterProvider()) {
        self.provider = provider; self.rasterProvider = rasterProvider
    }
    deinit { task?.cancel(); control?.cancel() }

    func show(_ request: PreviewRequest?) {
        guard request != self.request else { return }
        if let failedAttempt, SourceKey(request) == failedAttempt.sourceKey {
            self.request = request
            return
        }
        failedAttempt = nil
        endCloudAttempt(outcome: .cancelled, refreshMetadata: false)
        self.request = request
        generation = UUID()
        isPreparingRaster = false
        task?.cancel(); task = nil
        control?.cancel(); control = nil
        // A renderer owns accepted resources and synchronously stops/detaches
        // them before initiating release. This model never releases its lease.
        renderer?.invalidate()
        if let pending { self.pending = nil; Task { _ = await pending.lease.release() } }
        state = .empty
        if let placeholder = request?.placeholder { state = placeholder; return }
        guard let request, !request.items.isEmpty else { return }
        guard request.items.count == 1 else { state = .multiple; return }
        guard let entry = request.entry, entry.isValid,
              let kind = PreviewContentKind(entry.item) else { state = .unsupported; return }
        state = .preparing
        let token = generation, provider = self.provider, control = TransferControl()
        let rasterProvider = self.rasterProvider
        self.control = control
        if case .filesystem = entry.context {
            // Progress delivery hops to MainActor and may trail a very fast
            // provider. A captured placeholder always needs a metadata refresh.
            cloudAttempt = (request, entry.item.availability == .onlineOnly)
            onCloudAttemptStarted?(PreviewAttempt(id: token, request: request))
        }
        task = Task { [weak self] in
            var owned: (any MaterializedContentLease)?
            do {
                try Task.checkCancellation()
                let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .preview,
                    requestID: token, hydrationPolicy: request.hydrationPolicy,
                    onProgress: { [weak self] phase in
                        Task { @MainActor [weak self] in self?.progress(phase, token: token, request: request) }
                    }), control: control)
                owned = lease
                try Task.checkCancellation()
                guard entry.acceptsContent(lease, for: .preview) else { throw ItemContentError.staleSource }
                try await lease.validateForUse()
                guard !Task.isCancelled, self?.generation == token, self?.request == request else {
                    _ = await lease.release(); return
                }
                // Execution may discover a placeholder after an unknown/local
                // listing. A receipt is terminal proof even if progress's
                // MainActor hop has not arrived; preserve its refresh authority.
                if lease.hydrationReconciliation != nil { self?.cloudAttempt = (request, true) }
                if let callback = self?.onHydrationPrepared {
                    callback(PreviewHydrationPrepared(attempt: PreviewAttempt(id: token, request: request),
                                                       receipt: lease.hydrationReconciliation))
                } else { lease.hydrationReconciliation?.invalidate() }
                guard lease.fileURL.isFileURL else { throw ItemContentError.unsupportedType }
                let content: PreviewPresentation.Content
                var zoomUnavailable = false
                switch kind {
                case .text:
                    let text = try await PreviewText.read(lease.fileURL, byteCount: lease.byteCount)
                    try await lease.validateForUse()
                    content = .text(text.value, truncated: text.truncated)
                case .quickLook: content = .quickLook
                case .raster(let rasterKind):
                    guard case .filesystem = entry.context, lease.isBorrowed else {
                        content = .quickLook
                        break
                    }
                    try Task.checkCancellation()
                    self?.isPreparingRaster = true
                    if self?.state == .downloading { self?.state = .preparing }
                    let raster = try await rasterProvider.prepare(rasterKind, from: lease.fileURL)
                    try Task.checkCancellation()
                    try await lease.validateForUse()
                    switch raster {
                    case .image(let image): content = .raster(image)
                    case .excluded: content = .quickLook
                    case .unavailable: content = .quickLook; zoomUnavailable = true
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == token, self.request == request else {
                    _ = await lease.release(); return
                }
                let result = PreviewPresentation(title: entry.item.name, content: content, lease: lease,
                                                 zoomUnavailable: zoomUnavailable)
                self.pending = result
                owned = nil
                self.state = .ready(result.id)
                self.task = nil; self.control = nil
            } catch {
                if let owned { _ = await owned.release() }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                var retryableDownload = false
                if let error = error as? ItemContentError {
                    switch error {
                    case .cloudNotDownloaded, .downloadFailed, .downloadTimedOut, .downloadQueueTimedOut:
                        retryableDownload = true
                        if case .filesystem = entry.context { self.cloudAttempt = (request, true) }
                    default: break
                    }
                }
                if (self.usesCloudLifecycle || retryableDownload), let sourceKey = SourceKey(request) {
                    self.failedAttempt = (sourceKey, retryableDownload)
                }
                let detail: String
                if let contentError = error as? ItemContentError, case .downloadFailed(let reason) = contentError { detail = reason }
                else { detail = error.localizedDescription }
                self.state = error is PreviewText.Error ? .unsupported : .failed(detail)
                self.task = nil; self.control = nil
                self.endCloudAttempt(outcome: .failed, refreshMetadata: true)
            }
        }
    }

    private func progress(_ phase: ContentPreparationPhase, token: UUID, request: PreviewRequest) {
        guard generation == token, self.request == request, task != nil,
              state == .preparing || state == .downloading,
              let entry = request.entry, case .filesystem = entry.context else { return }
        switch phase {
        case .queued: state = .preparing
        case .downloading:
            cloudAttempt = (request, true)
            if !isPreparingRaster { state = .downloading }
        case .preparing: state = .preparing
        }
    }

    /// A passive read temporarily withholds preview authority. Preserve only an
    /// already-failed, unchanged selection; all other content clears normally.
    func suspendForAutomaticRefresh(_ request: PreviewRequest?) {
        if let failedAttempt, SourceKey(request) == failedAttempt.sourceKey { self.request = request }
        else { show(nil) }
    }

    func retry() {
        guard canRetry, let request else { return }
        onRetryRequested?(PreviewRetryIntent(attemptID: generation, request: request))
    }

    func restartAfterExplicitRetry(_ intent: PreviewRetryIntent, request: PreviewRequest) {
        guard isCurrent(intent) else { return }
        failedAttempt = nil
        self.request = nil
        show(request)
    }

    func adoptHydrationTransition(_ transition: VerifiedHydrationTransition, loadGeneration: UUID?) {
        guard generation == transition.requestID, let old = request, let entry = old.entry,
              entry.item.url.absoluteString == transition.originalEntry.item.url.absoluteString,
              entry.item.identity == transition.originalEntry.item.identity,
              entry.context == .filesystem(transition.originalEntry.source) else { return }
        let current = PreviewRequest(tabID: old.tabID, generation: loadGeneration,
            searchGeneration: old.searchGeneration,
            items: old.items.map { $0.id == entry.item.id ? transition.refreshedItem : $0 },
            entry: ItemOperationEntry(item: transition.refreshedItem, context: .filesystem(transition.acceptedEntry.source)),
            searchSessionID: old.searchSessionID,
            hydrationPolicy: cloudAttempt == nil ? .residentOnly : old.hydrationPolicy,
            homeGeneration: old.homeGeneration)
        request = current
        if let failed = failedAttempt, let key = SourceKey(current) { failedAttempt = (key, failed.retryableDownload) }
        if let active = cloudAttempt { cloudAttempt = (current, active.needsMetadataRefresh) }
    }

    private func endCloudAttempt(outcome: PreviewAttemptEnded.Outcome, refreshMetadata: Bool) {
        guard let attempt = cloudAttempt else { return }
        cloudAttempt = nil
        onCloudAttemptEnded?(PreviewAttemptEnded(attempt: PreviewAttempt(id: generation, request: attempt.request),
            outcome: outcome, refreshMetadata: refreshMetadata && attempt.needsMetadataRefresh))
    }

    func takePresentation(_ id: UUID) -> PreviewPresentation? {
        guard pending?.id == id else { return nil }
        let result = pending; pending = nil
        endCloudAttempt(outcome: .completed, refreshMetadata: true)
        return result
    }
    func registerRenderer(id: UUID, invalidate: @escaping () -> Void) {
        renderer?.invalidate()
        renderer = (id, invalidate)
        if case .ready = state, pending == nil, let request {
            self.request = nil
            var remount = request
            if let entry = request.entry, case .filesystem = entry.context { remount.hydrationPolicy = .residentOnly }
            show(remount)
        }
    }
    func unregisterRenderer(id: UUID) { if renderer?.id == id { renderer = nil } }
    func rendererFailed(_ id: UUID, message: String) {
        guard state == .ready(id) else { return }
        renderer?.invalidate()
        state = .failed(message)
    }
}

enum PreviewContentKind {
    case text, quickLook, raster(PreviewRasterKind)
    init?(_ item: FileItem) {
        guard !item.isDirectory, !item.isSymbolicLink else { return nil }
        let ext = item.url.pathExtension.lowercased()
        guard !["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "app", "pkg", "exe", "bin"].contains(ext) else { return nil }
        if ext == "html" || ext == "htm" { self = .quickLook; return }
        let source = Set(["txt", "log", "csv", "tsv", "md", "markdown", "json", "xml", "yaml", "yml", "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "py", "rb", "rs", "go", "java", "c", "h", "cc", "cpp", "hpp", "cs", "sh", "bash", "zsh", "sql", "toml", "ini", "conf", "plist"])
        if source.contains(ext) { self = .text; return }
        if ext == "xlsx" { self = .raster(.workbook); return }
        if ["png", "jpg", "jpeg"].contains(ext) { self = .raster(.image); return }
        if ["rtf", "doc", "docx", "xls", "ppt", "pptx", "pages", "numbers", "key"].contains(ext) {
            self = .quickLook; return
        }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audio) || type.conforms(to: .movie) {
            self = .quickLook
        } else if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { self = .text }
        else { return nil }
    }
}

enum PreviewText {
    enum Error: Swift.Error { case invalidEncoding }
    struct Result: Sendable { let value: String; let truncated: Bool }
    static let limit = 1_048_576
    static func read(_ url: URL, byteCount: UInt64) async throws -> Result {
        try await BlockingIO.run(on: .content) { cancellation in
            try cancellation.checkCancellation()
            let data = try PreviewRegularFile.withOpen(url) { handle, _ in
                try handle.read(upToCount: limit + 4) ?? Data()
            }
            try cancellation.checkCancellation()
            return try decode(data, truncated: byteCount > UInt64(limit) || data.count > limit)
        }
    }
    static func decode(_ data: Data, truncated: Bool) throws -> Result {
        var bytes = Data(data.prefix(limit))
        let encoding: String.Encoding
        if bytes.starts(with: [0xff, 0xfe]) { bytes.removeFirst(2); encoding = .utf16LittleEndian }
        else if bytes.starts(with: [0xfe, 0xff]) { bytes.removeFirst(2); encoding = .utf16BigEndian }
        else {
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
            encoding = .utf8
        }
        // Trim only a valid scalar interrupted by the byte limit. Removing
        // arbitrary invalid trailing bytes would silently accept malformed text.
        if truncated {
            if encoding == .utf8 { trimIncompleteUTF8(&bytes) }
            else {
                if bytes.count % 2 != 0 { bytes.removeLast() }
                if bytes.count >= 2 {
                    let pair = Array(bytes.suffix(2))
                    let unit = encoding == .utf16LittleEndian
                        ? UInt16(pair[0]) | UInt16(pair[1]) << 8
                        : UInt16(pair[0]) << 8 | UInt16(pair[1])
                    if (0xd800...0xdbff).contains(unit) { bytes.removeLast(2) }
                }
            }
        }
        let text = String(data: bytes, encoding: encoding)
        guard let text, !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) else {
            throw Error.invalidEncoding
        }
        return Result(value: text, truncated: truncated)
    }

    private static func trimIncompleteUTF8(_ bytes: inout Data) {
        let tail = Array(bytes.suffix(4))
        guard !tail.isEmpty else { return }
        var start = tail.count - 1
        while start > 0 && (0x80...0xbf).contains(tail[start]) { start -= 1 }
        let lead = tail[start]
        let length: Int
        switch lead {
        case 0xc2...0xdf: length = 2
        case 0xe0...0xef: length = 3
        case 0xf0...0xf4: length = 4
        default: return
        }
        let available = tail.count - start
        guard available < length, tail.dropFirst(start + 1).allSatisfy({ (0x80...0xbf).contains($0) }) else { return }
        if available > 1 {
            let second = tail[start + 1]
            guard !(lead == 0xe0 && second < 0xa0), !(lead == 0xed && second > 0x9f),
                  !(lead == 0xf0 && second < 0x90), !(lead == 0xf4 && second > 0x8f) else { return }
        }
        bytes.removeLast(available)
    }
}
