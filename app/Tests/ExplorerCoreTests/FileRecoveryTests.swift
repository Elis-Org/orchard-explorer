import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// The fixture records only URLs returned by its own native Trash calls. Cleanup
/// exclusively moves those exact, identity-checked entries back under its root;
/// it never enumerates Trash or removes anything at a Trash path.
private final class RecoveryFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    private let lock = NSLock()
    private var ownedTrash: [(URL, LocalFileIdentity)] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerRecovery-" + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    deinit {
        var safeToRemoveFixture = true
        let recovery = root.appendingPathComponent("Recovered", isDirectory: true)
        for (url, expected) in ownedTrash {
            do {
                let actual: LocalFileIdentity?
                do { actual = try LocalFileIdentity.read(at: url, ifLocal: true) }
                catch let error as POSIXError where error.code == .ENOENT { continue }
                guard actual == expected else {
                    Issue.record("Owned Trash receipt changed during test cleanup; left untouched: \(url.path)")
                    safeToRemoveFixture = false
                    continue
                }
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                let destination = recovery.appendingPathComponent(UUID().uuidString)
                let result = url.withUnsafeFileSystemRepresentation { old in
                    destination.withUnsafeFileSystemRepresentation { new in
                        renameatx_np(AT_FDCWD, old!, AT_FDCWD, new!, UInt32(RENAME_EXCL))
                    }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch {
                safeToRemoveFixture = false
                Issue.record("Could not restore exact owned Trash test item \(url.path): \(error)")
            }
        }
        if safeToRemoveFixture { try? FileManager.default.removeItem(at: root) }
    }

    func nativeTrash(_ url: URL) throws -> URL? {
        let resolvedRoot = try FileSystemPath.resolvingExisting(root)
        guard url.path.hasPrefix(resolvedRoot.path + "/") else {
            throw FileOperationError.unsupported("Test Trash request escaped its owned fixture.")
        }
        var result: NSURL?
        try FileManager().trashItem(at: url, resultingItemURL: &result)
        guard let output = result as URL?, let identity = try LocalFileIdentity.read(at: output, ifLocal: true) else {
            throw FileOperationError.unsupported("Native test returned no identity-checked cleanup receipt.")
        }
        lock.lock(); ownedTrash.append((output, identity)); lock.unlock()
        return output
    }

    var service: LocalFileRecovery { LocalFileRecovery(nativeTrash: { try self.nativeTrash($0) }) }
    func context(_ url: URL? = nil) async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url ?? source)
        return FileOperationContext(directoryURL: url ?? source, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
    func item(_ name: String, at parent: URL? = nil) async throws -> FileItem {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: parent ?? source)
        return try #require(snapshot.items.first { $0.name == name })
    }
    @discardableResult func write(_ name: String = "item.txt", bytes: Data = Data("owned synthetic item".utf8)) throws -> URL {
        let url = source.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    func trash(_ name: String = "item.txt") async throws -> TrashReceipt {
        let result = try await service.trash(item(name), in: context())
        #expect(result.warning == nil)
        return try #require(result.receipt)
    }
}

