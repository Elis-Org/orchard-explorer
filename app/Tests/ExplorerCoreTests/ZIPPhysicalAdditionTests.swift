import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPPhysicalAdditionTests {
    @Test func spaceAdvisoryDoesNotUseUncompressedSizeAsAHardRefusal() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("compressible")
        try Data(repeating: 0, count: 1_024 * 1_024).write(to: source)
        let entry = try await capture(source), context = try await fixture.context()
        var hooks = ArchiveMutationHooks(); hooks.availableSpace = { _ in 4_096 }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([.add(source: entry, destination: fixture.location(["new"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination != nil)
        #expect(try Data(contentsOf: fixture.url).count < 4_096)
    }

    @Test func recursiveAddPreservesBytesEmptyFoldersPermissionsAndLocalDOSDate() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep", contents: Data([8]))])
        let source = fixture.root.appendingPathComponent("source"), empty = source.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("café.txt"), bytes = Data("physical source bytes".utf8)
        try bytes.write(to: file)
        #expect(chmod(file.path, 0o6751) == 0)
        let date = Date(timeIntervalSince1970: 1_769_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let entry = try await capture(source), context = try await fixture.context()
        let result = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["incoming"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination?.locations == [try fixture.location(["incoming"])])
        #expect(result.warning == nil)
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(Set(manifest.records.map { $0.components.joined(separator: "/") }) == ["keep", "incoming", "incoming/empty", "incoming/café.txt"])
        let record = try #require(manifest.records.first { $0.components.last == "café.txt" })
        #expect(record.method == 8 && record.flags & 0x800 != 0 && record.unixPermissions == 0o751)
        #expect(abs(try #require(record.modifiedAt).timeIntervalSince(date)) < 2)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [record.id]))
        var actual = Data()
        _ = try ZIPContentExtraction.extract(record: record, layout: layout.records[record.id]!, reader: reader,
            maximumBytes: 1_024, checkpoint: {}, consume: { actual.append($0) })
        #expect(actual == bytes)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func replacementFiltersOldSubtreeOnceAndPreservesOtherMembers() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("target/old", contents: Data([1])), ZIPOperationTestEntry("keep", contents: Data([9]))])
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([2]).write(to: source.appendingPathComponent("new"))
        let entry = try await capture(source), context = try await fixture.context(), destination = try fixture.location(["target"])
        let replaced = ArchiveReplacementTarget(member: ArchiveMemberTarget(location: destination, revision: context.revision))
        let result = try await LocalArchiveOperations().modify([.add(source: entry, destination: destination, replacing: replaced)], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination != nil)
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(Set(manifest.records.map { $0.components.joined(separator: "/") }) == ["keep", "target", "target/new"])
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("new").path))
    }

    @Test func stalePhysicalSourceBeforeCommitRefusesAndRetainsBothOriginals() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep")])
        let source = fixture.root.appendingPathComponent("source.txt")
        try Data([1, 2, 3]).write(to: source)
        let entry = try await capture(source), context = try await fixture.context()
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in try Data([7, 8, 9, 10]).write(to: source) }
        await #expect(throws: FileOperationError.staleSource) {
            try await LocalArchiveOperations(hooks: hooks).modify([.add(source: entry, destination: fixture.location(["new"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try Data(contentsOf: source) == Data([7, 8, 9, 10]))
    }

    @Test func symlinkAndSelfArchiveAddRefuseBeforePublication() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep")])
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        for source in [link, fixture.url] {
            let entry = try await capture(source), context = try await fixture.context()
            await #expect(throws: ArchiveOperationError.self) {
                try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["new"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
            }
            #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        }
    }

    @Test func cancellationAfterSwapReportsTheCommittedAddition() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("keep")])
        let source = fixture.root.appendingPathComponent("source.txt"); try Data([1]).write(to: source)
        let entry = try await capture(source), context = try await fixture.context(), control = TransferControl()
        var hooks = ArchiveMutationHooks(); hooks.afterSwap = { _, _ in control.cancel() }
        let result = try await LocalArchiveOperations(hooks: hooks).modify([.add(source: entry, destination: fixture.location(["new"]), replacing: nil)], in: context, control: control, onProgress: { _ in })
        #expect(result.verifiedDestination != nil)
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.count == 2)
    }

    private func capture(_ url: URL) async throws -> TransferEntry {
        let parent = url.deletingLastPathComponent()
        let snapshot = try await LocalDirectoryLoader().snapshot(of: parent, showHidden: true)
        let item = try #require(snapshot.items.first { Data($0.name.utf8) == Data(url.lastPathComponent.utf8) })
        return TransferEntry(source: FileOperationContext(directoryURL: parent, directoryIdentity: try #require(snapshot.directoryIdentity)), item: item)
    }
}
