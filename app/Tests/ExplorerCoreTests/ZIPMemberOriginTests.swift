import Darwin
import CoreServices
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPMemberOriginTests {
    @Test func boundedNativeRoundTripPreservesWhereFromsWithoutNamedScratchLeaks() throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let directory = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0); defer { close(directory) }
        let origins = ZIPOriginAttributes(quarantine: nil, whereFroms: try whereFroms("download"))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let data = try ZIPMemberOrigins.pack(origins, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        try ZIPMemberOrigins.validateOriginCompanion(data)
        let actual = try ZIPMemberOrigins.unpack(data, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        #expect(actual == origins)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == before)
    }

    @Test func exactCompanionIndexFindsMetadataWithoutTreatingItAsAUserMember() throws {
        let bytes = ZIPOperationTestArchive(entries: [ZIPOperationTestEntry("folder/note"), ZIPOperationTestEntry("__MACOSX/folder/._note")]).bytes
        let fixture = try ZIPOperationTestFixture(entries: [])
        try bytes.write(to: fixture.url)
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        let index = try ZIPOriginCompanionIndex(manifest: manifest)
        let associated = try index.companion(for: ["folder", "note"])
        let record = try #require(associated)
        #expect(record.components == ["__MACOSX", "folder", "._note"])
        #expect(index.memberComponents(forCompanionRecordID: record.id) == ["folder", "note"])
        #expect(try index.companion(for: ["unrelated"]) == nil)
    }

    @Test func addingDownloadedFileCreatesNativeReadableOriginCompanion() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("download.txt")
        try Data("downloaded content".utf8).write(to: source)
        let origin = try whereFroms("source")
        try setOrigin(source, origin)
        let entry = try await capture(source), context = try await fixture.context()
        let result = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["note.txt"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination != nil)
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        let companion = try #require(manifest.records.first { $0.components == ["__MACOSX", "._note.txt"] })
        let data = try extract(companion, manifest: manifest, reader: reader)
        #expect(try nativeUnpackWhereFroms(data, root: fixture.root) == origin)
    }

    @Test func renameMovesMemberAndOriginCompanionTogether() async throws {
        let origin = try whereFroms("rename")
        let payload = try nativeCompanion(origin)
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note", contents: Data([1])), ZIPOperationTestEntry("__MACOSX/._note", contents: payload)])
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["note"]), revision: context.revision), newName: "renamed")], in: context, control: TransferControl(), onProgress: { _ in })
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(Set(manifest.records.map { $0.components.joined(separator: "/") }) == ["renamed", "__MACOSX/._renamed"])
        let companion = try #require(manifest.records.first { $0.components == ["__MACOSX", "._renamed"] })
        #expect(try extract(companion, manifest: manifest, reader: reader) == payload)
    }

    @Test func removeDeletesAssociatedOriginInOneRewrite() async throws {
        let payload = try nativeCompanion(whereFroms("remove"))
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note"), ZIPOperationTestEntry("__MACOSX/._note", contents: payload)])
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["note"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.isEmpty)
    }

    @Test func independentRecognizedCompanionDeleteIsRefused() async throws {
        let payload = try nativeCompanion(whereFroms("protected"))
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note"), ZIPOperationTestEntry("__MACOSX/._note", contents: payload)])
        let context = try await fixture.context(["__MACOSX"])
        await #expect(throws: ArchiveOperationError.self) {
            try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["__MACOSX", "._note"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func replacingAttributedMemberWithPlainFileRemovesOldCompanion() async throws {
        let payload = try nativeCompanion(whereFroms("old"))
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note"), ZIPOperationTestEntry("__MACOSX/._note", contents: payload)])
        let source = fixture.root.appendingPathComponent("plain")
        try Data([7]).write(to: source)
        let entry = try await capture(source), context = try await fixture.context(), destination = try fixture.location(["note"])
        let replacement = ArchiveReplacementTarget(member: ArchiveMemberTarget(location: destination, revision: context.revision))
        _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: destination, replacing: replacement)], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)).records.map(\.components) == [["note"]])
    }

    @Test(arguments: [false, true])
    func realMetadataFolderCannotTakeCanonicalOwnersCompanion(rename: Bool) async throws {
        let payload = try nativeCompanion(whereFroms("canonical-owner"))
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("F/leaf", contents: Data([1])),
            ZIPOperationTestEntry("__MACOSX/F/ordinary", contents: Data([2])),
            ZIPOperationTestEntry("__MACOSX/._F", contents: payload)])
        let context = try await fixture.context(["__MACOSX"])
        let target = try ArchiveMemberTarget(location: fixture.location(["__MACOSX", "F"]), revision: context.revision)
        let edit: ArchiveEdit = rename ? .rename(source: target, newName: "G") : .remove(source: target)
        await #expect(throws: ArchiveOperationError.self) {
            _ = try await LocalArchiveOperations().modify([edit], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func nestedAttributedTreeSurvivesAddAndParentRename() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let parent = fixture.root.appendingPathComponent("source"), folder = parent.appendingPathComponent("F"), leaf = folder.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: leaf)
        for (index, url) in [parent, folder, leaf].enumerated() { try setOrigin(url, whereFroms("nested-\(index)")) }
        let entry = try await capture(parent), initial = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["P"]), replacing: nil)], in: initial, control: TransferControl(), onProgress: { _ in })
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["P"]), revision: context.revision), newName: "Q")],
            in: context, control: TransferControl(), onProgress: { _ in })
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        let paths = [["Q"], ["Q", "F"], ["Q", "F", "leaf"]]
        for (index, path) in paths.enumerated() {
            let key = ZIPArchiveManifest.pathKey(ZIPOriginCompanionIndex.components(for: path))
            let record = try #require(manifest.records.first { $0.pathKey == key })
            let bytes = try extract(record, manifest: manifest, reader: reader)
            #expect(try nativeUnpackWhereFroms(bytes, root: fixture.root) == whereFroms("nested-\(index)"))
        }
        let content = try #require(manifest.records.first { $0.pathKey == Data("Q/F/leaf".utf8) })
        #expect(try extract(content, manifest: manifest, reader: reader) == Data([1, 2, 3]))
    }

    @Test func recursiveOriginsAndEmptyDirectoryFollowFolderRename() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let folder = fixture.root.appendingPathComponent("folder"), empty = folder.appendingPathComponent("empty"), file = folder.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data([4]).write(to: file)
        for (index, url) in [folder, empty, file].enumerated() { try setOrigin(url, whereFroms("node-\(index)")) }
        let source = try await capture(folder), initial = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.add(source: source, destination: fixture.location(["incoming"]), replacing: nil)], in: initial, control: TransferControl(), onProgress: { _ in })
        let context = try await fixture.context()
        _ = try await LocalArchiveOperations().modify([.rename(source: ArchiveMemberTarget(location: fixture.location(["incoming"]), revision: context.revision), newName: "renamed")], in: context, control: TransferControl(), onProgress: { _ in })
        let reader = try ZIPFileReader(url: fixture.url), manifest = try ZIPArchiveManifest.read(from: reader)
        #expect(Set(manifest.records.map { $0.components.joined(separator: "/") }) == ["renamed", "renamed/empty", "renamed/leaf", "__MACOSX/._renamed", "__MACOSX/renamed/._empty", "__MACOSX/renamed/._leaf"])
        for (index, components) in [["renamed"], ["renamed", "empty"], ["renamed", "leaf"]].enumerated() {
            let record = try #require(manifest.records.first { $0.components == ZIPOriginCompanionIndex.components(for: components) })
            let bytes = try extract(record, manifest: manifest, reader: reader)
            #expect(try nativeUnpackWhereFroms(bytes, root: fixture.root) == whereFroms("node-\(index)"))
        }
    }

    @Test func malformedOrBroaderAppleDoubleCannotReachNativeUnpack() throws {
        let valid = try nativeCompanion(whereFroms("validation"))
        var finderInfo = valid; finderInfo[50] = 1
        var fork = valid; fork[49] = 1
        var unknownName = valid; unknownName[131] = 120
        var overlap = valid; overlap.replaceSubrange(120..<124, with: [0, 0, 0, 119])
        var extra = valid; extra.append(1)
        for data in [Data(), finderInfo, fork, unknownName, overlap, extra] {
            #expect(throws: ArchiveOperationError.self) { try ZIPMemberOrigins.validateOriginCompanion(data) }
        }
        try ZIPMemberOrigins.validateOriginCompanion(valid)
        let whereName = "com.apple.metadata:kMDItemWhereFroms"
        let duplicate = originEnvelope(basedOn: valid, fields: [(whereName, Data([1])), (whereName, Data([2]))])
        let acl = originEnvelope(basedOn: valid, fields: [("com.apple.system.Security", Data([1]))])
        var flagged = valid; flagged[129] = 1
        for bytes in [duplicate, acl, flagged] {
            #expect(throws: ArchiveOperationError.self) { try ZIPMemberOrigins.validateOriginCompanion(bytes) }
        }
        // Check the test encoder's framing independently of the negative names.
        let encoded = originEnvelope(basedOn: valid, fields: [(whereName, try whereFroms("independent"))])
        try ZIPMemberOrigins.validateOriginCompanion(encoded)
        let fixture = try ZIPOperationTestFixture(entries: [])
        #expect(try nativeUnpackWhereFroms(encoded, root: fixture.root) == whereFroms("independent"))
    }

    @Test func canonicalAndSameParentCompanionsAreAmbiguousWithoutChangingArchive() async throws {
        let payload = try nativeCompanion(whereFroms("ambiguous"))
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("note"), ZIPOperationTestEntry("._note", contents: payload), ZIPOperationTestEntry("__MACOSX/._note", contents: payload)])
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)), index = try ZIPOriginCompanionIndex(manifest: manifest)
        #expect(throws: ArchiveOperationError.self) { try index.companion(for: ["note"]) }
        let context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            try await LocalArchiveOperations().modify([.remove(source: ArchiveMemberTarget(location: fixture.location(["note"]), revision: context.revision))], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func companionAssociationPreservesExactUnicodeAndCaseBytes() throws {
        let names = ["caf\u{e9}", "cafe\u{301}", "Case", "case"]
        let fixture = try ZIPOperationTestFixture(entries: names.flatMap { [ZIPOperationTestEntry($0), ZIPOperationTestEntry("__MACOSX/._" + $0)] })
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url)), index = try ZIPOriginCompanionIndex(manifest: manifest)
        var ids: Set<Int> = []
        for name in names {
            let associated = try index.companion(for: [name]), record = try #require(associated)
            #expect(record.pathKey == Data(("__MACOSX/._" + name).utf8))
            let member = try #require(index.memberComponents(forCompanionRecordID: record.id))
            #expect(ZIPArchiveManifest.pathKey(member) == Data(name.utf8))
            ids.insert(record.id)
        }
        #expect(ids.count == 4)
    }

    @Test(arguments: ["__MACOSX", "__MACOSX/._incoming"])
    func generatedCompanionCollisionRefusesBeforePublication(_ occupied: String) async throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry(occupied, contents: Data([4]))])
        let source = fixture.root.appendingPathComponent("source")
        try Data([2]).write(to: source); try setOrigin(source, whereFroms("collision"))
        let entry = try await capture(source), context = try await fixture.context()
        await #expect(throws: ArchiveOperationError.self) {
            try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(["incoming"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try Data(contentsOf: source) == Data([2]))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)).contains { $0.hasPrefix(".maxplorer-zip-") })
    }

    @Test func generatedCompanionDepthCountsAgainstPathLimit() async throws {
        let parent = (0..<127).map { "d\($0)" }
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry(parent.joined(separator: "/") + "/", attributes: UInt32(0o40755) << 16)])
        let source = fixture.root.appendingPathComponent("source")
        try Data([2]).write(to: source); try setOrigin(source, whereFroms("depth"))
        let entry = try await capture(source), context = try await fixture.context(parent)
        await #expect(throws: ZIPListingError.limitExceeded) {
            try await LocalArchiveOperations().modify([.add(source: entry, destination: fixture.location(parent + ["incoming"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func generatedCompanionBytesCountAgainstPathLimit() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("source")
        try Data([2]).write(to: source); try setOrigin(source, whereFroms("path-bytes"))
        let entry = try await capture(source), context = try await fixture.context()
        let destination = try fixture.location([String(repeating: "n", count: 4_090)])
        await #expect(throws: ZIPListingError.limitExceeded) {
            try await LocalArchiveOperations().modify([.add(source: entry, destination: destination, replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test(arguments: [65_534, 99_999])
    func generatedCompanionCountsInZIP64TransitionAndRecordLimit(_ count: Int) async throws {
        let fixture = try ZIPOperationTestFixture(entries: (0..<count).map { ZIPOperationTestEntry("e\($0)") }, zip64: count >= 65_535)
        let source = fixture.root.appendingPathComponent("source")
        try Data([2]).write(to: source); try setOrigin(source, whereFroms("count"))
        let entry = try await capture(source), context = try await fixture.context()
        let edits: [ArchiveEdit] = try [.add(source: entry, destination: fixture.location(["incoming"]), replacing: nil)]
        if count == 99_999 {
            await #expect(throws: ZIPListingError.limitExceeded) {
                try await LocalArchiveOperations().modify(edits, in: context, control: TransferControl(), onProgress: { _ in })
            }
            #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
            #expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)).contains { $0.hasPrefix(".maxplorer-zip-") })
        } else {
            _ = try await LocalArchiveOperations().modify(edits, in: context, control: TransferControl(), onProgress: { _ in })
            let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
            #expect(manifest.records.count == 65_536)
            let zip64 = try #require(manifest.envelope.rawZIP64Record)
            #expect(ZIPBytes.u64(Array(zip64), 32) == 65_536)
            let origin = manifest.records.first { $0.pathKey == Data("__MACOSX/._incoming".utf8) }
            #expect(origin != nil)
        }
    }

    @Test func budgetsAndCancellationCloseEveryUnlinkedScratch() throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let directory = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0); defer { close(directory) }
        let attributes = ZIPOriginAttributes(quarantine: nil, whereFroms: try whereFroms("budget"))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(throws: ZIPListingError.limitExceeded) {
            try ZIPMemberOrigins.pack(attributes, scratchDirectory: directory, budget: ZIPOriginBudget(maximumAttributeBytes: 1), checkpoint: {})
        }
        #expect(throws: ZIPListingError.limitExceeded) {
            try ZIPMemberOrigins.pack(attributes, scratchDirectory: directory, budget: ZIPOriginBudget(maximumTotalBytes: 1), checkpoint: {})
        }
        var callbacks = 0
        #expect(throws: CancellationError.self) {
            try ZIPMemberOrigins.pack(attributes, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {
                callbacks += 1
                if callbacks >= 2 { throw CancellationError() }
            })
        }
        #expect(callbacks >= 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == names)
    }

    @Test func absentOriginsLeaveExistingSystemMetadataAlone() throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let file = fixture.root.appendingPathComponent("new-output")
        try Data().write(to: file)
        let existing = try whereFroms("system-created")
        try setOrigin(file, existing)
        let directory = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC), descriptor = open(file.path, O_RDWR | O_CLOEXEC)
        #expect(directory >= 0 && descriptor >= 0); defer { close(directory); close(descriptor) }
        let result = try ZIPMemberOrigins.apply(member: nil, outer: ZIPOriginAttributes(quarantine: nil, whereFroms: nil),
            to: descriptor, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        #expect(result.whereFroms == existing)
    }

    @Test func nativeApplyUsesOuterQuarantineAndMemberProvenanceWithoutChangingPayload() throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let directory = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0); defer { close(directory) }
        func publicSource(_ name: String) throws -> (URL, ZIPOriginAttributes) {
            let url = fixture.root.appendingPathComponent(name)
            try Data().write(to: url)
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                           kLSQuarantineAgentNameKey as String: name]
            var mutable = url; try mutable.setResourceValues(values)
            try setOrigin(url, whereFroms(name))
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            return (url, try ZIPMemberOrigins.capture(from: fd, budget: ZIPOriginBudget()))
        }
        let (memberURL, member) = try publicSource("Member"), (outerURL, outer) = try publicSource("Outer")
        #expect(member.quarantine != nil && outer.quarantine != nil)
        let packed = try ZIPMemberOrigins.pack(member, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        let decoded = try ZIPMemberOrigins.unpack(packed, scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        let output = fixture.root.appendingPathComponent("output"), content = Data([8, 9, 10])
        try content.write(to: output)
        let fd = open(output.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        let applied = try ZIPMemberOrigins.apply(member: decoded, outer: outer, to: fd,
            scratchDirectory: directory, budget: ZIPOriginBudget(), checkpoint: {})
        #expect(applied.quarantine != nil && applied.whereFroms == member.whereFroms)
        #expect(try Data(contentsOf: output) == content)
        let expected = try outerURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties ?? [:]
        let actual = try output.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties ?? [:]
        let keys = Set([kLSQuarantineAgentNameKey as String, kLSQuarantineTimeStampKey as String,
                        kLSQuarantineTypeKey as String, "LSQuarantineEventIdentifier"])
        #expect(NSDictionary(dictionary: expected.filter { keys.contains($0.key) }).isEqual(to: actual.filter { keys.contains($0.key) }))
        #expect(memberURL != outerURL)
    }

    @Test func sourceOriginChangeBeforeSwapRetainsArchiveAndSource() async throws {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("source")
        try Data([1]).write(to: source); try setOrigin(source, whereFroms("before"))
        let entry = try await capture(source), context = try await fixture.context(), after = try whereFroms("after")
        var hooks = ArchiveMutationHooks()
        hooks.beforeSwap = { _, _ in
            guard after.withUnsafeBytes({ setxattr(source.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
        }
        await #expect(throws: FileOperationError.staleSource) {
            try await LocalArchiveOperations(hooks: hooks).modify([.add(source: entry, destination: fixture.location(["new"]), replacing: nil)], in: context, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
        #expect(try Data(contentsOf: source) == Data([1]))
    }

    private func whereFroms(_ label: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/" + label], format: .binary, options: 0)
    }
    private func setOrigin(_ url: URL, _ value: Data) throws {
        guard value.withUnsafeBytes({ setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
    }
    private func capture(_ url: URL) async throws -> TransferEntry {
        let parent = url.deletingLastPathComponent(), snapshot = try await LocalDirectoryLoader().snapshot(of: url.deletingLastPathComponent(), showHidden: true)
        return TransferEntry(source: FileOperationContext(directoryURL: parent, directoryIdentity: try #require(snapshot.directoryIdentity)), item: try #require(snapshot.items.first { $0.name == url.lastPathComponent }))
    }
    private func extract(_ record: ZIPCentralRecord, manifest: ZIPArchiveManifest, reader: ZIPFileReader) throws -> Data {
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [record.id]))
        var data = Data()
        _ = try ZIPContentExtraction.extract(record: record, layout: try #require(layout.records[record.id]), reader: reader, maximumBytes: 1_024 * 1_024, checkpoint: {}, consume: { data.append($0) })
        return data
    }
    /// Independent system-produced metadata fixture; does not call the new codec.
    private func nativeCompanion(_ origin: Data) throws -> Data {
        let fixture = try ZIPOperationTestFixture(entries: [])
        let source = fixture.root.appendingPathComponent("source"), packed = fixture.root.appendingPathComponent("packed")
        try Data().write(to: source); try setOrigin(source, origin)
        let from = open(source.path, O_RDONLY | O_CLOEXEC), to = open(packed.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard from >= 0 && to >= 0 else { throw POSIXError(.EIO) }; defer { close(from); close(to) }
        // Named Foundation fixtures may acquire unrelated system attributes.
        // This independent native fixture intentionally serializes only origins,
        // just as its test name promises; broader metadata has separate cases.
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, _ in
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_XATTR, stage == COPYFILE_START {
                var name: UnsafePointer<CChar>?
                guard copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &name) == 0, let name else { return COPYFILE_QUIT }
                let text = String(cString: name)
                if text != "com.apple.metadata:kMDItemWhereFroms" && text != "com.apple.quarantine" {
                    print("ORIGIN_FIXTURE excluded unrelated native attribute=\(text)")
                    return COPYFILE_SKIP
                }
            }
            return COPYFILE_CONTINUE
        }
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              fcopyfile(from, to, state, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_PACK)) == 0 else { throw POSIXError(.EIO) }
        return try Data(contentsOf: packed)
    }
    private func nativeUnpackWhereFroms(_ data: Data, root: URL) throws -> Data? {
        let packed = root.appendingPathComponent(UUID().uuidString), output = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: packed)
        let from = open(packed.path, O_RDONLY | O_CLOEXEC), to = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard from >= 0 && to >= 0 else { throw POSIXError(.EIO) }; defer { close(from); close(to) }
        guard fcopyfile(from, to, nil, copyfile_flags_t(COPYFILE_UNPACK)) == 0 else { throw POSIXError(.EIO) }
        let count = fgetxattr(to, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        if count < 0 && errno == ENOATTR { return nil }
        guard count >= 0 else { throw POSIXError(.EIO) }
        var value = Data(count: count)
        guard value.withUnsafeMutableBytes({ fgetxattr(to, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == count else { throw POSIXError(.EIO) }
        return value
    }

    /// Only a test encoder, based on an independently native-generated fixed
    /// envelope. It allows malformed duplicate/ACL tables without native apply.
    private func originEnvelope(basedOn native: Data, fields: [(String, Data)]) -> Data {
        func be16(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
        func be32(_ value: Int) -> Data { be16(value >> 16) + be16(value) }
        let tableSize = fields.reduce(0) { $0 + ((11 + $1.0.utf8.count + 1 + 3) & ~3) }
        let start = 120 + tableSize, total = start + fields.reduce(0) { $0 + $1.1.count }
        var bytes = native.prefix(120), table = Data(), values = Data(), offset = start
        for (name, value) in fields {
            table.append(be32(offset)); table.append(be32(value.count)); table.append(be16(0))
            table.append(UInt8(name.utf8.count + 1)); table.append(contentsOf: name.utf8); table.append(0)
            while table.count % 4 != 0 { table.append(0) }
            values.append(value); offset += value.count
        }
        bytes.replaceSubrange(34..<38, with: be32(total - 50))
        bytes.replaceSubrange(42..<46, with: be32(total))
        bytes.replaceSubrange(92..<96, with: be32(total))
        bytes.replaceSubrange(96..<100, with: be32(start))
        bytes.replaceSubrange(100..<104, with: be32(values.count))
        bytes.replaceSubrange(118..<120, with: be16(fields.count))
        bytes.append(table); bytes.append(values)
        return Data(bytes)
    }
}
