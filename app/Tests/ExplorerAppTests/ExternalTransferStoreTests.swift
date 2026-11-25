import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Deliberately ignores cancellation so the store must reject obsolete results itself.
private actor ExternalHeldImporter: FileTransferImporting {
    private(set) var requests: [[String]] = []
    private var pending: [Int: CheckedContinuation<[TransferEntry], Error>] = [:]
    private var closed = false

    func capture(urlStrings: [String]) async throws -> [TransferEntry] {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requests.count] = continuation
            requests.append(urlStrings)
        }
    }

    func complete(_ index: Int, entries: [TransferEntry]) {
        pending.removeValue(forKey: index)?.resume(returning: entries)
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: FileOperationError.staleSource)
    }

    func shutdown() {
        closed = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor ExternalRecordingWriter: FileTransferring {
    struct Call: Sendable {
        let item: FileItem
        let source: FileOperationContext
        let destination: FileOperationContext
        let kind: TransferKind
    }
    private(set) var calls: [Call] = []
    let writesFiles: Bool

    init(writesFiles: Bool = false) { self.writesFiles = writesFiles }

    func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext,
                  name: String, kind: TransferKind, control: TransferControl,
                  onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
        calls.append(Call(item: item, source: from, destination: to, kind: kind))
        if writesFiles {
            return try await LocalFileTransfers().transfer(item, from: from, to: to,
                name: name, kind: kind, control: control, onProgress: onProgress)
        }
        try control.checkpoint()
        return FileOperationResult(url: to.directoryURL.appendingPathComponent(name),
                                   identity: item.identity, warning: nil)
    }
}

/// All actual files and pasteboard contents belong exclusively to one test instance.
@MainActor
private final class ExternalStoreFiles {
    let root: URL
    let first: URL
    let second: URL
    let target: URL
    let otherTarget: URL
    let a: URL
    let b: URL
    let bytesA = Data([0, 1, 2, 127, 255, 10])
    let bytesB = Data("Unicode payload: café 日本語\n".utf8)
    let board = NSPasteboard(name: NSPasteboard.Name("ExplorerExternalStore-\(UUID().uuidString)"))
    let clipboard: TransferClipboard

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerExternalStore-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        first = root.appendingPathComponent("First", isDirectory: true)
        second = root.appendingPathComponent("Second", isDirectory: true)
        target = root.appendingPathComponent("Destination", isDirectory: true)
        otherTarget = root.appendingPathComponent("OtherDestination", isDirectory: true)
        a = first.appendingPathComponent("a.bin")
        b = second.appendingPathComponent("日本語.txt")
        clipboard = TransferClipboard(pasteboard: board)
        for directory in [first, second, target, otherTarget] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try bytesA.write(to: a)
        try bytesB.write(to: b)
    }

    func publish(_ urls: [URL]) throws {
        board.clearContents()
        try #require(board.writeObjects(urls.map { $0 as NSURL }))
    }

    func cleanup() {
        board.releaseGlobally()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned external-transfer fixture: \(error)") }
    }
}

