import CoreGraphics
import Darwin
import ExplorerCore
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum PreviewRasterKind: Sendable { case workbook, image }

enum PreviewRasterResult: Sendable {
    case image(CGImage)
    case excluded
    case unavailable
}

protocol PreviewRasterPreparing {
    @MainActor func prepare(_ kind: PreviewRasterKind, from url: URL) async throws -> PreviewRasterResult
}

enum PreviewRegularFile {
    static func withOpen<T>(_ url: URL, _ read: (FileHandle, stat) throws -> T) throws -> T {
        guard url.isFileURL else { throw ItemContentError.unsupportedType }
        // Validation brackets the read, but a path can be replaced in between.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ItemContentError.unsupportedType }
        return try read(FileHandle(fileDescriptor: descriptor, closeOnDealloc: false), metadata)
    }
}

struct PreviewRasterProvider: PreviewRasterPreparing {
    static let maximumEdge = 4096
    static let maximumEncodedBytes = 32 * 1_024 * 1_024

    private let thumbnails: PreviewThumbnailGenerator

    init(thumbnails: PreviewThumbnailGenerator = PreviewThumbnailGenerator()) {
        self.thumbnails = thumbnails
    }

    @MainActor
    func prepare(_ kind: PreviewRasterKind, from url: URL) async throws -> PreviewRasterResult {
        switch kind {
        case .workbook:
            if let image = try await thumbnails.generate(for: url) { return .image(image) }
            return .unavailable
        case .image:
            return try await BlockingIO.run(on: .content) { cancellation in
                try cancellation.checkCancellation()
                let data: Data
                do {
                    data = try PreviewRegularFile.withOpen(url) { handle, metadata in
                        guard metadata.st_size > 0, metadata.st_size <= Int64(Self.maximumEncodedBytes),
                              metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
                            throw ItemContentError.unsupportedType
                        }
                        let expectedSize = Int(metadata.st_size)
                        guard let data = try handle.read(upToCount: expectedSize + 1),
                              data.count == expectedSize else {
                            throw ItemContentError.staleSource
                        }
                        return data
                    }
                } catch ItemContentError.staleSource {
                    throw ItemContentError.staleSource
                } catch {
                    try cancellation.checkCancellation()
                    return .unavailable
                }
                try cancellation.checkCancellation()
                let result = Self.decode(data)
                try cancellation.checkCancellation()
                return result
            }
        }
    }

    private static func decode(_ data: Data) -> PreviewRasterResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let imageType = UTType(type as String),
              imageType == .png || imageType == .jpeg else { return .unavailable }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 { return .excluded }
        guard frameCount == 1 else { return .unavailable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              accepts(image) else { return .unavailable }
        return .image(image)
    }

    static func accepts(_ image: CGImage) -> Bool {
        // Bounding each positive edge also bounds the total to 16,777,216 pixels.
        (1...maximumEdge).contains(image.width) && (1...maximumEdge).contains(image.height)
    }
}

struct PreviewThumbnailGenerator {
    private static let requestEdge = 1024
    typealias Completion = @Sendable (CGImage?) -> Void
    typealias Start = @MainActor (QLThumbnailGenerator.Request, @escaping Completion) -> Void
    typealias Cancel = @MainActor (QLThumbnailGenerator.Request) -> Void

    private let timeout: Duration
    private let start: Start
    private let cancel: Cancel

    init(timeout: Duration = .seconds(8), start: @escaping Start = { request, complete in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard error == nil, let representation, representation.type == .thumbnail else {
                complete(nil)
                return
            }
            complete(representation.cgImage)
        }
    }, cancel: @escaping Cancel = { QLThumbnailGenerator.shared.cancel($0) }) {
        self.timeout = timeout
        self.start = start
        self.cancel = cancel
    }

    @MainActor
    func generate(for url: URL) async throws -> CGImage? {
        let edge = CGFloat(Self.requestEdge)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: edge, height: edge),
                                                   scale: 1, representationTypes: .thumbnail)
        request.iconMode = false
        let pending = PendingThumbnail(cancel: { cancel(request) })
        let image = try await withTaskCancellationHandler {
            try await pending.wait(timeout: timeout) { start(request, $0) }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError()), cancelRequest: true) }
        }
        try Task.checkCancellation()
        return image.flatMap { PreviewRasterProvider.accepts($0) ? $0 : nil }
    }
}

/// Selection changes can stop waiting immediately. Quick Look may still be
/// reading the URL, so callers may only use this with a borrowed lease.
@MainActor
private final class PendingThumbnail {
    private let cancel: () -> Void
    private var reply: CheckedContinuation<CGImage?, Error>?
    private var timer: Task<Void, Never>?

    init(cancel: @escaping () -> Void) { self.cancel = cancel }

    func wait(timeout: Duration, start: (@escaping PreviewThumbnailGenerator.Completion) -> Void) async throws -> CGImage? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            reply = continuation
            timer = Task { [weak self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                self?.finish(.success(nil), cancelRequest: true)
            }
            start { [weak self] image in
                Task { @MainActor in self?.finish(.success(image), cancelRequest: false) }
            }
        }
    }

    func finish(_ result: Result<CGImage?, Error>, cancelRequest: Bool) {
        guard let reply else { return }
        self.reply = nil
        timer?.cancel()
        timer = nil
        if cancelRequest { cancel() }
        reply.resume(with: result)
    }
}
