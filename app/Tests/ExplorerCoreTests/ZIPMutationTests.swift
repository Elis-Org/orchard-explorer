import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPMutationTests {
    @Test func recoveryErrorIncludesEveryRetainedArtifactLocation() {
        let archive = URL(fileURLWithPath: "/synthetic/example.zip")
        let retained = URL(fileURLWithPath: "/synthetic/.maxplorer-zip-retained/payload")
        let error = ArchiveOperationError.recoveryRequired(ArchiveRecoveryReceipt(archiveURL: archive,
            retainedURLs: [archive, retained], reason: "Restoration could not be verified."))
        #expect(error.localizedDescription.contains("Restoration could not be verified."))
        #expect(error.localizedDescription.contains(archive.path))
        #expect(error.localizedDescription.contains(retained.path))
    }

    @Test func copiedBirthTimeReconcilesOnlyTheContinuouslyHeldCreatedFile() throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")])
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: fixture.url.path)
        let parent = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        let stage = try ServiceStage(parent: parent, url: fixture.root, prefix: ".identity-")
        defer { stage.clean() }
        let (file, created) = try stage.createFile("payload")
        let source = open(fixture.url.path, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw POSIXError(.EIO) }
        defer { close(source) }
        #expect(fcopyfile(source, file.fileDescriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0)
        var sourceStat = stat(), copiedStat = stat()
        #expect(fstat(source, &sourceStat) == 0 && fstat(file.fileDescriptor, &copiedStat) == 0)
        let updated = try LocalFileIdentity.afterMetadataCopy(of: created, descriptor: file.fileDescriptor, parent: stage.descriptor, name: "payload")
        #expect(updated.device == created.device && updated.inode == created.inode)
        // The Foundation creationDate request is not the contract under test.
        // Reconcile the birth time actually observed after native metadata copy,
        // while still requiring a real identity change and exact named ownership.
        #expect(updated != created)
        #expect(updated == LocalFileIdentity.fromStat(copiedStat))
        #expect(updated == (try LocalFileOperations.identity(of: "payload", in: stage.descriptor)))
        print("ZIP_METADATA_BIRTH requested=1600000000 source=\(sourceStat.st_birthtimespec.tv_sec).\(sourceStat.st_birthtimespec.tv_nsec) sourceMtime=\(sourceStat.st_mtimespec.tv_sec).\(sourceStat.st_mtimespec.tv_nsec) created=\(created.birthSeconds).\(created.birthNanoseconds) copied=\(updated.birthSeconds).\(updated.birthNanoseconds)")
        let payload = stage.url.appendingPathComponent("payload")
        try Data([8]).write(to: payload, options: .atomic)
        #expect(throws: FileOperationError.staleSource) {
            try LocalFileIdentity.afterMetadataCopy(of: created, descriptor: file.fileDescriptor, parent: stage.descriptor, name: "payload")
        }
    }

    @Test func rawPassHashesDeletedBytesAndEnvelopeWithoutASecondDigestPass() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("remove", contents: Data(repeating: 7, count: 90_000)),
            ZIPOperationTestEntry("keep", contents: Data([1, 2, 3]))
        ], comment: Data("end comment".utf8))
        let context = try await fixture.context(), reader = try RecordingZIPReader(url: fixture.url)
        let manifest = try ZIPArchiveManifest.read(from: reader)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
        let plan = try ZIPStructuralPlan(edits: [.remove(source: ArchiveMemberTarget(location: fixture.location(["remove"]), revision: context.revision))], context: context, manifest: manifest)
        reader.reads = []; var candidate = Data()
        let result = try ZIPStructuralRewrite.write(manifest: manifest, layout: layout, plan: plan, reader: reader, output: { candidate.append($0) })
        #expect(result.originalDigest == Data(SHA256.hash(data: fixture.bytes)))
        #expect(result.candidateDigest == Data(SHA256.hash(data: candidate)))
        let start = try #require(reader.reads.lastIndex { $0.offset == 0 })
        var position: UInt64 = 0
        for read in reader.reads[start...] { #expect(read.offset == position); position += read.length }
        #expect(position == UInt64(fixture.bytes.count))
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func deleteRelocatesSaturatedZIP64OffsetWithoutDroppingAdjacentOpaqueExtra() async throws {
        let source = ZIPOperationTestArchive(entries: [ZIPOperationTestEntry("remove", contents: Data([1, 2])), ZIPOperationTestEntry("keep", contents: Data([8, 9]))])
        let all = Array(source.bytes), firstLength = 46 + "remove".utf8.count
        var local = Array(all[..<source.directoryOffset])
        ZIPBytes.put16(45, into: &local, at: source.localOffsets[1] + 4)
        var second = Array(all[(source.directoryOffset + firstLength)..<(all.count - 22)])
        ZIPBytes.put16(45, into: &second, at: 6)
        ZIPBytes.put32(UInt32.max, into: &second, at: 42)
        ZIPBytes.put16(18, into: &second, at: 30)
        var extra = [UInt8](repeating: 0, count: 12)
        ZIPBytes.put16(1, into: &extra, at: 0); ZIPBytes.put16(8, into: &extra, at: 2)
        ZIPBytes.put64(UInt64(source.localOffsets[1]), into: &extra, at: 4)
        let opaque = Data([0xfe, 0xca, 2, 0, 42, 43])
        let central = Data(all[source.directoryOffset..<(source.directoryOffset + firstLength)]) + Data(second) + Data(extra) + opaque
        var end = Array(all.suffix(22)), record = [UInt8](repeating: 0, count: 56), locator = [UInt8](repeating: 0, count: 20)
        ZIPBytes.put32(UInt32(central.count), into: &end, at: 12)
        ZIPBytes.put32(0x06064b50, into: &record, at: 0); ZIPBytes.put64(44, into: &record, at: 4)
        ZIPBytes.put16(45, into: &record, at: 12); ZIPBytes.put16(45, into: &record, at: 14)
        ZIPBytes.put64(2, into: &record, at: 24); ZIPBytes.put64(2, into: &record, at: 32)
        ZIPBytes.put64(UInt64(central.count), into: &record, at: 40); ZIPBytes.put64(UInt64(local.count), into: &record, at: 48)
        ZIPBytes.put32(0x07064b50, into: &locator, at: 0); ZIPBytes.put64(UInt64(local.count + central.count), into: &locator, at: 8); ZIPBytes.put32(1, into: &locator, at: 16)
        let fixture = try ZIPOperationTestFixture(entries: [])
        try (Data(local) + central + Data(record) + Data(locator) + Data(end)).write(to: fixture.url)
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["remove"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        let kept = try #require(manifest.records.first)
        #expect(manifest.envelope.rawZIP64Record != nil && manifest.records.count == 1)
        #expect(kept.localHeaderOffset == 0)
        #expect(kept.extraBytes.suffix(opaque.count) == opaque)
        #expect(ZIPBytes.u64(Array(kept.extraBytes), 4) == 0)
        _ = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
    }

    @Test func renamePreservesCompressedBytesOpaqueUntouchedMetadataAndArchiveComment() async throws {
        let compressed = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 7, 0])
        let extra = Data([0xfe, 0xca, 2, 0, 42, 43])
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("folder/a", contents: Data("hello".utf8), compressed: compressed, method: 8, attributes: UInt32(0o100751) << 16),
            ZIPOperationTestEntry("untouched", contents: Data([9]), extra: extra, comment: Data("entry note".utf8))
        ], comment: Data("archive note".utf8))
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["folder"]), revision: context.revision), newName: "renamed")], in: context, control: TransferControl(), onProgress: { _ in })
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
        let first = try #require(manifest.records.first), member = try #require(layout.records[first.id])
        #expect(first.components == ["renamed", "a"] && first.method == 8 && first.unixPermissions == 0o751)
        #expect(try reader.read(offset: member.payloadRange.offset, count: Int(member.payloadRange.length)) == compressed)
        #expect(manifest.records[1].extraBytes == extra)
        #expect(manifest.records[1].commentBytes == Data("entry note".utf8))
        #expect(manifest.archiveComment == Data("archive note".utf8))
    }

    @Test func unknownRenameMetadataAndAppleDoubleCompanionsRefuseWithoutChangingArchive() async throws {
        for entries in [[ZIPOperationTestEntry("a", extra: Data([0xfe, 0xca, 0, 0]))],
                        [ZIPOperationTestEntry("a"), ZIPOperationTestEntry("__MACOSX/._a")],
                        [ZIPOperationTestEntry("a"), ZIPOperationTestEntry("._a")]] {
            let fixture = try ZIPOperationTestFixture(entries: entries), context = try await fixture.context()
            await #expect(throws: ArchiveOperationError.self) {
                try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "b")], in: context, control: TransferControl(), onProgress: { _ in })
            }
            #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        }
    }

    @Test func cp437CommentTranscodesWhenRenameRequiresUTF8AndRegeneratesUnicodeCRC() async throws {
        var entry = ZIPOperationTestEntry("a", flags: 0, comment: Data([0x82])) // CP437 e acute
        entry.extra = unicodeField(0x7075, raw: entry.name, text: "a") + unicodeField(0x6375, raw: entry.comment, text: "é")
        let fixture = try ZIPOperationTestFixture(entries: [entry]), context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision), newName: "😀")], in: context, control: TransferControl(), onProgress: { _ in })
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)), record = try #require(manifest.records.first)
        #expect(record.flags & 0x800 != 0)
        #expect(record.nameBytes == Data("😀".utf8))
        #expect(record.commentBytes == Data("é".utf8))
        #expect(record.extraBytes == unicodeField(0x7075, raw: record.nameBytes, text: "😀") + unicodeField(0x6375, raw: record.commentBytes, text: "é"))
    }

    @Test func conflictingUnicodeMetadataOnlyBlocksTouchedRecords() async throws {
        let extra = unicodeField(0x7075, raw: Data("legacy".utf8), text: "other")
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a"), ZIPOperationTestEntry("legacy", extra: extra)])
        var context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        context = try await fixture.context(); let before = try Data(contentsOf: fixture.url)
        await #expect(throws: ArchiveOperationError.self) {
            try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["legacy"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func unsupportedAtomicSwapDoesNotFallBackToReplacement() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        var hooks = ArchiveMutationHooks(); hooks.swap = { _, _, _, _ in errno = ENOTSUP; return -1 }
        await #expect(throws: ArchiveOperationError.self) {
            try await LocalArchiveOperations(hooks: hooks).modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func substitutedArchiveIsRestoredAndNeverDeleted() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        let replacement = ZIPOperationTestArchive(entries: [ZIPOperationTestEntry("new-owner", contents: Data([8]))]).bytes
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { archive, _ in try replacement.write(to: archive, options: .atomic) }
        await #expect(throws: (any Error).self) {
            try await LocalArchiveOperations(hooks: hooks).modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == replacement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["fixture.zip"])
    }

    @Test func staleRevisionAndCancelledWorkLeaveOriginalBytes() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        let control = TransferControl(); control.cancel()
        await #expect(throws: CancellationError.self) {
            try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: control, onProgress: { _ in })
        }
        try fixture.bytes.write(to: fixture.url, options: .atomic)
        await #expect(throws: ArchiveOperationError.changed) {
            try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func changedDisplacedFileStopsRollbackAndPreservesBothCopies() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a")]), context = try await fixture.context()
        let changed = Data("unexpected edits must remain".utf8)
        var hooks = ArchiveMutationHooks()
        hooks.afterSwap = { _, _ in throw ArchiveOperationError.changed }
        hooks.beforeRollback = { _, displaced in
            let handle = try FileHandle(forWritingTo: displaced)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: changed)
        }
        do {
            _ = try await LocalArchiveOperations(hooks: hooks).modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["a"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
            Issue.record("Changing the displaced file must stop rollback.")
        } catch ArchiveOperationError.recoveryRequired(let receipt) {
            #expect(receipt.retainedURLs.contains(fixture.url))
            let stage = try #require(receipt.retainedURLs.first { $0 != fixture.url })
            #expect(try Data(contentsOf: stage.appendingPathComponent("payload")) == changed)
            #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.isEmpty)
        }
    }
}

private func unicodeField(_ tag: UInt16, raw: Data, text: String) -> Data {
    let utf8 = Data(text.utf8); var bytes = [UInt8](repeating: 0, count: 9)
    ZIPBytes.put16(tag, into: &bytes, at: 0); ZIPBytes.put16(UInt16(utf8.count + 5), into: &bytes, at: 2)
    bytes[4] = 1; ZIPBytes.put32(zipOperationReferenceCRC(raw), into: &bytes, at: 5)
    return Data(bytes) + utf8
}

private final class RecordingZIPReader: ZIPPositionalReading {
    let base: ZIPFileReader
    var reads: [ZIPByteRange] = []
    var length: UInt64 { base.length }
    var revision: ArchiveRevision { base.revision }
    init(url: URL) throws { base = try ZIPFileReader(url: url) }
    func read(offset: UInt64, count: Int) throws -> Data {
        reads.append(ZIPByteRange(offset: offset, length: UInt64(count)))
        return try base.read(offset: offset, count: count)
    }
    func validateUnchanged() throws { try base.validateUnchanged() }
}
