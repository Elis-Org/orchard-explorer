import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class TransferFixture {
    let root: URL
    let source: URL
    let destination: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerTransfers-" + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    deinit {
        do {
            try clearOwnedTransferTestMetadata(root)
            try FileManager.default.removeItem(at: root)
        } catch { Issue.record("Owned transfer fixture cleanup failed at \(root.path): \(error)") }
    }
    func context(_ url: URL) async throws -> FileOperationContext {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url)
        return FileOperationContext(directoryURL: url, directoryIdentity: try #require(snapshot.directoryIdentity))
    }
    func item(_ name: String, at url: URL? = nil) async throws -> FileItem {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url ?? source)
        return try #require(snapshot.items.first { $0.name == name })
    }
    func noStaging(at url: URL? = nil) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: (url ?? destination).path)
            .allSatisfy { !$0.hasPrefix(".explorer-transfer-") }
    }
}

private func transferTestStat(_ url: URL) throws -> stat {
    var value = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return value
}

/// Fixtures can deliberately contain locked items and synthetic replacements.
/// Only their own namespace is adjusted, using no-follow, identity-checked FDs.
private func clearOwnedTransferTestMetadata(_ url: URL) throws {
    let value = try transferTestStat(url)
    let type = value.st_mode & mode_t(S_IFMT)
    guard type == S_IFREG || type == S_IFDIR else { return }
    let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0, LocalFileIdentity.fromStat(opened) == LocalFileIdentity.fromStat(value) else {
        throw FileOperationError.staleSource
    }
    guard fchflags(fd, opened.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)) == 0 else { throw POSIXError(.EPERM) }
    guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
    defer { acl_free(UnsafeMutableRawPointer(empty)) }
    guard acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0,
          fchmod(fd, type == S_IFDIR ? mode_t(0o700) : mode_t(0o600)) == 0 else { throw POSIXError(.EACCES) }
    if type == S_IFDIR {
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try clearOwnedTransferTestMetadata(child)
        }
    }
}

private func setTransferTestACL(_ url: URL, _ rule: String = "everyone deny delete", at index: Int? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = index.map { ["+a#", String($0), rule, url.path] } ?? ["+a", rule, url.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw POSIXError(.EACCES) }
}

private func transferTestACL(_ url: URL) throws -> String {
    guard let acl = url.withUnsafeFileSystemRepresentation({ acl_get_file($0!, ACL_TYPE_EXTENDED) }) else {
        if errno == ENOENT { _ = try transferTestStat(url); return "" }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length: ssize_t = 0
    guard let text = acl_to_text(acl, &length) else { throw POSIXError(.EIO) }
    defer { acl_free(text) }
    return String(cString: text)
}

private func runTransferFixtureCommand(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run(); process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "OwnedTransferFixture", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
    }
    return data
}

/// A real ACL-unsupported filesystem, mounted only inside a new owned fixture.
/// The device comes from this exact attach result; cleanup never searches disks.
private final class TransferFATFixture {
    let root: URL
    let mount: URL
    private var device: String?
    private var attached = false
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerTransferFAT-" + UUID().uuidString, isDirectory: true)
        mount = root.appendingPathComponent("Mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let image = root.appendingPathComponent("owned.dmg")
            _ = try runTransferFixtureCommand("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "MS-DOS FAT32", "-volname", "ExplorerACLTest", image.path])
            let output = try runTransferFixtureCommand("/usr/bin/hdiutil", ["attach", "-nobrowse", "-owners", "off", "-mountpoint", mount.path, "-plist", image.path])
            attached = true
            let plist = try #require(PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
            let entities = try #require(plist["system-entities"] as? [[String: Any]])
            // Preserve a device from this attachment for cleanup even if its
            // reported mount path unexpectedly fails the canonical-path check.
            device = entities.compactMap { $0["dev-entry"] as? String }.first
            let entry = try #require(entities.first { entry in
                guard let path = entry["mount-point"] as? String else { return false }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path
            })
            device = try #require(entry["dev-entry"] as? String)
        } catch { cleanup(); throw error }
    }
    deinit { cleanup() }
    private func cleanup() {
        do {
            if let device {
                _ = try runTransferFixtureCommand("/usr/bin/hdiutil", ["detach", device])
                self.device = nil
                attached = false
            }
            guard !attached else {
                Issue.record("Owned disk image attachment needs inspection: \(root.path)")
                return
            }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch { Issue.record("Owned disk image could not be detached; retained at \(root.path): \(error)") }
    }
}

