import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPCopiedDestinationTests {
    @Test(arguments: ["missing", "truncated", "same-size", "symlink", "fifo", "replacement", "root", "parent"])
    func finalDestinationChangeRetainsCompleteSource(_ change: String) async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let destination = try fixture.claim(), leaf = fixture.published.appendingPathComponent("nested/leaf")
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in
            switch change {
            case "missing": try FileManager.default.removeItem(at: leaf)
            case "truncated": try Data([1]).write(to: leaf)
            case "same-size":
                let fd = open(leaf.path, O_WRONLY | O_CLOEXEC); guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
                let bytes: [UInt8] = [9, 9, 9]
                guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == 3 else { throw POSIXError(.EIO) }
            case "symlink":
                try FileManager.default.removeItem(at: leaf)
                try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: fixture.archive.url)
            case "fifo":
                try FileManager.default.removeItem(at: leaf)
                guard mkfifo(leaf.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            case "replacement":
                try FileManager.default.moveItem(at: leaf, to: leaf.appendingPathExtension("saved"))
                try Data([9, 9, 9]).write(to: leaf)
            case "root":
                try FileManager.default.moveItem(at: fixture.published, to: fixture.destination.appendingPathComponent("saved"))
                try FileManager.default.createDirectory(at: fixture.published, withIntermediateDirectories: false)
            case "parent":
                try FileManager.default.moveItem(at: fixture.destination, to: fixture.archive.root.appendingPathComponent("saved-parent"))
                try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
            default: throw POSIXError(.EINVAL)
            }
        }
        await #expect(throws: (any Error).self) {
            try await LocalArchiveOperations(hooks: hooks).modify([
                .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: destination)
            ], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.archive.url) == fixture.archive.bytes)
        #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func keepBothFolderWithExtraFilesAndChangedDirectoryTimesIsValid() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context(), destination = try fixture.claim()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in
            try Data([8]).write(to: fixture.published.appendingPathComponent(".DS_Store"))
            // APFS may lower birth time when mtime predates birth. Exercise an
            // ordinary timestamp-only change without replacing captured identity.
            let before = try copiedIdentity(fixture.published)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fixture.published.path)
            #expect(try copiedIdentity(fixture.published) == before)
            #expect(before == destination.identity)
        }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([
            .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: destination)
        ], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.revision != nil)
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.archive.url)).records.isEmpty)
        #expect(try Data(contentsOf: fixture.published.appendingPathComponent("nested/leaf")) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: fixture.published.appendingPathComponent("empty").path))
        #expect(FileManager.default.fileExists(atPath: fixture.published.appendingPathComponent(".DS_Store").path))
    }

    @Test(arguments: ["bad-name", "wrong-root", "wrong-parent", "stale-source", "cancelled"])
    func invalidClaimNeverRemovesSource(_ failure: String) async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let real = try fixture.claim()
        let claim = ArchiveCopiedDestination(parent: failure == "wrong-parent" ? FileOperationContext(directoryURL: fixture.destination, directoryIdentity: real.identity) : real.parent,
            name: failure == "bad-name" ? "../escaped" : real.name,
            identity: failure == "wrong-root" ? real.parent.directoryIdentity : real.identity)
        let control = TransferControl()
        var hooks = ArchiveMutationHooks()
        if failure == "cancelled" { hooks.beforeSwap = { _, _ in control.cancel() } }
        if failure == "stale-source" { try Data([99]).write(to: fixture.archive.url) }
        let expected = try Data(contentsOf: fixture.archive.url)
        await #expect(throws: (any Error).self) {
            try await LocalArchiveOperations(hooks: hooks).modify([
                .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: claim)
            ], in: context, control: control, onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.archive.url) == expected)
        #expect(try Data(contentsOf: fixture.published.appendingPathComponent("nested/leaf")) == Data([1, 2, 3]))
    }

    @Test func oneFailedWitnessRetainsEveryMemberInTheRemovalBatch() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context(["folder"])
        let directory = fixture.published.appendingPathComponent("nested")
        let parent = FileOperationContext(directoryURL: fixture.published, directoryIdentity: try copiedIdentity(fixture.published))
        let empty = fixture.published.appendingPathComponent("empty")
        let first = ArchiveCopiedDestination(parent: parent, name: "empty", identity: try copiedIdentity(empty))
        let second = ArchiveCopiedDestination(parent: parent, name: "nested", identity: try copiedIdentity(directory))
        var hooks = ArchiveMutationHooks(); hooks.beforeSwap = { _, _ in try FileManager.default.removeItem(at: directory.appendingPathComponent("leaf")) }
        await #expect(throws: (any Error).self) {
            try await LocalArchiveOperations(hooks: hooks).modify([
                .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder", "empty"]), revision: context.revision), destination: first),
                .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder", "nested"]), revision: context.revision), destination: second)
            ], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.archive.url) == fixture.archive.bytes)
        #expect(FileManager.default.fileExists(atPath: empty.path))
    }

    @Test func bytesEntriesAndDeadlineAreChargedToTheTransaction() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let reader = try ZIPFileReader(url: fixture.archive.url), manifest = try ZIPArchiveManifest.read(from: reader)
        let edits: [ArchiveEdit] = try [.removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: fixture.claim())]
        #expect(throws: ZIPListingError.limitExceeded) {
            try ZIPCopiedDestinationVerification(edits: edits, context: context, manifest: manifest, maximumBytes: 2, checkpoint: {})
        }
        #expect(throws: ZIPListingError.limitExceeded) {
            try ZIPCopiedDestinationVerification(edits: edits, context: context, manifest: manifest, maximumEntries: 3, checkpoint: {})
        }
        let verifier = try ZIPCopiedDestinationVerification(edits: edits, context: context, manifest: manifest, checkpoint: {})
        #expect(throws: ArchiveOperationError.limitExceeded("deadline")) {
            try verifier.verify { throw ArchiveOperationError.limitExceeded("deadline") }
        }
        #expect(try Data(contentsOf: fixture.archive.url) == fixture.archive.bytes)
    }

    @Test func regularFileAndExplicitEmptyDirectoryCanBeRemovedAfterVerifiedCopy() async throws {
        let fixture = try CopiedZIPFixture()
        for components in [["folder", "nested", "leaf"], ["folder", "empty"]] {
            let context = try await fixture.archive.context(Array(components.dropLast()))
            let published = components.count == 3 ? fixture.published.appendingPathComponent("nested/leaf") : fixture.published.appendingPathComponent("empty")
            let claim = ArchiveCopiedDestination(parent: FileOperationContext(directoryURL: published.deletingLastPathComponent(), directoryIdentity: try copiedIdentity(published.deletingLastPathComponent())),
                name: published.lastPathComponent, identity: try copiedIdentity(published))
            _ = try await LocalArchiveOperations().modify([.removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(components), revision: context.revision), destination: claim)],
                in: context, control: TransferControl(), onProgress: { _ in })
            #expect(FileManager.default.fileExists(atPath: published.path))
        }
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.archive.url)).records.isEmpty)
    }

    @Test func archiveOriginChangedDuringDestinationReadRefusesBeforeExchange() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let edits: [ArchiveEdit] = try [.removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: fixture.claim())]
        let gate = CopiedVerificationGate()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in gate.arm() }
        let nativeSwap = hooks.swap
        hooks.swap = { first, name, second, other in gate.swapping(); return nativeSwap(first, name, second, other) }
        #expect(throws: (any Error).self) {
            _ = try ArchiveMutationTransaction.run(edits: edits, context: context, hooks: hooks, checkpoint: {
                if gate.changeOnce() {
                    let value = Data("changed during destination verification".utf8)
                    guard value.withUnsafeBytes({ setxattr(fixture.archive.url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
                }
            }, onProgress: { _ in })
        }
        #expect(gate.swapCount == 0)
        #expect(try Data(contentsOf: fixture.archive.url) == fixture.archive.bytes)
        #expect(try Data(contentsOf: fixture.published.appendingPathComponent("nested/leaf")) == Data([1, 2, 3]))
    }

    @Test func verificationAnnouncesCopyingAndCancellationNeverAnnouncesCommit() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let edits: [ArchiveEdit] = try [.removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: fixture.claim())]
        let gate = CopiedProgressGate()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in gate.arm() }
        let nativeSwap = hooks.swap
        hooks.swap = { first, name, second, other in gate.didSwap(); return nativeSwap(first, name, second, other) }
        #expect(throws: CancellationError.self) {
            _ = try ArchiveMutationTransaction.run(edits: edits, context: context, hooks: hooks, checkpoint: {
                if gate.isArmed {
                    #expect(gate.lastPhase == .copying, "The UI must remain cancellable during destination verification")
                    throw CancellationError()
                }
            }, onProgress: { gate.progress($0.phase) })
        }
        #expect(gate.swaps == 0)
        #expect(!gate.phases.contains(.finalizing))
        #expect(try Data(contentsOf: fixture.archive.url) == fixture.archive.bytes)
    }

    @Test func finalizingIsAnnouncedOnlyAfterSwapAndCallbackCancellationReportsCommit() async throws {
        let fixture = try CopiedZIPFixture(), context = try await fixture.archive.context()
        let gate = CopiedProgressGate(), control = TransferControl()
        var hooks = ArchiveMutationHooks()
        let nativeSwap = hooks.swap
        hooks.swap = { first, name, second, other in
            #expect(!gate.phases.contains(.finalizing), "No commit phase or callback belongs before exchange")
            let result = nativeSwap(first, name, second, other)
            if result == 0 { gate.didSwap() }
            return result
        }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([
            .removeAfterVerifiedCopy(source: ArchiveMemberTarget(location: fixture.archive.location(["folder"]), revision: context.revision), destination: fixture.claim())
        ], in: context, control: control, onProgress: { progress in
            gate.progress(progress.phase)
            if progress.phase == .finalizing {
                #expect(gate.swaps == 1)
                control.cancel()
            }
        })
        #expect(result.revision != nil && result.recovery == nil)
        #expect(gate.phases.filter { $0 == .finalizing }.count == 1)
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.archive.url)).records.isEmpty)
    }
}

