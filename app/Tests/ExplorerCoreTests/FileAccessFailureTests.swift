import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class AccessFixture {
    let root: URL
    let gate: URL
    let folder: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerAccess-" + UUID().uuidString, isDirectory: true)
        gate = root.appendingPathComponent("Gate", isDirectory: true)
        folder = gate.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    deinit {
        _ = gate.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) }
        _ = folder.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned access fixture cleanup failed: \(root.path): \(error)") }
    }
    func context() async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: folder)
        return FileOperationContext(directoryURL: folder, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
    func item(_ name: String) async throws -> FileItem {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: folder)
        return try #require(snapshot.items.first { $0.name == name })
    }
    func mode(_ value: mode_t, at url: URL? = nil) throws {
        let target = url ?? folder
        guard target.withUnsafeFileSystemRepresentation({ chmod($0!, value) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class AccessErrorCycle: NSError, @unchecked Sendable {
    var next: NSError?
    init(domain: String = "OwnedErrorCycle", code: Int = 1) { super.init(domain: domain, code: code, userInfo: nil) }
    required init?(coder: NSCoder) { return nil }
    override var userInfo: [String: Any] { next.map { [NSUnderlyingErrorKey: $0] } ?? [:] }
}

/// Native permission-guidance adaptation supporting the existing navigation and
/// file-operation requirements. These are POSIX/ACL-style denials on owned local
/// fixtures, not TCC or Full Disk Access verification. No settings are changed.
struct FileAccessFailureTests {
    @Test
    func testNativeCodesDistinguishPermissionDeniedFromReadOnlyVolume() {
        for code in [EACCES, EPERM] {
            #expect(FileAccessFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(code))) == .permissionDenied)
            #expect(FileAccessFailure.classify(FileOperationError.systemFailure(operation: "Fixture operation", code: code)) == .permissionDenied)
        }
        #expect(FileAccessFailure.classify(POSIXError(.EROFS)) == .readOnlyVolume)
        #expect(FileAccessFailure.classify(FileOperationError.systemFailure(operation: "Write", code: EROFS)) == .readOnlyVolume)
        for code in [NSFileReadNoPermissionError, NSFileWriteNoPermissionError] {
            #expect(FileAccessFailure.classify(NSError(domain: NSCocoaErrorDomain, code: code)) == .permissionDenied)
        }
        #expect(FileAccessFailure.classify(CocoaError(.fileWriteVolumeReadOnly)) == .readOnlyVolume)
    }

    @Test
    func testUnderlyingNativeErrorsAreRecognizedAndReadOnlyBeatsGenericDenial() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        let wrapped = NSError(domain: "OuterFixture", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        #expect(FileAccessFailure.classify(wrapped) == .permissionDenied)
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EROFS)])
        #expect(FileAccessFailure.classify(readOnly) == .readOnlyVolume)
        let multiple = NSError(domain: "MultipleFixture", code: 1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [POSIXError(.EACCES) as NSError, POSIXError(.EROFS) as NSError]])
        #expect(FileAccessFailure.classify(multiple) == .readOnlyVolume)
    }

    @Test
    func testUnrelatedFailuresAndDescriptionsAreNotPermissionEvidence() {
        let errors: [Error] = [CancellationError(), POSIXError(.ENOENT), POSIXError(.ENOTDIR), POSIXError(.ENOSPC),
            POSIXError(.EIO), FileOperationError.staleParent, FileOperationError.staleSource,
            FileOperationError.collision("existing"), FileOperationError.unsupported("Permission denied"),
            NSError(domain: "Unrelated", code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])]
        for error in errors { #expect(FileAccessFailure.classify(error) == nil) }
    }

    @Test
    func testCyclicNSErrorChainsTerminateAndStillRecognizeNativeCause() {
        let first = AccessErrorCycle(), second = AccessErrorCycle()
        first.next = second; second.next = first
        defer { first.next = nil; second.next = nil }
        #expect(FileAccessFailure.classify(first) == nil)
        let native = AccessErrorCycle(domain: NSPOSIXErrorDomain, code: Int(EROFS))
        native.next = first; second.next = native
        defer { native.next = nil }
        #expect(FileAccessFailure.classify(first) == .readOnlyVolume)
    }

    @Test
    func testStructuredWrappersRetainFailureWithoutChangingOutcomeSemantics() {
        let location = URL(fileURLWithPath: "/owned-fixture-only")
        let cleanup = FileTransferError.cleanupFailed(cause: "Cancellation", stagingURL: location, accessFailure: .permissionDenied)
        #expect(FileAccessFailure.classify(cleanup) == .permissionDenied)
        let uncertain = FileRecoveryError.outcomeUncertain("Unknown outcome", accessFailure: .readOnlyVolume)
        #expect(FileAccessFailure.classify(uncertain) == .readOnlyVolume)
        #expect(FileAccessFailure.classify(FileRecoveryError.outcomeUncertain("Permission denied")) == nil)
        #expect(FileAccessFailure.classify(FileTransferError.cleanupFailed(cause: "Permission denied", stagingURL: location)) == nil)
        let committed = FileOperationResult(url: location, identity: nil, warning: "Already created", accessFailure: .permissionDenied)
        #expect(committed.accessFailure == .permissionDenied)
        #expect(committed.warning == "Already created")
    }

    @Test
    func testOwnedDirectoryDeniedThenRepairedCanBeEnumeratedAgain() async throws {
        let fixture = try AccessFixture()
        try Data("owned bytes".utf8).write(to: fixture.folder.appendingPathComponent("item.txt"))
        let before = try await fixture.context()
        try fixture.mode(0)
        do { _ = try await LocalDirectoryLoader().snapshot(of: fixture.folder); Issue.record("Unreadable directory was enumerated") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        try fixture.mode(0o700)
        let after = try await LocalDirectoryLoader().snapshot(of: fixture.folder)
        #expect(after.items.map(\.name) == ["item.txt"])
        #expect(after.directoryIdentity == before.directoryIdentity)
    }

    @Test
    func testDeniedAncestorDoesNotBecomeStaleParentAndExplicitRetrySucceeds() async throws {
        let fixture = try AccessFixture()
        let context = try await fixture.context()
        let resolved = fixture.folder.resolvingSymlinksInPath()
        try fixture.mode(0, at: fixture.gate)
        do { _ = try await LocalFileOperations().createFolder(named: "Created", in: context); Issue.record("Denied parent created a folder") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        do { try LocalFileOperations.revalidateRoute(context, resolved: resolved); Issue.record("Denied route revalidated") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        try fixture.mode(0o700, at: fixture.gate)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("Created").path))
        let result = try await LocalFileOperations().createFolder(named: "Created", in: context)
        #expect(result.warning == nil)
        #expect(result.accessFailure == nil)
        #expect(result.identity != nil)
    }

    @Test
    func testCreateDenialFromNonwritableFolderPreservesTypedErrno() async throws {
        let fixture = try AccessFixture()
        let context = try await fixture.context()
        try fixture.mode(0o500)
        do { _ = try await LocalFileOperations().createFolder(named: "Created", in: context); Issue.record("Nonwritable folder allowed creation") }
        catch {
            #expect(FileAccessFailure.classify(error) == .permissionDenied)
            guard case FileOperationError.systemFailure(_, let code) = error else { Issue.record("Native syscall code was lost"); return }
            #expect(code == EACCES || code == EPERM)
        }
        try fixture.mode(0o700)
        let result = try await LocalFileOperations().createFolder(named: "Created", in: context)
        #expect(result.warning == nil)
    }

    @Test
    func testUnreadableCopySourceCanBeRepairedAndRetriedWithoutLeftoverStage() async throws {
        let fixture = try AccessFixture()
        let destination = fixture.root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = fixture.folder.appendingPathComponent("source.txt"), bytes = Data("copy after repair".utf8)
        try bytes.write(to: source)
        let item = try await fixture.item("source.txt"), from = try await fixture.context()
        let snapshot = try await LocalDirectoryLoader().snapshot(of: destination)
        let to = FileOperationContext(directoryURL: destination, directoryIdentity: try #require(snapshot.directoryIdentity))
        try fixture.mode(0, at: source)
        do {
            _ = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "copied.txt", kind: .copy,
                control: TransferControl(), onProgress: { _ in })
            Issue.record("Unreadable source was copied")
        } catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try fixture.mode(0o600, at: source)
        let result = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "copied.txt", kind: .copy,
            control: TransferControl(), onProgress: { _ in })
        #expect(result.warning == nil)
        #expect(try Data(contentsOf: result.url) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test
    func testImmutableRenameIsGenericAccessDenialNotProofOfPrivacyPolicy() async throws {
        let fixture = try AccessFixture()
        let source = fixture.folder.appendingPathComponent("source.txt"), bytes = Data("unchanged locked file".utf8)
        try bytes.write(to: source)
        let item = try await fixture.item("source.txt"), context = try await fixture.context()
        try #require(source.withUnsafeFileSystemRepresentation { chflags($0!, UInt32(UF_IMMUTABLE)) } == 0)
        defer { _ = source.withUnsafeFileSystemRepresentation { chflags($0!, 0) } }
        do { _ = try await LocalFileOperations().rename(item, to: "renamed.txt", in: context); Issue.record("Locked source was renamed") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        try #require(source.withUnsafeFileSystemRepresentation { chflags($0!, 0) } == 0)
        let result = try await LocalFileOperations().rename(item, to: "renamed.txt", in: context)
        #expect(result.warning == nil)
        #expect(try Data(contentsOf: result.url) == bytes)
    }

    @Test
    func testPostcommitDeniedSamplingRemainsSuccessWithStructuredWarning() async throws {
        let fixture = try AccessFixture()
        let gate = fixture.gate
        let service = LocalFileOperations(afterCommit: { _ in
            if gate.withUnsafeFileSystemRepresentation({ chmod($0!, 0) }) != 0 { Issue.record("Could not restrict owned parent") }
        })
        let result = try await service.createFolder(named: "AlreadyCreated", in: fixture.context())
        #expect(result.warning != nil)
        #expect(result.identity == nil)
        #expect(result.accessFailure == .permissionDenied)
        try fixture.mode(0o700, at: gate)
        #expect(try result.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test
    func testUncertainTrashFailureKeepsItsAccessCategoryWithoutBecomingRetryable() async throws {
        let fixture = try AccessFixture()
        let source = fixture.folder.appendingPathComponent("source.txt")
        try Data("owned uncertain outcome".utf8).write(to: source)
        let displaced = fixture.root.appendingPathComponent("displaced.txt")
        let service = LocalFileRecovery(nativeTrash: { original in
            // This injected boundary moves only our fixture; no system Trash access.
            try FileManager.default.moveItem(at: original, to: displaced)
            throw POSIXError(.EACCES)
        })
        do { _ = try await service.trash(fixture.item("source.txt"), in: fixture.context()); Issue.record("Uncertain native outcome reported success") }
        catch {
            guard case FileRecoveryError.outcomeUncertain(_, let failure) = error else { Issue.record("Uncertain-outcome contract was lost"); return }
            #expect(failure == .permissionDenied)
            #expect(FileAccessFailure.classify(error) == .permissionDenied)
        }
        #expect(FileManager.default.fileExists(atPath: displaced.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
