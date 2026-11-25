import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ArchiveCreationTests {
    @Test func roundTripSelectionLinksAndSuffixes() async throws {
        for format in ArchiveFormat.allCases {
            for multiple in [false, true] {
                let fixture = try ServiceFixture()
                let docs = fixture.root.appendingPathComponent("Docs")
                try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false)
                let bytes = Data([0, 1, 2, 255, 128])
                try bytes.write(to: docs.appendingPathComponent("data"))
                try FileManager.default.createSymbolicLink(atPath: docs.appendingPathComponent("link").path, withDestinationPath: "data")
                try bytes.write(to: fixture.root.appendingPathComponent("-report.txt"))
                let items = try await fixture.items().filter { multiple || $0.name == "Docs" }
                let creator = LocalArchiveCreator()
                let result = try await creator.compress(items, in: fixture.context(), format: format, control: TransferControl())
                #expect(result.url.lastPathComponent == (multiple ? "Archive" : "Docs") + "." + format.fileExtension)
                let second = try await creator.compress(items, in: fixture.context(), format: format, control: TransferControl())
                #expect(second.url.lastPathComponent == (multiple ? "Archive" : "Docs") + " 2." + format.fileExtension)
                let extraction = fixture.root.appendingPathComponent("extracted")
                try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
                let tool = Process(); tool.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tool.arguments = ["-xf", result.url.path, "-C", extraction.path]
                try tool.run(); tool.waitUntilExit(); #expect(tool.terminationStatus == 0)
                #expect(try Data(contentsOf: extraction.appendingPathComponent("Docs/data")) == bytes)
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: extraction.appendingPathComponent("Docs/link").path) == "data")
                let names = try FileManager.default.contentsOfDirectory(atPath: extraction.path)
                #expect(Set(names) == Set(items.map(\.name)))
                #expect(try fixture.noStaging())
            }
        }
    }
    @Test func singleFileKeepsExtensionAndSelectedLinkIsNotFollowed() async throws {
        let fixture = try ServiceFixture()
        try Data("payload".utf8).write(to: fixture.root.appendingPathComponent("report.txt"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "report.txt")
        let items = try await fixture.items()
        for name in ["report.txt", "link"] {
            let item = try #require(items.first { $0.name == name })
            let result = try await LocalArchiveCreator().compress([item], in: fixture.context(), format: .zip, control: TransferControl())
            #expect(result.url.lastPathComponent == name + ".zip")
            let output = fixture.root.appendingPathComponent("extract-" + name)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let tool = Process(); tool.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tool.arguments = ["-xf", result.url.path, "-C", output.path]
            try tool.run(); tool.waitUntilExit(); #expect(tool.terminationStatus == 0)
            if name == "link" {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent(name).path) == "report.txt")
            } else { #expect(try Data(contentsOf: output.appendingPathComponent(name)) == Data("payload".utf8)) }
        }
    }

    // CZ-1: inspect the central directory before extraction can consume AppleDouble.
    @Test(arguments: [false, true]) func zipOmitsGeneratedMetadataAndPreservesSelectedBytes(_ multiple: Bool) async throws {
        let fixture = try ServiceFixture()
        // Deterministic high-byte xorshift output remains larger than one tar
        // block after compression, exercising the final partial output block.
        var state: UInt32 = 0x6d2b79f5
        let largePayload = Data((0..<(32 * 1_024)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state >> 24)
        })
        let payloads = ["report.txt": largePayload, "second.txt": Data("second payload".utf8)]
        let attributes = ["com.example.maxplorer.clean-zip": Data("custom metadata".utf8),
                          "com.apple.ResourceFork": Data("synthetic resource fork".utf8),
                          "com.apple.FinderInfo": Data([0x54, 0x45, 0x58, 0x54] + Array(repeating: 0, count: 28))]
        for (name, bytes) in payloads {
            let url = fixture.root.appendingPathComponent(name)
            try bytes.write(to: url)
            for (attribute, value) in attributes {
                try archiveTestTool("/usr/bin/xattr", ["-wx", attribute, value.map { String(format: "%02x", $0) }.joined(), url.path])
                #expect(try archiveTestAttribute(attribute, at: url) == value)
            }
        }
        try Data("unselected".utf8).write(to: fixture.root.appendingPathComponent("leave-out.txt"))
        let names = multiple ? ["report.txt", "second.txt"] : ["report.txt"]
        let items = try await archiveTestSelection(names, in: fixture)
        let result = try await LocalArchiveCreator().compress(items, in: fixture.context(), format: .zip, control: TransferControl())
        let archiveSize = try #require(try result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(archiveSize > 10_240 && archiveSize % 10_240 != 0)
        try verifyCleanZIP(result.url, files: payloads.filter { names.contains($0.key) })
        for (name, bytes) in payloads {
            let url = fixture.root.appendingPathComponent(name)
            #expect(try Data(contentsOf: url) == bytes)
            for (attribute, value) in attributes { #expect(try archiveTestAttribute(attribute, at: url) == value) }
        }
        #expect(try fixture.noStaging())
    }

    // CZ-2/3: patterns must apply recursively to files and directory subtrees,
    // including literal metacharacters, without dropping ordinary hidden files.
    @Test(arguments: ["Docs", "folder [*?] café"])
    func zipFolderOmitsNestedHousekeepingAndKeepsOrdinaryHiddenFiles(_ folder: String) async throws {
        let fixture = try ServiceFixture()
        let kept = ["data": Data("data".utf8), ".env": Data("HIDDEN=kept".utf8),
                    ".DS_Store.txt": Data("ordinary name".utf8), "__MACOSX-notes": Data("ordinary notes".utf8),
                    "nested [*?]/deep/leaf.txt": Data([42, 0, 255])]
        for (name, bytes) in kept { try archiveTestWrite(bytes, at: fixture.root.appendingPathComponent(folder + "/" + name)) }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(folder + "/empty"), withIntermediateDirectories: true)
        let omitted = [".DS_Store", "._data", "__MACOSX/metadata", "nested [*?]/.DS_Store",
                       "nested [*?]/deep/._leaf.txt", "nested [*?]/deep/__MACOSX/metadata",
                       "nested [*?]/deep/.DS_Store/child", "nested [*?]/._directory/child"]
        for name in omitted { try archiveTestWrite(Data("housekeeping".utf8), at: fixture.root.appendingPathComponent(folder + "/" + name)) }
        let items = try await archiveTestSelection([folder], in: fixture)
        let capturedFolder = try #require(items.first).name
        #expect(capturedFolder == folder)
        let result = try await LocalArchiveCreator().compress(items, in: fixture.context(), format: .zip, control: TransferControl())
        try verifyCleanZIP(result.url, files: Dictionary(uniqueKeysWithValues: kept.map { (capturedFolder + "/" + $0.key, $0.value) }),
                           directories: [capturedFolder, capturedFolder + "/empty", capturedFolder + "/nested [*?]", capturedFolder + "/nested [*?]/deep"])
        for name in omitted { #expect(try Data(contentsOf: fixture.root.appendingPathComponent(folder + "/" + name)) == Data("housekeeping".utf8)) }
        #expect(try fixture.noStaging())
    }

    // CZ-2: explicit housekeeping selections are data. The directory descendants
    // still use the recursive rule, including when a selected sibling is x/._x.
    @Test func zipPreservesExplicitHousekeepingSelections() async throws {
        let fixture = try ServiceFixture()
        let files = [".DS_Store": Data("selected store".utf8), "x": Data("selected data".utf8),
                     "._x": Data("selected sidecar".utf8), "__MACOSX/keep.txt": Data("selected directory".utf8),
                     "__MACOSX/.env": Data("hidden content".utf8), "._folder/keep.txt": Data("selected dot directory".utf8)]
        for (name, bytes) in files { try archiveTestWrite(bytes, at: fixture.root.appendingPathComponent(name)) }
        for name in ["__MACOSX/.DS_Store", "__MACOSX/._keep.txt", "__MACOSX/__MACOSX/child", "._folder/._nested/child"] {
            try archiveTestWrite(Data("omit descendant".utf8), at: fixture.root.appendingPathComponent(name))
        }
        let items = try await archiveTestSelection([".DS_Store", "x", "._x", "__MACOSX", "._folder"], in: fixture)
        let result = try await LocalArchiveCreator().compress(items, in: fixture.context(), format: .zip, control: TransferControl())
        try verifyCleanZIP(result.url, files: files, directories: ["__MACOSX", "._folder"])
        #expect(try fixture.noStaging())
    }

    // CZ-3: @ is bsdtar archive-import syntax even after --. The unselected valid
    // literal.zip makes that regression observable; Unicode runs under the host's
    // C locale in the focused native command, without mutating this test process.
    @Test func zipPreservesLiteralNamesHardlinksAndVerbatimSymlinkTargets() async throws {
        let fixture = try ServiceFixture(), outside = try ServiceFixture()
        let linkedBytes = Data([0, 255, 17, 23])
        let files = ["-dash.txt": Data("dash".utf8), "@literal.zip": NewFileTemplate.zipArchive.contents,
                     "café ☃.txt": Data("unicode payload".utf8), "Docs/data": linkedBytes, "Docs/hardlink": linkedBytes]
        for (name, bytes) in files where name != "Docs/hardlink" { try archiveTestWrite(bytes, at: fixture.root.appendingPathComponent(name)) }
        try FileManager.default.linkItem(at: fixture.root.appendingPathComponent("Docs/data"), to: fixture.root.appendingPathComponent("Docs/hardlink"))
        try NewFileTemplate.zipArchive.contents.write(to: fixture.root.appendingPathComponent("literal.zip"))
        let outsideFile = outside.root.appendingPathComponent("outside.txt")
        try Data("outside sentinel".utf8).write(to: outsideFile)
        let links = ["Docs/link": "./data", "relative-link": "./Docs/data", "directory-link": "./Docs",
                     "outside-link": outside.root.path, "dangling-link": "./missing"]
        for (name, target) in links {
            try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let names = ["-dash.txt", "@literal.zip", "café ☃.txt", "Docs", "relative-link", "directory-link", "outside-link", "dangling-link"]
        let items = try await archiveTestSelection(names, in: fixture)
        let capturedFiles = try Dictionary(uniqueKeysWithValues: files.map { entry in
            let components = entry.key.split(separator: "/").map(String.init)
            let capturedRoot = try #require(items.first { $0.name == components[0] }).name
            #expect(capturedRoot == components[0])
            return (([capturedRoot] + Array(components.dropFirst())).joined(separator: "/"), entry.value)
        })
        let result = try await LocalArchiveCreator().compress(items, in: fixture.context(), format: .zip, control: TransferControl())
        try verifyCleanZIP(result.url, files: capturedFiles, directories: ["Docs"], links: links)
        let selectedLink = try #require(items.first { $0.name == "directory-link" })
        let linkResult = try await LocalArchiveCreator().compress([selectedLink], in: fixture.context(), format: .zip, control: TransferControl())
        try verifyCleanZIP(linkResult.url, files: [:], links: ["directory-link": "./Docs"])
        #expect(try Data(contentsOf: outsideFile) == Data("outside sentinel".utf8))
        #expect(try fixture.noStaging())
    }
    @Test func emptyStaleAndCancelledSelections() async throws {
        let fixture = try ServiceFixture()
        try Data("bytes".utf8).write(to: fixture.root.appendingPathComponent("source"))
        let items = try await fixture.items()
        let creator = LocalArchiveCreator()
        do { _ = try await creator.compress([], in: fixture.context(), format: .zip, control: TransferControl()); Issue.record("Empty accepted") }
        catch FileOperationError.unsupported {}
        let control = TransferControl(); control.cancel()
        do { _ = try await creator.compress(items, in: fixture.context(), format: .tar, control: control); Issue.record("Cancelled accepted") }
        catch is CancellationError {}
        try FileManager.default.moveItem(at: items[0].url, to: fixture.root.appendingPathComponent("old"))
        try Data().write(to: items[0].url)
        do { _ = try await creator.compress(items, in: fixture.context(), format: .tar, control: TransferControl()); Issue.record("Stale accepted") }
        catch FileOperationError.staleSource {}
        #expect(try fixture.noStaging())
    }
    @Test(arguments: ArchiveFormat.allCases) func failingToolLeavesNoArchiveOrStage(_ format: ArchiveFormat) async throws {
        if getuid() == 0 { return }
        let fixture = try ServiceFixture()
        let source = fixture.root.appendingPathComponent("unreadable")
        try Data("secret".utf8).write(to: source)
        let items = try await fixture.items()
        try #require(chmod(source.path, 0) == 0)
        defer { chmod(source.path, 0o600) }
        do {
            _ = try await LocalArchiveCreator().compress(items, in: fixture.context(), format: format, control: TransferControl())
            Issue.record("Unreadable source accepted")
        } catch FileOperationError.unsupported(let message) { #expect(message.contains("Archive tool failed")) }
        #expect(try fixture.noStaging())
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["unreadable"])
    }
    @Test(arguments: [false, true]) func runningCancellationCleansStage(taskCancellation: Bool) async throws {
        let fixture = try ServiceFixture()
        try Data(repeating: 0x62, count: 64 * 1024 * 1024).write(to: fixture.root.appendingPathComponent("large"))
        let items = try await fixture.items(), context = try fixture.context()
        let control = TransferControl()
        let task = Task { try await LocalArchiveCreator().compress(items, in: context, format: .zip, control: control) }
        for _ in 0..<500 {
            if try !fixture.noStaging() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if taskCancellation { task.cancel() } else { control.cancel() }
        do { _ = try await task.value; Issue.record("Cancelled archive published") } catch is CancellationError {}
        #expect(try fixture.noStaging())
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["large"])
    }
}

