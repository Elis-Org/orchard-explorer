import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class DropPreparationFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerDropPreparation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned drop preparation fixture cleanup failed: \(root.path): \(error)") }
    }
    func directory(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name)
        try Data(("drop fixture: " + name).utf8).write(to: url)
        return url
    }
    func entries(_ urls: [URL]) async throws -> [TransferEntry] {
        try await LocalFileTransferImporter().capture(urlStrings: urls.map(\.absoluteString))
    }
    func context(_ url: URL) async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url)
        return FileOperationContext(directoryURL: url, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
    func identity(_ url: URL) throws -> LocalFileIdentity {
        var path = url.path
        while path.count > 1 && path.last == "/" { path.removeLast() }
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { throw POSIXError(.EIO) }
        return try #require(LocalFileIdentity.fromStat(value))
    }
    /// Snapshot only this owned namespace, preserving symlink text without
    /// following it. This catches staging or other writes by a read-only API.
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        func visit(_ url: URL, relative: String) throws {
            var value = stat()
            guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else { throw POSIXError(.EIO) }
            switch value.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                result[relative + "/"] = Data()
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                    try visit(url.appendingPathComponent(name, isDirectory: false), relative: relative + "/" + name)
                }
            case mode_t(S_IFLNK):
                result[relative + "@"] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            case mode_t(S_IFREG):
                result[relative] = try Data(contentsOf: url)
            default:
                result[relative + "#"] = Data("special:\(value.st_mode)".utf8)
            }
        }
        try visit(root, relative: "")
        return result
    }
}

private func expectDropFailure(_ expected: FileOperationError, entries: [TransferEntry], destination: URL,
                               expectedDestination: LocalFileIdentity? = nil,
                               expectedEntry: LocalFileIdentity? = nil, kind: TransferKind = .copy) async {
    do {
        _ = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination,
            expectedDestinationIdentity: expectedDestination, expectedEntryIdentity: expectedEntry, kind: kind)
        Issue.record("Expected the entire drop to be refused")
    } catch let error as FileOperationError {
        #expect(error == expected)
    } catch { Issue.record("Unexpected drop preparation failure: \(error)") }
}

/// NATIVE-P13 read-only preflight. Pointer feedback, Escape and actual drops
/// remain separate UI checks; FR-DROP-003 Windows behavior stays UNVERIFIED.
struct FileDropPreparationTests {
    @Test
    func rootAliasMissingRowTargetParentReportsStaleParent() async throws {
        let fixture = try DropPreparationFixture()
        let source = try fixture.file("source.txt")
        let parent = try fixture.directory("RemovedParent")
        let target = try fixture.directory("Target", in: parent)
        let expectedEntry = try fixture.identity(target)
        let entries = try await fixture.entries([source])
        // Both removed directories belong to this existing synthetic fixture.
        try FileManager.default.removeItem(at: parent)
        let before = try fixture.snapshot()
        await expectDropFailure(.staleParent, entries: entries, destination: target,
            expectedEntry: expectedEntry, kind: .copy)
        #expect(try fixture.snapshot() == before)
    }

