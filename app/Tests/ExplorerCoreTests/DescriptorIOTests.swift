import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite(.serialized) struct DescriptorIOTests {
    @Test func positionalWritePreservesOtherBytesAndDescriptorOffset() throws {
        let fixture = try DescriptorFixture()
        let url = fixture.root.appendingPathComponent("data")
        try Data("0123456789".utf8).write(to: url)
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        try file.seek(toOffset: 7)
        try DescriptorIO.writeAll(Data("abc".utf8), to: file.fileDescriptor, at: 2)
        try DescriptorIO.writeAll(Data(), to: file.fileDescriptor, at: 0)
        #expect(try file.offset() == 7)
        #expect(try Data(contentsOf: url) == Data("01abc56789".utf8))
    }

    @Test func unrepresentableWriteExtentRefusesBeforeChangingFile() throws {
        let fixture = try DescriptorFixture(), original = Data("original".utf8)
        let url = fixture.root.appendingPathComponent("data")
        try original.write(to: url)
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        for offset in [UInt64(off_t.max), UInt64.max] {
            do {
                try DescriptorIO.writeAll(Data([1]), to: file.fileDescriptor, at: offset)
                Issue.record("An unrepresentable write extent was accepted.")
            } catch let error as POSIXError { #expect(error.code == .EFBIG) }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try file.offset() == 0)
    }

    @Test func repeatedAndNestedEnumerationLeavesCallerCursorIndependent() throws {
        let fixture = try DescriptorFixture()
        for name in ["a", "b", ".hidden"] { try Data().write(to: fixture.root.appendingPathComponent(name)) }
        let offset = lseek(fixture.descriptor, 0, SEEK_CUR)
        try #require(offset >= 0)
        var outer: [String] = []
        try DescriptorIO.forEachDirectoryEntry(in: fixture.descriptor) { name in
            outer.append(name)
            let nested = try ContentFileIO.names(fixture.descriptor)
            #expect(Set(nested) == ["a", "b", ".hidden"])
        }
        #expect(Set(outer) == ["a", "b", ".hidden"])
        #expect(lseek(fixture.descriptor, 0, SEEK_CUR) == offset)
        #expect(Set(try LocalFileTransfers.directoryNames(in: fixture.descriptor)) == Set(outer))
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func callbackFailurePropagatesAndKeepsCallerUsable() throws {
        let fixture = try DescriptorFixture()
        try Data().write(to: fixture.root.appendingPathComponent("entry"))
        enum Stopped: Error { case callback }
        do {
            try DescriptorIO.forEachDirectoryEntry(in: fixture.descriptor) { _ in throw Stopped.callback }
            Issue.record("The callback failure was swallowed.")
        } catch Stopped.callback {}
        #expect(try ContentFileIO.names(fixture.descriptor) == ["entry"])
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingEnumerationUsesTheGivenDescriptorAndClosesIt() throws {
        let fixture = try DescriptorFixture()
        for name in ["a", ".hidden", "日本語"] { try Data("entry".utf8).write(to: fixture.root.appendingPathComponent(name)) }
        let owned = try ownedCursor(fixture)
        var names: [String] = []
        try DescriptorIO.forEachDirectoryEntry(consuming: owned) { name, borrowed in
            #expect(borrowed == owned)
            var value = stat()
            #expect(name.withCString { fstatat(borrowed, $0, &value, AT_SYMLINK_NOFOLLOW) } == 0)
            #expect(value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            names.append(name)
        }
        expectConsumed(owned)
        #expect(Set(names) == ["a", ".hidden", "日本語"])
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingCallbackFailureClosesBeforePropagating() throws {
        let fixture = try DescriptorFixture()
        try Data().write(to: fixture.root.appendingPathComponent("entry"))
        let owned = try ownedCursor(fixture)
        enum Stopped: Error { case callback }
        var failure: Error?
        do {
            try DescriptorIO.forEachDirectoryEntry(consuming: owned) { _, _ in throw Stopped.callback }
        } catch { failure = error }
        expectConsumed(owned)
        #expect(failure is Stopped)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingCancellationAfterAnEntryClosesAndKeepsCancellationType() throws {
        let fixture = try DescriptorFixture(), control = TransferControl()
        for name in ["a", "b"] { try Data().write(to: fixture.root.appendingPathComponent(name)) }
        let owned = try ownedCursor(fixture)
        var visited = 0
        var failure: Error?
        do {
            try DescriptorIO.forEachDirectoryEntry(consuming: owned, checkpoint: { try control.checkpoint() }) { _, _ in
                visited += 1
                control.cancel()
            }
        } catch { failure = error }
        expectConsumed(owned)
        #expect(failure is CancellationError)
        #expect(visited == 1)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingRegularFileFailureClosesAndPreservesENOTDIR() throws {
        let fixture = try DescriptorFixture()
        let url = fixture.root.appendingPathComponent("regular")
        let original = Data("unchanged".utf8)
        try original.write(to: url)
        let owned = openat(fixture.descriptor, "regular", O_RDONLY | O_CLOEXEC)
        try #require(owned >= 0)
        var failure: Error?
        do {
            try DescriptorIO.forEachDirectoryEntry(consuming: owned) { _, _ in Issue.record("A regular file produced a directory entry") }
        } catch { failure = error }
        expectConsumed(owned)
        #expect((failure as? POSIXError)?.code == .ENOTDIR)
        #expect(try Data(contentsOf: url) == original)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingDecoderFailureClosesAndPreservesItsType() throws {
        let fixture = try DescriptorFixture()
        let owned = try ownedCursor(fixture)
        let invalid: [UInt8] = [0xc3, 0x28]
        var failure: Error?
        do {
            // Exercise the real decoder's failure and owned cleanup without
            // requiring APFS to store an invalid UTF-8 filename.
            try DescriptorIO.forEachDirectoryEntry(consuming: owned, checkpoint: {
                _ = try invalid.withUnsafeBufferPointer { try DescriptorIO.decodeDirectoryName($0) }
            }) { _, _ in Issue.record("A failed decoding checkpoint visited an entry") }
        } catch { failure = error }
        expectConsumed(owned)
        #expect(failure is DescriptorIO.DirectoryEntryError)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func consumingNestedTraversalUsesOnePassedDescriptorPerDepth() throws {
        let fixture = try DescriptorFixture()
        var leaf = fixture.root
        for _ in 0..<12 {
            leaf.appendPathComponent("level", isDirectory: true)
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        }
        try Data("leaf".utf8).write(to: leaf.appendingPathComponent("end"))
        var deepest = 0
        var visited = 0
        func enumerate(_ owned: Int32, depth: Int) throws {
            deepest = max(deepest, depth)
            var failure: Error?
            do {
                try DescriptorIO.forEachDirectoryEntry(consuming: owned) { name, borrowed in
                    #expect(borrowed == owned, "The consuming overload must not open a second cursor at each level")
                    visited += 1
                    var value = stat()
                    try #require(name.withCString { fstatat(borrowed, $0, &value, AT_SYMLINK_NOFOLLOW) } == 0)
                    if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        let child = name.withCString { openat(borrowed, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                        try #require(child >= 0)
                        try enumerate(child, depth: depth + 1)
                        #expect(fcntl(borrowed, F_GETFD) >= 0, "Returning from a child must retain its parent's cursor")
                    } else {
                        #expect(name == "end" && value.st_size == 4)
                    }
                }
            } catch { failure = error }
            expectConsumed(owned)
            if let failure { throw failure }
        }
        try enumerate(ownedCursor(fixture), depth: 1)
        #expect(deepest == 13 && visited == 13)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
    }

    @Test func transferEnumerationPreservesCancellationTypeAndCallerDescriptor() throws {
        let fixture = try DescriptorFixture(), control = TransferControl()
        for index in 0..<8 { try Data().write(to: fixture.root.appendingPathComponent("entry-\(index)")) }
        var checkpoints = 0
        do {
            _ = try LocalFileTransfers.directoryNames(in: fixture.descriptor, checkpoint: {
                checkpoints += 1
                if checkpoints == 4 { control.cancel() }
                try control.checkpoint()
            })
            Issue.record("Enumeration cancellation was swallowed.")
        } catch is CancellationError {}
        #expect(checkpoints == 4)
        #expect(fcntl(fixture.descriptor, F_GETFD) >= 0)
        #expect(try LocalFileTransfers.directoryNames(in: fixture.descriptor).count == 8)
    }

    @Test func strictNamesKeepExactUTF8AndCallersMapOnlyDecodingFailure() throws {
        for bytes in [Array("caf\u{e9}".utf8), Array("cafe\u{301}".utf8)] {
            let decoded = try bytes.withUnsafeBufferPointer { try DescriptorIO.decodeDirectoryName($0) }
            #expect(Array(decoded.utf8) == bytes)
        }
        let invalid: [UInt8] = [0xc3, 0x28]
        func refuseInvalidName() throws {
            _ = try invalid.withUnsafeBufferPointer { try DescriptorIO.decodeDirectoryName($0) }
        }
        #expect(throws: DescriptorIO.DirectoryEntryError.self) { try refuseInvalidName() }
        let fixture = try DescriptorFixture()
        // Drive the real decoder through each wrapper's callback error boundary;
        // a synthetic invalid filename need not be supported by the host volume.
        #expect(throws: ItemContentError.unsupportedType) {
            _ = try ContentFileIO.names(fixture.descriptor, checkpoint: refuseInvalidName)
        }
        #expect(throws: FileOperationError.unsupported("A filename is not valid UTF-8 and cannot be copied safely.")) {
            _ = try LocalFileTransfers.directoryNames(in: fixture.descriptor, checkpoint: refuseInvalidName)
        }
        #expect(throws: CancellationError.self) {
            _ = try ContentFileIO.names(fixture.descriptor, checkpoint: { throw CancellationError() })
        }
    }

    @Test func aclCallersClearSameACLWithoutChangingModeOrIdentity() throws {
        let fixture = try DescriptorFixture()
        var observations: [String] = []
        for useContent in [true, false] {
            let url = fixture.root.appendingPathComponent(useContent ? "content" : "transfer")
            try Data("payload".utf8).write(to: url)
            let file = try FileHandle(forUpdating: url)
            defer { try? file.close() }
            try #require(fchmod(file.fileDescriptor, 0o640) == 0)
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "everyone allow read", url.path]
            try command.run(); command.waitUntilExit()
            try #require(command.terminationStatus == 0)
            let before = try ContentFileIO.sample(file.fileDescriptor)
            try #require(try aclText(file.fileDescriptor).contains(":allow:read"))
            if useContent { try ContentFileIO.clearACL(file.fileDescriptor) }
            else { try DeferredCopyMetadata.clearAccessControl(file.fileDescriptor) }
            let after = try ContentFileIO.sample(file.fileDescriptor)
            let text = try aclText(file.fileDescriptor)
            #expect(!text.contains(":allow:"))
            #expect(after.st_mode == before.st_mode && after.st_mode & 0o777 == 0o640)
            #expect(LocalFileIdentity.fromStat(after) == LocalFileIdentity.fromStat(before))
            #expect(try Data(contentsOf: url) == Data("payload".utf8))
            observations.append(text)
        }
        #expect(observations.count == 2 && observations[0] == observations[1])
    }

    @Test func aclCallersKeepOriginalPOSIXErrorType() {
        for useContent in [true, false] {
            do {
                if useContent { try ContentFileIO.clearACL(-1) }
                else { try DeferredCopyMetadata.clearAccessControl(-1) }
                Issue.record("Invalid descriptor unexpectedly accepted ACL mutation.")
            } catch let error as POSIXError { #expect(error.code == .EBADF) }
            catch { Issue.record("ACL caller changed its error type: \(error)") }
        }
    }

    private func aclText(_ descriptor: Int32) throws -> String {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return "" }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw POSIXError(.EIO) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    private func ownedCursor(_ fixture: DescriptorFixture) throws -> Int32 {
        let descriptor = openat(fixture.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private func expectConsumed(_ descriptor: Int32) {
        // Serialized tests inspect immediately, before opening another file
        // could reuse this descriptor number. No second owner closes it here.
        let result = fcntl(descriptor, F_GETFD)
        let error = errno
        #expect(result == -1 && error == EBADF)
    }
}

private final class DescriptorFixture {
    let root: URL
    let descriptor: Int32
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-descriptor-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        descriptor = root.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { try? FileManager.default.removeItem(at: root); throw POSIXError(.EIO) }
    }
    deinit { close(descriptor); try? FileManager.default.removeItem(at: root) }
}
