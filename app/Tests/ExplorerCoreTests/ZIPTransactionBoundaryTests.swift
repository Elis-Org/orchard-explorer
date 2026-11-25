import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPTransactionBoundaryTests {
    @Test func provenInsufficientSpaceRefusesBeforeCreatingStage() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a", contents: Data([1]))]), context = try await fixture.context()
        var hooks = ArchiveMutationHooks(); hooks.availableSpace = { _ in 1 }
        await #expect(throws: POSIXError(.ENOSPC)) {
            try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func partialMetadataCopyFailureReconcilesBirthAndCleansOnlyCandidate() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a", contents: Data([1]))])
        let context = try await fixture.context()
        var hooks = ArchiveMutationHooks()
        hooks.copyMetadata = { source, candidate in
            guard fcopyfile(source, candidate, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { return -1 }
            errno = ENOSPC; return -1
        }
        await #expect(throws: POSIXError(.ENOSPC)) {
            try await LocalArchiveOperations(hooks: hooks).modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func changedCandidatePayloadIsRejectedBeforeSwap() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a", contents: Data([1]))])
        let context = try await fixture.context()
        var hooks = ArchiveMutationHooks()
        hooks.copyMetadata = { source, candidate in
            guard fcopyfile(source, candidate, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { return -1 }
            var byte: UInt8 = 99
            return pwrite(candidate, &byte, 1, 31) == 1 ? 0 : -1
        }
        await #expect(throws: ZIPListingError.corrupt) {
            try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func parentFlushFailureReturnsCommittedWarningAndRetainsOldArchive() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        var hooks = ArchiveMutationHooks(); hooks.flushParent = { _ in errno = EIO; return -1 }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.revision != nil && result.warning != nil && result.verifiedDestination == nil)
        let receipt = try #require(result.recovery), stage = try #require(receipt.retainedURLs.first { $0 != fixture.url })
        #expect(try Data(contentsOf: stage.appendingPathComponent("payload")) == fixture.bytes)
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.first?.components == ["b"])
    }

    @Test func failedRollbackKeepsOriginalAndPublishedCandidateWithRecoveryLocations() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        let gate = SwapGate()
        var hooks = ArchiveMutationHooks()
        hooks.afterSwap = { _, _ in throw ArchiveOperationError.changed }
        hooks.swap = { first, a, second, b in
            if gate.next() > 1 { errno = EIO; return -1 }
            return renameatx_np(first, a, second, b, UInt32(RENAME_SWAP))
        }
        do {
            _ = try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
            Issue.record("Failed rollback must report retained artifacts.")
        } catch ArchiveOperationError.recoveryRequired(let receipt) {
            let stage = try #require(receipt.retainedURLs.first { $0 != fixture.url })
            #expect(try Data(contentsOf: stage.appendingPathComponent("payload")) == fixture.bytes)
            #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.first?.components == ["b"])
        }
    }

    @Test func unexpectedStageChildIsPreservedTogetherWithVerifiedOldCopy() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        let unexpected = Data("unexpected sibling".utf8)
        var hooks = ArchiveMutationHooks()
        hooks.afterSwap = { _, displaced in try unexpected.write(to: displaced.deletingLastPathComponent().appendingPathComponent("unknown")) }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.warning != nil && result.verifiedDestination == nil)
        let receipt = try #require(result.recovery), stage = try #require(receipt.retainedURLs.first { $0 != fixture.url })
        #expect(try Data(contentsOf: stage.appendingPathComponent("unknown")) == unexpected)
        #expect(try Data(contentsOf: stage.appendingPathComponent("payload")) == fixture.bytes)
    }

    @Test func archiveOuterPermissionsOwnershipACLAndOriginAttributesSurviveMutation() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")])
        #expect(chmod(fixture.url.path, 0o640) == 0)
        let chmodACL = Process(); chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "everyone allow read", fixture.url.path]
        chmodACL.standardOutput = FileHandle.nullDevice; chmodACL.standardError = FileHandle.nullDevice
        try chmodACL.run(); chmodACL.waitUntilExit(); #expect(chmodACL.terminationStatus == 0)
        let quarantine = Data("0081;00000000;MaxplorerTests;".utf8)
        let origin = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/synthetic.zip"], format: .binary, options: 0)
        for (name, value) in [("com.apple.quarantine", quarantine), ("com.apple.metadata:kMDItemWhereFroms", origin)] {
            #expect(value.withUnsafeBytes { setxattr(fixture.url.path, name, $0.baseAddress, $0.count, 0, 0) } == 0)
        }
        var before = stat(), after = stat()
        #expect(fstatat(AT_FDCWD, fixture.url.path, &before, 0) == 0)
        let capturedOrigin = try ZIPFileReader(url: fixture.url).originAttributes()
        #expect(capturedOrigin.quarantine != nil && capturedOrigin.whereFroms == origin)
        let acl = try aclText(fixture.url), context = try await fixture.context()
        let observation = NativeOriginObservation()
        var hooks = ArchiveMutationHooks()
        let nativeCopy = hooks.copyMetadata
        hooks.copyMetadata = { source, destination in
            let result = nativeCopy(source, destination)
            guard result == 0 else { return result }
            do {
                observation.record(source: try ZIPMemberOrigins.capture(from: source, budget: ZIPOriginBudget()),
                                   output: try ZIPMemberOrigins.capture(from: destination, budget: ZIPOriginBudget()))
                return 0
            } catch { errno = EIO; return -1 }
        }
        _ = try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(fstatat(AT_FDCWD, fixture.url.path, &after, 0) == 0)
        #expect(after.st_mode & 0o777 == before.st_mode & 0o777)
        #expect(after.st_uid == before.st_uid && after.st_gid == before.st_gid)
        #expect(try aclText(fixture.url) == acl)
        let attributes = try ZIPFileReader(url: fixture.url).originAttributes()
        let native = try #require(observation.values)
        #expect(native.source == capturedOrigin)
        #expect(native.output.quarantine != nil)
        #expect(attributes == native.output)
        #expect(attributes.whereFroms == capturedOrigin.whereFroms)
    }

    @Test func candidateOriginChangedAfterNativeCopyIsRefusedBeforeSwap() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, candidate in
            let value = Data("changed provenance".utf8)
            guard value.withUnsafeBytes({ setxattr(candidate.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
        }
        await #expect(throws: ArchiveOperationError.changed) {
            try await LocalArchiveOperations(hooks: hooks).modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
}

private final class SwapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
}

private final class NativeOriginObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: (source: ZIPOriginAttributes, output: ZIPOriginAttributes)?
    var values: (source: ZIPOriginAttributes, output: ZIPOriginAttributes)? {
        lock.lock(); defer { lock.unlock() }; return captured
    }
    func record(source: ZIPOriginAttributes, output: ZIPOriginAttributes) {
        lock.lock(); defer { lock.unlock() }; captured = (source, output)
    }
}
