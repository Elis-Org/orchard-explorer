import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPCompanionCollisionTests {
    @Test(arguments: ["add-sibling", "add-canonical", "rename-sibling", "rename-canonical"])
    func plainDestinationCannotAdoptRetainedOrphan(_ scenario: String) async throws {
        let orphan = scenario.hasSuffix("canonical") ? "__MACOSX/._a" : "._a"
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("b", contents: Data([2])), ZIPOperationTestEntry(orphan, contents: Data([0xfa]))])
        let context = try await fixture.context()
        let edit: ArchiveEdit
        if scenario.hasPrefix("add") {
            let source = fixture.root.appendingPathComponent("source")
            try Data([3]).write(to: source)
            let entry = try await capture(source)
            edit = .add(source: entry, destination: try fixture.location(["a"]), replacing: nil)
        } else {
            edit = .rename(source: try ArchiveMemberTarget(location: fixture.location(["b"]), revision: context.revision), newName: "a")
        }
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([edit], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func renamedFolderDescendantCannotAdoptCanonicalOrphan() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("old/leaf", contents: Data([1])), ZIPOperationTestEntry("__MACOSX/new/._leaf", contents: Data([0xfa]))])
        let context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["old"]), revision: context.revision), newName: "new")],
                in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func attributedAddCannotCreateAmbiguityBesideSiblingOrphan() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("._a", contents: Data([0xfa]))])
        let source = fixture.root.appendingPathComponent("source")
        try Data([3]).write(to: source); try mark(source)
        let entry = try await capture(source), context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["a"]), replacing: nil)],
                in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test(arguments: ["add-sibling", "add-canonical", "rename-sibling", "rename-canonical"])
    func ordinaryCompanionShapedDestinationCannotAttachToExistingOwner(_ scenario: String) async throws {
        let canonical = scenario.hasSuffix("canonical"), parent = canonical ? ["__MACOSX"] : []
        let from = parent + ["b"], to = parent + ["._a"]
        // The owner is an implicit directory, not just an explicit file row.
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a/child"), ZIPOperationTestEntry(from.joined(separator: "/"), contents: Data([3]))])
        let context = try await fixture.context(parent)
        let edit: ArchiveEdit
        if scenario.hasPrefix("add") {
            let source = fixture.root.appendingPathComponent("source")
            try Data([4]).write(to: source)
            let entry = try await capture(source)
            edit = .add(source: entry, destination: try fixture.location(to), replacing: nil)
        } else {
            edit = .rename(source: try ArchiveMemberTarget(location: fixture.location(from), revision: context.revision), newName: "._a")
        }
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([edit], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func folderRenameToMetadataDirectoryCannotAttachDescendant() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("a"), ZIPOperationTestEntry("old/._a", contents: Data([0xfa]))])
        let context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["old"]), revision: context.revision), newName: "__MACOSX")],
                in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func physicalFolderWithOrdinaryOwnerAndCompanionIsRefused() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let folder = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["x", "._x"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
        let entry = try await capture(folder), context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["folder"]), replacing: nil)],
                in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test(arguments: [false, true])
    func orphanRemovedOrRelocatedBySamePlanDoesNotBlockRename(relocate: Bool) async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("b"), ZIPOperationTestEntry("._a", contents: Data([0xfa]))])
        let context = try await fixture.context()
        let orphan = try ArchiveMemberTarget(location: fixture.location(["._a"]), revision: context.revision)
        let first: ArchiveEdit = relocate ? .rename(source: orphan, newName: "unrelated") : .remove(source: orphan)
        _ = try await LocalArchiveOperations().modify([first, .rename(source: ArchiveMemberTarget(location: fixture.location(["b"]), revision: context.revision), newName: "a")],
            in: context, control: TransferControl(), onProgress: { _ in })
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(Set(manifest.records.map(\.pathKey)) == Set((relocate ? ["a", "unrelated"] : ["a"]).map { Data($0.utf8) }))
    }

    @Test func standaloneCompanionShapedFileAndUnrelatedForeignMetadataRemainOrdinary() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("__MACOSX/._unrelated", contents: Data([0xfa]))])
        let source = fixture.root.appendingPathComponent("source")
        try Data([3]).write(to: source)
        let entry = try await capture(source), context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["._standalone"]), replacing: nil)],
            in: context, control: TransferControl(), onProgress: { _ in })
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(Set(manifest.records.map(\.pathKey)) == Set(["__MACOSX/._unrelated", "._standalone"].map { Data($0.utf8) }))
        #expect(manifest.records.first?.crc32 == zipOperationReferenceCRC(Data([0xfa])))
    }

    @Test func replacementRemovesItsOwnValidatedCompanion() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("source"), plain = fixture.root.appendingPathComponent("plain")
        try Data([1]).write(to: source); try mark(source); try Data([2]).write(to: plain)
        let marked = try await capture(source), initial = try await fixture.context(), destination = try fixture.location(["a"])
        _ = try await LocalArchiveOperations().modify([.add(source: marked, destination: destination, replacing: nil)], in: initial, control: TransferControl(), onProgress: { _ in })
        let context = try await fixture.context(), unmarked = try await capture(plain)
        let replacement = ArchiveReplacementTarget(member: ArchiveMemberTarget(location: destination, revision: context.revision))
        _ = try await LocalArchiveOperations().modify([.add(source: unmarked, destination: destination, replacing: replacement)], in: context, control: TransferControl(), onProgress: { _ in })
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(manifest.records.map(\.pathKey) == [Data("a".utf8)])
        #expect(manifest.records.first?.crc32 == zipOperationReferenceCRC(Data([2])))
    }

    @Test func generatedCanonicalCompanionCannotAlsoAttachToRetainedSiblingOwner() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("__MACOSX/a", contents: Data([8]))])
        let source = fixture.root.appendingPathComponent("source")
        try Data([3]).write(to: source); try mark(source)
        let entry = try await capture(source), context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["a"]), replacing: nil)],
                in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test(arguments: ["retained-explicit", "retained-implicit", "introduced-explicit"])
    func realMetadataDirectoryOwnerIsNeverExcludedAsGeneratedTopology(_ scenario: String) async throws {
        let existing: [ZIPOperationTestEntry]
        switch scenario {
        case "retained-explicit": existing = [ZIPOperationTestEntry("__MACOSX/F/", attributes: UInt32(0o40755) << 16)]
        case "retained-implicit": existing = [ZIPOperationTestEntry("__MACOSX/F/ordinary", contents: Data([8]))]
        default: existing = []
        }
        let fixture = try ZIPOperationTestFixture(entries: existing)
        let source = fixture.root.appendingPathComponent("source"), leaf = source.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([3]).write(to: leaf); try mark(source); try mark(leaf)
        let entry = try await capture(source), context = try await fixture.context()
        var edits: [ArchiveEdit] = try [.add(source: entry, destination: fixture.location(["F"]), replacing: nil)]
        if scenario == "introduced-explicit" {
            let metadata = fixture.root.appendingPathComponent("metadata")
            try FileManager.default.createDirectory(at: metadata.appendingPathComponent("F"), withIntermediateDirectories: true)
            let metadataEntry = try await capture(metadata)
            edits.append(.add(source: metadataEntry, destination: try fixture.location(["__MACOSX"]), replacing: nil))
        }
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify(edits, in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try Data(contentsOf: leaf) == Data([3]))
    }

    private func capture(_ url: URL) async throws -> TransferEntry {
        let snapshot = try await LocalDirectoryLoader().snapshot(of: url.deletingLastPathComponent(), showHidden: true)
        let item = try #require(snapshot.items.first { Data($0.name.utf8) == Data(url.lastPathComponent.utf8) })
        return TransferEntry(source: FileOperationContext(directoryURL: url.deletingLastPathComponent(), directoryIdentity: try #require(snapshot.directoryIdentity)), item: item)
    }
    private func mark(_ url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/collision-fixture"], format: .binary, options: 0)
        guard value.withUnsafeBytes({ setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
    }
}