    @Test(arguments: [TransferKind.copy, TransferKind.move])
    func validMixedParentBatchCapturesDestinationWithoutWrites(_ kind: TransferKind) async throws {
        let fixture = try DropPreparationFixture()
        let first = try fixture.directory("First"), second = try fixture.directory("Second")
        let destination = try fixture.directory("Destination")
        let a = try fixture.file("a.txt", in: first), b = try fixture.file("文件.txt", in: second)
        let entries = try await fixture.entries([b, a])
        let context = try await fixture.context(destination)
        let before = try fixture.snapshot()
        let prepared = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination,
            expectedDestinationIdentity: context.directoryIdentity, kind: kind)
        #expect(prepared.kind == kind)
        #expect(prepared.entries.map(\.item.id) == entries.map(\.item.id))
        #expect(prepared.destination == context)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func targetLinkEntryAndResolvedDirectoryUseDifferentExpectedIdentities() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source"), target = try fixture.directory("Target")
        let alias = fixture.root.appendingPathComponent("FolderLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let entries = try await fixture.entries([file])
        let linkIdentity = try fixture.identity(alias)
        let context = try await fixture.context(target)
        #expect(linkIdentity != context.directoryIdentity)
        let before = try fixture.snapshot()
        let prepared = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: alias,
            expectedDestinationIdentity: context.directoryIdentity, expectedEntryIdentity: linkIdentity, kind: .copy)
        #expect(prepared.destination.directoryURL == alias)
        #expect(prepared.destination.directoryIdentity == context.directoryIdentity)
        await expectDropFailure(.staleParent, entries: entries, destination: alias,
            expectedDestination: linkIdentity, expectedEntry: linkIdentity)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func ordinaryFolderRowIdentityIsCheckedBeforePreparing() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source"), target = try fixture.directory("Target")
        let entries = try await fixture.entries([file])
        let identity = try fixture.identity(target)
        let before = try fixture.snapshot()
        let prepared = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: target,
            expectedEntryIdentity: identity, kind: .move)
        #expect(prepared.destination.directoryIdentity == identity)
        #expect(try fixture.snapshot() == before)
    }

    @Test(arguments: [TransferKind.copy, TransferKind.move])
    func rejectsSelfDescendantAndAliasedDescendantWithoutWrites(_ kind: TransferKind) async throws {
        let fixture = try DropPreparationFixture()
        let folder = try fixture.directory("Source"), child = try fixture.directory("Child", in: folder)
        _ = try fixture.file("retained", in: folder)
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let sourceAlias = fixture.root.appendingPathComponent("SourceAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: fixture.root)
        let ordinary = try await fixture.entries([folder])
        let aliased = try await fixture.entries([sourceAlias.appendingPathComponent("Source", isDirectory: true)])
        let before = try fixture.snapshot()
        for entries in [ordinary, aliased] {
            for destination in [folder, child, alias] {
                do {
                    _ = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination, kind: kind)
                    Issue.record("A self/descendant drop was prepared")
                } catch FileOperationError.unsupported(let message) {
                    #expect(message.contains("itself or its descendants"))
                }
            }
        }
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func selectedDirectorySymlinkRemainsAnEntryWhenDroppedInsideItsTarget() async throws {
        let fixture = try DropPreparationFixture()
        let target = try fixture.directory("Target")
        let link = fixture.root.appendingPathComponent("selected-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let entries = try await fixture.entries([link])
        #expect(entries[0].item.isSymbolicLink)
        let before = try fixture.snapshot()
        let prepared = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: target, kind: .copy)
        #expect(prepared.entries[0].item.identity == entries[0].item.identity)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func staleSourceEntryInMixedBatchRejectsEverythingWithoutWrites() async throws {
        let fixture = try DropPreparationFixture()
        let destination = try fixture.directory("Destination")
        let first = try fixture.file("first"), second = try fixture.file("second")
        let entries = try await fixture.entries([first, second])
        try FileManager.default.moveItem(at: second, to: fixture.root.appendingPathComponent("retained-original"))
        _ = try fixture.file("second")
        let before = try fixture.snapshot()
        await expectDropFailure(.staleSource, entries: entries, destination: destination)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func unsupportedCapturedNodeIsRefusedWithoutOpeningItsContents() async throws {
        let fixture = try DropPreparationFixture()
        let destination = try fixture.directory("Destination")
        let fifo = fixture.root.appendingPathComponent("pipe")
        let made = fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) }
        #expect(made == 0)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root)
        let item = try #require(snapshot.items.first { $0.name == "pipe" })
        let identity = try #require(snapshot.directoryIdentity)
        let entry = TransferEntry(source: FileOperationContext(directoryURL: fixture.root, directoryIdentity: identity), item: item)
        let before = try fixture.snapshot()
        do {
            _ = try await LocalFileDropPreparer().prepare(entries: [entry], destinationURL: destination, kind: .copy)
            Issue.record("A special source node was prepared")
        } catch FileOperationError.unsupported(let message) {
            #expect(message.contains("supported local files"))
        }
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func retargetedSourceParentRefusesItsPreviouslyCapturedEntries() async throws {
        let fixture = try DropPreparationFixture()
        let original = try fixture.directory("Original"), replacement = try fixture.directory("Replacement")
        let destination = try fixture.directory("Destination")
        _ = try fixture.file("file", in: original)
        _ = try fixture.file("file", in: replacement)
        let alias = fixture.root.appendingPathComponent("SourceLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let entries = try await fixture.entries([alias.appendingPathComponent("file")])
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let before = try fixture.snapshot()
        await expectDropFailure(.staleParent, entries: entries, destination: destination)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func changedTargetEntryAndChangedTargetDirectoryAreRefused() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source")
        let original = try fixture.directory("Original"), replacement = try fixture.directory("Replacement")
        let alias = fixture.root.appendingPathComponent("TargetLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let entries = try await fixture.entries([file])
        let expectedEntry = try fixture.identity(alias)
        let originalContext = try await fixture.context(alias)
        // Keep the original symlink alive so its replacement cannot reuse its inode.
        try FileManager.default.moveItem(at: alias, to: fixture.root.appendingPathComponent("RetainedLink"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let before = try fixture.snapshot()
        await expectDropFailure(.staleParent, entries: entries, destination: alias, expectedEntry: expectedEntry)
        await expectDropFailure(.staleParent, entries: entries, destination: alias,
            expectedDestination: originalContext.directoryIdentity)
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func sameFolderMoveIsRefusedByIdentityWhileCopyStillPrepares() async throws {
        let fixture = try DropPreparationFixture()
        let source = try fixture.directory("Source")
        let file = try fixture.file("source.txt", in: source)
        let alias = fixture.root.appendingPathComponent("SourceAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let entries = try await fixture.entries([file])
        let before = try fixture.snapshot()
        for destination in [source, alias] {
            await expectDropFailure(.unsupported("Items cannot be moved into their current folder."),
                entries: entries, destination: destination, kind: .move)
            let copy = try await LocalFileDropPreparer().prepare(entries: entries,
                destinationURL: destination, kind: .copy)
            #expect(copy.kind == .copy)
            #expect(copy.destination.directoryIdentity == entries[0].source.directoryIdentity)
        }
        #expect(try fixture.snapshot() == before)
    }

    /// NATIVE-P15: cross-volume moves are now supported (MAC-066), but an entry
    /// whose recorded device does not match the actual item is still refused
    /// read-only, before any writer can start.
    @Test
    func mismatchedMoveDeviceIdentityIsRefusedBeforeAnyWriterCanStart() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source"), destination = try fixture.directory("Destination")
        let original = try #require(try await fixture.entries([file]).first)
        let identity = try #require(original.item.identity)
        let foreign = LocalFileIdentity(device: identity.device ^ 1, inode: identity.inode,
            birthSeconds: identity.birthSeconds, birthNanoseconds: identity.birthNanoseconds)
        let item = FileItem(url: original.item.url, name: original.item.name, isDirectory: false,
            isSymbolicLink: false, size: original.item.size, modifiedAt: original.item.modifiedAt,
            kind: original.item.kind, identity: foreign)
        let entries = [original, TransferEntry(source: original.source, item: item)]
        let before = try fixture.snapshot()
        do {
            _ = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination, kind: .move)
            Issue.record("A mismatched move device was accepted")
        } catch FileOperationError.staleSource {
        }
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func ancestryDepthCapIsAnExplicitReadOnlyRefusal() async throws {
        let fixture = try DropPreparationFixture()
        let source = try fixture.directory("Source"), destination = try fixture.directory("Destination")
        let entries = try await fixture.entries([source])
        let before = try fixture.snapshot()
        do {
            _ = try await LocalFileDropPreparer(maximumAncestryDepth: 1).prepare(entries: entries,
                destinationURL: destination, kind: .copy)
            Issue.record("Expected bounded ancestry refusal")
        } catch FileOperationError.unsupported(let message) {
            #expect(message.contains("verification depth"))
        }
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func cancelledPreparationReturnsNoPreparedDropAndWritesNothing() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source"), destination = try fixture.directory("Destination")
        let entries = try await fixture.entries([file])
        let before = try fixture.snapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination, kind: .copy)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled preparation returned a drop")
        } catch is CancellationError {}
        #expect(try fixture.snapshot() == before)
    }

    @Test
    func invalidDestinationOrNonFolderTargetCannotPrepareADrop() async throws {
        let fixture = try DropPreparationFixture()
        let file = try fixture.file("source"), targetFile = try fixture.file("target-file")
        let entries = try await fixture.entries([file])
        let before = try fixture.snapshot()
        let invalid = [URL(string: "https://example.com/folder")!, URL(string: "file://remote-host/tmp/folder")!,
            URL(string: "file:///tmp/folder?query=1")!, URL(string: "file:///tmp/folder%00")!,
            URL(string: "file:///tmp/../folder")!]
        for destination in invalid {
            do {
                _ = try await LocalFileDropPreparer().prepare(entries: entries, destinationURL: destination, kind: .copy)
                Issue.record("An invalid destination was accepted")
            } catch FileOperationError.unsupported {}
        }
        await expectDropFailure(.staleParent, entries: entries, destination: targetFile)
        #expect(try fixture.snapshot() == before)
    }
}
