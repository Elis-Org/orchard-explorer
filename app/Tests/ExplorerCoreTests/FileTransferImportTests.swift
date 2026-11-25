import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class TransferImportFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned transfer import fixture cleanup failed: \(root.path): \(error)") }
    }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ name: String, in parent: URL? = nil, bytes: Data = Data("import fixture".utf8)) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    func context(_ url: URL) async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url)
        return FileOperationContext(directoryURL: url, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
}

private func captureImport(_ urls: [URL]) async throws -> [TransferEntry] {
    try await LocalFileTransferImporter().capture(urlStrings: urls.map(\.absoluteString))
}

private func actualFileReferenceString(_ url: URL) throws -> String {
    // The typed Swift fileReferenceURL() method returns URL, eagerly converting
    // the reference to a path. Invoke the same public Objective-C selector and
    // serialize its NSURL result before any Swift URL bridge occurs.
    let result = (url as NSURL).perform(NSSelectorFromString("fileReferenceURL"))?.takeUnretainedValue()
    let reference = try #require(result as? NSURL)
    #expect(reference.isFileReferenceURL())
    return try #require(reference.absoluteString)
}

private func expectImportUnsupported(_ urls: [URL]) async {
    await expectImportUnsupportedStrings(urls.map(\.absoluteString))
}

private func expectImportUnsupportedStrings(_ spellings: [String]) async {
    do {
        _ = try await LocalFileTransferImporter().capture(urlStrings: spellings)
        Issue.record("Expected rejection of the complete import payload")
    } catch FileOperationError.unsupported {} catch {
        Issue.record("Expected unsupported payload, received \(error)")
    }
}

/// NATIVE-P12 import safety; original AT-FILE-003/004 GUI acceptance is separate.
struct FileTransferImportTests {
    @Test
    func mixedParentsPreserveOrderIdentityUnicodeAndNodeKinds() async throws {
        let fixture = try TransferImportFixture()
        let first = try fixture.directory("First"), second = try fixture.directory("Second")
        let file = try fixture.file("café-文件.txt", in: first, bytes: Data([0, 1, 2, 255]))
        let directory = second.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = second.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
        let entries = try await captureImport([link, file, directory])
        #expect(entries.map(\.item.name) == ["broken-link", "café-文件.txt", "Empty"])
        #expect(entries.map(\.source.directoryURL.path) == [second.path, first.path, second.path])
        #expect(entries.allSatisfy { $0.item.identity != nil })
        #expect(entries[0].item.isSymbolicLink && !entries[0].item.isDirectory)
        #expect(entries[0].item.size == nil)
        #expect(entries[1].item.size == 4)
        #expect(entries[2].item.isDirectory && !entries[2].item.isSymbolicLink)
        #expect(entries[2].item.url.hasDirectoryPath)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("missing-target").path))
    }

