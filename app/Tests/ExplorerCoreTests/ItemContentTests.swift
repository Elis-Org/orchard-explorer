import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// Complete synthetic ZIP records. The payload and CRC are the standard
/// CRC32 check vector; the raw DEFLATE bytes are fixed independently of Core.
@Suite struct ItemContentTests {
    @Test func explicitDownloadRejectsArchiveWithoutCreatingExport() async throws {
        let fixture = try ContentFixture()
        let entry = try await fixture.archiveEntry()
        await #expect(throws: ItemContentError.unsupportedType) {
            _ = try await fixture.provider.materialize(ContentRequest(source: entry, purpose: .download), control: TransferControl())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.exports.path))
    }

    @Test func persistentRootResolvesExistingAncestorBeforeCreatingMissingDirectories() throws {
        let fixture = try ContentFixture()
        let alias = fixture.root.appendingPathComponent("ancestor-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let requested = alias.appendingPathComponent("new-parent/new-root", isDirectory: true)
        let held = try ContentRoot(requested)
        let expected = try FileSystemPath.resolvingExisting(fixture.root).appendingPathComponent("new-parent/new-root", isDirectory: true)
        #expect(held.url.path == expected.path)
        #expect(try ContentFileIO.sample(held.fd).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        try held.validate()
        let registry = ContentLeaseRegistry(rootURL: alias.appendingPathComponent("different/missing", isDirectory: true))
        #expect(registry.containsManagedURL(try FileSystemPath.resolvingExisting(fixture.root).appendingPathComponent("different/missing/member.txt")))
    }

    @Test func impossibleSpaceRequirementRefusesBeforeCreatingAnExportStage() throws {
        let fixture = try ContentFixture()
        let root = try ContentRoot(fixture.exports)
        #expect(throws: POSIXError(.ENOSPC)) { try ContentFileIO.requireAvailableSpace(UInt64.max, at: root.fd) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path).isEmpty)
    }

    @Test func ownedMetadataApplicationReconcilesHeldFileIdentityBeforePublication() throws {
        let fixture = try ContentFixture()
        let stage = try ContentOwnedStage(root: ContentRoot(fixture.exports), id: UUID())
        let fd = try stage.create(["note.txt"], directory: false)
        defer { close(fd) }
        let before = try ContentFileIO.sample(fd)
        try ContentFileIO.write(Data("123456789".utf8), to: fd)
        try ContentFileIO.applyMetadata(fd, mode: 0o644, modifiedAt: Date(timeIntervalSince1970: 1_704_067_200))
        let after = try ContentFileIO.sample(fd)
        #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        // The platform may adjust birth time when an older mtime is applied.
        // The held inode and named entry must agree before adopting that state.
        try stage.seal(["note.txt"], fd: fd, digest: ContentFileIO.digest(fd, checkpoint: {}), reconcilingMetadata: true)
        #expect(stage.nodes[ContentOwnedStage.key(["note.txt"])]?.version == (try ContentFileVersion(after)))
        try stage.validateContents()
        #expect(stage.cleanup(deadline: ContentDeadline(seconds: 5)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stage.url.appendingPathComponent("note.txt").path))
    }

    @Test func managedNamespaceRefusesDescendantsButNotSiblingPrefixesOrEscapes() throws {
        let registry = ContentLeaseRegistry(rootURL: URL(fileURLWithPath: "/synthetic/owned", isDirectory: true))
        #expect(registry.containsManagedURL(URL(fileURLWithPath: "/synthetic/owned/session/note.txt")))
        #expect(registry.containsManagedURL(URL(fileURLWithPath: "/SYNTHETIC/OWNED/session/note.txt")))
        #expect(!registry.containsManagedURL(URL(fileURLWithPath: "/synthetic/owned-other/note.txt")))
        #expect(!registry.containsManagedURL(URL(fileURLWithPath: "/synthetic/owned/../outside.txt")))
        #expect(!registry.containsManagedURL(try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/synthetic/owned/a.zip"), components: ["note.txt"]).url))
        let other = ContentLeaseRegistry(rootURL: URL(fileURLWithPath: "/synthetic/other", isDirectory: true))
        #expect(!other.containsManagedURL(URL(fileURLWithPath: "/synthetic/owned/session/note.txt")))
    }

    @Test func storedMemberProducesVerifiedRealFileAndReleaseRemovesOnlyExport() async throws {
        let fixture = try ContentFixture()
        let source = try await fixture.archiveEntry()
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: source, purpose: .preview), control: TransferControl())
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
        #expect(lease.fileURL.isFileURL)
        #expect(lease.fileURL.lastPathComponent == "note.txt")
        #expect(!lease.isBorrowed)
        #expect(try FileSystemPath.resolvingExisting(lease.fileURL).path.hasPrefix(FileSystemPath.resolvingExisting(fixture.exports).path + "/"))
        #expect(lease.sourceURL == source.item.url)
        #expect(lease.archiveRevision == source.item.archiveRevision)
        #expect(lease.byteCount == 9)
        #expect(lease.physicalEntry.item.url == lease.fileURL)
        #expect(lease.physicalEntry.item.identity != nil)
        try await lease.validateForUse()
        let result = await lease.release()
        #expect(result.disposition == .released)
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
        #expect(await lease.release().disposition == .alreadyReleased)
    }

    @Test func rawDeflateMemberDecodesRatherThanReturningCompressedBytes() async throws {
        let fixture = try ContentFixture(deflated: true)
        let source = try await fixture.archiveEntry()
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: source, purpose: .preview), control: TransferControl())
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
        #expect(lease.byteCount == 9)
        _ = await lease.release()
    }

    @Test func borrowedPhysicalFileIsNeverRemovedOrChmoddedByRelease() async throws {
        let fixture = try ContentFixture()
        let url = fixture.root.appendingPathComponent("physical.txt")
        try Data("physical".utf8).write(to: url)
        #expect(chmod(url.path, 0o640) == 0)
        let entry = try await fixture.physicalEntry(url)
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: entry, purpose: .preview), control: TransferControl())
        #expect(lease.fileURL == url && lease.isBorrowed)
        try await lease.validateForUse()
        #expect(await lease.release().disposition == .released)
        #expect(try Data(contentsOf: url) == Data("physical".utf8))
        var value = stat()
        #expect(lstat(url.path, &value) == 0)
        #expect(value.st_mode & 0o777 == 0o640)
    }

    @Test func borrowedFileAcceptanceRejectsChangedVersion() async throws {
        let fixture = try ContentFixture()
        let url = fixture.root.appendingPathComponent("physical.txt")
        try Data("before".utf8).write(to: url)
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: try await fixture.physicalEntry(url), purpose: .preview),
            control: TransferControl())
        try Data("after with different length".utf8).write(to: url)
        await #expect(throws: ItemContentError.staleSource) { try await lease.validateForUse() }
        _ = await lease.release()
        #expect(try Data(contentsOf: url) == Data("after with different length".utf8))
    }

    @Test func externalOpenIsReadOnlyAndEditedCopySurvivesReleaseAndShutdown() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen),
            control: TransferControl())
        var value = stat()
        #expect(lstat(lease.fileURL.path, &value) == 0)
        #expect(value.st_mode & 0o777 == 0o444)
        #expect(chmod(lease.fileURL.path, 0o600) == 0)
        try Data("edited copy".utf8).write(to: lease.fileURL)
        let result = await lease.release()
        #expect(result.disposition == .preserved)
        #expect(result.preservedURLs.contains(lease.fileURL))
        #expect(try Data(contentsOf: lease.fileURL) == Data("edited copy".utf8))
        let retained = try await fixture.registry.shutdown()
        #expect(retained.contains { $0.url == lease.fileURL })
        #expect(try Data(contentsOf: lease.fileURL) == Data("edited copy".utf8))
        let nextRegistry = ContentLeaseRegistry(rootURL: fixture.exports)
        let nextLaunch = try await nextRegistry.retainedArtifacts()
        #expect(nextLaunch.contains { $0.url == lease.fileURL && !$0.reason.isEmpty })
    }

    @Test func clipboardReleaseRetiresExportWithoutDeletingConsumerFile() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(
            ContentRequest(source: try await fixture.archiveEntry(), purpose: .clipboardExport),
            control: TransferControl())
        #expect(await lease.release().disposition == .retired)
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
        #expect(await lease.release().disposition == .alreadyReleased)
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
    }

    @Test func badCRCRefusesLeaseAndLeavesOriginalBytesUntouched() async throws {
        let fixture = try ContentFixture(crc: 0)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.corruptContent) {
            _ = try await fixture.provider.materialize(request, control: TransferControl())
        }
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func changedArchiveRevisionRefusesMaterialization() async throws {
        let fixture = try ContentFixture()
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        try Data("replacement".utf8).write(to: fixture.archive)
        await #expect(throws: ItemContentError.staleSource) {
            _ = try await fixture.provider.materialize(request, control: TransferControl())
        }
        #expect(try Data(contentsOf: fixture.archive) == Data("replacement".utf8))
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func cancelledRequestCreatesNoExport() async throws {
        let fixture = try ContentFixture()
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        let control = TransferControl(); control.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.provider.materialize(request, control: control)
        }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func declaredLimitsRefuseBeforePublishingFiles() async throws {
        for key in 0..<4 {
            var limits = ContentLimits()
            if key == 0 { limits.memberBytes = 8 }
            if key == 1 { limits.previewBytes = 8 }
            if key == 2 { limits.transactionBytes = 8 }
            if key == 3 { limits.archiveBytes = 10 }
            let fixture = try ContentFixture(limits: limits)
            let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
            await #expect(throws: ItemContentError.limitExceeded) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
            #expect(try fixture.exportedRegularFiles().isEmpty)
        }
    }

    @Test func aggregateQuotaIsReclaimedOnlyAfterOwnedRelease() async throws {
        var limits = ContentLimits(); limits.ownedBytes = 9
        let fixture = try ContentFixture(limits: limits)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        let first = try await fixture.provider.materialize(request, control: TransferControl())
        await #expect(throws: ItemContentError.limitExceeded) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try Data(contentsOf: first.fileURL) == Data("123456789".utf8))
        _ = await first.release()
        let next = try await fixture.provider.materialize(request, control: TransferControl())
        #expect(try Data(contentsOf: next.fileURL) == Data("123456789".utf8))
        _ = await next.release()
    }

    @Test func retiredClipboardExportsRemainUntilAtLeastSixtyMinutesUnderPressure() async throws {
        var limits = ContentLimits(); limits.ownedBytes = 9
        let clock = ContentTestClock()
        let fixture = try ContentFixture(limits: limits, now: { clock.now })
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .clipboardExport)
        let first = try await fixture.provider.materialize(request, control: TransferControl())
        #expect(await first.release().disposition == .retired)
        clock.advance(3_599)
        await #expect(throws: ItemContentError.limitExceeded) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try Data(contentsOf: first.fileURL) == Data("123456789".utf8))
        clock.advance(1)
        let next = try await fixture.provider.materialize(request, control: TransferControl())
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(try Data(contentsOf: next.fileURL) == Data("123456789".utf8))
        _ = await next.release(); _ = try await fixture.registry.shutdown()
    }

    @Test func madeWritableUneditedExternalCopyIsPreserved() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen), control: TransferControl())
        #expect(chmod(lease.fileURL.path, 0o644) == 0)
        #expect(await lease.release().disposition == .preserved)
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
        _ = try await fixture.registry.shutdown()
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
    }

    @Test func replacementAndUnknownSiblingAreNeverDeleted() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview), control: TransferControl())
        try FileManager.default.removeItem(at: lease.fileURL)
        try Data("replacement".utf8).write(to: lease.fileURL)
        let extra = lease.fileURL.deletingLastPathComponent().appendingPathComponent("unknown.txt")
        try Data("unknown".utf8).write(to: extra)
        #expect(await lease.release().disposition == .preserved)
        #expect(try Data(contentsOf: lease.fileURL) == Data("replacement".utf8))
        #expect(try Data(contentsOf: extra) == Data("unknown".utf8))
    }

    @Test func directoryExportContainsEmptyFolderAndAcceptanceRejectsNewChild() async throws {
        let fixture = try ContentFixture(folder: true)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        #expect(lease.fileURL.lastPathComponent == "folder")
        #expect(lease.physicalEntry.item.isDirectory)
        #expect(try Data(contentsOf: lease.fileURL.appendingPathComponent("note.txt")) == Data("123456789".utf8))
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.appendingPathComponent("empty").path, isDirectory: &directory) && directory.boolValue)
        try await lease.validateForUse()
        let extra = lease.fileURL.appendingPathComponent("unknown.txt")
        try Data("unknown".utf8).write(to: extra)
        await #expect(throws: ItemContentError.staleSource) { try await lease.validateForUse() }
        #expect(await lease.release().disposition == .preserved)
        #expect(try Data(contentsOf: extra) == Data("unknown".utf8))
    }

    @Test func movedDirectoryExportIsSkippedWithoutChasingOrInventingRetainedChildren() async throws {
        let fixture = try ContentFixture(folder: true)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        let moved = fixture.root.appendingPathComponent("consumer-owned", isDirectory: true)
        try FileManager.default.moveItem(at: lease.fileURL, to: moved)
        let result = await lease.release()
        #expect(result.disposition == .released)
        #expect(result.preservedURLs.isEmpty)
        #expect(try Data(contentsOf: moved.appendingPathComponent("note.txt")) == Data("123456789".utf8))
    }

    @Test func externallyChangedDirectoryPreservesItsWholeRemainingSubtree() async throws {
        let fixture = try ContentFixture(folder: true)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        // Change metadata without adding/removing children or changing its mode.
        // Identity+mode alone must not authorize deleting this modified tree.
        let marker = Data("changed directory".utf8)
        #expect(marker.withUnsafeBytes { setxattr(lease.fileURL.path, "com.example.explorer-content-test", $0.baseAddress, $0.count, 0, 0) } == 0)
        let result = await lease.release()
        #expect(result.disposition == .preserved)
        #expect(try Data(contentsOf: lease.fileURL.appendingPathComponent("note.txt")) == Data("123456789".utf8))
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.appendingPathComponent("empty").path))
    }

    @Test func substitutedContainerPreservesBothOriginalAndReplacementTrees() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview), control: TransferControl())
        let container = lease.fileURL.deletingLastPathComponent()
        let moved = fixture.root.appendingPathComponent("moved-container", isDirectory: true)
        try FileManager.default.moveItem(at: container, to: moved)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let replacement = container.appendingPathComponent("unknown.txt")
        try Data("replacement tree".utf8).write(to: replacement)
        let result = await lease.release()
        #expect(result.disposition == .preserved)
        #expect(result.preservedURLs.contains { $0.path == moved.resolvingSymlinksInPath().path })
        #expect(try Data(contentsOf: moved.appendingPathComponent("note.txt")) == Data("123456789".utf8))
        #expect(try Data(contentsOf: replacement) == Data("replacement tree".utf8))
    }

    @Test func shutdownDeadlinePreservesUnprovenFilesAndPersistsNextLaunchNotice() async throws {
        var limits = ContentLimits(); limits.shutdownSeconds = 0
        let fixture = try ContentFixture(limits: limits)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen), control: TransferControl())
        let report = try await fixture.registry.shutdown()
        #expect(!report.isEmpty)
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
        let nextLaunch = try await ContentLeaseRegistry(rootURL: fixture.exports).retainedArtifacts()
        #expect(!nextLaunch.isEmpty)
        #expect(try Data(contentsOf: lease.fileURL) == Data("123456789".utf8))
    }

    @Test func expiredAdmissionCreatesNoExport() async throws {
        var limits = ContentLimits(); limits.previewSeconds = 0
        let fixture = try ContentFixture(limits: limits)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.deadlineExceeded) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func exportPreservesExecuteAndTimestampButStripsPrivilegedBits() async throws {
        let fixture = try ContentFixture(mode: 0o6751)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        var value = stat(); #expect(lstat(lease.fileURL.path, &value) == 0)
        #expect(value.st_mode & 0o7777 == 0o751)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec))
        #expect(calendar.component(.year, from: date) == 2024)
        #expect(calendar.component(.month, from: date) == 1)
        #expect(calendar.component(.day, from: date) == 1)
        _ = await lease.release()
    }

    @Test func explicitDirectoryUsesValidatedExtendedTimestamp() async throws {
        let fixture = try ContentFixture(folder: true, directoryTimestamp: 1_234_567_890)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        var value = stat()
        #expect(lstat(lease.fileURL.appendingPathComponent("empty").path, &value) == 0)
        #expect(value.st_mtimespec.tv_sec == 1_234_567_890)
        _ = await lease.release()
    }

    @Test func directoryMovedAfterHashIsNotFollowedThroughHeldParentDescriptor() throws {
        let fixture = try ContentFixture()
        let stage = try ContentOwnedStage(root: ContentRoot(fixture.exports), id: UUID())
        let folder = try stage.create(["folder"], directory: true)
        defer { close(folder) }
        let file = try stage.create(["folder", "note.txt"], directory: false)
        defer { close(file) }
        try ContentFileIO.write(Data("123456789".utf8), to: file)
        try stage.seal(["folder", "note.txt"], fd: file, digest: ContentFileIO.digest(file, checkpoint: {}))
        try stage.seal(["folder"], fd: folder, digest: nil)
        let moved = fixture.root.appendingPathComponent("consumer-directory", isDirectory: true)
        var didMove = false
        let report = stage.cleanup(deadline: ContentDeadline(seconds: 5), deleting: { operation in
            if !didMove {
                try FileManager.default.moveItem(at: stage.url.appendingPathComponent("folder", isDirectory: true), to: moved)
                didMove = true
            }
            try operation()
        })
        #expect(didMove)
        #expect(report.isEmpty)
        #expect(try Data(contentsOf: moved.appendingPathComponent("note.txt")) == Data("123456789".utf8))
    }

    @Test func originAttributesSurvivePublicExport() async throws {
        let fixture = try ContentFixture()
        let values = [("com.apple.quarantine", Data("0081;00000000;ExplorerContentTest;".utf8)),
                      ("com.apple.metadata:kMDItemWhereFroms", try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/synthetic.zip"], format: .binary, options: 0))]
        for (name, data) in values {
            let status = data.withUnsafeBytes { bytes in setxattr(fixture.archive.path, name, bytes.baseAddress, bytes.count, 0, 0) }
            #expect(status == 0)
        }
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        for (name, expected) in values {
            let size = getxattr(lease.fileURL.path, name, nil, 0, 0, 0)
            // Approved native-origin contract: copyfile may normalize opaque
            // quarantine bytes; WhereFroms remains byte-exact. Never repair the
            // OS output back to this synthetic zero-time source serialization.
            #expect(size > 0)
            var actual = Data(count: max(0, size))
            let count = actual.withUnsafeMutableBytes { getxattr(lease.fileURL.path, name, $0.baseAddress, $0.count, 0, 0) }
            #expect(count == size)
            if name != "com.apple.quarantine" { #expect(actual == expected) }
            let source = try? Self.originAttribute(fixture.archive, name: name)
            #expect(source == expected)
        }
        _ = await lease.release()
    }

    @Test func filesystemCollisionPlanningKeepsByteDistinctArchiveNamesSafe() throws {
        #expect(throws: ItemContentError.unsupportedType) { try LocalItemContentProvider.validateExportNames([["folder", "Case"], ["folder", "case"]], caseSensitive: false) }
        try LocalItemContentProvider.validateExportNames([["folder", "Case"], ["folder", "case"]], caseSensitive: true)
        #expect(throws: ItemContentError.unsupportedType) { try LocalItemContentProvider.validateExportNames([["folder", "café"], ["folder", "cafe\u{301}"]], caseSensitive: true) }
    }

    @Test func productionNamespaceUsesPersistentApplicationSupport() {
        let registry = ContentLeaseRegistry()
        let persistent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/dev.native-explorer.app/ZIP Content/session/note.txt")
        #expect(registry.containsManagedURL(persistent))
        #expect(!registry.containsManagedURL(FileManager.default.temporaryDirectory.appendingPathComponent("ZIP Content/session/note.txt")))
        #expect(!registry.containsManagedURL(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dev.native-explorer.app/ZIP Content/session/note.txt")))
    }

    @Test func failureBeforeNativeOriginApplicationRefusesHandoffAndCleansOnlyOwnedOutput() async throws {
        let fixture = try ContentFixture()
        let value = Data("0081;00000000;ExplorerContentTest;".utf8)
        #expect(value.withUnsafeBytes { setxattr(fixture.archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
        let provider = LocalItemContentProvider(registry: fixture.registry, originObserver: { _, origin in
            guard origin.quarantine == value else { throw ItemContentError.corruptContent }
            throw POSIXError(.EPERM)
        })
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen)
        await #expect(throws: POSIXError(.EPERM)) { _ = try await provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
    }

    @Test func extractionReadsOnlySelectedValidatedPayloadAndStreamsToConsumer() throws {
        let fixture = try ContentFixture(deflated: true)
        let reader = try ContentRecordingReader(fixture.archive)
        let manifest = try ZIPArchiveManifest.read(from: reader)
        let record = try #require(manifest.records.first)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [record.id]))
        let range = try #require(layout.records[record.id])
        reader.reads.removeAll()
        var output = Data()
        let digest = try ZIPContentExtraction.extract(record: record, layout: range, reader: reader, maximumBytes: 9,
            checkpoint: {}, consume: { output.append($0) })
        #expect(output == Data("123456789".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
        #expect(reader.reads == [ZIPByteRange(offset: 38, length: 11)])
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test(arguments: ["trailing", "truncated"])
    func deflateTrailingBytesAndTruncatedStreamsNeverPublishLease(variant: String) async throws {
        let fixture = try ContentFixture(deflated: true, trailing: variant == "trailing", truncated: variant == "truncated")
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.corruptContent) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test(arguments: [ContentPurpose.preview, .externalOpen, .transfer, .clipboardExport])
    func associatedMemberWhereFromsIsRestoredByContentProvider(purpose: ContentPurpose) async throws {
        let (companion, expected) = try Self.memberOriginFixture()
        let fixture = try ContentFixture(originCompanion: companion)
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: purpose), control: TransferControl())
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let count = getxattr(lease.fileURL.path, name, nil, 0, 0, 0)
        #expect(count == expected.count)
        if count >= 0 {
            var actual = Data(count: count)
            #expect(actual.withUnsafeMutableBytes { getxattr(lease.fileURL.path, name, $0.baseAddress, count, 0, 0) } == count)
            #expect(actual == expected)
        }
        let bytes = try? Data(contentsOf: lease.fileURL)
        #expect(bytes == Data("123456789".utf8))
        #expect(await lease.release().disposition == (purpose == .clipboardExport ? .retired : .released))
    }

    @Test(arguments: [ContentPurpose.preview, .externalOpen, .transfer, .clipboardExport])
    func malformedAssociatedOriginCompanionRefusesContentPublication(purpose: ContentPurpose) async throws {
        let fixture = try ContentFixture(originCompanion: Data("not AppleDouble".utf8))
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: purpose)
        await #expect(throws: (any Error).self) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func validOriginCompanionWithIncorrectZIPChecksumCannotPublishContent() async throws {
        let (companion, _) = try Self.memberOriginFixture()
        // The local and central headers agree, and the AppleDouble bytes are
        // valid. Only decoding the selected companion and checking its CRC
        // reveals this corruption; metadata parsing alone must not accept it.
        let fixture = try ContentFixture(originCompanion: companion, incorrectCompanionCRC: true)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.corruptContent) {
            _ = try await fixture.provider.materialize(request, control: TransferControl())
        }
        #expect(try fixture.exportedRegularFiles().isEmpty)
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
    }

    @Test func downloadedOuterQuarantineAndMemberProvenanceUseTheirApprovedPriorities() async throws {
        let (companion, memberWhereFroms) = try Self.memberOriginFixture()
        let fixture = try ContentFixture(originCompanion: companion)
        var archive = fixture.archive, values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeWebDownload", "LSQuarantineAgentName": "MaxplorerContentOriginTest"]
        try archive.setResourceValues(values)
        let sourcePublic = try URL(fileURLWithPath: archive.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        let event = try #require(sourcePublic?["LSQuarantineEventIdentifier"] as? String)
        let outerWhereFroms = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/container.zip"], format: .binary, options: 0)
        #expect(outerWhereFroms.withUnsafeBytes { setxattr(archive.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) } == 0)
        let originalQuarantine = try Self.originAttribute(archive, name: "com.apple.quarantine")
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen), control: TransferControl())
        let actualPublic = try? URL(fileURLWithPath: lease.fileURL.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(actualPublic?["LSQuarantineEventIdentifier"] as? String == event)
        #expect((try? Self.originAttribute(lease.fileURL, name: "com.apple.metadata:kMDItemWhereFroms")) == memberWhereFroms)
        #expect((try? Self.originAttribute(archive, name: "com.apple.quarantine")) == originalQuarantine)
        #expect((try? Self.originAttribute(archive, name: "com.apple.metadata:kMDItemWhereFroms")) == outerWhereFroms)
        #expect(await lease.release().disposition == .released)
    }

    @Test func selectedFolderRestoresEmptyDirectoryOriginWithoutExposingScratchFiles() async throws {
        let (companion, expected) = try Self.memberOriginFixture()
        let fixture = try ContentFixture(folder: true, originCompanion: companion, originCompanionPath: "__MACOSX/folder/._empty")
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer), control: TransferControl())
        let empty = lease.fileURL.appendingPathComponent("empty", isDirectory: true)
        #expect((try? Self.originAttribute(empty, name: "com.apple.metadata:kMDItemWhereFroms")) == expected)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: lease.fileURL.path).sorted()) == ["empty", "note.txt"])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: lease.fileURL.deletingLastPathComponent().path)) == ["folder"])
        #expect(await lease.release().disposition == .released)
    }

    @Test func unrelatedForeignCompanionDoesNotBlockSelectedContent() async throws {
        let fixture = try ContentFixture(originCompanion: Data("foreign metadata remains opaque".utf8), originCompanionPath: "__MACOSX/._unrelated.txt")
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview), control: TransferControl())
        #expect((try? Data(contentsOf: lease.fileURL)) == Data("123456789".utf8))
        #expect(await lease.release().disposition == .released)
    }

    @Test(arguments: ["companion", "cumulative"])
    func originLimitsRefuseBeforeContentPublication(limit: String) async throws {
        let (companion, _) = try Self.memberOriginFixture()
        let fixture = try ContentFixture(originCompanion: limit == "companion" ? Data(repeating: 0, count: 1_024 * 1_024 + 1) : companion)
        let provider = LocalItemContentProvider(registry: fixture.registry, maximumOriginBytes: limit == "cumulative" ? 0 : 64 * 1_024 * 1_024,
            originObserver: { _, _ in })
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.limitExceeded) { _ = try await provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func cancellationAfterCompanionUnpackStillCleansOnlyOwnedOutput() async throws {
        let (companion, _) = try Self.memberOriginFixture()
        let fixture = try ContentFixture(originCompanion: companion), control = TransferControl()
        let provider = LocalItemContentProvider(registry: fixture.registry, originObserver: { _, _ in control.cancel() })
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .transfer)
        await #expect(throws: CancellationError.self) { _ = try await provider.materialize(request, control: control) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
        #expect(try Data(contentsOf: fixture.archive) == fixture.archiveBytes)
    }

    private static func memberOriginFixture() throws -> (Data, Data) {
        // Native COPYFILE_PACK fixture from d68627b09ac641ce89114d3e79ed5082.
        // 285 bytes, SHA256 cd4913e2fdf8886e74042221d39eb3e0b692ebfdb395b024f3a9d18a4a10f27e.
        let companion = try #require(Data(base64Encoded: "AAUWBwACAABNYWMgT1MgWCAgICAgICAgAAIAAAAJAAAAMgAAAOsAAAACAAABHQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQVRUUgAAAAAAAAEdAAAAqAAAAHUAAAAAAAAAAAAAAAAAAAABAAAAqAAAAHUAACVjb20uYXBwbGUubWV0YWRhdGE6a01ESXRlbVdoZXJlRnJvbXMAYnBsaXN0MDCiAQJfEB5odHRwczovL2V4YW1wbGUuaW52YWxpZC9tZW1iZXJfECNodHRwczovL2V4YW1wbGUuaW52YWxpZC9tZW1iZXItcGFnZQgLLAAAAAAAAAEBAAAAAAAAAAMAAAAAAAAAAAAAAAAAAABS"))
        let expected = try #require(Data(base64Encoded: "YnBsaXN0MDCiAQJfEB5odHRwczovL2V4YW1wbGUuaW52YWxpZC9tZW1iZXJfECNodHRwczovL2V4YW1wbGUuaW52YWxpZC9tZW1iZXItcGFnZQgLLAAAAAAAAAEBAAAAAAAAAAMAAAAAAAAAAAAAAAAAAABS"))
        return (companion, expected)
    }

    private static func originAttribute(_ url: URL, name: String) throws -> Data? {
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0, count <= 256 * 1_024 else { throw POSIXError(.EIO) }
        var bytes = Data(count: count)
        guard bytes.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }) == count else { throw POSIXError(.EIO) }
        return bytes
    }

    @Test(arguments: ["zero", "nonzero", "second-stream", "truncated-one", "truncated-two", "zlib", "gzip", "empty-extent"])
    func rawDeflateRequiresExactlyOneCompleteUnwrappedStream(variant: String) async throws {
        let valid = Data([0x33,0x34,0x32,0x36,0x31,0x35,0x33,0xB7,0xB0,0x04,0x00])
        let payload: Data
        switch variant {
        case "zero": payload = valid + Data([0])
        case "nonzero": payload = valid + Data([0x7F])
        case "second-stream": payload = valid + valid
        case "truncated-one": payload = Data(valid.dropLast())
        case "truncated-two": payload = Data(valid.dropLast(2))
        case "zlib": payload = Data([0x78,0x9C]) + valid + Data([0x09,0x1E,0x01,0xDE])
        case "gzip": payload = Data([0x1F,0x8B,0x08,0,0,0,0,0,0,0x0A]) + valid + Data([0x26,0x39,0xF4,0xCB,0x09,0,0,0])
        default: payload = Data()
        }
        let fixture = try ContentFixture(deflated: true, rawPayload: payload,
            contents: variant == "empty-extent" ? Data() : Data("123456789".utf8),
            crc: variant == "empty-extent" ? 0 : 0xCBF43926)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        await #expect(throws: ItemContentError.corruptContent) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func completeEmptyRawDeflateStreamPublishesAnEmptyFile() async throws {
        let fixture = try ContentFixture(deflated: true, rawPayload: Data([0x03, 0x00]), contents: Data(), crc: 0)
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
        let lease = try await fixture.provider.materialize(request, control: TransferControl())
        #expect(lease.byteCount == 0)
        #expect(try Data(contentsOf: lease.fileURL).isEmpty)
        #expect(await lease.release().disposition == .released)
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test(arguments: [65_536, 131_072])
    func rawDeflateAcceptsExactOutputBufferFillsOnlyAfterStreamEnd(count: Int) throws {
        // Fixed Python zlib raw-DEFLATE vectors, independent of the decoder.
        let hex = count == 65_536 ? "edc181000000008020b6fda516a90a0000" : "edc13101000000c2a06ceb5fcac31a4001"
        var payload = Data(stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
        payload.append(Data(repeating: 0, count: count == 65_536 ? 60 : 126))
        payload.append(count == 65_536 ? Data([0, 0x6A]) : Data([0xDC, 0]))
        let expected = Data(repeating: 65, count: count)
        let fixture = try ContentFixture(deflated: true, rawPayload: payload, contents: expected,
                                         crc: count == 65_536 ? 0xA09B0680 : 0x0FC3AA76)
        let (reader, record, layout) = try fixture.extractionInputs()
        var output = Data(), chunkLengths: [Int] = []
        let digest = try ZIPContentExtraction.extract(record: record, layout: layout, reader: reader,
            maximumBytes: UInt64(count), checkpoint: {}, consume: { output.append($0); chunkLengths.append($0.count) })
        #expect(output == expected)
        #expect(chunkLengths.allSatisfy { $0 > 0 && $0 <= 65_536 })
        #expect(chunkLengths.reduce(0, +) == count)
        let expectedSHA = count == 65_536 ? "156c38442089c1323d3e3ba549a6ac24341c47e8b6367bec4740c9b8c865826e" : "02c9a68f567b8ec215d893cde67ae2da41ba3c9b838d0ba4d3d04ab3cdc58da6"
        #expect(digest.map { String(format: "%02x", $0) }.joined() == expectedSHA)
    }

    @Test func rawDeflateStreamsMultipleInputChunksWithoutReadingBeyondSelectedExtent() throws {
        let expected = Data((0..<131_101).map { UInt8($0 % 251) })
        let fixture = try ContentFixture(deflated: true, rawPayload: Self.rawStoredBlocks(expected),
                                         contents: expected, crc: 0x07C1B474)
        let (reader, record, layout) = try fixture.extractionInputs()
        var output = Data()
        let digest = try ZIPContentExtraction.extract(record: record, layout: layout, reader: reader,
            maximumBytes: UInt64(expected.count), checkpoint: {}, consume: { output.append($0) })
        #expect(output == expected)
        #expect(digest.map { String(format: "%02x", $0) }.joined() == "29b078bfbf16449c611b8279983cd29d29e58b6bbed96a4cab0427ef2bc0cdee")
        #expect(reader.reads.count >= 3)
        var next = layout.payloadRange.offset
        for range in reader.reads {
            #expect(range.offset == next && range.length > 0 && range.length <= 65_536)
            next += range.length
        }
        #expect(next == layout.payloadRange.offset + layout.payloadRange.length)
    }

    @Test(arguments: ["cancellation", "consumer"])
    func rawDeflateStopsReadingWhenAnOutputConsumerOrCheckpointFails(reason: String) throws {
        let expected = Data((0..<131_101).map { UInt8($0 % 251) })
        let fixture = try ContentFixture(deflated: true, rawPayload: Self.rawStoredBlocks(expected),
                                         contents: expected, crc: 0x07C1B474)
        let (reader, record, layout) = try fixture.extractionInputs()
        var delivered = 0
        func run() throws {
            _ = try ZIPContentExtraction.extract(record: record, layout: layout, reader: reader,
                maximumBytes: UInt64(expected.count), checkpoint: {
                    if reason == "cancellation", delivered > 0 { throw CancellationError() }
                }, consume: { _ in delivered += 1; if reason == "consumer" { throw POSIXError(.EIO) } })
        }
        if reason == "cancellation" { #expect(throws: CancellationError.self) { try run() } }
        else { #expect(throws: POSIXError(.EIO)) { try run() } }
        #expect(delivered == 1)
        #expect(reader.reads.count == 1)
        #expect(try fixture.exportedRegularFiles().isEmpty)
    }

    @Test func rawDeflateRefusesOutputBeyondDeclaredSizeAndBadCRC() async throws {
        for wrongSize in [true, false] {
            let fixture = try ContentFixture(deflated: true,
                contents: wrongSize ? Data("12345678".utf8) : Data("123456789".utf8),
                crc: wrongSize ? 0xCBF43926 : 0xCBF43927)
            let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview)
            await #expect(throws: ItemContentError.corruptContent) { _ = try await fixture.provider.materialize(request, control: TransferControl()) }
            #expect(try fixture.exportedRegularFiles().isEmpty)
        }
    }

    private static func rawStoredBlocks(_ data: Data) -> Data {
        // RFC1951 byte-aligned stored blocks, not a second compression codec.
        var result = Data(), offset = 0
        while offset < data.count {
            let count = min(32_768, data.count - offset)
            result.append(offset + count == data.count ? 1 : 0)
            result.content16(UInt16(count)); result.content16(~UInt16(count))
            result.append(data.subdata(in: offset..<(offset + count))); offset += count
        }
        return result
    }

    @Test func cancelledCallerStillWaitsForLeaseCleanup() async throws {
        let fixture = try ContentFixture()
        let lease = try await fixture.provider.materialize(ContentRequest(source: try await fixture.archiveEntry(), purpose: .preview), control: TransferControl())
        let gate = ContentReleaseGate()
        let cleanup = Task { await gate.wait(); return await lease.release() }
        cleanup.cancel(); await gate.open()
        #expect(await cleanup.value.disposition == .released)
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    @Test func shutdownPreservesAdmittedOutputAndLateWorkerCannotPublishOrDeleteIt() async throws {
        let fixture = try ContentFixture()
        let gate = ContentPreparationGate()
        let provider = LocalItemContentProvider(registry: fixture.registry, originObserver: { fd, _ in try gate.block(fd: fd) })
        let request = ContentRequest(source: try await fixture.archiveEntry(), purpose: .externalOpen)
        let work = Task { try await provider.materialize(request, control: TransferControl()) }
        defer { gate.open(); work.cancel() }
        let timeout = Date().addingTimeInterval(3)
        while gate.file == nil, Date() < timeout { try await Task.sleep(for: .milliseconds(2)) }
        let file = try #require(gate.file)
        let report = try await fixture.registry.shutdown()
        #expect(report.contains { $0.url.path == file.deletingLastPathComponent().path })
        #expect(try Data(contentsOf: file) == Data("123456789".utf8))
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        // The queued worker finished after the shutdown decision: no late lease
        // was returned, and its ordinary failure cleanup could not unlink data.
        #expect(try Data(contentsOf: file) == Data("123456789".utf8))
        let nextLaunch = try await ContentLeaseRegistry(rootURL: fixture.exports).retainedArtifacts()
        #expect(nextLaunch.contains { $0.url.path == file.deletingLastPathComponent().path })
    }
}

private final class ContentFixture: @unchecked Sendable {
    let root: URL
    let archive: URL
    let archiveBytes: Data
    let exports: URL
    let registry: ContentLeaseRegistry
    let provider: LocalItemContentProvider
    let selectedName: String

    init(deflated: Bool = false, rawPayload: Data? = nil, contents: Data = Data("123456789".utf8),
         crc: UInt32 = 0xCBF43926, folder: Bool = false,
         trailing: Bool = false, truncated: Bool = false, directoryTimestamp: UInt32? = nil, originCompanion: Data? = nil,
         originCompanionPath: String? = nil, incorrectCompanionCRC: Bool = false,
         mode: UInt32 = 0o644, limits: ContentLimits = ContentLimits(),
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerContent-" + UUID().uuidString, isDirectory: true)
        archive = root.appendingPathComponent("fixture.zip")
        exports = root.appendingPathComponent("persistent-content", isDirectory: true)
        registry = ContentLeaseRegistry(rootURL: exports, limits: limits, now: now)
        provider = LocalItemContentProvider(registry: registry)
        selectedName = folder ? "folder" : "note.txt"
        let name = Data((folder ? "folder/note.txt" : "note.txt").utf8)
        var payload = rawPayload ?? (deflated ? Data([0x33,0x34,0x32,0x36,0x31,0x35,0x33,0xB7,0xB0,0x04,0x00]) : contents)
        if trailing { payload.append(0) }
        if truncated { payload = payload.dropLast(2) }
        let method: UInt16 = deflated ? 8 : 0
        var data = Data()
        data.content32(0x04034B50); data.content16(20); data.content16(0x800); data.content16(method)
        data.content16(0); data.content16(0x5821); data.content32(crc)
        data.content32(UInt32(payload.count)); data.content32(UInt32(contents.count)); data.content16(UInt16(name.count)); data.content16(0)
        data.append(name); data.append(payload)
        let directoryName = Data("folder/empty/".utf8)
        var directoryExtra = Data()
        if let directoryTimestamp {
            directoryExtra.content16(0x5455); directoryExtra.content16(5); directoryExtra.append(1)
            directoryExtra.content32(directoryTimestamp)
        }
        let directoryOffset = data.count
        if folder {
            data.content32(0x04034B50); data.content16(20); data.content16(0x800); data.content16(0)
            data.content16(0); data.content16(0x5821); data.content32(0); data.content32(0); data.content32(0)
            data.content16(UInt16(directoryName.count)); data.content16(UInt16(directoryExtra.count)); data.append(directoryName); data.append(directoryExtra)
        }
        let companionOffset = data.count
        let companionName = Data((originCompanionPath ?? (folder ? "__MACOSX/folder/._note.txt" : "__MACOSX/._note.txt")).utf8)
        if let originCompanion {
            data.content32(0x04034B50); data.content16(20); data.content16(0x800); data.content16(0)
            data.content16(0); data.content16(0x5821); data.content32(zipOperationReferenceCRC(originCompanion) ^ (incorrectCompanionCRC ? 1 : 0))
            data.content32(UInt32(originCompanion.count)); data.content32(UInt32(originCompanion.count))
            data.content16(UInt16(companionName.count)); data.content16(0); data.append(companionName); data.append(originCompanion)
        }
        let central = data.count
        var centralFile = Data()
        centralFile.content32(0x02014B50); centralFile.content16(0x0314); centralFile.content16(20); centralFile.content16(0x800); centralFile.content16(method)
        centralFile.content16(0); centralFile.content16(0x5821); centralFile.content32(crc)
        centralFile.content32(UInt32(payload.count)); centralFile.content32(UInt32(contents.count)); centralFile.content16(UInt16(name.count)); centralFile.content16(0)
        centralFile.content16(0); centralFile.content16(0); centralFile.content16(0); centralFile.content32((0o100000 | mode) << 16); centralFile.content32(0)
        centralFile.append(name); data.append(centralFile)
        if folder {
            data.content32(0x02014B50); data.content16(0x0314); data.content16(20); data.content16(0x800); data.content16(0)
            data.content16(0); data.content16(0x5821); data.content32(0); data.content32(0); data.content32(0)
            data.content16(UInt16(directoryName.count)); data.content16(UInt16(directoryExtra.count)); data.content16(0); data.content16(0); data.content16(0)
            data.content32(0o40755 << 16); data.content32(UInt32(directoryOffset)); data.append(directoryName); data.append(directoryExtra)
        }
        if let originCompanion {
            data.content32(0x02014B50); data.content16(0x0314); data.content16(20); data.content16(0x800); data.content16(0)
            data.content16(0); data.content16(0x5821); data.content32(zipOperationReferenceCRC(originCompanion) ^ (incorrectCompanionCRC ? 1 : 0))
            data.content32(UInt32(originCompanion.count)); data.content32(UInt32(originCompanion.count))
            data.content16(UInt16(companionName.count)); data.content16(0); data.content16(0); data.content16(0); data.content16(0)
            data.content32(0o100600 << 16); data.content32(UInt32(companionOffset)); data.append(companionName)
        }
        let centralSize = data.count - central
        let count: UInt16 = (folder ? 2 : 1) + (originCompanion == nil ? 0 : 1)
        data.content32(0x06054B50); data.content16(0); data.content16(0); data.content16(count); data.content16(count)
        data.content32(UInt32(centralSize)); data.content32(UInt32(central)); data.content16(0)
        archiveBytes = data
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try data.write(to: archive)
    }

    deinit {
        // Test-owned synthetic tree only. Production lease cleanup is separately
        // required to use its recorded descriptor ledger, never recursive paths.
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Content fixture cleanup failed: \(error)") }
    }

    func archiveEntry() async throws -> ItemOperationEntry {
        let location = try ArchiveLocation(archiveURL: archive)
        let snapshot = try await LocalZIPDirectoryLoader().snapshot(of: location.url, showHidden: true)
        let item = try #require(snapshot.items.first { $0.name == selectedName })
        let revision = try #require(snapshot.archiveRevision)
        return ItemOperationEntry(item: item, context: .archive(ArchiveOperationContext(location: location, revision: revision)))
    }

    func physicalEntry(_ url: URL) async throws -> ItemOperationEntry {
        let entries = try await LocalFileTransferImporter().capture(urlStrings: [url.absoluteString])
        let entry = try #require(entries.first)
        return ItemOperationEntry(item: entry.item, context: .filesystem(entry.source))
    }

    func extractionInputs() throws -> (ContentRecordingReader, ZIPCentralRecord, ZIPRecordLayout) {
        let reader = try ContentRecordingReader(archive)
        let manifest = try ZIPArchiveManifest.read(from: reader)
        let record = try #require(manifest.records.first)
        let validated = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [record.id]))
        let layout = try #require(validated.records[record.id])
        reader.reads.removeAll()
        return (reader, record, layout)
    }

    func exportedRegularFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: exports.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: exports, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try enumerator.compactMap { value -> URL? in
            guard let url = value as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}

private final class ContentTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

private final class ContentRecordingReader: ZIPPositionalReading {
    private let reader: ZIPFileReader
    var reads: [ZIPByteRange] = []
    var length: UInt64 { reader.length }
    var revision: ArchiveRevision { reader.revision }
    init(_ url: URL) throws { reader = try ZIPFileReader(url: url) }
    func read(offset: UInt64, count: Int) throws -> Data {
        reads.append(ZIPByteRange(offset: offset, length: UInt64(count)))
        return try reader.read(offset: offset, count: count)
    }
    func validateUnchanged() throws { try reader.validateUnchanged() }
}

private actor ContentReleaseGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { isOpen = true; waiter?.resume(); waiter = nil }
}

private final class ContentPreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var location: URL?
    var file: URL? { condition.lock(); defer { condition.unlock() }; return location }
    func block(fd: Int32) throws {
        guard let path = ContentFileIO.path(of: fd) else { throw ItemContentError.staleSource }
        condition.lock(); defer { condition.unlock() }
        location = URL(fileURLWithPath: path.path, isDirectory: false).standardizedFileURL
        while !opened { condition.wait() }
    }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
}

private extension Data {
    mutating func content16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func content32(_ value: UInt32) { content16(UInt16(truncatingIfNeeded: value)); content16(UInt16(truncatingIfNeeded: value >> 16)) }
}
