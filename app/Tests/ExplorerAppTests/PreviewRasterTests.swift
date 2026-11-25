import CoreGraphics
import Darwin
import Foundation
import ImageIO
import QuickLookThumbnailing
import Testing
import UniformTypeIdentifiers
@testable import ExplorerApp

@Suite
@MainActor
struct PreviewRasterTests {
    private let workbookURL = URL(fileURLWithPath: "/tmp/preview-fixture.xlsx")

    @Test
    func thumbnailTimeoutCancelsTheExactRequestAndIgnoresALateCallback() async throws {
        var started: QLThumbnailGenerator.Request?
        var cancelled: QLThumbnailGenerator.Request?
        var callback: PreviewThumbnailGenerator.Completion?
        let generator = PreviewThumbnailGenerator(timeout: .zero, start: { request, complete in
            started = request
            callback = complete
        }, cancel: { cancelled = $0 })

        let result = try await generator.generate(for: workbookURL)
        let request = try #require(started)
        #expect(result == nil && cancelled === request)
        #expect(request.size == CGSize(width: 1024, height: 1024) && request.scale == 1)
        #expect(!request.iconMode && request.representationTypes == .thumbnail)
        callback?(try image())
        await Task.yield()
    }

    @Test
    func duplicateThumbnailCompletionOnlyReturnsOneImage() async throws {
        let raster = try image()
        var cancelled = false
        let generator = PreviewThumbnailGenerator(start: { _, complete in
            complete(raster)
            complete(raster)
        }, cancel: { _ in cancelled = true })
        let result = try await generator.generate(for: workbookURL)
        #expect(result === raster)
        #expect(!cancelled)
    }

    @Test
    func directImageReadKeepsPngAlphaAndExcludesAnimatedPng() async throws {
        // These two tiny fixtures differ in frame count and both have transparent pixels.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGP4z8Dwn4GBgQEADPwB//0td20AAAAASUVORK5CYII="
        let apng = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAQAAAAAAAAAAAAEACgAA+Sm2eQAAABFJREFUeJxj+M/A8J+BgYEBAAz8Af/9LXdtAAAAGmZjVEwAAAABAAAAAgAAAAEAAAAAAAAAAAABAAoAAGJaXK0AAAAVZmRBVAAAAAJ4nGNgYPj/n4GBgQEACv4B/1U5ryIAAAAASUVORK5CYII="
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let still = root.appendingPathComponent("still.png"), animated = root.appendingPathComponent("animated.png")
        try #require(Data(base64Encoded: png)).write(to: still)
        try #require(Data(base64Encoded: apng)).write(to: animated)
        let provider = PreviewRasterProvider()
        guard case .image(let raster) = try await provider.prepare(.image, from: still) else {
            Issue.record("Expected a single-frame image")
            return
        }
        #expect(raster.width == 2 && raster.height == 1)
        #expect([.premultipliedFirst, .premultipliedLast, .first, .last].contains(raster.alphaInfo))
        guard case .excluded = try await provider.prepare(.image, from: animated) else {
            Issue.record("Expected the animated PNG to retain its Quick Look renderer")
            return
        }
    }

    @Test
    func directJpegReadUsesEmbeddedOrientation() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rotated.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        guard case .image(let raster) = try await PreviewRasterProvider().prepare(.image, from: url) else {
            Issue.record("Expected an oriented JPEG")
            return
        }
        #expect(raster.width == 1 && raster.height == 2)
    }

    @Test
    func imageReadRefusesSymlinkFifoAndOversizedInput() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.png"), link = root.appendingPathComponent("link.png")
        let fifo = root.appendingPathComponent("fifo.png"), oversized = root.appendingPathComponent("oversized.png")
        let destination = try #require(CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(), nil)
        try #require(CGImageDestinationFinalize(destination))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PreviewRasterProvider.maximumEncodedBytes + 1))
        try handle.close()

        for url in [link, fifo, oversized] {
            guard case .unavailable = try await PreviewRasterProvider().prepare(.image, from: url) else {
                Issue.record("Expected the bounded image reader to refuse \(url.lastPathComponent)")
                continue
            }
        }
    }

    private func image() throws -> CGImage {
        try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
