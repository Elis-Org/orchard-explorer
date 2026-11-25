import AppKit
import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor PreviewProviderGate: ItemContentProviding {
    private(set) var requests: [ContentRequest] = []
    private var continuations: [Int: CheckedContinuation<any MaterializedContentLease, Error>] = [:]
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, lease: any MaterializedContentLease) { continuations.removeValue(forKey: index)?.resume(returning: lease) }
}

private final class PreviewLeaseProbe: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    var fileURL: URL { physicalEntry.item.url }
    var sourceURL: URL { fileURL }
    let archiveRevision: ArchiveRevision? = nil
    let byteCount: UInt64 = 24
    let isBorrowed: Bool
    let failAfterFirstValidation: Bool
    private let lock = NSLock()
    private var validationCount = 0
    private var releaseCount = 0
    private var recordedEvents: [String] = []
    var validations: Int { lock.lock(); defer { lock.unlock() }; return validationCount }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return releaseCount }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recordedEvents }
    func stoppedAndDetached() { lock.lock(); recordedEvents.append("stop/detach"); lock.unlock() }
    init(_ entry: TransferEntry, isBorrowed: Bool = false, failAfterFirstValidation: Bool = false) {
        physicalEntry = entry
        self.isBorrowed = isBorrowed
        self.failAfterFirstValidation = failAfterFirstValidation
    }
    func validateForUse() async throws {
        if incrementValidation() > 1 && failAfterFirstValidation { throw ItemContentError.staleSource }
    }
    private func incrementValidation() -> Int {
        lock.lock(); defer { lock.unlock() }
        validationCount += 1
        return validationCount
    }
    func release() async -> ContentLeaseReleaseResult {
        incrementRelease()
        return ContentLeaseReleaseResult(disposition: .released)
    }
    private func incrementRelease() { lock.lock(); releaseCount += 1; recordedEvents.append("release"); lock.unlock() }
}

@MainActor
private final class PreviewRasterStub: PreviewRasterPreparing {
    let result: PreviewRasterResult
    private(set) var urls: [URL] = []
    init(_ result: PreviewRasterResult) { self.result = result }
    func prepare(_ kind: PreviewRasterKind, from url: URL) async throws -> PreviewRasterResult {
        urls.append(url)
        return result
    }
}

