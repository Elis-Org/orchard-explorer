import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class OperationFixture {
    let parent: URL
    let directory: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerOperations-" + UUID().uuidString, isDirectory: true)
        directory = parent.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: parent) }
    func snapshot() async throws -> DirectorySnapshot { try await LocalDirectoryLoader().snapshot(of: directory) }
    func context() async throws -> FileOperationContext {
        let snapshot = try await snapshot()
        return FileOperationContext(directoryURL: directory, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
    func item(_ name: String) async throws -> FileItem {
        let snapshot = try await snapshot()
        return try #require(snapshot.items.first { $0.name == name })
    }
}

/// Owns only one empty UUID child of /tmp (under either of two exact names).
/// The system alias is metadata-only; cleanup never recursively removes a path.
private final class RootAliasWriteFixture {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: false)
    let firstName = "Maxplorer-root-write-" + UUID().uuidString
    let renamedName = "Maxplorer-root-renamed-" + UUID().uuidString
    let descriptor: Int32
    let parentIdentity: LocalFileIdentity
    private(set) var ownedIdentity: LocalFileIdentity?

    init() throws {
        var link = stat()
        let linkResult = lstat("/tmp", &link)
        try #require(linkResult == 0 && link.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        let physical = try FileSystemPath.resolvingExisting(directory)
        try #require(physical.path == "/private/tmp", "This regression requires the native root alias")
        let opened = physical.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var value = stat()
        guard fstat(opened, &value) == 0, let identity = LocalFileIdentity.fromStat(value),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            Darwin.close(opened)
            throw POSIXError(.EIO)
        }
        descriptor = opened
        parentIdentity = identity
        for name in [firstName, renamedName] {
            var entry = stat()
            let result = name.withCString { fstatat(opened, $0, &entry, AT_SYMLINK_NOFOLLOW) }
            try #require(result == -1 && errno == ENOENT, "The unique test name must not exist")
        }
    }

    deinit {
        for name in [firstName, renamedName] {
            var value = stat()
            let result = name.withCString { fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
            if result != 0 {
                if errno != ENOENT { Issue.record("Owned root-alias cleanup could not inspect its UUID child") }
                continue
            }
            guard let ownedIdentity, LocalFileIdentity.fromStat(value) == ownedIdentity,
                  value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                Issue.record("Root-alias cleanup preserved an unverified UUID entry")
                continue
            }
            let removed = name.withCString { unlinkat(descriptor, $0, AT_REMOVEDIR) }
            if removed != 0 { Issue.record("Owned empty root-alias child could not be removed") }
        }
        Darwin.close(descriptor)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

    func context() async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: directory)
        try #require(snapshot.directoryIdentity == parentIdentity)
        return FileOperationContext(directoryURL: directory, directoryIdentity: parentIdentity)
    }

    @discardableResult
    func remember(_ name: String) throws -> LocalFileIdentity {
        var value = stat()
        let result = name.withCString { fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
        try #require(result == 0)
        try #require(value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        let identity = try #require(LocalFileIdentity.fromStat(value))
        try #require(ownedIdentity == nil || ownedIdentity == identity)
        ownedIdentity = identity
        return identity
    }

    func seed() throws {
        let result = firstName.withCString { mkdirat(descriptor, $0, mode_t(0o700)) }
        try #require(result == 0)
        try remember(firstName)
    }

    func item() async throws -> FileItem {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: directory)
        return try #require(snapshot.items.first { $0.name == firstName })
    }

    func assertEmpty(_ name: String) throws {
        let child = name.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        try #require(child >= 0)
        defer { Darwin.close(child) }
        var names = 0
        try DescriptorIO.forEachDirectoryEntry(in: child) { _ in names += 1 }
        #expect(names == 0)
    }
}

/// FR-FILE-001/018 / EV-0267, EV-0235 / AT-FILE-001/018 filesystem subsets.
/// Collision refusal, native naming, cancellation, and stale identity are separate
/// macOS safety contracts; these tests do not assert unobserved Windows UI behavior.
struct FileOperationTests {
    @Test
    func rootAliasCreateUsesLoaderIdentityAndReturnsLexicalChild() async throws {
        let fixture = try RootAliasWriteFixture()
        let context = try await fixture.context()
        let result = try await LocalFileOperations().createFolder(named: fixture.firstName, in: context)
        let identity = try fixture.remember(fixture.firstName)
        #expect(result.url.path == fixture.url(fixture.firstName).path)
        #expect(result.identity == identity && result.warning == nil && result.accessFailure == nil)
        try fixture.assertEmpty(fixture.firstName)
    }

