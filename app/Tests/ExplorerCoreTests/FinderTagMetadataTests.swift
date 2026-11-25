import Darwin
import Foundation
import Testing
@testable import ExplorerCore

struct FinderTagMetadataTests {
    @Test func applyRebasesOnFreshNamesAndSerializesChangesAcrossEditors() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("report.txt")
        try Data("unchanged".utf8).write(to: file)
        try fixture.setNames(["Remove", "Keep"], at: file)
        let captured = try await FinderTagFile.read(at: file)
        #expect(Set(captured.names) == ["Remove", "Keep"])
        try fixture.setNames(["Remove", "Keep", "Outside"], at: file)
        async let first = captured.apply(adding: ["Résumé"], removing: ["Remove"])
        async let second = captured.apply(adding: ["Research"], removing: [])
        _ = try await (first, second)
        #expect(try Set(fixture.names(at: file)) == ["Keep", "Outside", "Résumé", "Research"])
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    @Test func freshFolderAssignmentsRemainVisibleInFoundationAndCanBeRemoved() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let folder = try await FinderTagFile.read(at: directory)
        #expect(folder.names.isEmpty)
        _ = try await folder.apply(adding: ["Tag A"], removing: [])
        #expect(try fixture.names(at: directory) == ["Tag A"])
        _ = try await folder.apply(adding: [], removing: ["Tag A"])
        #expect(try fixture.names(at: directory).isEmpty)
    }

    @Test func unrelatedColoredFinderTagKeepsItsColor() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("colored.txt")
        try Data().write(to: file)
        let key = "com.apple.metadata:_kMDItemUserTags"
        let data = try PropertyListSerialization.data(fromPropertyList: ["Color fixture\n6"], format: .binary, options: 0)
        let written = data.withUnsafeBytes { setxattr(file.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        #expect(written == 0)
        let captured = try await FinderTagFile.read(at: file)
        #expect(captured.names == ["Color fixture"])
        _ = try await captured.apply(adding: ["Another tag"], removing: [])
        let count = getxattr(file.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        try #require(count > 0)
        var actual = Data(count: count)
        let read = actual.withUnsafeMutableBytes { getxattr(file.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        #expect(read == count)
        let payload = try PropertyListSerialization.propertyList(from: actual, format: nil)
        let raw = try #require(payload as? [String])
        #expect(raw.contains("Color fixture\n6"))
        #expect(try Set(fixture.names(at: file)) == ["Color fixture", "Another tag"])
    }

    @Test func removalPreservesColorsChangedSincePresentationAndNewOutsideTags() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("colored-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try fixture.writeRaw(PropertyListSerialization.data(fromPropertyList: ["Keep\n6", "Remove\n3"],
                                                             format: .binary, options: 0), at: folder)
        let captured = try await FinderTagFile.read(at: folder)
        let latest = ["Keep\n1", "Remove\n3", "Received later\n7"]
        try fixture.writeRaw(PropertyListSerialization.data(fromPropertyList: latest, format: .binary, options: 0), at: folder)
        _ = try await captured.apply(adding: [], removing: ["Remove"])
        let payload = try PropertyListSerialization.propertyList(from: fixture.raw(at: folder), format: nil)
        #expect(payload as? [String] == ["Keep\n1", "Received later\n7"])
        #expect(try Set(fixture.names(at: folder)) == ["Keep", "Received later"])
    }

    @Test func publicChangesKeepUnrelatedFinderFlagsAndUpdateFirstAndLastColors() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("palette.txt")
        try Data().write(to: file)
        var flags = Data(repeating: 0, count: 32)
        flags[8] = 0x04
        try fixture.writeFinderInfo(flags, at: file)
        try fixture.setNames(["Red", "Blue", "Other"], at: file)
        let initialFlag = try fixture.finderInfo(at: file)
        #expect(initialFlag[8] == 0x04 && initialFlag[9] & 0x0e == 8)
        let original = try await FinderTagFile.read(at: file)
        _ = try await original.apply(adding: [], removing: ["Red"])
        let blueFlag = try fixture.finderInfo(at: file)
        #expect(blueFlag[8] == 0x04 && blueFlag[9] & 0x0e == 8)
        _ = try await original.apply(adding: [], removing: ["Blue"])
        let clearFlag = try fixture.finderInfo(at: file)
        #expect(clearFlag[8] == 0x04 && clearFlag[9] & 0x0e == 0)
        #expect(try Set(fixture.names(at: file)) == ["Other"])
    }

    @Test func legacyLabelOnlyCanBeRetainedOrRemovedWithoutLosingOtherFlags() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("legacy.txt")
        try Data().write(to: file)
        var flags = Data(repeating: 0, count: 32)
        flags[8] = 0x04
        flags[9] = 12
        try fixture.writeFinderInfo(flags, at: file)
        let captured = try await FinderTagFile.read(at: file)
        #expect(captured.names == ["Red"])
        _ = try await captured.apply(adding: ["Other"], removing: [])
        #expect(try Set(fixture.names(at: file)) == ["Red", "Other"])
        #expect(try fixture.finderInfo(at: file) == flags)
        _ = try await captured.apply(adding: [], removing: ["Red"])
        flags[9] = 0
        #expect(try fixture.finderInfo(at: file) == flags)
    }

    @Test func changingMirrorOfRetainedCustomColorRefusesBeforeMutation() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("custom-mirror.txt")
        try Data().write(to: file)
        var flags = Data(repeating: 0, count: 32)
        flags[8] = 0x04
        flags[9] = 12
        try fixture.writeFinderInfo(flags, at: file)
        let raw = try PropertyListSerialization.data(fromPropertyList: ["Other custom\n4", "Old custom\n6"], format: .binary, options: 0)
        try fixture.writeRaw(raw, at: file)
        let captured = try await FinderTagFile.read(at: file)
        await #expect(throws: (any Error).self) {
            try await captured.apply(adding: [], removing: ["Old custom"])
        }
        #expect(try fixture.raw(at: file) == raw)
        #expect(try fixture.finderInfo(at: file) == flags)
    }

    @Test func malformedOrAmbiguousNativeTagsCannotBeSilentlyReplaced() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("malformed.txt")
        try Data().write(to: file)
        for sample in [Data([0xff, 0x11]), try PropertyListSerialization.data(fromPropertyList: ["Duplicate\n6", "Duplicate\n3"], format: .binary, options: 0)] {
            try fixture.writeRaw(sample, at: file)
            await #expect(throws: (any Error).self) {
                let captured = try await FinderTagFile.read(at: file)
                _ = try await captured.apply(adding: ["Other"], removing: [])
            }
            #expect(try fixture.raw(at: file) == sample)
        }
    }

    @Test func rawFallbackRequiresResidentLocalAPFSOutsideCloudStorage() {
        func allowed(_ fs: String = "apfs", local: Bool = true, dataless: Bool = false,
                     ubiquitous: Bool? = false, path: [String] = ["/", "Users", "test", "Documents"]) -> Bool {
            FinderTagNativeMetadata.hasLocalPreconditions(fsType: fs, local: local, dataless: dataless,
                                                    ubiquitous: ubiquitous, path: path)
        }
        #expect(allowed())
        #expect(!allowed("smbfs"))
        #expect(!allowed(local: false))
        #expect(!allowed(dataless: true))
        #expect(!allowed(ubiquitous: true))
        #expect(allowed(ubiquitous: nil)) // Ordinary APFS items still require separate provider-negative verification.
        #expect(!allowed("smbfs", ubiquitous: nil))
        #expect(!allowed(path: ["/", "Users", "test", "Library", "CloudStorage", "Example", "Document"]))
        #expect(!allowed(path: ["/", "Users", "test", "Library", "Mobile Documents", "CloudDocs"]))
    }

    @Test func replacementAndSymbolicLinkCannotReceiveAssignments() async throws {
        let fixture = try TagDiskFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("original.txt")
        let parked = fixture.root.appendingPathComponent("parked.txt")
        let other = fixture.root.appendingPathComponent("other.txt")
        try Data().write(to: file)
        try Data().write(to: other)
        let captured = try await FinderTagFile.read(at: file)
        try FileManager.default.moveItem(at: file, to: parked)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        await #expect(throws: (any Error).self) { try await FinderTagFile.read(at: file) }
        await #expect(throws: (any Error).self) { try await captured.apply(adding: ["Never"], removing: []) }
        #expect(try fixture.names(at: other).isEmpty)
        #expect(try fixture.names(at: parked).isEmpty)
        try FileManager.default.removeItem(at: file)
        try Data().write(to: file)
        await #expect(throws: (any Error).self) { try await captured.apply(adding: ["Never"], removing: []) }
        #expect(try fixture.names(at: file).isEmpty)
    }
}

private struct TagDiskFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("maxplorer-tags-\(UUID())", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func writeRaw(_ data: Data, at url: URL) throws {
        let written = data.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard written == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func writeFinderInfo(_ value: Data, at url: URL) throws {
        let written = value.withUnsafeBytes { setxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard written == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func finderInfo(at url: URL) throws -> Data {
        var value = Data(count: 32)
        let count = value.withUnsafeMutableBytes { getxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard count == value.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }
    func raw(at url: URL) throws -> Data {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let count = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var result = Data(count: count)
        let received = result.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard received == count else { throw POSIXError(.EIO) }
        return result
    }
    func names(at source: URL) throws -> [String] {
        let uncached = URL(fileURLWithPath: source.path)
        return try uncached.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }
    func setNames(_ names: [String], at source: URL) throws {
        var url = URL(fileURLWithPath: source.path)
        var properties = URLResourceValues()
        properties.tagNames = names
        try url.setResourceValues(properties)
    }
}