private final class TransferInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class TransferProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [TransferProgress] = []
    private var fired = false
    private let onFirstPositive: @Sendable () -> Void
    let firstPositive: AsyncStream<Int64>
    private let continuation: AsyncStream<Int64>.Continuation
    init(onFirstPositive: @escaping @Sendable () -> Void = {}) {
        self.onFirstPositive = onFirstPositive
        (firstPositive, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func record(_ progress: TransferProgress) {
        lock.lock()
        captured.append(progress)
        let signal = !fired && progress.bytesCopied > 0
        if signal { fired = true }
        lock.unlock()
        if signal { onFirstPositive(); continuation.yield(progress.bytesCopied) }
    }
    var values: [TransferProgress] { lock.lock(); defer { lock.unlock() }; return captured }
}

/// Native service tests supporting FR-FILE-003/004/014/015 / EV-0252, EV-0255,
/// EV-0102 / AT-FILE-003/004/014/015. All mutations use isolated owned fixtures.
struct FileTransferTests {
    @Test
    func testExactProbeCopyAndMovePreserveHashesAndReportActualBytes() async throws {
        let fixture = try TransferFixture()
        let copyData = Data("Synthetic shell probe copy".utf8)
        let moveData = Data("Synthetic shell probe move".utf8)
        #expect(copyData.count == 26 && moveData.count == 26)
        try copyData.write(to: fixture.source.appendingPathComponent("copy.txt"))
        try moveData.write(to: fixture.source.appendingPathComponent("move.txt"))
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let copied = try await fixture.item("copy.txt"), moved = try await fixture.item("move.txt")
        let progress = TransferProgressProbe()
        let copy = try await LocalFileTransfers().transfer(copied, from: from, to: to, name: "copied.txt", kind: .copy,
            control: TransferControl(), onProgress: { progress.record($0) })
        #expect(hash(try Data(contentsOf: copy.url)) == "832fa13ea5334e1e724ef3fa0fd8618ae2d76fe6793064b342304c9f550ae85a")
        #expect(try Data(contentsOf: copied.url) == copyData)
        #expect(progress.values.last?.bytesCopied == 26)
        #expect(copy.identity != copied.identity)
        let moveProgress = TransferProgressProbe()
        let move = try await LocalFileTransfers().transfer(moved, from: from, to: to, name: "moved.txt", kind: .move,
            control: TransferControl(), onProgress: { moveProgress.record($0) })
        #expect(hash(try Data(contentsOf: move.url)) == "de5d76f5a7ba6a0333538581d6657c505c218f66f67d2148e5bd7d71b868e98c")
        #expect(!FileManager.default.fileExists(atPath: moved.url.path))
        #expect(move.identity == moved.identity)
        #expect(moveProgress.values.allSatisfy { $0.bytesCopied == 0 }, "Rename-based move must not invent copied bytes")
        #expect(try fixture.noStaging())
    }

    @Test
    func testTwentyFourByteFixtureAndNativeMetadataAreCopied() async throws {
        let fixture = try TransferFixture()
        let url = fixture.source.appendingPathComponent("sample.txt")
        let data = Data("Copy operation sample.\r\n".utf8)
        #expect(data.count == 24)
        try data.write(to: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: url.path)
        let attribute = Data("metadata-value".utf8)
        let setResult = url.withUnsafeFileSystemRepresentation { path in
            attribute.withUnsafeBytes { setxattr(path!, "com.nativeexplorer.test", $0.baseAddress, $0.count, 0, 0) }
        }
        try #require(setResult == 0)
        let result = try await transfer("sample.txt", fixture: fixture, kind: .copy)
        #expect(try Data(contentsOf: result.url) == data)
        let attributes = try FileManager.default.attributesOfItem(atPath: result.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(abs((attributes[.modificationDate] as? Date ?? .distantPast).timeIntervalSince(date)) < 0.001)
        var buffer = [UInt8](repeating: 0, count: 64)
        let bufferSize = buffer.count
        let count = result.url.withUnsafeFileSystemRepresentation { getxattr($0!, "com.nativeexplorer.test", &buffer, bufferSize, 0, 0) }
        try #require(count >= 0)
        #expect(Data(buffer.prefix(count)) == attribute)
        let listing = try await fixture.item("sample.txt", at: fixture.destination)
        #expect(result.identity == listing.identity, "Published identity must include metadata-adjusted birth time")
        #expect(try fixture.noStaging())
    }

    @Test
    func testImmutableAndAppendFlagsAreRestoredAfterExclusivePublication() async throws {
        let fixture = try TransferFixture()
        let data = Data("locked source bytes".utf8)
        for (name, flag) in [("immutable", UInt32(UF_IMMUTABLE)), ("append", UInt32(UF_APPEND))] {
            let source = fixture.source.appendingPathComponent(name)
            try data.write(to: source)
            try #require(source.withUnsafeFileSystemRepresentation { chflags($0!, flag) } == 0)
            let original = try await fixture.item(name)
            let before = try transferTestStat(source)
            let result = try await transfer(name, fixture: fixture, kind: .copy)
            #expect(result.warning == nil)
            #expect(try Data(contentsOf: result.url) == data)
            #expect(try transferTestStat(result.url).st_flags & flag == flag)
            #expect(try transferTestStat(source).st_flags == before.st_flags)
            #expect(try LocalFileIdentity.read(at: source, ifLocal: true) == original.identity)
            #expect(try Data(contentsOf: source) == data)
            #expect(try fixture.noStaging())
        }
    }

    @Test
    func testDenyDeleteDirectoryACLsPublishAndFinalizeDescendantsBeforeParent() async throws {
        let fixture = try TransferFixture()
        let tree = fixture.source.appendingPathComponent("Tree", isDirectory: true)
        let child = tree.appendingPathComponent("Protected", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let data = Data("protected directory contents".utf8)
        try data.write(to: child.appendingPathComponent("data.txt"))
        try setTransferTestACL(tree)
        try setTransferTestACL(child)
        let originalACL = try transferTestACL(tree), childACL = try transferTestACL(child)
        let result = try await transfer("Tree", fixture: fixture, kind: .copy)
        #expect(result.warning == nil)
        #expect(try Data(contentsOf: result.url.appendingPathComponent("Protected/data.txt")) == data)
        #expect(try transferTestACL(result.url) == originalACL)
        #expect(try transferTestACL(result.url.appendingPathComponent("Protected")) == childACL)
        #expect(try transferTestACL(tree) == originalACL)
        #expect(try transferTestACL(child) == childACL)
        #expect(try Data(contentsOf: child.appendingPathComponent("data.txt")) == data)
        #expect(try fixture.noStaging())
    }

    @Test
    func testCancellationAfterDeferredDescendantACLLeavesNoUnpublishedTree() async throws {
        let fixture = try TransferFixture()
        let tree = fixture.source.appendingPathComponent("Tree", isDirectory: true)
        let data = Data(repeating: 0x71, count: 64 * 1024)
        for index in 0..<3 {
            let child = tree.appendingPathComponent("Protected-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try data.write(to: child.appendingPathComponent("data.bin"))
            try setTransferTestACL(child)
        }
        let control = TransferControl()
        let progress = TransferProgressProbe()
        do {
            _ = try await LocalFileTransfers().transfer(fixture.item("Tree"), from: fixture.context(fixture.source),
                to: fixture.context(fixture.destination), name: "Cancelled", kind: .copy, control: control, onProgress: { value in
                    progress.record(value)
                    // Cumulative bytes prove one complete protected descendant
                    // has been staged before cancellation enters the next one.
                    if value.bytesCopied > Int64(data.count) { control.cancel() }
                })
            Issue.record("Cancelled protected-tree copy succeeded")
        } catch is CancellationError {}
        #expect(progress.values.contains { $0.bytesCopied > Int64(data.count) })
        #expect(try fixture.noStaging())
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("Cancelled").path))
        for index in 0..<3 {
            let child = tree.appendingPathComponent("Protected-\(index)", isDirectory: true)
            #expect(try transferTestACL(child).contains(":deny:delete"))
            #expect(try Data(contentsOf: child.appendingPathComponent("data.bin")) == data)
        }
    }

    @Test
    func testCancellationClearsBlockingACLOnlyOnOwnedStagedPayload() async throws {
        let fixture = try TransferFixture()
        let data = Data(repeating: 0x52, count: 1024 * 1024)
        try data.write(to: fixture.source.appendingPathComponent("source.bin"))
        let destination = fixture.destination
        let control = TransferControl()
        let progress = TransferProgressProbe(onFirstPositive: {
            do {
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: destination.path)
                    .first { $0.hasPrefix(".explorer-transfer-") })
                try setTransferTestACL(destination.appendingPathComponent(name).appendingPathComponent("payload"))
            } catch { Issue.record("Could not apply bounded staged ACL: \(error)") }
            control.cancel()
        })
        do {
            _ = try await LocalFileTransfers().transfer(fixture.item("source.bin"), from: fixture.context(fixture.source),
                to: fixture.context(fixture.destination), name: "Cancelled", kind: .copy, control: control,
                onProgress: { progress.record($0) })
            Issue.record("Cancelled staged-ACL copy succeeded")
        } catch is CancellationError {}
        #expect(try fixture.noStaging())
        #expect(try Data(contentsOf: fixture.source.appendingPathComponent("source.bin")) == data)
    }

    @Test
    func testPostcommitMetadataFailureKeepsCommittedDataAndReturnsWarning() async throws {
        let fixture = try TransferFixture()
        let data = Data("committed data must survive".utf8)
        let source = fixture.source.appendingPathComponent("source.txt")
        try data.write(to: source)
        try #require(source.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o644)) } == 0)
        try setTransferTestACL(source, "everyone deny read")
        try setTransferTestACL(source, "user:\(NSUserName()) allow read", at: 0)
        let originalACL = try transferTestACL(source)
        let service = LocalFileTransfers(afterCommit: { destination in
            if destination.withUnsafeFileSystemRepresentation({ chflags($0!, UInt32(UF_IMMUTABLE)) }) != 0 {
                Issue.record("Could not inject postcommit metadata failure")
            }
        })
        let result = try await service.transfer(fixture.item("source.txt"), from: fixture.context(fixture.source),
            to: fixture.context(fixture.destination), name: "committed.txt", kind: .copy,
            control: TransferControl(), onProgress: { _ in })
        #expect(result.warning?.contains("copy completed") == true)
        #expect(result.identity != nil)
        #expect(try transferTestStat(result.url).st_mode & mode_t(0o777) == mode_t(0o600), "Failed ACL installation must leave owner-only permissions")
        #expect(try transferTestACL(result.url).isEmpty)
        #expect(try Data(contentsOf: result.url) == data)
        #expect(try Data(contentsOf: source) == data)
        #expect(try transferTestStat(source).st_flags & UInt32(UF_IMMUTABLE) == 0)
        #expect(try transferTestACL(source) == originalACL)
        #expect(try fixture.noStaging())
    }

    @Test
    func testPublicationIsOwnerOnlyUntilCapturedDenyReadACLIsInstalled() async throws {
        let fixture = try TransferFixture()
        let bytes = Data("ACL-protected copy".utf8)
        for isDirectory in [false, true] {
            let name = isDirectory ? "ProtectedFolder" : "protected.txt"
            let source = fixture.source.appendingPathComponent(name, isDirectory: isDirectory)
            if isDirectory {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try bytes.write(to: source.appendingPathComponent("child.txt"))
            } else { try bytes.write(to: source) }
            let originalMode = isDirectory ? mode_t(0o755) : mode_t(0o644)
            try #require(source.withUnsafeFileSystemRepresentation { chmod($0!, originalMode) } == 0)
            let rights = isDirectory ? "read,search" : "read"
            try setTransferTestACL(source, "everyone deny \(rights)")
            // The copy caller remains authorized; other principals are denied.
            try setTransferTestACL(source, "user:\(NSUserName()) allow \(rights)", at: 0)
            let sourceACL = try transferTestACL(source)
            let commits = TransferInvocationCount()
            let service = LocalFileTransfers(afterCommit: { published in
                commits.record()
                do {
                    #expect(try transferTestStat(published).st_mode & mode_t(0o777) == (isDirectory ? mode_t(0o700) : mode_t(0o600)))
                    #expect(try transferTestACL(published).isEmpty, "This seam runs before captured ACL installation")
                    if isDirectory {
                        #expect(try transferTestStat(published.appendingPathComponent("child.txt")).st_mode & mode_t(0o777) == mode_t(0o600))
                    }
                } catch { Issue.record("Could not inspect publication permissions: \(error)") }
            })
            let result = try await service.transfer(fixture.item(name), from: fixture.context(fixture.source),
                to: fixture.context(fixture.destination), name: name, kind: .copy,
                control: TransferControl(), onProgress: { _ in })
            #expect(commits.value == 1)
            #expect(result.warning == nil)
            #expect(try transferTestStat(result.url).st_mode & mode_t(0o777) == originalMode)
            #expect(try transferTestACL(result.url) == sourceACL)
            #expect(try transferTestACL(source) == sourceACL)
            #expect(try Data(contentsOf: isDirectory ? result.url.appendingPathComponent("child.txt") : result.url) == bytes)
            #expect(try fixture.noStaging())
        }
    }

    @Test
    func testNativeFATWithoutACLsSupportsEmptyMetadataButRefusesDroppingNonemptyACL() async throws {
        let fixture = try TransferFixture()
        let volume = try TransferFATFixture()
        defer { withExtendedLifetime(volume) {} }
        let source = volume.mount.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("owned.txt")
        let bytes = Data("owned FAT ACL fixture".utf8)
        try bytes.write(to: file)
        let fd = file.withUnsafeFileSystemRepresentation { open($0!, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        try #require(fd >= 0)
        defer { close(fd) }
        let empty = try DeferredCopyMetadata(source: fd, flags: 0)
        empty.mode = mode_t(0o600)
        try DeferredCopyMetadata.clearAccessControl(fd)
        try empty.apply(to: fd)
        #expect(try Data(contentsOf: file) == bytes)

        let protected = fixture.source.appendingPathComponent("protected.txt")
        try bytes.write(to: protected)
        try setTransferTestACL(protected)
        let protectedFD = protected.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        try #require(protectedFD >= 0)
        defer { close(protectedFD) }
        let nonempty = try DeferredCopyMetadata(source: protectedFD, flags: 0)
        nonempty.mode = mode_t(0o644)
        do { try nonempty.apply(to: fd); Issue.record("Unsupported destination silently dropped a nonempty ACL") }
        catch FileOperationError.unsupported(let reason) { #expect(reason.contains("access control")) }
        #expect(try transferTestACL(protected).contains(":deny:delete"))
        #expect(try Data(contentsOf: file) == bytes)

        let capability = try volume.mount.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        print("Owned FAT32 exclusive rename capability: \(String(describing: capability.volumeSupportsExclusiveRenaming))")
        let snapshot = try await LocalDirectoryLoader().snapshot(of: source)
        if let identity = snapshot.directoryIdentity, let item = snapshot.items.first, item.identity != nil {
            let result = try await LocalFileTransfers().transfer(item,
                from: FileOperationContext(directoryURL: source, directoryIdentity: identity),
                to: fixture.context(fixture.destination), name: "from-fat.txt", kind: .copy,
                control: TransferControl(), onProgress: { _ in })
            #expect(result.warning == nil)
            #expect(try Data(contentsOf: result.url) == bytes)
            #expect(try fixture.noStaging())
            print("Owned FAT32-to-APFS service copy passed.")
        } else {
            print("Native ACL helper cases executed; FAT-to-APFS service case not exercised because local identity was unavailable.")
        }
    }

    @Test
    func testForeignPublishedChildIsUntouchedWhileOwnedSiblingsAndParentFinalize() async throws {
        let fixture = try TransferFixture()
        let tree = fixture.source.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try #require(tree.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o755)) } == 0)
        try setTransferTestACL(tree)
        let parentACL = try transferTestACL(tree)
        let child = tree.appendingPathComponent("owned.txt")
        let bytes = Data("owned copied contents".utf8), foreignBytes = Data("foreign synthetic child".utf8)
        try bytes.write(to: child)
        try #require(child.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o644)) } == 0)
        try setTransferTestACL(child)
        let childACL = try transferTestACL(child)
        try #require(child.withUnsafeFileSystemRepresentation { chflags($0!, UInt32(UF_APPEND)) } == 0)
        let service = LocalFileTransfers(afterCommit: { published in
            let foreign = published.appendingPathComponent("0-Foreign.txt")
            do {
                try foreignBytes.write(to: foreign, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: foreign.path)
                try setTransferTestACL(foreign, "everyone allow read")
            } catch { Issue.record("Could not add bounded foreign publication child: \(error)") }
        })
        let result = try await service.transfer(fixture.item("Tree"), from: fixture.context(fixture.source),
            to: fixture.context(fixture.destination), name: "Copied", kind: .copy,
            control: TransferControl(), onProgress: { _ in })
        #expect(result.warning?.contains("left untouched") == true)
        #expect(result.identity != nil)
        #expect(try transferTestStat(result.url).st_mode & mode_t(0o777) == mode_t(0o755))
        #expect(try transferTestACL(result.url) == parentACL)
        let copied = result.url.appendingPathComponent("owned.txt")
        #expect(try Data(contentsOf: copied) == bytes)
        #expect(try transferTestStat(copied).st_mode & mode_t(0o777) == mode_t(0o644))
        #expect(try transferTestStat(copied).st_flags & UInt32(UF_APPEND) != 0)
        #expect(try transferTestACL(copied) == childACL)
        let foreign = result.url.appendingPathComponent("0-Foreign.txt")
        #expect(try Data(contentsOf: foreign) == foreignBytes)
        #expect(try transferTestStat(foreign).st_mode & mode_t(0o777) == mode_t(0o640))
        #expect(try transferTestStat(foreign).st_flags & UInt32(UF_APPEND | UF_IMMUTABLE) == 0)
        #expect(try transferTestACL(foreign).contains(":allow:read"))
        #expect(!(try transferTestACL(foreign)).contains(":deny:delete"))
        #expect(try transferTestACL(tree) == parentACL)
        #expect(try transferTestACL(child) == childACL)
        #expect(try fixture.noStaging())
    }

    @Test
    func testPublishedReplacementReceivesNeitherCopiedACLNorFlags() async throws {
        let fixture = try TransferFixture()
        let source = fixture.source.appendingPathComponent("source.txt")
        let bytes = Data("original copied contents".utf8), replacement = Data("foreign synthetic replacement".utf8)
        try bytes.write(to: source)
        try setTransferTestACL(source)
        try #require(source.withUnsafeFileSystemRepresentation { chflags($0!, UInt32(UF_APPEND)) } == 0)
        let displaced = fixture.destination.appendingPathComponent("displaced.txt")
        let service = LocalFileTransfers(afterCommit: { destination in
            do {
                try FileManager.default.moveItem(at: destination, to: displaced)
                try replacement.write(to: destination, options: .withoutOverwriting)
                try setTransferTestACL(destination, "everyone allow read")
            } catch { Issue.record("Could not inject postcommit replacement: \(error)") }
        })
        let result = try await service.transfer(fixture.item("source.txt"), from: fixture.context(fixture.source),
            to: fixture.context(fixture.destination), name: "result.txt", kind: .copy,
            control: TransferControl(), onProgress: { _ in })
        #expect(result.warning != nil)
        #expect(result.identity == nil)
        #expect(try Data(contentsOf: result.url) == replacement)
        #expect(try transferTestStat(result.url).st_flags & UInt32(UF_APPEND | UF_IMMUTABLE) == 0)
        #expect(!(try transferTestACL(result.url)).contains(":deny:delete"))
        #expect(try transferTestACL(result.url).contains(":allow:read"))
        #expect(try Data(contentsOf: displaced) == bytes)
        #expect(try transferTestACL(source).contains(":deny:delete"))
        #expect(try transferTestStat(source).st_flags & UInt32(UF_APPEND) != 0)
        #expect(try fixture.noStaging())
    }

    @Test
    func testACLReadableSourceRetainsRestrictivePOSIXModeAfterCopy() async throws {
        let fixture = try TransferFixture()
        let source = fixture.source.appendingPathComponent("acl-readable.txt")
        let bytes = Data("readable through ACL".utf8)
        try bytes.write(to: source)
        try setTransferTestACL(source, "user:\(NSUserName()) allow read,readattr,readextattr,readsecurity")
        try #require(source.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o200)) } == 0)
        let sourceACL = try transferTestACL(source)
        let result = try await transfer("acl-readable.txt", fixture: fixture, kind: .copy)
        #expect(result.warning == nil)
        #expect(try transferTestStat(result.url).st_mode & mode_t(0o777) == mode_t(0o200))
        #expect(try transferTestACL(result.url) == sourceACL)
        #expect(try Data(contentsOf: result.url) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try fixture.noStaging())
    }

    @Test
    func testReplacingStagedPathCannotBeAcceptedAsMetadataIdentityChange() async throws {
        let fixture = try TransferFixture()
        let data = Data(repeating: 0x61, count: 1024 * 1024)
        try data.write(to: fixture.source.appendingPathComponent("source.bin"))
        let destinationRoot = fixture.destination
        let replacement = Data("replacement staging entry must survive".utf8)
        let probe = TransferProgressProbe(onFirstPositive: {
            guard let name = try? FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
                .first(where: { $0.hasPrefix(".explorer-transfer-") }) else { return }
            let stage = destinationRoot.appendingPathComponent(name, isDirectory: true)
            let payload = stage.appendingPathComponent("payload")
            do {
                try FileManager.default.moveItem(at: payload, to: stage.appendingPathComponent("displaced"))
                try replacement.write(to: payload, options: .withoutOverwriting)
                try setTransferTestACL(payload)
            } catch { Issue.record("Could not inject the bounded staging replacement: \(error)") }
        })
        do {
            _ = try await LocalFileTransfers().transfer(fixture.item("source.bin"), from: fixture.context(fixture.source),
                to: fixture.context(fixture.destination), name: "result.bin", kind: .copy, control: TransferControl(), onProgress: { probe.record($0) })
            Issue.record("A replacement staging entry was accepted")
        } catch FileTransferError.cleanupFailed(_, let stagingURL, _) {
            #expect(try Data(contentsOf: stagingURL.appendingPathComponent("payload")) == replacement)
            #expect(try transferTestACL(stagingURL.appendingPathComponent("payload")).contains(":deny:delete"), "Cleanup must not clear a replacement's ACL")
            #expect(FileManager.default.fileExists(atPath: stagingURL.appendingPathComponent("displaced").path))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("result.bin").path))
        #expect(hash(try Data(contentsOf: fixture.source.appendingPathComponent("source.bin"))) == hash(data))
    }

    @Test
    func testRecursivePackageCopyPreservesContentsAndDoesNotFollowDirectoryLink() async throws {
        let fixture = try TransferFixture()
        let package = fixture.source.appendingPathComponent("Demo.app", isDirectory: true)
        let nested = package.appendingPathComponent("Contents/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data("package contents".utf8)
        try bytes.write(to: nested.appendingPathComponent("data.bin"))
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("Cycle"), withDestinationURL: package)
        let item = try await fixture.item("Demo.app")
        let probe = TransferProgressProbe()
        let result = try await LocalFileTransfers().transfer(item, from: fixture.context(fixture.source), to: fixture.context(fixture.destination),
            name: "Copied.app", kind: .copy, control: TransferControl(), onProgress: { probe.record($0) })
        #expect(try Data(contentsOf: result.url.appendingPathComponent("Contents/Nested/data.bin")) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.url.appendingPathComponent("Cycle").path) == package.path)
        #expect(probe.values.last?.bytesCopied == Int64(bytes.count))
        #expect(try Data(contentsOf: nested.appendingPathComponent("data.bin")) == bytes)
        #expect(try fixture.noStaging())
    }

    @Test
    func testSymbolicLinkCopyAndMovePreserveTargetTextAndTargetBytes() async throws {
        let fixture = try TransferFixture()
        let target = fixture.root.appendingPathComponent("target.txt")
        let bytes = Data("untouched target".utf8)
        try bytes.write(to: target)
        let link = fixture.source.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let copy = try await transfer("Link", fixture: fixture, kind: .copy, name: "Copied Link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.url.path) == target.path)
        let move = try await transfer("Link", fixture: fixture, kind: .move, name: "Moved Link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: move.url.path) == target.path)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test
    func testCollisionsIncludingDanglingLinksNeverOverwriteOrLeaveStage() async throws {
        let fixture = try TransferFixture()
        let source = fixture.source.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let destination = fixture.destination.appendingPathComponent("existing.txt")
        try Data("destination".utf8).write(to: destination)
        let dangling = fixture.destination.appendingPathComponent("dangling")
        let target = fixture.root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: target)
        try FileManager.default.createDirectory(at: fixture.destination.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        for kind in [TransferKind.copy, .move] {
            for name in ["existing.txt", "dangling", "Folder"] {
                do { _ = try await transfer("source.txt", fixture: fixture, kind: kind, name: name); Issue.record("Collision accepted") }
                catch FileOperationError.collision(let actual) { #expect(actual == name) }
            }
        }
        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(try Data(contentsOf: destination) == Data("destination".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == target.path)
        #expect(try fixture.noStaging())
    }

    @Test
    func testLatePublicationCollisionCleansStageAndPreservesCompletedDestination() async throws {
        let fixture = try TransferFixture()
        let source = fixture.source.appendingPathComponent("source.txt")
        try Data("copied source bytes".utf8).write(to: source)
        let destination = fixture.destination.appendingPathComponent("result.txt")
        let probe = TransferProgressProbe(onFirstPositive: { try? Data("concurrent destination".utf8).write(to: destination, options: .withoutOverwriting) })
        do {
            _ = try await LocalFileTransfers().transfer(fixture.item("source.txt"), from: fixture.context(fixture.source),
                to: fixture.context(fixture.destination), name: "result.txt", kind: .copy, control: TransferControl(), onProgress: { probe.record($0) })
            Issue.record("Late collision overwrote the destination")
        } catch FileOperationError.collision(let name) { #expect(name == "result.txt") }
        #expect(try Data(contentsOf: destination) == Data("concurrent destination".utf8))
        #expect(try Data(contentsOf: source) == Data("copied source bytes".utf8))
        #expect(try fixture.noStaging())
    }

    @Test
    func testStaleSourceAndDestinationRootAreRejected() async throws {
        let fixture = try TransferFixture()
        let source = fixture.source.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let item = try await fixture.item("source.txt")
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        try FileManager.default.moveItem(at: source, to: fixture.source.appendingPathComponent("preserved.txt"))
        try Data("replacement".utf8).write(to: source)
        do {
            _ = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "result.txt", kind: .copy, control: TransferControl(), onProgress: { _ in })
            Issue.record("Stale source accepted")
        } catch FileOperationError.staleSource {}
        let fresh = try await fixture.item("source.txt")
        try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("OldDestination"))
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        do {
            _ = try await LocalFileTransfers().transfer(fresh, from: from, to: to, name: "result.txt", kind: .copy, control: TransferControl(), onProgress: { _ in })
            Issue.record("Stale destination accepted")
        } catch FileOperationError.staleParent {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try Data(contentsOf: source) == Data("replacement".utf8))
    }

    @Test
    func testSameItemMoveAndCopyIntoOwnSubtreeAreRejected() async throws {
        let fixture = try TransferFixture()
        let tree = fixture.source.appendingPathComponent("Tree/Child", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let item = try await fixture.item("Tree")
        let from = try await fixture.context(fixture.source)
        do {
            _ = try await LocalFileTransfers().transfer(item, from: from, to: from, name: "Tree", kind: .move, control: TransferControl(), onProgress: { _ in })
            Issue.record("Same identity move accepted")
        } catch FileOperationError.unsupported {}
        for destination in [tree, tree.deletingLastPathComponent()] {
            do {
                _ = try await LocalFileTransfers().transfer(item, from: from, to: fixture.context(destination), name: "Recursive", kind: .copy,
                    control: TransferControl(), onProgress: { _ in })
                Issue.record("Recursive destination accepted")
            } catch FileOperationError.unsupported {}
            #expect(try fixture.noStaging(at: destination))
        }
    }

    @Test
    func testDestinationMovedIntoSourceAfterPreflightIsNeverTraversed() async throws {
        let fixture = try TransferFixture()
        let tree = fixture.source.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("source bytes".utf8).write(to: tree.appendingPathComponent("source.txt"))
        let item = try await fixture.item("Tree")
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let oldDestination = fixture.destination
        let relocated = tree.appendingPathComponent("Destination", isDirectory: true)
        do {
            _ = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "result", kind: .copy, control: TransferControl(), onProgress: { progress in
                if progress.bytesCopied == 0 { try? FileManager.default.moveItem(at: oldDestination, to: relocated) }
            })
            Issue.record("Destination subtree was accepted")
        } catch FileOperationError.unsupported(let reason) {
            #expect(reason.contains("destination") || reason.contains("staging"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: relocated.path).isEmpty)
        #expect(try Data(contentsOf: tree.appendingPathComponent("source.txt")) == Data("source bytes".utf8))
        #expect(try fixture.noStaging(at: relocated))
    }

    @Test
    func testSpecialNodeIsRefusedWithoutBlockingOrTouchingSource() async throws {
        let fixture = try TransferFixture()
        let fifo = fixture.source.appendingPathComponent("pipe")
        try #require(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) } == 0)
        for kind in [TransferKind.copy, .move] {
            do { _ = try await transfer("pipe", fixture: fixture, kind: kind); Issue.record("Special node accepted") }
            catch FileOperationError.unsupported {}
        }
        #expect(FileManager.default.fileExists(atPath: fifo.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test
    func testPauseAtFirstActualBytesThenResumeCompletesWithoutPublishingEarly() async throws {
        let fixture = try TransferFixture()
        let data = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        try data.write(to: fixture.source.appendingPathComponent("large.bin"))
        let item = try await fixture.item("large.bin")
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let control = TransferControl()
        let probe = TransferProgressProbe(onFirstPositive: { control.pause() })
        let task = Task { try await LocalFileTransfers().transfer(item, from: from, to: to, name: "large.bin", kind: .copy, control: control, onProgress: { probe.record($0) }) }
        defer { control.cancel(); task.cancel() }
        #expect(try await firstPositive(probe) > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("large.bin").path))
        control.resume()
        let result = try await task.value
        #expect(hash(try Data(contentsOf: result.url)) == hash(data))
        #expect(probe.values.last?.bytesCopied == Int64(data.count))
        #expect(try fixture.noStaging())
    }

    @Test
    func testCancelWhilePausedRemovesOnlyUnpublishedTopItem() async throws {
        let fixture = try TransferFixture()
        try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: fixture.source.appendingPathComponent("large.bin"))
        let existing = fixture.destination.appendingPathComponent("earlier.txt")
        try Data("earlier completed item".utf8).write(to: existing)
        let item = try await fixture.item("large.bin")
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let control = TransferControl()
        let probe = TransferProgressProbe(onFirstPositive: { control.pause() })
        let task = Task { try await LocalFileTransfers().transfer(item, from: from, to: to, name: "cancelled.bin", kind: .copy, control: control, onProgress: { probe.record($0) }) }
        defer { control.cancel(); task.cancel() }
        #expect(try await firstPositive(probe) > 0)
        control.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transfer succeeded") } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("cancelled.bin").path))
        #expect(try Data(contentsOf: existing) == Data("earlier completed item".utf8))
        #expect(try fixture.noStaging())
        #expect(FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test
    func testCancelBeforeCopyCreatesNothingAndAfterCommitStillReportsSuccess() async throws {
        let fixture = try TransferFixture()
        try Data("bytes".utf8).write(to: fixture.source.appendingPathComponent("source.txt"))
        let item = try await fixture.item("source.txt")
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let cancelled = TransferControl()
        cancelled.cancel()
        do {
            _ = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "cancelled", kind: .copy, control: cancelled, onProgress: { _ in })
            Issue.record("Pre-cancelled transfer succeeded")
        } catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        let control = TransferControl()
        let service = LocalFileTransfers(afterCommit: { _ in control.cancel(); withUnsafeCurrentTask { $0?.cancel() } })
        let result = try await service.transfer(item, from: from, to: to, name: "committed", kind: .copy, control: control, onProgress: { _ in })
        #expect(try Data(contentsOf: result.url) == Data("bytes".utf8))
        #expect(result.identity != nil)
        #expect(try fixture.noStaging())
    }

    @Test
    func testConcurrentCopiesPublishAtMostOneItemAndNeverOverwriteWinner() async throws {
        let fixture = try TransferFixture()
        for name in ["first.txt", "second.txt"] { try Data(name.utf8).write(to: fixture.source.appendingPathComponent(name)) }
        let items = try await LocalDirectoryLoader().contents(of: fixture.source)
        let from = try await fixture.context(fixture.source), to = try await fixture.context(fixture.destination)
        let winners = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for item in items {
                group.addTask {
                    do {
                        _ = try await LocalFileTransfers().transfer(item, from: from, to: to, name: "winner.txt", kind: .copy,
                            control: TransferControl(), onProgress: { _ in })
                        return item.name
                    } catch { return nil }
                }
            }
            var winners: [String] = []
            for await result in group { if let result { winners.append(result) } }
            return winners
        }
        let winner = try #require(winners.first)
        #expect(winners.count == 1)
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("winner.txt")) == Data(winner.utf8))
        #expect(try fixture.noStaging())
        for item in items { #expect(try Data(contentsOf: item.url) == Data(item.name.utf8)) }
    }

    @Test
    func testUnicodeNamesAndDirectoryMovePreserveEnumeratedIdentity() async throws {
        let fixture = try TransferFixture()
        let folder = fixture.source.appendingPathComponent("Café Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("東京.txt"))
        let item = try await fixture.item("Café Folder")
        let result = try await transfer("Café Folder", fixture: fixture, kind: .move, name: "Café Moved")
        let refreshed = try await fixture.item("Café Moved", at: fixture.destination)
        #expect(result.url == refreshed.url)
        #expect(result.identity == item.identity)
        #expect(try Data(contentsOf: result.url.appendingPathComponent("東京.txt")) == Data("nested".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    private func transfer(_ name: String, fixture: TransferFixture, kind: TransferKind, name destinationName: String? = nil) async throws -> FileOperationResult {
        try await LocalFileTransfers().transfer(fixture.item(name), from: fixture.context(fixture.source), to: fixture.context(fixture.destination),
            name: destinationName ?? name, kind: kind, control: TransferControl(), onProgress: { _ in })
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func firstPositive(_ probe: TransferProgressProbe) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask {
                for await value in probe.firstPositive { return value }
                throw CancellationError()
            }
            group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw POSIXError(.ETIMEDOUT) }
            defer { group.cancelAll() }
            let value = try await group.next()
            return try #require(value)
        }
    }
}
