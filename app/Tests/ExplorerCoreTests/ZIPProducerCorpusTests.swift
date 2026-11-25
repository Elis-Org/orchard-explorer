import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// Native runner supplies an immutable, independently CRC-checked producer set.
/// A normal checkout has no generated native fixtures; that absence is an explicit skip.
@Suite struct ZIPProducerCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAXPLORER_ZIP_PRODUCER_CORPUS"] != nil),
          arguments: ["windows.zip", "ditto.zip", "ditto-sequestered.zip", "infozip.zip", "infozip-stored.zip"])
    func producerReadRenameDeleteAndAdd(_ filename: String) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["MAXPLORER_ZIP_PRODUCER_CORPUS"])
        let input = URL(fileURLWithPath: root).appendingPathComponent(filename)
        let original = try Data(contentsOf: input)
        let fixture = try ZIPOperationTestFixture(entries: [])
        try original.write(to: fixture.url)
        var reader = try ZIPFileReader(url: fixture.url)
        var manifest = try ZIPArchiveManifest.read(from: reader)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
        for record in manifest.records where record.kind == .file {
            _ = try ZIPContentExtraction.extract(record: record, layout: try #require(layout.records[record.id]), reader: reader,
                maximumBytes: 1_024 * 1_024 * 1_024, checkpoint: {}, consume: { _ in })
        }
        let targetName = filename == "windows.zip" ? "add-me.txt" : "plain.txt"
        let selected = try #require(manifest.records.first { $0.components.last == targetName })
        let parent = Array(selected.components.dropLast())
        var context = try await fixture.context(parent)
        var target = try fixture.location(selected.components)
        var rename = "PASS"
        do {
            _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: target, revision: context.revision), newName: "renamed-by-maxplorer.txt")], in: context, control: TransferControl(), onProgress: { _ in })
            target = try fixture.location(parent + ["renamed-by-maxplorer.txt"])
        } catch ArchiveOperationError.unsupported(let reason) where filename.hasPrefix("ditto") && reason.contains("AppleDouble") {
            rename = "REFUSED_AppleDouble"
            #expect(try Data(contentsOf: fixture.url) == original)
        }
        context = try await fixture.context(parent)
        var deletion = "PASS"
        do {
            _ = try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: target, revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        } catch ArchiveOperationError.unsupported(let reason) where filename.hasPrefix("ditto") && reason.contains("AppleDouble") {
            deletion = "REFUSED_AppleDouble"
            #expect(try Data(contentsOf: fixture.url) == original)
        }
        reader = try ZIPFileReader(url: fixture.url); manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(manifest.records.contains { $0.pathKey == ZIPArchiveManifest.pathKey(target.components) } == (deletion != "PASS"))
        let beforeLayout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
        var foreignPayloads: [Data: Data] = [:]
        for record in manifest.records where record.components.last?.hasPrefix("._") == true {
            var data = Data()
            _ = try ZIPContentExtraction.extract(record: record, layout: try #require(beforeLayout.records[record.id]), reader: reader,
                maximumBytes: 1_024 * 1_024, checkpoint: {}, consume: { data.append($0) })
            foreignPayloads[record.pathKey] = data
        }

        let addedURL = fixture.root.appendingPathComponent("physical-add.txt"), bytes = Data("producer addition checked\n".utf8)
        try bytes.write(to: addedURL)
        let origin = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/producer-add"], format: .binary, options: 0)
        #expect(origin.withUnsafeBytes { setxattr(addedURL.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) } == 0)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let item = try #require(snapshot.items.first { $0.name == "physical-add.txt" })
        let source = TransferEntry(source: FileOperationContext(directoryURL: fixture.root, directoryIdentity: try #require(snapshot.directoryIdentity)), item: item)
        let rootContext = try await fixture.context()
        let result = try await LocalArchiveOperations().modify([.add(source: source, destination: fixture.location(["added-by-maxplorer.txt"]), replacing: nil)], in: rootContext, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination != nil)
        reader = try ZIPFileReader(url: fixture.url); manifest = try ZIPArchiveManifest.read(from: reader)
        let added = try #require(manifest.records.first { $0.components == ["added-by-maxplorer.txt"] })
        #expect(added.crc32 == zipOperationReferenceCRC(bytes))
        #expect(manifest.records.contains { $0.components == ["__MACOSX", "._added-by-maxplorer.txt"] })
        let afterLayout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
        for (key, expected) in foreignPayloads {
            let record = try #require(manifest.records.first { $0.pathKey == key })
            var actual = Data()
            _ = try ZIPContentExtraction.extract(record: record, layout: try #require(afterLayout.records[record.id]), reader: reader,
                maximumBytes: 1_024 * 1_024, checkpoint: {}, consume: { actual.append($0) })
            #expect(actual == expected)
        }
        #expect(try Data(contentsOf: input) == original)
        print("ZIPCORPUS producer=\(filename == "windows.zip" ? "Windows-Explorer-updated" : filename) listing=PASS read=PASS rename=\(rename) delete=\(deletion) attributedAdd=PASS foreignMetadata=UNCHANGED")
    }
}