/// FR-FILE-005/007 / EV-0448, EV-0453 / AT-FILE-005/007 filesystem subsets.
/// Native APFS adaptation tests; no global Trash view or Windows UI claim.
@Suite(.serialized)
struct FileRecoveryTests {
    @Test
    func testNativeTrashAdapterRefusesAnOwnedOutsideFixtureFile() throws {
        let fixture = try RecoveryFixture()
        let outside = try RecoveryFixture()
        let bytes = Data("owned outside-fixture file".utf8)
        let url = try outside.write("outside.txt", bytes: bytes)
        let identity = try #require(try LocalFileIdentity.read(at: url, ifLocal: true))
        let resolvedParent = try FileSystemPath.resolvingExisting(outside.source)
        let request = resolvedParent.appendingPathComponent(url.lastPathComponent)

        do {
            _ = try fixture.nativeTrash(request)
            Issue.record("Trash adapter accepted a file outside its owned fixture")
        } catch FileOperationError.unsupported(let reason) {
            #expect(reason == "Test Trash request escaped its owned fixture.")
        }
        #expect(try LocalFileIdentity.read(at: url, ifLocal: true) == identity)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test
    func testKnownChildMutationsNeedSearchPermissionWithoutDirectoryReadPermission() async throws {
        let fixture = try RecoveryFixture()
        try fixture.write()
        let context = try await fixture.context()
        let item = try await fixture.item("item.txt")
        #expect(fixture.source.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o300)) } == 0)
        defer { _ = fixture.source.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) } }
        // Exercise the mutation contract, not Trash permissions or enumeration:
        // a known child can be renamed and another created with write+search.
        let renamed = try await LocalFileOperations().rename(item, to: "renamed.txt", in: context)
        #expect(renamed.identity == item.identity)
        let created = try await LocalFileOperations().createFolder(named: "Created", in: context)
        #expect(created.identity != nil)
        #expect(created.warning == nil)
        #expect(try Data(contentsOf: renamed.url) == Data("owned synthetic item".utf8))
    }

    @Test
    func testNativeReferenceFileTrashAndRestorePreserve26BytesHashTimeAndIdentity() async throws {
        let fixture = try RecoveryFixture()
        let payload = Data("Delete operation sample.\r\n".utf8)
        let url = try fixture.write(bytes: payload)
        let timestamp = Date(timeIntervalSince1970: 1_707_019_200)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        let original = try await fixture.item("item.txt")
        let receipt = try await fixture.trash()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(receipt.trashed.identity == original.identity)
        #expect(receipt.originalContext.directoryURL == fixture.source)
        let data = try Data(contentsOf: receipt.trashed.url)
        #expect(data.count == 26)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == "d7477207e7366241ce8a3606a39df051949f543ff639e2038f910153c2bac05e")
        let result = try await fixture.service.restore(receipt, as: receipt.original.name)
        let restored = try await fixture.item("item.txt")
        #expect(result.warning == nil)
        #expect(result.url == restored.url)
        #expect(result.identity == original.identity)
        #expect(restored.modifiedAt == original.modifiedAt)
        #expect(try Data(contentsOf: result.url) == payload)
        #expect((try? LocalFileIdentity.read(at: receipt.trashed.url, ifLocal: true)) == nil)
    }

    @Test
    func testNativePackageRoundTripRetainsNestedContents() async throws {
        let fixture = try RecoveryFixture()
        let folder = fixture.source.appendingPathComponent("Synthetic.app/Contents/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("package content".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let receipt = try await fixture.trash("Synthetic.app")
        #expect(try Data(contentsOf: receipt.trashed.url.appendingPathComponent("Contents/Nested/child.txt")) == Data("package content".utf8))
        let restored = try await fixture.service.restore(receipt, as: "Restored.app")
        #expect(try Data(contentsOf: restored.url.appendingPathComponent("Contents/Nested/child.txt")) == Data("package content".utf8))
        #expect(restored.identity == receipt.original.identity)
    }

    @Test
    func testNativeSymlinkEntriesRoundTripWithoutChangingTargets() async throws {
        let fixture = try RecoveryFixture()
        let target = try fixture.write("target.txt")
        let folder = fixture.source.appendingPathComponent("TargetFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (index, destination) in [target.path, folder.path, fixture.source.appendingPathComponent("absent").path].enumerated() {
            let name = "Link-\(index)"
            let link = fixture.source.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            let receipt = try await fixture.trash(name)
            #expect(receipt.trashed.isSymbolicLink)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.trashed.url.path) == destination)
            let restored = try await fixture.service.restore(receipt, as: name)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.url.path) == destination)
            #expect(restored.identity == receipt.original.identity)
        }
        #expect(try Data(contentsOf: target) == Data("owned synthetic item".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test
    func testNativeDuplicateNamesUseDistinctReturnedTrashLocations() async throws {
        let fixture = try RecoveryFixture()
        let name = "ExplorerDuplicate-" + UUID().uuidString + ".txt"
        var receipts: [TrashReceipt] = []
        for parentName in ["A", "B"] {
            let parent = fixture.source.appendingPathComponent(parentName, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data(parentName.utf8).write(to: parent.appendingPathComponent(name))
            let result = try await fixture.service.trash(fixture.item(name, at: parent), in: fixture.context(parent))
            receipts.append(try #require(result.receipt))
        }
        #expect(receipts[0].trashed.url != receipts[1].trashed.url)
        for receipt in receipts {
            let restored = try await fixture.service.restore(receipt, as: name)
            #expect(try Data(contentsOf: restored.url) == Data(receipt.originalContext.directoryURL.lastPathComponent.utf8))
        }
    }

    @Test
    func testRestoreCollisionNeverOverwritesFileFolderOrDanglingLink() async throws {
        let fixture = try RecoveryFixture()
        for kind in ["file", "folder", "link"] {
            let name = kind + ".txt"
            let originalURL = try fixture.write(name)
            let receipt = try await fixture.trash(name)
            switch kind {
            case "file": try Data("existing destination".utf8).write(to: originalURL)
            case "folder": try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(atPath: originalURL.path, withDestinationPath: "missing-target")
            }
            let collisionIdentity = try LocalFileIdentity.read(at: originalURL, ifLocal: true)
            do {
                _ = try await fixture.service.restore(receipt, as: name)
                Issue.record("Restore overwrote an existing destination")
            } catch FileOperationError.collision(let collidedName) { #expect(collidedName == name) }
            #expect(try LocalFileIdentity.read(at: originalURL, ifLocal: true) == collisionIdentity)
            #expect(try LocalFileIdentity.read(at: receipt.trashed.url, ifLocal: true) == receipt.trashed.identity)
            let restored = try await fixture.service.restore(receipt, as: "Recovered-" + name)
            #expect(try Data(contentsOf: restored.url) == Data("owned synthetic item".utf8))
        }
    }

    @Test
    func testStaleSourceAndParentRefuseBeforeNativeCall() async throws {
        let fixture = try RecoveryFixture()
        let url = try fixture.write()
        let item = try await fixture.item("item.txt")
        let context = try await fixture.context()
        try FileManager.default.moveItem(at: url, to: fixture.root.appendingPathComponent("original"))
        try Data("replacement".utf8).write(to: url)
        let service = LocalFileRecovery(nativeTrash: { _ in Issue.record("Stale request reached native Trash"); return nil })
        do { _ = try await service.trash(item, in: context); Issue.record("Stale source accepted") }
        catch FileOperationError.staleSource {}
        let replacement = try await fixture.item("item.txt")
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("moved-source"))
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        do { _ = try await service.trash(replacement, in: context); Issue.record("Stale parent accepted") }
        catch FileOperationError.staleParent {}
    }

    @Test
    func testNativeFailureWithUnchangedSourceIsThrownWithoutFallback() async throws {
        let fixture = try RecoveryFixture()
        let url = try fixture.write()
        let item = try await fixture.item("item.txt")
        let service = LocalFileRecovery(nativeTrash: { _ in throw POSIXError(.EACCES) })
        do { _ = try await service.trash(item, in: fixture.context()); Issue.record("Native failure reported success") }
        catch let error as POSIXError { #expect(error.code == .EACCES) }
        #expect(try LocalFileIdentity.read(at: url, ifLocal: true) == item.identity)
    }

    @Test
    func testErrorAfterNativeMoveReportsUncertainOutcome() async throws {
        let fixture = try RecoveryFixture()
        let url = try fixture.write()
        let service = LocalFileRecovery(nativeTrash: { url in
            _ = try fixture.nativeTrash(url)
            throw POSIXError(.EIO)
        })
        do { _ = try await service.trash(fixture.item("item.txt"), in: fixture.context()); Issue.record("Ambiguous native failure reported success") }
        catch FileRecoveryError.outcomeUncertain(let detail, _) { #expect(!detail.isEmpty) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The fixture restores its exact native receipt even though service output is uncertain.
    }

    @Test
    func testNativeSuccessWithMissingReceiptReturnsWarningWithoutRetryableFailure() async throws {
        let fixture = try RecoveryFixture()
        let url = try fixture.write()
        let service = LocalFileRecovery(nativeTrash: { url in _ = try fixture.nativeTrash(url); return nil })
        let result = try await service.trash(fixture.item("item.txt"), in: fixture.context())
        #expect(result.receipt == nil)
        #expect(result.warning != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func testNativeSuccessWithWrongReturnedIdentityReturnsWarning() async throws {
        let fixture = try RecoveryFixture()
        try fixture.write()
        let unrelatedOwned = try fixture.write("unrelated.txt", bytes: Data("unchanged".utf8))
        let service = LocalFileRecovery(nativeTrash: { url in _ = try fixture.nativeTrash(url); return unrelatedOwned })
        let result = try await service.trash(fixture.item("item.txt"), in: fixture.context())
        #expect(result.receipt == nil)
        #expect(result.warning != nil)
        #expect(try Data(contentsOf: unrelatedOwned) == Data("unchanged".utf8))
    }

    @Test
    func testCancellationBeforeNativeCallAndAfterNativeSuccessHaveDistinctOutcomes() async throws {
        let fixture = try RecoveryFixture()
        let url = try fixture.write()
        let item = try await fixture.item("item.txt"), context = try await fixture.context()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.trash(item, in: context)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled Trash succeeded") }
        catch is CancellationError {}
        #expect(try LocalFileIdentity.read(at: url, ifLocal: true) == item.identity)
        let service = LocalFileRecovery(nativeTrash: { url in
            let returned = try fixture.nativeTrash(url)
            withUnsafeCurrentTask { $0?.cancel() }
            return returned
        })
        let result = try await service.trash(item, in: context)
        #expect(result.receipt != nil)
        #expect(result.warning == nil)
    }

    @Test
    func testMissingOriginalParentRefusesRestoreAndKeepsReceiptItem() async throws {
        let fixture = try RecoveryFixture()
        try fixture.write()
        let receipt = try await fixture.trash()
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("moved-parent"))
        do { _ = try await fixture.service.restore(receipt, as: "item.txt"); Issue.record("Missing parent restore succeeded") }
        catch FileOperationError.staleParent {}
        #expect(try LocalFileIdentity.read(at: receipt.trashed.url, ifLocal: true) == receipt.trashed.identity)
    }

    @Test
    func testStaleTrashEntryRefusesRestoreWithoutTouchingDisplacedItem() async throws {
        let fixture = try RecoveryFixture()
        try fixture.write()
        let receipt = try await fixture.trash()
        let displaced = fixture.root.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: receipt.trashed.url, to: displaced)
        do { _ = try await fixture.service.restore(receipt, as: "item.txt"); Issue.record("Stale Trash entry restored") }
        catch { #expect(error is FileOperationError) }
        #expect(try LocalFileIdentity.read(at: displaced, ifLocal: true) == receipt.trashed.identity)
        #expect(!FileManager.default.fileExists(atPath: receipt.original.url.path))
    }

    @Test
    func testInvalidRestoreNameCannotEscapeOriginalParent() async throws {
        let fixture = try RecoveryFixture()
        try fixture.write()
        let receipt = try await fixture.trash()
        for name in ["", ".", "..", "../escape", "part/name", "nul\0name"] {
            do { _ = try await fixture.service.restore(receipt, as: name); Issue.record("Invalid restore name accepted") }
            catch FileOperationError.invalidName {}
        }
        #expect(try LocalFileIdentity.read(at: receipt.trashed.url, ifLocal: true) == receipt.trashed.identity)
    }

    @Test
    func testUnicodeAndSymlinkParentKeepOriginalLexicalContext() async throws {
        let fixture = try RecoveryFixture()
        let parent = fixture.source.appendingPathComponent("Café", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let route = fixture.root.appendingPathComponent("route", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: route.path, withDestinationPath: parent.path)
        try Data("unicode".utf8).write(to: parent.appendingPathComponent("Café?.txt"))
        let result = try await fixture.service.trash(fixture.item("Café?.txt", at: route), in: fixture.context(route))
        let receipt = try #require(result.receipt)
        #expect(receipt.originalContext.directoryURL == route)
        let restored = try await fixture.service.restore(receipt, as: "東京?.txt")
        let item = try await fixture.item("東京?.txt", at: route)
        #expect(restored.url == item.url)
        #expect(restored.identity == receipt.original.identity)
        #expect(try Data(contentsOf: restored.url) == Data("unicode".utf8))
    }

    @Test
    func testSpecialNodeAndUnknownIdentityNeverReachNativeTrash() async throws {
        let fixture = try RecoveryFixture()
        let fifo = fixture.source.appendingPathComponent("pipe")
        #expect(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) } == 0)
        let service = LocalFileRecovery(nativeTrash: { _ in Issue.record("Unsupported entry reached native Trash"); return nil })
        do { _ = try await service.trash(fixture.item("pipe"), in: fixture.context()); Issue.record("FIFO accepted") }
        catch FileOperationError.unsupported {}
        let url = try fixture.write()
        let unknown = FileItem(url: url, name: "item.txt", isDirectory: false, isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "File")
        do { _ = try await service.trash(unknown, in: fixture.context()); Issue.record("Unknown identity accepted") }
        catch FileOperationError.staleSource {}
        #expect(try Data(contentsOf: url) == Data("owned synthetic item".utf8))
    }
}