private func archiveTestSelection(_ names: [String], in fixture: ServiceFixture) async throws -> [FileItem] {
    let listed = try await LocalDirectoryLoader().contents(of: fixture.root, showHidden: true)
    // Foundation enumeration can suppress an existing ._x beside x, even when
    // hidden files are requested. Sample those explicit entries directly; use
    // enumerated names otherwise to preserve the filesystem's Unicode spelling.
    return try names.map { name in
        let item = listed.first { $0.name == name }
            ?? LocalDirectoryLoader.item(for: fixture.root.appendingPathComponent(name), displayedIn: fixture.root, supportsLocalIdentity: true)
        #expect(item.name == name)
        try #require(item.identity != nil)
        return item
    }
}

private func archiveTestWrite(_ bytes: Data, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
}

private func archiveTestTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // Fixture tools may read Unicode paths. This is child-local, so the archiver
    // still inherits the C locale deliberately supplied by the native test run.
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
    try process.run(); process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

private func archiveTestAttribute(_ name: String, at url: URL) throws -> Data {
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    try #require(size >= 0)
    var bytes = Data(count: size)
    let count = bytes.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
    try #require(count == size)
    return bytes
}

private func verifyCleanZIP(_ url: URL, files: [String: Data], directories: [String] = [], links: [String: String] = [:]) throws {
    let reader = try ZIPFileReader(url: url), manifest = try ZIPArchiveManifest.read(from: reader)
    let expectedNames = Array(files.keys) + directories.map { $0 + "/" } + Array(links.keys)
    #expect(manifest.records.count == expectedNames.count)
    #expect(Set(manifest.records.map(\.nameBytes)) == Set(expectedNames.map { Data($0.utf8) }))
    for name in expectedNames where name.utf8.contains(where: { $0 >= 0x80 }) {
        let record = try #require(manifest.records.first { $0.nameBytes == Data(name.utf8) })
        #expect(record.flags & 0x0800 != 0, "Unicode ZIP names must declare UTF-8 even when the application starts in the C locale")
    }
    for directory in directories {
        let record = try #require(manifest.records.first { $0.nameBytes == Data((directory + "/").utf8) })
        #expect(record.kind == .directory)
    }
    for (name, expected) in files {
        let record = try #require(manifest.records.first { $0.nameBytes == Data(name.utf8) })
        #expect(record.kind == .file)
        let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .content(recordIDs: [record.id]))
        var actual = Data()
        _ = try ZIPContentExtraction.extract(record: record, layout: try #require(layout.records[record.id]), reader: reader,
            maximumBytes: 1_024 * 1_024, checkpoint: {}, consume: { actual.append($0) })
        #expect(actual == expected)
    }
    if !links.isEmpty {
        let extraction = try ServiceFixture()
        try archiveTestTool("/usr/bin/tar", ["-xf", url.path, "-C", extraction.root.path])
        for (name, expected) in links {
            let record = try #require(manifest.records.first { $0.nameBytes == Data(name.utf8) })
            #expect(record.kind == .symbolicLink)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: extraction.root.appendingPathComponent(name).path) == expected)
        }
    }
}