    @Test
    func finalDirectoryHintNeverFollowsSymlinkAndLocalhostIsAccepted() async throws {
        let fixture = try TransferImportFixture()
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "absent-folder")
        var components = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let localhostURL = try #require(components.url)
        let captured = try await captureImport([localhostURL])
        let imported = try #require(captured.first)
        #expect(imported.item.isSymbolicLink)
        #expect(!imported.item.isDirectory)
        #expect(!imported.item.url.hasDirectoryPath)
        #expect(imported.item.name == "link")
        var value = stat()
        let result = imported.item.url.withUnsafeFileSystemRepresentation { lstat($0!, &value) }
        #expect(result == 0)
        #expect(imported.item.identity == LocalFileIdentity.fromStat(value))
    }

    @Test
    func distinctHardLinkNamesRemainSeparateEntries() async throws {
        let fixture = try TransferImportFixture()
        let first = try fixture.file("original")
        let second = fixture.root.appendingPathComponent("second-name")
        try FileManager.default.linkItem(at: first, to: second)
        let entries = try await captureImport([first, second])
        #expect(entries.count == 2)
        #expect(entries[0].item.id != entries[1].item.id)
        #expect(entries[0].item.identity == entries[1].item.identity)
    }

    @Test
    func parentAliasesCannotHideDuplicateOrOverlappingSelections() async throws {
        let fixture = try TransferImportFixture()
        let directory = try fixture.directory("Folder")
        let file = try fixture.file("child", in: directory)
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        await expectImportUnsupported([file, alias.appendingPathComponent("child")])
        await expectImportUnsupported([directory, alias.appendingPathComponent("child")])
        // A selected symlink entry is independent of its target, so importing
        // the link itself alongside that target's child is valid.
        let entries = try await captureImport([alias, file])
        #expect(entries.count == 2)
        #expect(entries[0].item.isSymbolicLink)
    }

    @Test
    func publicFileReferencesResolveCurrentPathsBeforeNoFollowCapture() async throws {
        let fixture = try TransferImportFixture()
        let file = try fixture.file("original", bytes: Data("reference bytes".utf8))
        let folder = try fixture.directory("Package.app")
        let reference = try actualFileReferenceString(file)
        let folderReference = try actualFileReferenceString(folder)
        let expectedIdentity = try LocalFileIdentity.read(at: file, ifLocal: true)
        let other = try fixture.directory("Other")
        let moved = other.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: file, to: moved)
        let entries = try await LocalFileTransferImporter().capture(urlStrings: [reference, folderReference])
        #expect(entries.map(\.item.name) == ["renamed", "Package.app"])
        #expect(entries[0].item.url.path == moved.path)
        #expect(entries[0].source.directoryURL.path == other.path)
        #expect(entries[0].item.identity == expectedIdentity)
        #expect(entries[1].item.url.hasDirectoryPath)
        #expect(!(entries[0].item.url as NSURL).isFileReferenceURL())
        #expect(try Data(contentsOf: moved) == Data("reference bytes".utf8))
        await expectImportUnsupportedStrings([reference, moved.absoluteString])
    }

    @Test
    func stalePublicFileReferenceRejectsWholeBatchWithClearFeedback() async throws {
        let fixture = try TransferImportFixture()
        let retained = try fixture.file("retained")
        let removed = try fixture.file("removed")
        let reference = try actualFileReferenceString(removed)
        try FileManager.default.removeItem(at: removed)
        do {
            _ = try await LocalFileTransferImporter().capture(urlStrings: [retained.absoluteString, reference])
            Issue.record("A deleted file reference returned an import batch")
        } catch FileOperationError.unsupported(let message) {
            #expect(message.contains("referenced file is unavailable"))
        }
        // All syntactic validation precedes even a stale-reference lookup.
        do {
            _ = try await LocalFileTransferImporter().capture(urlStrings: [reference, "https://example.com/file"])
            Issue.record("Invalid mixed input returned an import batch")
        } catch FileOperationError.unsupported(let message) {
            #expect(message.contains("canonical absolute local file URLs"))
        }
        #expect(try Data(contentsOf: retained) == Data("import fixture".utf8))
    }

    @Test
    func rejectsInvalidMixedPayloadBeforeAnyFilesystemRead() async throws {
        // The first URL does not exist. Syntactic rejection of the later URL must
        // win over a missing-parent error: validate the entire batch first.
        let absent = URL(fileURLWithPath: "/nonexistent-explorer-import-" + UUID().uuidString + "/file")
        let invalid = [
            URL(string: "https://example.com/file")!,
            URL(string: "file://remote-host/tmp/file")!,
            URL(string: "file:///tmp/file?query=1")!,
            URL(string: "file:///tmp/file#fragment")!,
            URL(string: "file:///tmp/file%00name")!,
            URL(string: "file:///tmp/file%00")!,
            URL(string: "file:///tmp/folder/../file")!,
            URL(string: "file:///tmp/folder/./file")!,
            URL(string: "file:///tmp/folder%2Ffile")!,
            URL(fileURLWithPath: "/")
        ]
        for url in invalid { await expectImportUnsupported([absent, url]) }
        await expectImportUnsupported([])
        await expectImportUnsupported([absent, absent])
        let folder = URL(fileURLWithPath: "/nonexistent-explorer-overlap", isDirectory: true)
        await expectImportUnsupported([folder.appendingPathComponent("child"), folder])
    }

    @Test
    func payloadLimitsRefuseBeforeMetadataReads() async {
        let absent = URL(fileURLWithPath: "/nonexistent-explorer-import/file")
        await expectImportUnsupported(Array(repeating: absent, count: 1_025))
        let urls = (0..<1_024).map {
            URL(fileURLWithPath: "/" + String(repeating: "x", count: 1_100) + "-\($0)")
        }
        await expectImportUnsupported(urls)
    }

    @Test
    func missingOrSpecialEntryFailsWholeCaptureWithoutMutations() async throws {
        let fixture = try TransferImportFixture()
        let file = try fixture.file("valid")
        let fifo = fixture.root.appendingPathComponent("pipe")
        #expect(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) } == 0)
        await expectImportUnsupported([file, fifo])
        do {
            _ = try await captureImport([file, fixture.root.appendingPathComponent("missing")])
            Issue.record("Expected whole-batch rejection for a missing entry")
        } catch FileOperationError.staleSource {}
        #expect(try Data(contentsOf: file) == Data("import fixture".utf8))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["valid", "pipe"])
    }

    @Test
    func cancelledCaptureReturnsNoEntries() async throws {
        let fixture = try TransferImportFixture()
        let file = try fixture.file("source")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await captureImport([file])
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled import returned entries")
        } catch is CancellationError {}
        #expect(try Data(contentsOf: file) == Data("import fixture".utf8))
    }

    @Test
    func capturedMixedParentsFeedExistingTransferServiceAndPreserveBytes() async throws {
        let fixture = try TransferImportFixture()
        let first = try fixture.directory("First"), second = try fixture.directory("Second")
        let destination = try fixture.directory("Destination")
        let aBytes = Data([0, 7, 255, 80]), bBytes = Data("Unicode 🌿 transfer".utf8)
        let a = try fixture.file("a.bin", in: first, bytes: aBytes)
        let b = try fixture.file("b.txt", in: second, bytes: bBytes)
        let entries = try await captureImport([b, a])
        let context = try await fixture.context(destination)
        for entry in entries {
            _ = try await LocalFileTransfers().transfer(entry.item, from: entry.source, to: context,
                name: entry.item.name, kind: .copy, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("a.bin")) == aBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.txt")) == bBytes)
        #expect(try Data(contentsOf: a) == aBytes)
        #expect(try Data(contentsOf: b) == bBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["a.bin", "b.txt"])
    }

    @Test
    func transferStillRejectsReplacedImportedEntryAndRetargetedParent() async throws {
        let fixture = try TransferImportFixture()
        let source = try fixture.directory("Source"), destination = try fixture.directory("Destination")
        let file = try fixture.file("source.txt", in: source)
        let imported = try #require(try await captureImport([file]).first)
        let context = try await fixture.context(destination)
        // Keep the original inode alive, making replacement unambiguous.
        try FileManager.default.moveItem(at: file, to: source.appendingPathComponent("retained-original"))
        _ = try fixture.file("source.txt", in: source, bytes: Data("replacement".utf8))
        do {
            _ = try await LocalFileTransfers().transfer(imported.item, from: imported.source, to: context,
                name: imported.item.name, kind: .copy, control: TransferControl(), onProgress: { _ in })
            Issue.record("Transfer accepted a replaced imported entry")
        } catch FileOperationError.staleSource {}

        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let aliasFile = alias.appendingPathComponent("source.txt")
        let routed = try #require(try await captureImport([aliasFile]).first)
        let other = try fixture.directory("Other")
        _ = try fixture.file("source.txt", in: other)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        do {
            _ = try await LocalFileTransfers().transfer(routed.item, from: routed.source, to: context,
                name: routed.item.name, kind: .move, control: TransferControl(), onProgress: { _ in })
            Issue.record("Transfer accepted a retargeted imported parent")
        } catch FileOperationError.staleParent {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: other.appendingPathComponent("source.txt")) == Data("import fixture".utf8))
    }
}