@Suite(.serialized)
@MainActor
struct ItemPreviewTests {
    private func entry(_ name: String) -> TransferEntry {
        let root = URL(fileURLWithPath: "/tmp/preview-model", isDirectory: true)
        let identity = LocalFileIdentity(device: 1, inode: 10, birthSeconds: 1, birthNanoseconds: 0)
        let item = FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "",
            identity: LocalFileIdentity(device: 1, inode: name == "First.pdf" ? 11 : 12, birthSeconds: 1, birthNanoseconds: 0))
        return TransferEntry(source: FileOperationContext(directoryURL: root, directoryIdentity: identity), item: item)
    }
    private func request(_ entry: TransferEntry, tab: UUID = UUID(), generation: UUID = UUID()) -> PreviewRequest {
        PreviewRequest(tabID: tab, generation: generation, searchGeneration: nil,
            items: [entry.item], entry: ItemOperationEntry(entry))
    }
    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
    }

    @Test
    func paneKindsAreExclusiveAndToolbarRemembersLastKindWithoutLosingWidth() {
        var state = InspectorPaneState()
        state.toggle(.preview)
        #expect(state.mode == .preview && state.lastMode == .preview)
        state.resize(to: 420, available: 1000)
        state.toggle(.details)
        #expect(state.mode == .details && state.lastMode == .details && state.width == 420)
        state.toggleLast()
        #expect(state.mode == .none && state.lastMode == .details)
        state.toggleLast()
        #expect(state.mode == .details)
        state.resize(to: 900, available: 500)
        #expect(state.width == 500)
        state.resize(to: 100, available: 1000)
        #expect(state.width == 220)
    }

    @Test
    func unsupportedAndMultipleSelectionsNeverAskForContent() async throws {
        let provider = PreviewProviderGate(), model = ItemPreviewModel(provider: provider)
        let binary = entry("Unknown.bin")
        model.show(request(binary))
        #expect(model.state == .unsupported)
        model.show(PreviewRequest(tabID: UUID(), generation: UUID(), searchGeneration: nil,
            items: [entry("First.pdf").item, binary.item], entry: nil))
        #expect(model.state == .multiple)
        model.show(nil)
        #expect(model.state == .empty)
        #expect(await provider.requests.isEmpty)
    }

    @Test
    func staleCompletionReleasesOnlyItsLeaseAndHideReleasesPendingPresentation() async throws {
        let provider = PreviewProviderGate(), model = ItemPreviewModel(provider: provider)
        let first = entry("First.pdf"), second = entry("Second.pdf")
        model.show(request(first))
        try await waitFor { await provider.requests.count == 1 }
        model.show(request(second))
        try await waitFor { await provider.requests.count == 2 }
        let oldLease = PreviewLeaseProbe(first), currentLease = PreviewLeaseProbe(second)
        await provider.finish(1, lease: currentLease)
        try await waitFor { if case .ready = model.state { return true }; return false }
        let currentState = model.state
        await provider.finish(0, lease: oldLease)
        try await waitFor { oldLease.releases == 1 }
        #expect(model.state == currentState && currentLease.validations == 1 && currentLease.releases == 0)
        model.show(nil)
        try await waitFor { currentLease.releases == 1 }
        #expect(model.state == .empty)
    }

    @Test
    func acceptedPresentationHasOneOwnerAndModelHideCannotReleaseIt() async throws {
        let provider = PreviewProviderGate(), model = ItemPreviewModel(provider: provider)
        let source = entry("First.pdf"), lease = PreviewLeaseProbe(entry("First.pdf"))
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { if case .ready = model.state { return true }; return false }
        guard case .ready(let id) = model.state else { Issue.record("Expected a prepared presentation"); return }
        let presentation = try #require(model.takePresentation(id))
        #expect(model.takePresentation(id) == nil)
        model.show(nil)
        #expect(lease.releases == 0 && lease.validations == 1)
        _ = await presentation.lease.release()
        #expect(lease.releases == 1)
    }

    @Test
    func rendererRemountUsesResidentOnlyWithoutChangingAnInflightRequest() async throws {
        let provider = PreviewProviderGate(), model = ItemPreviewModel(provider: provider)
        let source = entry("First.pdf"), firstRenderer = UUID()
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        model.registerRenderer(id: firstRenderer) {}
        #expect(await provider.requests.count == 1)
        #expect(await provider.requests[0].hydrationPolicy == .whenNeeded)
        let firstLease = PreviewLeaseProbe(source)
        await provider.finish(0, lease: firstLease)
        try await waitFor { if case .ready = model.state { return true }; return false }
        guard case .ready(let id) = model.state else { return }
        let presentation = try #require(model.takePresentation(id))
        model.unregisterRenderer(id: firstRenderer)
        model.registerRenderer(id: UUID()) {}
        try await waitFor { await provider.requests.count == 2 }
        #expect(await provider.requests[1].hydrationPolicy == .residentOnly)
        let nextLease = PreviewLeaseProbe(source)
        await provider.finish(1, lease: nextLease)
        try await waitFor { if case .ready = model.state { return true }; return false }
        model.show(nil)
        _ = await presentation.lease.release()
        try await waitFor { nextLease.releases == 1 }
    }

    @Test
    func htmlDocumentsChooseRenderingForPhysicalAndArchiveLocations() throws {
        for name in ["Page.html", "Page.htm", "Page.HTML", "Page.HTM"] {
            let physical = entry(name).item
            let archiveURL = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/preview-model/Sample.zip"),
                components: ["Pages", name]).url
            let archived = FileItem(url: archiveURL, name: name, isDirectory: false,
                isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "HTML document")
            for item in [physical, archived] {
                guard case .quickLook = PreviewContentKind(item) else {
                    Issue.record("HTML should render instead of showing source: \(item.url)")
                    continue
                }
            }
        }
        for name in ["Style.css", "Script.js", "Data.xml", "Notes.txt"] {
            guard case .text = PreviewContentKind(entry(name).item) else {
                Issue.record("Source text routing changed for \(name)")
                continue
            }
        }
    }

    @Test
    func htmlPresentationUsesTheValidatedQuickLookLease() async throws {
        let provider = PreviewProviderGate(), source = entry("Rendered.html")
        let model = ItemPreviewModel(provider: provider), lease = PreviewLeaseProbe(source)
        defer { model.show(nil) }
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { model.state != .preparing }
        guard case .ready(let id) = model.state else {
            Issue.record("HTML should be handed to the renderer with its validated lease")
            return
        }
        let presentation = try #require(model.takePresentation(id))
        guard case .quickLook = presentation.content else {
            _ = await presentation.lease.release()
            Issue.record("HTML presentation contains source text")
            return
        }
        #expect(lease.validations == 1 && lease.releases == 0)
        _ = await presentation.lease.release()
        #expect(lease.releases == 1)
    }

    @Test(arguments: [false, true])
    func workbookFallbackRequiresBorrowedLeaseAndReportsOnlyAttemptedRasterFailure(_ borrowed: Bool) async throws {
        let provider = PreviewProviderGate(), raster = PreviewRasterStub(.unavailable)
        let model = ItemPreviewModel(provider: provider, rasterProvider: raster)
        let source = entry("Workbook.XLSX"), lease = PreviewLeaseProbe(source, isBorrowed: borrowed)
        defer { model.show(nil) }
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { model.state != .preparing }
        guard case .ready(let id) = model.state else { Issue.record("Expected Quick Look fallback"); return }
        let presentation = try #require(model.takePresentation(id))
        guard case .quickLook = presentation.content else {
            _ = await presentation.lease.release()
            Issue.record("Expected Quick Look fallback")
            return
        }
        #expect(raster.urls == (borrowed ? [lease.fileURL] : []))
        #expect(presentation.zoomUnavailable == borrowed)
        #expect(lease.validations == (borrowed ? 2 : 1))
        _ = await presentation.lease.release()
        #expect(lease.releases == 1)
    }

    @Test
    func borrowedWorkbookPublishesRasterAfterSecondValidation() async throws {
        let provider = PreviewProviderGate()
        let image = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let raster = PreviewRasterStub(.image(image))
        let model = ItemPreviewModel(provider: provider, rasterProvider: raster)
        let source = entry("Workbook.xlsx"), lease = PreviewLeaseProbe(source, isBorrowed: true)
        defer { model.show(nil) }
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { model.state != .preparing }
        guard case .ready(let id) = model.state else { Issue.record("Expected a raster preview"); return }
        let presentation = try #require(model.takePresentation(id))
        guard case .raster(let accepted) = presentation.content else {
            _ = await presentation.lease.release()
            Issue.record("Expected a raster preview")
            return
        }
        #expect(accepted === image && !presentation.zoomUnavailable)
        #expect(lease.validations == 2 && lease.releases == 0)
        _ = await presentation.lease.release()
        #expect(lease.releases == 1)
    }

    @Test
    func staleSourceAfterThumbnailFailureDoesNotFallBack() async throws {
        let provider = PreviewProviderGate(), raster = PreviewRasterStub(.unavailable)
        let model = ItemPreviewModel(provider: provider, rasterProvider: raster)
        let source = entry("Workbook.xlsx")
        let lease = PreviewLeaseProbe(source, isBorrowed: true, failAfterFirstValidation: true)
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { model.state != .preparing }
        #expect(model.state == .failed(ItemContentError.staleSource.localizedDescription))
        #expect(raster.urls == [lease.fileURL] && lease.validations == 2 && lease.releases == 1)
    }

    @Test
    func lateWorkbookCallbackCannotReplaceAnotherSelectionOrShowDownloading() async throws {
        let provider = PreviewProviderGate()
        var complete: PreviewThumbnailGenerator.Completion?
        var cancellations = 0
        let thumbnails = PreviewThumbnailGenerator(start: { _, reply in complete = reply },
                                                   cancel: { _ in cancellations += 1 })
        let model = ItemPreviewModel(provider: provider, rasterProvider: PreviewRasterProvider(thumbnails: thumbnails))
        let source = entry("Workbook.xlsx"), other = entry("Other.pdf")
        let lease = PreviewLeaseProbe(source, isBorrowed: true), otherLease = PreviewLeaseProbe(other)
        let workbookRequest = request(source)
        defer { model.show(nil) }
        model.show(workbookRequest)
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { complete != nil }
        let materialization = await provider.requests[0]
        materialization.onProgress?(.downloading)
        try await waitFor { model.blocksAutomaticRefresh(tabID: workbookRequest.tabID) }
        #expect(model.state == .preparing && model.downloadingItemID == nil)

        model.show(request(other))
        try await waitFor { await provider.requests.count == 2 }
        await provider.finish(1, lease: otherLease)
        try await waitFor { lease.releases == 1 && model.state != .preparing }
        guard case .ready(let id) = model.state else { Issue.record("Expected the replacement preview"); return }
        let lateImage = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        complete?(lateImage)
        await Task.yield()
        #expect(model.state == .ready(id) && cancellations == 1 && lease.releases == 1)
        #expect(lease.validations == 1)
    }

    @Test
    func boundedTextSupportsBOMEmptyAndSourceButRejectsBinaryControls() throws {
        #expect(try PreviewText.decode(Data(), truncated: false).value.isEmpty)
        #expect(try PreviewText.decode(Data([0xef, 0xbb, 0xbf]) + Data("let value = 1\n".utf8), truncated: false).value == "let value = 1\n")
        #expect(try PreviewText.decode(Data([0xff, 0xfe, 0x41, 0, 0x0a, 0]), truncated: false).value == "A\n")
        #expect(try PreviewText.decode(Data([0xfe, 0xff, 0, 0x41]), truncated: false).value == "A")
        #expect(throws: PreviewText.Error.self) { try PreviewText.decode(Data([0, 1, 2, 3]), truncated: false) }
        let prefix = try PreviewText.decode(Data(repeating: 65, count: PreviewText.limit + 10), truncated: true)
        #expect(prefix.truncated && prefix.value.utf8.count == PreviewText.limit)
        #expect(PreviewContentKind(entry("index.html").item) != nil)
        #expect(PreviewContentKind(entry("Bundle.zip").item) == nil)
    }

    @Test
    func truncatedTextDropsOnlyAnIncompleteValidScalar() throws {
        let completePrefix = Data(repeating: 65, count: PreviewText.limit - 1)
        let splitEmoji = try PreviewText.decode(completePrefix + Data([0xf0, 0x9f, 0x98, 0x80]), truncated: true)
        #expect(splitEmoji.truncated && splitEmoji.value.utf8.count == PreviewText.limit - 1)
        #expect(throws: PreviewText.Error.self) {
            _ = try PreviewText.decode(completePrefix + Data([0xff, 0x41]), truncated: true)
        }
        #expect(throws: PreviewText.Error.self) {
            _ = try PreviewText.decode(Data(repeating: 65, count: PreviewText.limit - 2) + Data([0xed, 0xa0, 0x80]), truncated: true)
        }
        let utf16 = Data([0xff, 0xfe]) + Data(repeating: 0x41, count: PreviewText.limit - 4) + Data([0x3d, 0xd8, 0x00, 0xde])
        let splitSurrogate = try PreviewText.decode(utf16, truncated: true)
        #expect(splitSurrogate.truncated && splitSurrogate.value.utf16.count == (PreviewText.limit - 4) / 2)
    }

    @Test
    func finalTextReadRejectsSymlinksAndFIFOWithoutOpeningAStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewText-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.txt")
        try Data("Synthetic text".utf8).write(to: regular)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let fifo = root.appendingPathComponent("pipe.txt")
        try #require(mkfifo(fifo.path, mode_t(0o600)) == 0)
        await #expect(throws: (any Error).self) { _ = try await PreviewText.read(link, byteCount: 14) }
        await #expect(throws: ItemContentError.self) { _ = try await PreviewText.read(fifo, byteCount: 0) }
        #expect(try await PreviewText.read(regular, byteCount: 14).value == "Synthetic text")
    }

    @Test
    func rendererStopsAndDetachesBeforeExactlyOneLeaseRelease() async throws {
        let lease = PreviewLeaseProbe(entry("First.pdf"))
        let owner = PreviewPresentationOwner()
        owner.accept(PreviewPresentation(title: "First.pdf", content: .quickLook, lease: lease)) {
            lease.stoppedAndDetached()
        }
        let cleanup = try #require(owner.clear())
        #expect(lease.events.first == "stop/detach")
        await cleanup.value
        #expect(lease.events == ["stop/detach", "release"])
        #expect(owner.clear() == nil && lease.releases == 1)
    }

    @Test(arguments: [false, true])
    func clearingRendererRepairsOnlyFocusOwnedByItsOutgoingContent(_ previewFocused: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewFocus-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Synthetic focus preview.".utf8).write(to: root.appendingPathComponent("note.txt"))
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let source = TransferEntry(source: FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity)),
            item: try #require(snapshot.items.first))
        let provider = PreviewProviderGate(), model = ItemPreviewModel(provider: provider)
        let lease = PreviewLeaseProbe(source), focus = ExplorerFocusCoordinator()
        let host = PreviewHostView(frame: NSRect(x: 100, y: 0, width: 300, height: 240))
        let list = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 240))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        container.addSubview(list); container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        focus.register(.list, owner: list) { [weak list, weak window] in
            guard let list else { return false }
            return window?.makeFirstResponder(list) == true
        }
        let coordinator = PreviewRenderer.Coordinator(model: model)
        coordinator.attach(host, focus: focus)
        defer { coordinator.detach(); model.show(nil) }
        model.show(request(source))
        try await waitFor { await provider.requests.count == 1 }
        await provider.finish(0, lease: lease)
        try await waitFor { if case .ready = model.state { return true }; return false }
        coordinator.update(model.state)
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try #require(textView(in: host))
        try #require(window.makeFirstResponder(previewFocused ? text : list))
        model.show(nil)
        let expected: NSResponder = previewFocused ? host : list
        #expect(window.firstResponder === expected,
            "Invalidation repairs outgoing preview focus without taking focus from the list")
        #expect(host.subviews.isEmpty)
        try await waitFor { lease.releases == 1 }
        coordinator.detach()
        #expect(window.firstResponder === list, "Removing the pane returns its owned focus to the list")
    }

    @Test
    func shutdownReceiptFailureRefusesTerminationAndReportsWithoutModal() async {
        let termination = ContentSessionTermination {
            throw CocoaError(.fileWriteNoPermission)
        }
        var errors: [String] = []
        termination.onFailure = { errors.append($0) }
        #expect(!(await termination.finish()))
        #expect(termination.state == .idle && errors.count == 1 && !errors[0].isEmpty)
        let success = ContentSessionTermination(shutdown: {})
        #expect(await success.finish())
        #expect(success.state == .finished)
        #expect(await success.finish())
    }
}