    @Test
    func rootAliasRenameUsesLoaderIdentityAndReturnsLexicalChild() async throws {
        let fixture = try RootAliasWriteFixture()
        try fixture.seed()
        let item = try await fixture.item(), context = try await fixture.context()
        let result = try await LocalFileOperations().rename(item, to: fixture.renamedName, in: context)
        let identity = try fixture.remember(fixture.renamedName)
        #expect(result.url.path == fixture.url(fixture.renamedName).path)
        #expect(result.identity == item.identity && result.identity == identity)
        #expect(result.warning == nil && result.accessFailure == nil)
        var old = stat()
        let oldResult = fixture.firstName.withCString { fstatat(fixture.descriptor, $0, &old, AT_SYMLINK_NOFOLLOW) }
        #expect(oldResult == -1 && errno == ENOENT)
        try fixture.assertEmpty(fixture.renamedName)
    }

    @Test
    func rootAliasCopyDropPreparesTargetWithoutWriting() async throws {
        let fixture = try RootAliasWriteFixture()
        try fixture.seed()
        let item = try await fixture.item(), context = try await fixture.context()
        let prepared = try await LocalFileDropPreparer().prepare(
            entries: [TransferEntry(source: context, item: item)], destinationURL: fixture.directory,
            expectedDestinationIdentity: context.directoryIdentity, kind: .copy)
        #expect(prepared.destination == context && prepared.kind == .copy)
        #expect(prepared.entries.count == 1 && prepared.entries.first?.item.identity == fixture.ownedIdentity)
        try fixture.assertEmpty(fixture.firstName)
    }

    @Test
    func rootAliasRowTargetParentIsResolvedBeforeNoFollowEntryCheck() async throws {
        let fixture = try RootAliasWriteFixture(), source = try OperationFixture()
        try fixture.seed()
        try Data("owned drop source".utf8).write(to: source.directory.appendingPathComponent("source.txt"))
        let entry = TransferEntry(source: try await source.context(), item: try await source.item("source.txt"))
        let identity = try #require(fixture.ownedIdentity)
        let prepared = try await LocalFileDropPreparer().prepare(entries: [entry],
            destinationURL: fixture.url(fixture.firstName), expectedDestinationIdentity: identity,
            expectedEntryIdentity: identity, kind: .copy)
        #expect(prepared.destination.directoryURL.path == fixture.url(fixture.firstName).path)
        #expect(prepared.destination.directoryIdentity == identity && prepared.kind == .copy)
        #expect(try Data(contentsOf: entry.item.url) == Data("owned drop source".utf8))
        try fixture.assertEmpty(fixture.firstName)
    }

