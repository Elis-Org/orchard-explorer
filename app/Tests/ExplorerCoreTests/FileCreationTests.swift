import Foundation
import Testing
@testable import ExplorerCore

final class ServiceFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerServices-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func context() throws -> FileOperationContext {
        FileOperationContext(directoryURL: root, directoryIdentity: try #require(try LocalFileIdentity.read(at: root, ifLocal: true)))
    }
    func items() async throws -> [FileItem] { try await LocalDirectoryLoader().contents(of: root) }
    func noStaging() throws -> Bool { try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".explorer-") } }
}
@Suite struct FileCreationTests {
    @Test func templatesAndExclusiveCreation() async throws {
        let fixture = try ServiceFixture()
        for template in NewFileTemplate.allCases {
            let result = try await LocalFileCreator().createFile(named: template.defaultName, template: template, in: fixture.context())
            #expect(try Data(contentsOf: result.url) == template.contents)
            #expect(result.identity != nil)
            do { _ = try await LocalFileCreator().createFile(named: template.defaultName, template: .textDocument, in: fixture.context()); Issue.record("Overwrote file") }
            catch FileOperationError.collision(let name) { #expect(name == template.defaultName) }
            #expect(try Data(contentsOf: result.url) == template.contents)
            if template == .zipArchive {
                let tool = Process()
                tool.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
                tool.arguments = [result.url.path]
                let pipe = Pipe(); tool.standardOutput = pipe; tool.standardError = pipe
                try tool.run()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                tool.waitUntilExit()
                #expect(text.contains("Empty zipfile") || text.contains("0 entries"))
            }
        }
    }
    // ND-NEW-02: Explorer creates a zero-byte bitmap before any editor opens it.
    @Test func bitmapTemplateCreatesEmptyFileWithObservedName() async throws {
        let fixture = try ServiceFixture()
        let template = try #require(NewFileTemplate.allCases.first { $0.defaultName == "New Bitmap image.bmp" })
        let result = try await LocalFileCreator().createFile(named: template.defaultName, template: template, in: fixture.context())
        #expect(result.url.lastPathComponent == "New Bitmap image.bmp")
        #expect(try Data(contentsOf: result.url).isEmpty)
        #expect(result.identity != nil)
    }

    @Test func invalidNameAndStaleParent() async throws {
        let fixture = try ServiceFixture()
        let context = try fixture.context()
        do { _ = try await LocalFileCreator().createFile(named: "../escape", template: .textDocument, in: context); Issue.record("Invalid name accepted") }
        catch FileOperationError.invalidName {}
        try FileManager.default.moveItem(at: fixture.root, to: fixture.root.appendingPathExtension("old"))
        defer { try? FileManager.default.removeItem(at: fixture.root.appendingPathExtension("old")) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        do { _ = try await LocalFileCreator().createFile(named: "file", template: .textDocument, in: context); Issue.record("Stale parent accepted") }
        catch FileOperationError.staleParent {}
    }
}

/// Astra review 4980d3b6 finding 2 (MAC-078): ownership comes from the created
/// descriptor, so a replacement at the new name is never reported as created and
/// never removed by failure cleanup.
@Suite struct FileCreationReplacementTests {
    @Test(arguments: [false, true]) func replacementAfterCreationIsNeitherClaimedNorRemoved(_ failWrite: Bool) async throws {
        let fixture = try ServiceFixture()
        let name = NewFileTemplate.zipArchive.defaultName
        let creator = LocalFileCreator(afterCreate: { url in
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("created-moved"))
            try? Data("foreign".utf8).write(to: url)
        }, failWrite: failWrite)
        let foreign = fixture.root.appendingPathComponent(name)
        if failWrite {
            do { _ = try await creator.createFile(named: name, template: .zipArchive, in: fixture.context()); Issue.record("Write failure not reported") }
            catch FileOperationError.systemFailure(_, let code) { #expect(code == EIO) }
        } else {
            let result = try await creator.createFile(named: name, template: .zipArchive, in: fixture.context())
            #expect(result.identity == nil && result.warning != nil, "The replacement must not be reported as the created file")
        }
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
    }
}

/// Astra review 4980d3b6 finding 6 (MAC-078): routing commands revalidate the
/// captured entry without following links.
@Suite struct RoutingTargetValidationTests {
    @Test func currentReplacedMissingAndUnverifiableEntries() async throws {
        let fixture = try ServiceFixture()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        try Data("a".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "Folder")
        let items = try await fixture.items()
        for item in items { #expect(await RoutingTargetValidation.isCurrent(item), "\(item.name) is unchanged") }
        let folder = try #require(items.first { $0.name == "Folder" })
        let file = try #require(items.first { $0.name == "file.txt" })
        let link = try #require(items.first { $0.name == "link" })
        try FileManager.default.removeItem(at: folder.url)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: false)
        #expect(!(await RoutingTargetValidation.isCurrent(folder)), "A replaced folder is a different entry")
        #expect(await RoutingTargetValidation.isCurrent(link), "The link itself is unchanged although its target folder was replaced")
        try FileManager.default.removeItem(at: file.url)
        #expect(!(await RoutingTargetValidation.isCurrent(file)), "A missing entry is not current")
        let unverifiable = FileItem(url: file.url, name: file.name, isDirectory: false, isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Text", identity: nil)
        #expect(await RoutingTargetValidation.isCurrent(unverifiable), "Entries without a local identity route by path")
    }
}

/// Follow-up 029698a5 finding 8: the displayed folder is checked on disk the way
/// the listing identifies it (resolved path, local volume).
@Suite struct RoutingFolderValidationTests {
    @Test func currentReplacedAndLinkedFolders() async throws {
        let fixture = try ServiceFixture()
        let folder = fixture.root.appendingPathComponent("Shown", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = fixture.root.appendingPathComponent("ShownLink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Shown")
        let snapshot = try await LocalDirectoryLoader().snapshot(of: link)
        #expect(await RoutingTargetValidation.isCurrentFolder(link, identity: snapshot.directoryIdentity), "Shown through a link, identified like the listing")
        #expect(await RoutingTargetValidation.isCurrentFolder(folder, identity: snapshot.directoryIdentity))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(!(await RoutingTargetValidation.isCurrentFolder(link, identity: snapshot.directoryIdentity)), "A replaced folder is not the displayed one")
        #expect(await RoutingTargetValidation.isCurrentFolder(folder, identity: nil), "Without a local identity, routed by path")
    }
}