/// Astra review 4980d3b6 finding 1 (MAC-078): the archive tool writes only through
/// descriptors created in the held stage, so renaming the stage and substituting a
/// directory whose `payload`/`stderr` are links to another file cannot redirect or
/// truncate anything, and nothing is published.
@Suite struct ArchiveStageSubstitutionTests {
    @Test(arguments: [ArchiveFormat.zip, .tar]) func substitutedStageCannotRedirectToolOutput(_ format: ArchiveFormat) async throws {
        let fixture = try ServiceFixture()
        try Data("payload".utf8).write(to: fixture.root.appendingPathComponent("report.txt"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerVictim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let victim = outside.appendingPathComponent("precious.txt")
        try Data("precious".utf8).write(to: victim)
        let items = try await fixture.items()
        let moved = fixture.root.appendingPathComponent("moved-stage")
        let creator = LocalArchiveCreator(afterStaging: { stage in
            try? FileManager.default.moveItem(at: stage, to: moved)
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            for name in ["payload", "stderr"] {
                try? FileManager.default.createSymbolicLink(atPath: stage.appendingPathComponent(name).path, withDestinationPath: victim.path)
            }
        })
        var thrown: (any Error)?
        do { _ = try await creator.compress(items, in: fixture.context(), format: format, control: TransferControl()); Issue.record("Published from a substituted stage") }
        catch { thrown = error }
        #expect(try Data(contentsOf: victim) == Data("precious".utf8), "The tool must not write through the substituted stage")
        if case .staleSource? = thrown as? FileOperationError {} else { Issue.record("Expected staleSource, got \(String(describing: thrown))") }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!names.contains { $0.hasSuffix("." + format.fileExtension) })
    }
}
