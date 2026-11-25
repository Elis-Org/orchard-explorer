import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPManifestOperationsTests {
    @Test func manifestRetainsExactNamesRawMetadataAndImplicitDirectories() throws {
        let extra = Data([0xfe, 0xca, 2, 0, 0x42, 0x43])
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("inside/café.txt", contents: Data("first".utf8), extra: extra, comment: Data("kept".utf8)),
            ZIPOperationTestEntry("inside/cafe\u{301}.txt", contents: Data("second".utf8)),
            ZIPOperationTestEntry("empty/", attributes: UInt32(0o40755) << 16)
        ], comment: Data("archive note".utf8))
        let reader = try ZIPFileReader(url: fixture.url)
        let manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(manifest.records.count == 3)
        #expect(manifest.archiveComment == Data("archive note".utf8))
        let selection = try manifest.selection(at: fixture.location(["inside"]))
        #expect(selection.isDirectory)
        #expect(selection.records.count == 2)
        #expect(Set(selection.records.map(\.pathKey)).count == 2)
        #expect(selection.records[0].extraBytes == extra)
        #expect(selection.records[0].commentBytes == Data("kept".utf8))
        #expect(selection.directories.contains { $0.components == ["inside"] && !$0.isExplicit })
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func validatedLayoutPointsAtActualPayloadAndRetainsUnixPermissions() throws {
        let contents = Data("#!/bin/sh\nexit 0\n".utf8)
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("run.sh", contents: contents, attributes: UInt32(0o100755) << 16)
        ])
        let reader = try ZIPFileReader(url: fixture.url)
        let manifest = try ZIPArchiveManifest.read(from: reader)
        let record = try #require(manifest.records.first)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader,
                                                       scope: .content(recordIDs: [record.id]))
        let member = try #require(layout.records[record.id])
        #expect(try reader.read(offset: member.payloadRange.offset, count: Int(member.payloadRange.length)) == contents)
        #expect(member.unixPermissions == 0o755)
        #expect(member.modifiedAt != nil)
        #expect(member.payloadRange.length == UInt64(contents.count))
        try reader.validateUnchanged()
    }

    @Test func incrementalCRCMatchesStandardVectorAndChunkBoundaries() throws {
        var crc = ZIPCRC32()
        try crc.update(Data("1234".utf8)); try crc.update(Data("56789".utf8))
        #expect(crc.value == 0xcbf43926)
        #expect(try ZIPCRC32.checksum(Data()) == 0)
    }

    @Test func malformedOrConflictingExtendedTimestampsFallBackToDOS() {
        let fallback = Date(timeIntervalSince1970: 99), correct = Date(timeIntervalSince1970: 42)
        let valid = Data([0x55, 0x54, 5, 0, 1, 42, 0, 0, 0])
        let malformed = Data([0x55, 0x54, 2, 0, 1, 42])
        #expect(ZIPExtraFields.modificationDate(central: malformed, local: valid, fallback: fallback) == fallback)
        #expect(ZIPExtraFields.modificationDate(central: valid, local: malformed, fallback: fallback) == fallback)
        #expect(ZIPExtraFields.modificationDate(central: Data(), local: valid, fallback: fallback) == correct)
        let centralInfoZIP = Data([0x55, 0x54, 5, 0, 3, 42, 0, 0, 0])
        let localInfoZIP = Data([0x55, 0x54, 9, 0, 3, 42, 0, 0, 0, 7, 0, 0, 0])
        #expect(ZIPExtraFields.modificationDate(central: centralInfoZIP, local: localInfoZIP, fallback: fallback) == correct)
        let conflicting = Data([0x55, 0x54, 5, 0, 1, 43, 0, 0, 0])
        #expect(ZIPExtraFields.modificationDate(central: valid, local: conflicting, fallback: fallback) == fallback)
    }

    @Test func localNameDisagreementIsRejectedBeforePayloadUse() throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note", contents: Data([1, 2, 3]))])
        var changed = fixture.bytes; changed[30] = UInt8(ascii: "X")
        try changed.write(to: fixture.url)
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(throws: ZIPListingError.corrupt) {
            try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [0]))
        }
    }

    @Test func storedSizeMismatchAndCancelledValidationAreRefused() throws {
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("note", contents: Data([1, 2, 3]), compressed: Data([1, 2, 3, 4]))
        ])
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(throws: ZIPListingError.corrupt) {
            try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [0]))
        }
        #expect(throws: CancellationError.self) {
            try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [0]),
                                              checkpoint: { throw CancellationError() })
        }
    }

    @Test func committedRenameRemapsHistoryWithoutAddingNavigationOrLosingForwardState() throws {
        let archive = URL(fileURLWithPath: "/tmp/history.zip")
        let old = try ArchiveLocation(archiveURL: archive, components: ["old"]).url
        let child = try ArchiveLocation(archiveURL: archive, components: ["old", "child"]).url
        let renamed = try ArchiveLocation(archiveURL: archive, components: ["new"]).url
        let renamedChild = try ArchiveLocation(archiveURL: archive, components: ["new", "child"]).url
        let physical = URL(fileURLWithPath: "/tmp", isDirectory: true)
        var history = NavigationHistory(initialURL: physical)
        history.navigate(to: old); history.navigate(to: child); history.goBack()
        history.remapLocations { $0 == old ? renamed : $0 == child ? renamedChild : $0 }
        #expect(history.current == renamed)
        #expect(history.backStack == [physical])
        #expect(history.forwardStack == [renamedChild])
        #expect(history.goForward() == renamedChild)
    }

    @Test func renameChangesLogicalNameAndPreservesMemberBytes() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("before.txt", contents: Data("unchanged payload".utf8))
        ])
        let context = try await fixture.context()
        let before = try fixture.location(["before.txt"])
        let result = try await LocalArchiveOperations().modify([
            .rename(source: ArchiveMemberTarget(location: before, revision: context.revision), newName: "after.txt")
        ], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.previousRevision == context.revision)
        #expect(result.revision != nil && result.revision != context.revision)
        #expect(result.renamedLocations.first?.destinationURL == (try fixture.location(["after.txt"])).url)
        let listed = try await LocalZIPDirectoryLoader().contents(of: context.location.url, showHidden: true)
        #expect(listed.map(\.name) == ["after.txt"])
        let bytes = try Data(contentsOf: fixture.url)
        #expect(bytes.range(of: Data("unchanged payload".utf8)) != nil)
    }

    @Test func deletingLastImplicitChildRemovesItsSynthesizedParent() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("implicit/only.txt", contents: Data([7]))])
        let context = try await fixture.context(["implicit"])
        let child = try fixture.location(["implicit", "only.txt"])
        _ = try await LocalArchiveOperations().modify([
            .remove(source: ArchiveMemberTarget(location: child, revision: context.revision))
        ], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(try await LocalZIPDirectoryLoader().contents(of: fixture.location().url, showHidden: true).isEmpty)
    }
}
