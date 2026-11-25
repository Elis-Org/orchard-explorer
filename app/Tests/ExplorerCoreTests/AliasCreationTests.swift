import Foundation
import Testing
@testable import ExplorerCore

@Suite struct AliasCreationTests {
    @Test func resolvesAliasAndUsesExclusiveSuffix() async throws {
        let fixture = try ServiceFixture()
        let target = fixture.root.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        let items = try await fixture.items()
        for suffix in ["", " 2"] {
            let results = try await LocalAliasCreator().makeAliases(for: items, in: fixture.context())
            let alias = try #require(results.first)
            #expect(alias.url.lastPathComponent == "target.txt alias" + suffix)
            #expect(try alias.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
            #expect(try URL(resolvingAliasFileAt: alias.url).resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
        }
        #expect(try fixture.noStaging())
    }
    // ND-NEW-05: publish a native alias to a target outside the destination.
    @Test func namedAliasResolvesAndRejectsExactCollision() async throws {
        let source = try ServiceFixture(), destination = try ServiceFixture()
        let targetURL = source.root.appendingPathComponent("target.txt")
        try Data("source".utf8).write(to: targetURL)
        let creator = LocalAliasCreator()
        let context = try destination.context()
        let target = try await creator.prepareShortcut(to: targetURL, in: context).target
        let name = "My shortcut"
        let result = try await creator.createAlias(to: target, named: name, in: context)
        #expect(result.url.lastPathComponent == name)
        #expect(try result.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(try URL(resolvingAliasFileAt: result.url).resolvingSymlinksInPath() == targetURL.resolvingSymlinksInPath())
        await #expect(throws: FileOperationError.collision(name)) {
            _ = try await creator.createAlias(to: target, named: name, in: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.root.path) == [name])
        #expect(try Data(contentsOf: targetURL) == Data("source".utf8))
    }

    @Test(arguments: [false, true])
    func namedAliasRejectsReplacedLinkOrResolvedTarget(_ replaceLink: Bool) async throws {
        let source = try ServiceFixture(), destination = try ServiceFixture()
        let targetURL = source.root.appendingPathComponent("target.txt")
        let linkURL = source.root.appendingPathComponent("link")
        try Data("source".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let creator = LocalAliasCreator()
        let context = try destination.context()
        let target = try await creator.prepareShortcut(to: linkURL, in: context).target
        let replaced = replaceLink ? linkURL : targetURL
        try FileManager.default.moveItem(at: replaced, to: source.root.appendingPathComponent("original"))
        if replaceLink {
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        } else {
            try Data("replacement".utf8).write(to: targetURL)
        }
        await #expect(throws: FileOperationError.staleSource) {
            _ = try await creator.createAlias(to: target, named: "Shortcut", in: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.root.path).isEmpty)
    }

    @Test func namedAliasRejectsReplacedDestination() async throws {
        let source = try ServiceFixture(), destination = try ServiceFixture()
        let targetURL = source.root.appendingPathComponent("target.txt")
        try Data().write(to: targetURL)
        let creator = LocalAliasCreator()
        let context = try destination.context()
        let target = try await creator.prepareShortcut(to: targetURL, in: context).target
        let moved = source.root.appendingPathComponent("original-destination")
        try FileManager.default.moveItem(at: destination.root, to: moved)
        try FileManager.default.createDirectory(at: destination.root, withIntermediateDirectories: false)
        await #expect(throws: FileOperationError.staleParent) {
            _ = try await creator.prepareShortcut(to: targetURL, in: context)
        }
        await #expect(throws: FileOperationError.staleParent) {
            _ = try await creator.createAlias(to: target, named: "Shortcut", in: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.root.path).isEmpty)
    }

    @Test func partialFailureKeepsCompletedAliases() async throws {
        let fixture = try ServiceFixture()
        for name in ["first", "second"] { try Data().write(to: fixture.root.appendingPathComponent(name)) }
        let items = try await fixture.items().sorted { $0.name < $1.name }
        try FileManager.default.removeItem(at: items[1].url)
        do { _ = try await LocalAliasCreator().makeAliases(for: items, in: fixture.context()); Issue.record("Stale accepted") }
        catch let error as AliasCreationError {
            #expect(error.completed.count == 1)
            #expect(error.failedName == "second")
            #expect(FileManager.default.fileExists(atPath: error.completed[0].url.path))
        }
        #expect(try fixture.noStaging())
    }
}