private final class CopiedZIPFixture: @unchecked Sendable {
    let archive: ZIPOperationTestFixture
    let destination: URL
    let published: URL
    init() throws {
        archive = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("folder/empty/", attributes: UInt32(0o40755) << 16),
            ZIPOperationTestEntry("folder/nested/leaf", contents: Data([1, 2, 3]))
        ])
        destination = archive.root.appendingPathComponent("destination")
        published = destination.appendingPathComponent("folder (2)")
        try FileManager.default.createDirectory(at: published.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: published.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: published.appendingPathComponent("nested/leaf"))
    }
    func claim() throws -> ArchiveCopiedDestination {
        let parent = try copiedIdentity(destination)
        let identity = try copiedIdentity(published)
        return ArchiveCopiedDestination(parent: FileOperationContext(directoryURL: destination, directoryIdentity: parent), name: published.lastPathComponent, identity: identity)
    }
}

private func copiedIdentity(_ url: URL) throws -> LocalFileIdentity {
    let value = try LocalFileIdentity.read(at: url, ifLocal: true)
    return try #require(value)
}

private final class CopiedVerificationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, changed = false, swaps = 0
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func changeOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed, !changed else { return false }
        changed = true; return true
    }
    func swapping() { lock.lock(); defer { lock.unlock() }; swaps += 1 }
    var swapCount: Int { lock.lock(); defer { lock.unlock() }; return swaps }
}

private final class CopiedProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, count = 0
    private var announced: [TransferPhase] = []
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func didSwap() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func progress(_ phase: TransferPhase) { lock.lock(); defer { lock.unlock() }; announced.append(phase) }
    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }
    var lastPhase: TransferPhase? { lock.lock(); defer { lock.unlock() }; return announced.last }
    var phases: [TransferPhase] { lock.lock(); defer { lock.unlock() }; return announced }
    var swaps: Int { lock.lock(); defer { lock.unlock() }; return count }
}