    @Test
    func rootAliasExternalImportCapturesOwnedChildWithoutFollowingEntry() async throws {
        let fixture = try RootAliasWriteFixture()
        try fixture.seed()
        let entries = try await LocalFileTransferImporter().capture(urlStrings: [fixture.url(fixture.firstName).absoluteString])
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && entry.source.directoryURL.path == "/tmp")
        #expect(entry.source.directoryIdentity == fixture.parentIdentity && entry.item.identity == fixture.ownedIdentity)
        #expect(entry.item.url.path == fixture.url(fixture.firstName).path && entry.item.isDirectory && !entry.item.isSymbolicLink)
        try fixture.assertEmpty(fixture.firstName)
    }

    @Test
    func rootAliasHeldRouteRefusesRetargetedOwnedLink() async throws {
        let fixture = try OperationFixture()
        let alternate = fixture.parent.appendingPathComponent("Alternate", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
        let route = fixture.parent.appendingPathComponent("Route", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: fixture.directory)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: route)
        let context = FileOperationContext(directoryURL: route, directoryIdentity: try #require(snapshot.directoryIdentity))
        try LocalFileOperations.withParent(context) { _, resolved in
            try FileManager.default.moveItem(at: route, to: fixture.parent.appendingPathComponent("RetainedRoute"))
            try FileManager.default.createSymbolicLink(at: route, withDestinationURL: alternate)
            do {
                try LocalFileOperations.revalidateRoute(context, resolved: resolved)
                Issue.record("Retargeted owned route retained write authority")
            } catch FileOperationError.staleParent {} catch { Issue.record("Wrong retarget refusal: \(error)") }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: alternate.path).isEmpty)
    }

    @Test
    func testCreateMakesOneEmptyImmediateChildWithSampledIdentity() async throws {
        let fixture = try OperationFixture()
        let context = try await fixture.context()
        let result = try await LocalFileOperations().createFolder(named: "New folder", in: context)
        #expect(result.url.path == fixture.directory.appendingPathComponent("New folder").path)
        #expect(result.identity != nil)
        #expect(result.warning == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.url.path).isEmpty)
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.items.map(\.name) == ["New folder"])
        #expect(snapshot.items.first?.isDirectory == true)
        #expect(snapshot.items.first?.identity == result.identity)
    }

    @Test
    func testRenamePreservesFileBytesHashAndIdentity() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("before.txt")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let originalHash = SHA256.hash(data: bytes)
        let item = try await fixture.item("before.txt")
        let context = try await fixture.context()
        let result = try await LocalFileOperations().rename(item, to: "after.txt", in: context)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(SHA256.hash(data: try Data(contentsOf: result.url)) == originalHash)
        #expect(result.identity == item.identity)
        #expect(result.warning == nil)
    }

    @Test
    func testFolderRenamePreservesNestedContents() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("Before/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("nested content".utf8)
        try bytes.write(to: source.appendingPathComponent("child.txt"))
        let item = try await fixture.item("Before")
        let result = try await LocalFileOperations().rename(item, to: "After", in: fixture.context())
        #expect(try Data(contentsOf: result.url.appendingPathComponent("Nested/child.txt")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Before").path))
    }

    @Test
    func testSymlinkRenameMovesEntryWithoutChangingTarget() async throws {
        let fixture = try OperationFixture()
        let target = fixture.parent.appendingPathComponent("target.txt")
        let bytes = Data("target survives".utf8)
        try bytes.write(to: target)
        let link = fixture.directory.appendingPathComponent("before-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let item = try await fixture.item("before-link")
        #expect(item.isSymbolicLink)
        let result = try await LocalFileOperations().rename(item, to: "after-link", in: fixture.context())
        #expect(result.identity == item.identity)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.url.path) == target.path)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test
    func testDirectorySymlinkResultMatchesEnumeratedLexicalURL() async throws {
        let fixture = try OperationFixture()
        let target = fixture.parent.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("target child".utf8).write(to: target.appendingPathComponent("child.txt"))
        let link = fixture.directory.appendingPathComponent("before-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let item = try await fixture.item("before-link")
        #expect(item.isDirectory && item.isSymbolicLink)
        let result = try await LocalFileOperations().rename(item, to: "after-link", in: fixture.context())
        let refreshed = try await fixture.item("after-link")
        #expect(result.url == refreshed.url)
        #expect(result.identity == refreshed.identity)
        #expect(try Data(contentsOf: target.appendingPathComponent("child.txt")) == Data("target child".utf8))
    }

    @Test
    func testCreateCollisionsPreserveFilesFoldersAndDanglingLinks() async throws {
        let fixture = try OperationFixture()
        try installCollisions(in: fixture)
        let context = try await fixture.context()
        for name in ["existing.txt", "Existing folder", "dangling"] {
            await expectError(.collision(name)) { try await LocalFileOperations().createFolder(named: name, in: context) }
        }
        try assertCollisionsUnchanged(in: fixture)
    }

    @Test
    func testRenameCollisionsNeverOverwriteAnyDestinationKind() async throws {
        let fixture = try OperationFixture()
        try installCollisions(in: fixture)
        let source = fixture.directory.appendingPathComponent("source.txt")
        let bytes = Data("source stays".utf8)
        try bytes.write(to: source)
        let item = try await fixture.item("source.txt")
        let context = try await fixture.context()
        for name in ["existing.txt", "Existing folder", "dangling"] {
            await expectError(.collision(name)) { try await LocalFileOperations().rename(item, to: name, in: context) }
        }
        try assertCollisionsUnchanged(in: fixture)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test
    func testStaleParentReplacementRefusesCreateAndRename() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("source.txt")
        try Data("old root".utf8).write(to: source)
        let item = try await fixture.item("source.txt")
        let context = try await fixture.context()
        let preserved = fixture.parent.appendingPathComponent("Preserved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.directory, to: preserved)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
        try Data("replacement root".utf8).write(to: source)
        await expectError(.staleParent) { try await LocalFileOperations().createFolder(named: "must-not-exist", in: context) }
        await expectError(.staleParent) { try await LocalFileOperations().rename(item, to: "must-not-exist", in: context) }
        #expect(try Data(contentsOf: source) == Data("replacement root".utf8))
        #expect(try Data(contentsOf: preserved.appendingPathComponent("source.txt")) == Data("old root".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.txt"])
    }

    @Test
    func testStaleSourceReplacementRefusesRename() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let item = try await fixture.item("source.txt")
        let context = try await fixture.context()
        let preserved = fixture.directory.appendingPathComponent("preserved.txt")
        try FileManager.default.moveItem(at: source, to: preserved)
        try Data("replacement".utf8).write(to: source)
        await expectError(.staleSource) { try await LocalFileOperations().rename(item, to: "renamed.txt", in: context) }
        #expect(try Data(contentsOf: source) == Data("replacement".utf8))
        #expect(try Data(contentsOf: preserved) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("renamed.txt").path))
    }

    @Test
    func testRetargetedParentSymlinkDoesNotWriteIntoEitherRoot() async throws {
        let fixture = try OperationFixture()
        let alternate = fixture.parent.appendingPathComponent("Alternate", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
        let route = fixture.parent.appendingPathComponent("Route", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: fixture.directory)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: route)
        let context = FileOperationContext(directoryURL: route, directoryIdentity: try #require(snapshot.directoryIdentity))
        try FileManager.default.removeItem(at: route)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: alternate)
        await expectError(.staleParent) { try await LocalFileOperations().createFolder(named: "blocked", in: context) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: alternate.path).isEmpty)
    }

    @Test
    func testInvalidNamesCannotEscapeAndUnsupportedContextsCannotWrite() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("source.txt")
        try Data("keep".utf8).write(to: source)
        let item = try await fixture.item("source.txt")
        let context = try await fixture.context()
        for name in ["", ".", "..", "nested/escape", "../escape", "nul\0name"] {
            do {
                _ = try await LocalFileOperations().createFolder(named: name, in: context)
                Issue.record("Invalid create name was accepted")
            } catch FileOperationError.invalidName {} catch { Issue.record("Wrong invalid-name error: \(error)") }
            do {
                _ = try await LocalFileOperations().rename(item, to: name, in: context)
                Issue.record("Invalid rename name was accepted")
            } catch FileOperationError.invalidName {} catch { Issue.record("Wrong invalid-name error: \(error)") }
        }
        let remote = FileOperationContext(directoryURL: URL(string: "file://server/tmp")!, directoryIdentity: context.directoryIdentity)
        do {
            _ = try await LocalFileOperations().createFolder(named: "forbidden", in: remote)
            Issue.record("A remote-host file URL was accepted")
        } catch FileOperationError.unsupported {} catch { Issue.record("Wrong unsupported-context error: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["source.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path) == ["Visible"])
        #expect(try Data(contentsOf: source) == Data("keep".utf8))
    }

    @Test
    func testUnknownSourceIdentityIsRefusedAndSameByteNameIsValidatedNoOp() async throws {
        let fixture = try OperationFixture()
        let file = fixture.directory.appendingPathComponent("source.txt")
        try Data("same name".utf8).write(to: file)
        let item = try await fixture.item("source.txt")
        let context = try await fixture.context()
        let unknown = FileItem(url: item.url, name: item.name, isDirectory: false, isSymbolicLink: false,
                               size: item.size, modifiedAt: item.modifiedAt, kind: item.kind)
        do {
            _ = try await LocalFileOperations().rename(unknown, to: "different.txt", in: context)
            Issue.record("Unknown source identity was accepted")
        } catch FileOperationError.unsupported {} catch { Issue.record("Wrong missing-identity error: \(error)") }
        let result = try await LocalFileOperations().rename(item, to: item.name, in: context)
        #expect(result.identity == item.identity)
        #expect(result.url.path == item.url.path)
        #expect(result.warning == nil)
        #expect(try Data(contentsOf: file) == Data("same name".utf8))
    }

    @Test
    func testUnicodeAndQuestionMarkFollowNativeNamingRules() async throws {
        let fixture = try OperationFixture()
        let context = try await fixture.context()
        let folderName = "Café 東京 ?"
        let folder = try await LocalFileOperations().createFolder(named: folderName, in: context)
        // Foundation/filesystem presentation may normalize composed Unicode. Verify
        // canonical equivalence and the actual enumerated URL used for selection.
        let createdEntry = try await fixture.item(folderName)
        #expect(folder.url.lastPathComponent == folderName)
        #expect(createdEntry.name == folderName)
        #expect(createdEntry.name.contains("?"))
        #expect(createdEntry.name == createdEntry.url.lastPathComponent)
        #expect(folder.url == createdEntry.url)
        #expect(folder.identity == createdEntry.identity)
        let file = fixture.directory.appendingPathComponent("source.txt")
        try Data("Unicode bytes".utf8).write(to: file)
        let item = try await fixture.item("source.txt")
        let newName = "Cafe\u{301} 東京 ?.txt"
        let renamed = try await LocalFileOperations().rename(item, to: newName, in: context)
        let renamedEntry = try await fixture.item(newName)
        #expect(renamed.url.lastPathComponent == newName)
        #expect(renamedEntry.name == newName)
        #expect(renamedEntry.name.contains("?"))
        #expect(renamedEntry.name == renamedEntry.url.lastPathComponent)
        #expect(renamed.url == renamedEntry.url)
        #expect(renamed.identity == renamedEntry.identity)
        #expect(try Data(contentsOf: renamed.url) == Data("Unicode bytes".utf8))
    }

    @Test
    func testRenameFreshComposedUnicodeFolderInsideComposedParent() async throws {
        let fixture = try OperationFixture()
        let parent = fixture.directory.appendingPathComponent("Café Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let before = try await LocalDirectoryLoader().snapshot(of: parent)
        let context = FileOperationContext(directoryURL: parent, directoryIdentity: try #require(before.directoryIdentity))
        let created = try await LocalFileOperations().createFolder(named: "Café Source", in: context)
        let payload = Data("nested Unicode folder contents".utf8)
        try payload.write(to: created.url.appendingPathComponent("nested.txt"))
        let listing = try await LocalDirectoryLoader().snapshot(of: parent)
        let source = try #require(listing.items.first { $0.name == "Café Source" })

        // The enumerated name and Foundation's normalized URL can have different
        // Unicode bytes while naming the same entry. No-follow source identity
        // must still match the captured entry before the operation can commit.
        let result = try await LocalFileOperations().rename(source, to: "Café Renamed", in: context)
        let refreshed = try await LocalDirectoryLoader().snapshot(of: parent)
        let renamed = try #require(refreshed.items.first { $0.name == "Café Renamed" })
        #expect(result.url == renamed.url)
        #expect(result.identity == source.identity)
        #expect(result.identity == renamed.identity)
        #expect(try Data(contentsOf: renamed.url.appendingPathComponent("nested.txt")) == payload)
        #expect(!FileManager.default.fileExists(atPath: created.url.path))
    }

    @Test
    func testCancellationBeforeOperationWritesNothing() async throws {
        let fixture = try OperationFixture()
        let context = try await fixture.context()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalFileOperations().createFolder(named: "cancelled", in: context)
        }
        do { _ = try await task.value; Issue.record("A pre-cancelled operation succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test
    func testCancellationAfterCommitStillReportsSuccess() async throws {
        let fixture = try OperationFixture()
        let context = try await fixture.context()
        let operations = LocalFileOperations(afterCommit: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let result = try await operations.createFolder(named: "committed", in: context)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(result.identity != nil)
        #expect(result.warning == nil)
    }

    @Test
    func testPostcommitVerificationFailureReturnsWarningAndKeepsRenamedBytes() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("before.txt")
        let bytes = Data("committed bytes must survive".utf8)
        try bytes.write(to: source)
        let item = try await fixture.item("before.txt")
        let context = try await fixture.context()
        let originalRoot = fixture.directory
        let relocated = fixture.parent.appendingPathComponent("Relocated", isDirectory: true)
        let operations = LocalFileOperations(afterCommit: { _ in
            // Simulates an external root move after commit, not an operation rollback.
            try? FileManager.default.moveItem(at: originalRoot, to: relocated)
        })
        let result = try await operations.rename(item, to: "after.txt", in: context)
        #expect(result.identity == nil)
        #expect(result.warning != nil)
        #expect(try Data(contentsOf: relocated.appendingPathComponent("after.txt")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: relocated.appendingPathComponent("before.txt").path))
    }

    @Test
    func testConcurrentCreateHasExactlyOneWinner() async throws {
        let fixture = try OperationFixture()
        let context = try await fixture.context()
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try await LocalFileOperations().createFolder(named: "winner", in: context); return true }
                    catch { return false }
                }
            }
            var successes = 0
            for await result in group where result { successes += 1 }
            return successes
        }
        #expect(successes == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["winner"])
    }

    @Test
    func testConcurrentRenamesNeverOverwriteWinningDestination() async throws {
        let fixture = try OperationFixture()
        for name in ["first.txt", "second.txt"] { try Data(name.utf8).write(to: fixture.directory.appendingPathComponent(name)) }
        let snapshot = try await fixture.snapshot()
        let context = FileOperationContext(directoryURL: fixture.directory, directoryIdentity: try #require(snapshot.directoryIdentity))
        let winners = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for item in snapshot.items {
                group.addTask {
                    do { _ = try await LocalFileOperations().rename(item, to: "winner.txt", in: context); return item.name }
                    catch { return nil }
                }
            }
            var winners: [String] = []
            for await result in group { if let result { winners.append(result) } }
            return winners
        }
        let winner = try #require(winners.first)
        #expect(winners.count == 1)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("winner.txt")) == Data(winner.utf8))
        let loser = winner == "first.txt" ? "second.txt" : "first.txt"
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(loser)) == Data(loser.utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(winner).path))
    }

    @Test
    func testCaseOnlyRenameRecordsNativeExclusiveOutcomeWithoutFallback() async throws {
        let fixture = try OperationFixture()
        let source = fixture.directory.appendingPathComponent("Case.txt")
        let bytes = Data("case content".utf8)
        try bytes.write(to: source)
        let item = try await fixture.item("Case.txt")
        let context = try await fixture.context()
        do {
            let result = try await LocalFileOperations().rename(item, to: "case.txt", in: context)
            #expect(try Data(contentsOf: result.url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.utf8.elementsEqual("case.txt".utf8) })
            print("Case-only exclusive rename: native success")
        } catch FileOperationError.collision {
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.utf8.elementsEqual("Case.txt".utf8) })
            print("Case-only exclusive rename: native collision refusal; no fallback")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 1)
    }

    private func expectError(_ expected: FileOperationError,
                             operation: () async throws -> FileOperationResult) async {
        do { _ = try await operation(); Issue.record("Expected \(expected), but the operation succeeded") }
        catch let error as FileOperationError { #expect(error == expected) }
        catch { Issue.record("Expected \(expected), got \(error)") }
    }
    private func installCollisions(in fixture: OperationFixture) throws {
        try Data("existing bytes".utf8).write(to: fixture.directory.appendingPathComponent("existing.txt"))
        let folder = fixture.directory.appendingPathComponent("Existing folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested stays".utf8).write(to: folder.appendingPathComponent("child.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("dangling"),
                                                 withDestinationURL: fixture.parent.appendingPathComponent("missing"))
    }
    private func assertCollisionsUnchanged(in fixture: OperationFixture) throws {
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("existing.txt")) == Data("existing bytes".utf8))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("Existing folder/child.txt")) == Data("nested stays".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.directory.appendingPathComponent("dangling").path)
                == fixture.parent.appendingPathComponent("missing").path)
    }
}