/// FR-FILE-003/004, EV-0248–0255/9002/9008, AT-FILE-003/004; native Phase-12
/// interoperability acceptance NATIVE-P12. Named-pasteboard/store checks and real
/// disposable-file byte checks are separate from Finder UI and Windows fidelity.
@MainActor
final class ExternalTransferStoreTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "External transfer did not reach the expected state before the bounded deadline")
    }

    private func ready(_ store: ExplorerStore) async throws {
        try await waitUntil { !store.activeTab.isLoading && store.activeTab.hasLoaded }
        try #require(!store.activeTab.isUnavailable && store.activeTab.directoryIdentity != nil)
    }

    private func settled(_ store: ExplorerStore) async throws {
        try await waitUntil { !store.isPerformingOperation && !store.activeTab.isLoading }
    }

    private func stop(_ store: ExplorerStore, importer: ExternalHeldImporter? = nil) {
        store.cancelTransfer()
        store.cancelLoads()
        if let importer { Task { await importer.shutdown() } }
    }

    private func captured(_ urls: [URL]) async throws -> [TransferEntry] {
        try await LocalFileTransferImporter().capture(urlStrings: urls.map(\.absoluteString))
    }

    @Test
    func publicURLsFromDifferentParentsCopyTheirActualBytesAndRemainReusable() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let writer = ExternalRecordingWriter(writesFiles: true)
        let store = ExplorerStore(initialURL: files.target, transfers: writer, clipboard: files.clipboard)
        defer { stop(store) }
        try await ready(store)
        try files.publish([files.b, files.a])
        let changeCount = files.board.changeCount
        #expect(store.canPaste)
        store.pasteSelection()
        try await settled(store)
        #expect(await writer.calls.count == 2)
        #expect(await writer.calls.allSatisfy { $0.kind == .copy })
        #expect(await writer.calls.map(\.source.directoryURL) == [files.second, files.first])
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.a.lastPathComponent)) == files.bytesA)
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.b.lastPathComponent)) == files.bytesB)
        #expect(try Data(contentsOf: files.a) == files.bytesA)
        #expect(try Data(contentsOf: files.b) == files.bytesB)
        #expect(files.board.changeCount == changeCount && store.canPaste)

        store.navigate(to: files.otherTarget)
        try await ready(store)
        store.pasteSelection()
        try await settled(store)
        #expect(await writer.calls.count == 4)
        #expect(try Data(contentsOf: files.otherTarget.appendingPathComponent(files.a.lastPathComponent)) == files.bytesA)
        #expect(try Data(contentsOf: files.otherTarget.appendingPathComponent(files.b.lastPathComponent)) == files.bytesB)
        #expect(files.board.changeCount == changeCount)
    }

    @Test
    func explicitExternalMoveUsesEachParentAndPreservesBytes() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let writer = ExternalRecordingWriter(writesFiles: true)
        let store = ExplorerStore(initialURL: files.target, transfers: writer, clipboard: files.clipboard)
        defer { stop(store) }
        try await ready(store)
        try files.publish([files.a, files.b])
        store.moveHere()
        try await settled(store)
        #expect(await writer.calls.count == 2)
        #expect(await writer.calls.allSatisfy { $0.kind == .move })
        #expect(await writer.calls.map(\.source.directoryURL) == [files.first, files.second])
        #expect(!FileManager.default.fileExists(atPath: files.a.path))
        #expect(!FileManager.default.fileExists(atPath: files.b.path))
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.a.lastPathComponent)) == files.bytesA)
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.b.lastPathComponent)) == files.bytesB)
        #expect(!store.canPaste)
        store.moveHere()
        store.pasteSelection()
        #expect(await writer.calls.count == 2)
    }

    @Test
    func moveHereFromHomeClaimsTheChosenExternalTransferOnlyOnce() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let writer = ExternalRecordingWriter(writesFiles: true)
        let store = ExplorerStore(initialURL: BrowserPage.home.url, transfers: writer, clipboard: files.clipboard)
        defer { stop(store) }
        try files.publish([files.a, files.b])
        var choices = 0
        var choose: ((URL?) -> Void)?
        store.onChooseHomeFolder = { reply in choices += 1; choose = reply }
        try await waitUntil { store.activePage == .home && store.canPaste }
        store.moveHere()
        try await waitUntil { choose != nil }
        let cancel = try #require(choose)
        cancel(nil)
        #expect(await writer.calls.isEmpty)
        try await waitUntil { store.canPaste }
        choose = nil
        store.moveHere()
        try await waitUntil { choose != nil }
        let pickFolder = try #require(choose)
        pickFolder(files.target)
        try await waitUntil { await writer.calls.count == 2 && !store.isPerformingOperation }
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.a.lastPathComponent)) == files.bytesA)
        #expect(try Data(contentsOf: files.target.appendingPathComponent(files.b.lastPathComponent)) == files.bytesB)
        #expect(!FileManager.default.fileExists(atPath: files.a.path))
        #expect(!FileManager.default.fileExists(atPath: files.b.path))
        #expect(await writer.calls.allSatisfy { $0.kind == .move })
        #expect(!store.canPaste)
        store.moveHere()
        store.pasteSelection()
        #expect(choices == 2)
        #expect(await writer.calls.count == 2)
        #expect(store.activePage == .home)
    }

    @Test(arguments: ["copy", "move"])
    func importedFoldersAndPackagesReconcileSelectionWithFreshDirectoryURLs(_ command: String) async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let folder = files.first.appendingPathComponent("Folder", isDirectory: true)
        let package = files.second.appendingPathComponent("Sample.app", isDirectory: true)
        let folderResource = "Nested/payload.bin"
        let packageResource = "Contents/Resources/payload.bin"
        for (directory, resource, bytes) in [(folder, folderResource, files.bytesA),
                                             (package, packageResource, files.bytesB)] {
            let payload = directory.appendingPathComponent(resource)
            try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: payload)
        }
        let info: [String: Any] = ["CFBundleIdentifier": "test.explorer.external-transfer",
                                   "CFBundleName": "Sample", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: package.appendingPathComponent("Contents/Info.plist"))
        // Public file URLs need not carry a trailing slash. The importer must
        // derive the directory hint from captured metadata, including packages.
        let urls = [folder, package].map { URL(fileURLWithPath: $0.path, isDirectory: false) }
        #expect(urls.allSatisfy { !$0.hasDirectoryPath })
        let writer = ExternalRecordingWriter(writesFiles: true)
        let store = ExplorerStore(initialURL: files.target, transfers: writer, clipboard: files.clipboard)
        defer { stop(store) }
        try await ready(store)
        try files.publish(urls)
        if command == "copy" { store.pasteSelection() } else { store.moveHere() }
        try await settled(store)

        let fresh = try await LocalDirectoryLoader().snapshot(of: files.target)
        try #require(fresh.items.count == 2)
        let folderRow = try #require(fresh.items.first { $0.name == "Folder" })
        let packageRow = try #require(fresh.items.first { $0.name == "Sample.app" })
        #expect(folderRow.isDirectory && folderRow.url.hasDirectoryPath)
        #expect(!packageRow.isDirectory && packageRow.url.hasDirectoryPath)
        #expect(store.activeTab.selection.selectedIDs == Set(fresh.items.map(\.id)))
        #expect(store.activeTab.selection.focusedID.map { store.activeTab.selection.selectedIDs.contains($0) } == true)
        #expect(store.operationNotice?.contains("could not be verified") == false)
        #expect(store.operationNotice?.contains(command == "copy" ? "Copied 2 of 2" : "Moved 2 of 2") == true)
        #expect(await writer.calls.count == 2)
        #expect(try Data(contentsOf: files.target.appendingPathComponent("Folder/\(folderResource)")) == files.bytesA)
        #expect(try Data(contentsOf: files.target.appendingPathComponent("Sample.app/\(packageResource)")) == files.bytesB)
        #expect(FileManager.default.fileExists(atPath: folder.path) == (command == "copy"))
        #expect(FileManager.default.fileExists(atPath: package.path) == (command == "copy"))
        if command == "copy" {
            #expect(try Data(contentsOf: folder.appendingPathComponent(folderResource)) == files.bytesA)
            #expect(try Data(contentsOf: package.appendingPathComponent(packageResource)) == files.bytesB)
        }
    }

    @Test
    func preparingLocksMutationsAndNavigationAndCancellationRejectsALateCapture() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let entries = try await captured([files.a])
        try files.publish([files.a])
        let tabIDs = store.tabs.map(\.id)
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 1 }
        #expect(store.isPerformingOperation && store.transfer?.isPreparing == true)
        #expect(!store.canPaste && !store.canCreateFolder)
        store.navigate(to: files.otherTarget)
        store.addTab()
        store.closeTab(store.activeTabID)
        store.beginCreateFolder()
        store.pasteSelection()
        #expect(store.tabs.map(\.id) == tabIDs && store.activeTab.url == files.target)
        #expect(store.nameEdit == nil)
        #expect(await importer.requests.count == 1)
        store.cancelTransfer()
        try await settled(store)
        await importer.complete(0, entries: entries)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await writer.calls.isEmpty)
        #expect(store.transfer == nil && !store.isPerformingOperation && store.canPaste)
    }

    @Test
    func changedPasteboardRejectsPreparedEntriesAndPreservesReplacementContent() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let entries = try await captured([files.a])
        try files.publish([files.a])
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 1 }
        files.board.clearContents()
        try #require(files.board.setString("replacement text", forType: .string))
        await importer.complete(0, entries: entries)
        try await settled(store)
        #expect(await writer.calls.isEmpty)
        #expect(files.board.string(forType: .string) == "replacement text")
        #expect(store.operationNotice != nil)
    }

    @Test
    func cancelledPreparationCannotClearOrWriteThroughANewerSession() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let oldEntries = try await captured([files.a]), newEntries = try await captured([files.b])
        try files.publish([files.a])
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 1 }
        store.cancelTransfer()
        try await settled(store)
        try files.publish([files.b])
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 2 }
        let currentSessionID = try #require(store.transfer?.id)
        await importer.complete(0, entries: oldEntries)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await writer.calls.isEmpty)
        #expect(store.transfer?.id == currentSessionID && store.transfer?.isPreparing == true)
        await importer.complete(1, entries: newEntries)
        try await settled(store)
        #expect(await writer.calls.map(\.item.url) == [files.b])
    }

    @Test(arguments: ["generation", "active-tab", "identity", "unavailable"])
    func invalidatedDestinationCannotReceiveALatePreparedBatch(_ change: String) async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let entries = try await captured([files.a])
        try files.publish([files.a])
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 1 }
        switch change {
        case "generation": store.cancelLoads()
        case "active-tab":
            let tab = BrowserTab(url: files.otherTarget)
            store.tabs.append(tab)
            store.activeTabID = tab.id
        case "identity":
            let old = try #require(store.tabs[0].directoryIdentity)
            store.tabs[0].directoryIdentity = LocalFileIdentity(device: old.device, inode: old.inode &+ 1,
                birthSeconds: old.birthSeconds, birthNanoseconds: old.birthNanoseconds)
        default: store.tabs[0].isUnavailable = true
        }
        await importer.complete(0, entries: entries)
        try await settled(store)
        #expect(await writer.calls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.target.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.otherTarget.path).isEmpty)
    }

    @Test(arguments: ["cancel", "failure"])
    func externalMoveClaimIsSharedAndRemainsConsumedAfterPreparationStops(_ stopReason: String) async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let first = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        let second = ExplorerStore(initialURL: files.otherTarget, transfers: writer,
                                   transferImporter: importer, clipboard: files.clipboard)
        defer { stop(first, importer: importer); stop(second) }
        try await ready(first)
        try await ready(second)
        try files.publish([files.a])
        first.moveHere()
        try await waitUntil { await importer.requests.count == 1 }
        second.moveHere()
        #expect(await importer.requests.count == 1)
        if stopReason == "cancel" {
            first.cancelTransfer()
            await importer.complete(0, entries: try await captured([files.a]))
        } else { await importer.fail(0) }
        try await settled(first)
        first.moveHere()
        second.moveHere()
        #expect(await importer.requests.count == 1)
        #expect(await writer.calls.isEmpty)
        #expect(try Data(contentsOf: files.a) == files.bytesA)
        // The reservation is specifically move intent; public URLs still permit
        // an ordinary, independently validated copy after the move was refused.
        #expect(second.canPaste)
        second.pasteSelection()
        try await waitUntil { await importer.requests.count == 2 }
        await importer.complete(1, entries: try await captured([files.a]))
        try await settled(second)
        #expect(await writer.calls.count == 1)
        #expect(await writer.calls.first?.kind == .copy)
    }

    /// NATIVE-P15 / MAC-066 replaces the Phase 12 refusal: a mixed-device move
    /// batch is no longer refused up front. Each entry reaches the existing
    /// writer as a move with its own source context; the writer chooses rename
    /// or verified copy-and-remove. The single-use Move Here claim is retained.
    @Test
    func mixedDeviceMoveReachesTheWriterWithEachEntrysOwnSource() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let entries = try await captured([files.a, files.b])
        let old = entries[1].source.directoryIdentity
        let foreign = FileOperationContext(directoryURL: entries[1].source.directoryURL,
            directoryIdentity: LocalFileIdentity(device: old.device &+ 1, inode: old.inode,
                birthSeconds: old.birthSeconds, birthNanoseconds: old.birthNanoseconds))
        let mixed = [entries[0], TransferEntry(source: foreign, item: entries[1].item)]
        try files.publish([files.a, files.b])
        store.moveHere()
        try await waitUntil { await importer.requests.count == 1 }
        await importer.complete(0, entries: mixed)
        try await settled(store)
        let calls = await writer.calls
        #expect(calls.map(\.kind) == [.move, .move])
        #expect(calls.map(\.source) == mixed.map(\.source))
        store.moveHere()
        #expect(await importer.requests.count == 1)
    }

    @Test
    func mixedPublicFileAndTextItemsRefuseBeforeMetadataImport() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter()
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let file = NSPasteboardItem(), text = NSPasteboardItem()
        try #require(file.setString(files.a.absoluteString, forType: .fileURL))
        try #require(text.setString("unsupported companion", forType: .string))
        files.board.clearContents()
        try #require(files.board.writeObjects([file, text]))
        store.pasteSelection()
        #expect(!store.isPerformingOperation && store.transfer == nil)
        #expect(await importer.requests.isEmpty)
        #expect(await writer.calls.isEmpty)
        #expect(store.operationNotice != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.target.path).isEmpty)
    }

    @Test
    func sourceReplacementAfterCaptureIsRefusedByTheExistingWriter() async throws {
        let files = try ExternalStoreFiles()
        defer { files.cleanup() }
        let importer = ExternalHeldImporter(), writer = ExternalRecordingWriter(writesFiles: true)
        let store = ExplorerStore(initialURL: files.target, transfers: writer,
                                  transferImporter: importer, clipboard: files.clipboard)
        defer { stop(store, importer: importer) }
        try await ready(store)
        let entries = try await captured([files.a])
        try files.publish([files.a])
        store.pasteSelection()
        try await waitUntil { await importer.requests.count == 1 }
        let retainedOriginal = files.first.appendingPathComponent("retained-original.bin")
        try FileManager.default.moveItem(at: files.a, to: retainedOriginal)
        let replacementBytes = Data("replacement must not be copied".utf8)
        try replacementBytes.write(to: files.a)
        await importer.complete(0, entries: entries)
        try await settled(store)
        #expect(await writer.calls.count == 1)
        #expect(store.operationNotice?.contains("Copied 0 of 1") == true)
        #expect(try Data(contentsOf: files.a) == replacementBytes)
        #expect(try Data(contentsOf: retainedOriginal) == files.bytesA)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.target.path).isEmpty)
    }
}
