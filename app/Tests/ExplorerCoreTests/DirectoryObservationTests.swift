import CoreServices
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class ObservationFixture {
    let parent: URL
    let folder: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerObservation-" + UUID().uuidString, isDirectory: true)
        folder = parent.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: parent) }
}

private actor ObservedHints {
    private(set) var values: [DirectoryChange] = []
    func append(_ change: DirectoryChange) { values.append(change) }
}

private final class StopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Native platform safety/integration cases. FSEvents are refresh hints, not Windows
/// interaction evidence. Every filesystem write is confined to a unique temporary fixture.
@Suite(.serialized)
struct DirectoryObservationTests {
    @Test func editsToDifferentChildrenRetainTheirSeparateTargets() throws {
        let fixture = try ObservationFixture()
        let scope = try DirectoryWatchScope(url: fixture.folder)
        let flags = UInt32(kFSEventStreamEventFlagItemModified)
        let parent = fixture.folder.resolvingSymlinksInPath()
        let first = try #require(scope.change(for: parent.appendingPathComponent("first.txt").path, flags: flags))
        let second = try #require(scope.change(for: parent.appendingPathComponent("second.txt").path, flags: flags))
        #expect(first != second)
        #expect(first.merging(second) == .children(["first.txt", "second.txt"]))
        #expect(first.merging(.changed) == .changed)
        #expect(DirectoryChange.rootChanged.merging(first) == .rootChanged)
        let full = DirectoryChange.children(Set((0..<64).map { "child-\($0)" }))
        #expect(full.merging(first) == .changed)
    }

    @Test
    func testWatcherIsAttachedBeforeReturningAndSeesImmediateExternalCreate() async throws {
        let fixture = try ObservationFixture()
        let stream = try LocalDirectoryObserver().events(for: fixture.folder)
        // Deliberately write before creating an iterator: events() must already be attached.
        let created = fixture.folder.appendingPathComponent("created.txt")
        try Data("created".utf8).write(to: created)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try await waitForHint(hints)
        #expect(try Data(contentsOf: created) == Data("created".utf8))
    }

    /// GAP-036 / MAC-0385–0393: a direct child is created and removed while its
    /// containing directory remains watched. Root-deletion coverage is separate.
    @Test
    func testEmptyChildMkdirThenRmdirEachProduceFreshHints() async throws {
        let fixture = try ObservationFixture()
        // Match the desktop fixture's lexical /var route even when Foundation
        // supplies its /private/var spelling. Both refer to the same owned files.
        let path = fixture.folder.path
        let lexicalPath = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        let empty = URL(fileURLWithPath: lexicalPath, isDirectory: true)
            .appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let child = empty.appendingPathComponent("Chevron Validation Child", isDirectory: true)
        let stream = try LocalDirectoryObserver().events(for: empty)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try await settle(hints)

        for _ in 0..<2 {
            let beforeCreate = await hints.values.count
            try #require(child.withUnsafeFileSystemRepresentation { Darwin.mkdir($0!, 0o700) } == 0)
            try await waitForHint(hints, after: beforeCreate)
            try #require(await hints.values.count > beforeCreate, "Direct-child mkdir produced no fresh hint")
            #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path) == [child.lastPathComponent])

            try await settle(hints)
            let beforeRemoval = await hints.values.count
            try #require(child.withUnsafeFileSystemRepresentation { Darwin.rmdir($0!) } == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
            try await waitForHint(hints, after: beforeRemoval)
            try #require(await hints.values.count > beforeRemoval, "Direct-child rmdir produced no fresh hint")
            try await settle(hints)
        }
        withExtendedLifetime(stream) {}
    }

    @Test
    func testContentWriteAtomicReplacementAndRenameEachProduceRefreshHints() async throws {
        let fixture = try ObservationFixture()
        let file = fixture.folder.appendingPathComponent("item.txt")
        try Data("before".utf8).write(to: file)
        let stream = try LocalDirectoryObserver().events(for: fixture.folder)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try await settle(hints)
        var count = await hints.values.count
        try Data("ordinary write".utf8).write(to: file)
        try await waitForHint(hints, after: count)
        #expect(try Data(contentsOf: file) == Data("ordinary write".utf8))
        try await settle(hints)
        count = await hints.values.count
        try Data("atomic replacement".utf8).write(to: file, options: .atomic)
        try await waitForHint(hints, after: count)
        #expect(try Data(contentsOf: file) == Data("atomic replacement".utf8))
        try await settle(hints)
        count = await hints.values.count
        let renamed = fixture.folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        try await waitForHint(hints, after: count)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: renamed) == Data("atomic replacement".utf8))
    }

    @Test
    func testRootDeletionAndRecreationKeepParentRecoveryWatch() async throws {
        let fixture = try ObservationFixture()
        let stream = try LocalDirectoryObserver().events(for: fixture.folder)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try await settle(hints)
        var count = await hints.values.count
        try FileManager.default.removeItem(at: fixture.folder)
        try await waitForHint(hints, after: count, requiring: .rootChanged)
        try await settle(hints)
        count = await hints.values.count
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)
        try await waitForHint(hints, after: count, requiring: .rootChanged)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.path))
    }

    @Test
    func testMissingRootCanRecoverThroughNearestExistingAncestor() async throws {
        let fixture = try ObservationFixture()
        let missing = fixture.folder.appendingPathComponent("Parent/Child", isDirectory: true)
        let stream = try LocalDirectoryObserver().events(for: missing)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try await waitForHint(hints, requiring: .rootChanged)
    }

    @Test
    func testSymlinkRouteObservesTargetWritesAndLinkReplacement() async throws {
        let fixture = try ObservationFixture()
        let link = fixture.parent.appendingPathComponent("Route", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.folder)
        let scope = try DirectoryWatchScope(url: link)
        #expect(scope.logicalURL.path == link.path)
        let stream = try LocalDirectoryObserver().events(for: link)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        defer { consumer.cancel() }
        try await settle(hints)
        var count = await hints.values.count
        try Data("through target".utf8).write(to: fixture.folder.appendingPathComponent("target.txt"))
        try await waitForHint(hints, after: count)
        try await settle(hints)
        count = await hints.values.count
        let replacement = fixture.parent.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        try await waitForHint(hints, after: count, requiring: .rootChanged)
        #expect(link.resolvingSymlinksInPath().path == replacement.resolvingSymlinksInPath().path)
    }

    @Test
    func testAncestorSymlinkRetargetRequestsRebindAndNewTargetWritesAreObserved() async throws {
        let fixture = try ObservationFixture()
        let originalChild = fixture.folder.appendingPathComponent("Child", isDirectory: true)
        let replacement = fixture.parent.appendingPathComponent("Replacement", isDirectory: true)
        let replacementChild = replacement.appendingPathComponent("Child", isDirectory: true)
        let route = fixture.parent.appendingPathComponent("Route", isDirectory: true)
        try FileManager.default.createDirectory(at: originalChild, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementChild, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: fixture.folder)
        let lexicalChild = route.appendingPathComponent("Child", isDirectory: true)
        let scope = try DirectoryWatchScope(url: lexicalChild)
        #expect(scope.watchedPaths.contains(fixture.parent.resolvingSymlinksInPath().path),
                "The ancestor link's parent must be watched to detect retargeting")
        #expect(!scope.watchedPaths.contains("/"), "System aliases must not create a whole-volume subscription")
        let firstHints = ObservedHints()
        let firstConsumer = consume(try LocalDirectoryObserver().events(for: lexicalChild), into: firstHints)
        defer { firstConsumer.cancel() }
        try await settle(firstHints)
        let count = await firstHints.values.count

        try FileManager.default.removeItem(at: route)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: replacement)
        try await waitForHint(firstHints, after: count, requiring: .rootChanged)
        #expect(lexicalChild.resolvingSymlinksInPath().path == replacementChild.resolvingSymlinksInPath().path)

        // The store responds to rootChanged by binding the unchanged lexical URL again.
        firstConsumer.cancel()
        await firstConsumer.value
        let reboundHints = ObservedHints()
        let reboundConsumer = consume(try LocalDirectoryObserver().events(for: lexicalChild), into: reboundHints)
        defer { reboundConsumer.cancel() }
        try await settle(reboundHints)
        let reboundCount = await reboundHints.values.count
        let file = replacementChild.appendingPathComponent("after-rebind.txt")
        try Data("new target".utf8).write(to: file)
        try await waitForHint(reboundHints, after: reboundCount)
        #expect(try Data(contentsOf: lexicalChild.appendingPathComponent("after-rebind.txt")) == Data("new target".utf8))
    }

    @Test
    func testFilteringIgnoresSiblingAndDeepEventsButKeepsMetadataAndRecoveryHints() throws {
        let fixture = try ObservationFixture()
        let scope = try DirectoryWatchScope(url: fixture.folder)
        let root = fixture.folder.resolvingSymlinksInPath()
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        #expect(scope.change(for: root.appendingPathComponent("child").path, flags: modified) == .children(["child"]))
        #expect(scope.change(for: root.appendingPathComponent("child/deep.txt").path, flags: modified) == nil)
        #expect(scope.change(for: root.path + "-sibling/file.txt", flags: modified) == nil)
        #expect(scope.change(for: root.appendingPathComponent("child").path,
                             flags: UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)) == .children(["child"]))
        for flag in [kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMustScanSubDirs,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagUserDropped] {
            #expect(scope.change(for: fixture.parent.path, flags: UInt32(flag)) == .rootChanged)
        }
    }

    /// GAP-036: the same native /private/var path must classify identically
    /// before and after its final entry disappears. No native event timing is used.
    @Test
    func testPrivateVarDeletionPathsKeepChildRootAndRouteLinkClassification() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("ExplorerObservation-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("Empty", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let scope = try DirectoryWatchScope(url: root)
        let child = root.appendingPathComponent("Chevron Validation Child", isDirectory: true)
        let rawChildPath = "/private" + child.path
        let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        let removed = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
        let renamed = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
        try manager.createDirectory(at: child, withIntermediateDirectories: false)
        #expect(scope.change(for: rawChildPath, flags: created) == .children([child.lastPathComponent]))
        try manager.removeItem(at: child)
        #expect(scope.change(for: rawChildPath, flags: removed) == .children([child.lastPathComponent]))
        #expect(scope.change(for: child.path, flags: removed) == .children([child.lastPathComponent]))
        #expect(scope.change(for: rawChildPath, flags: renamed) == .changed)
        #expect(scope.change(for: rawChildPath + "/deep", flags: removed) == nil)
        #expect(scope.change(for: "/private" + root.path + "-sibling/child", flags: removed) == nil)

        let route = fixture.appendingPathComponent("Route", isDirectory: true)
        try manager.createSymbolicLink(at: route, withDestinationURL: root)
        let routeScope = try DirectoryWatchScope(url: route)
        #expect(routeScope.change(for: rawChildPath, flags: removed) == .children([child.lastPathComponent]))
        try manager.removeItem(at: route)
        #expect(routeScope.change(for: "/private" + route.path, flags: removed) == .rootChanged)
        #expect(manager.fileExists(atPath: root.path))

        try manager.removeItem(at: root)
        #expect(scope.change(for: "/private" + root.path, flags: removed) == .rootChanged)
        try manager.removeItem(at: fixture)
        #expect(scope.change(for: "/private" + fixture.path, flags: removed) == .rootChanged)
        #expect(scope.change(for: "/private" + root.path, flags: removed) == .rootChanged)
        #expect(scope.change(for: rawChildPath, flags: removed) == .children([child.lastPathComponent]))
        let missingScope = try DirectoryWatchScope(url: root)
        #expect(missingScope.change(for: "/private" + root.path, flags: created) == .rootChanged)
    }

    @Test
    func testRegularFileAndUnsupportedURLAreRejected() throws {
        let fixture = try ObservationFixture()
        let file = fixture.folder.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { _ = try LocalDirectoryObserver().events(for: file) }
        #expect(throws: (any Error).self) { _ = try LocalDirectoryObserver().events(for: URL(string: "https://example.com")!) }
        #expect(throws: (any Error).self) { _ = try LocalDirectoryObserver().events(for: URL(string: "file://server/tmp")!) }
    }

    @Test
    func testCancellationStopsNativeStreamOnceAndNoFurtherHintsArrive() async throws {
        let fixture = try ObservationFixture()
        let stopped = StopCount()
        let stream = try LocalDirectoryObserver(onStop: { stopped.increment() }).events(for: fixture.folder)
        let hints = ObservedHints()
        let consumer = consume(stream, into: hints)
        try Data("initial".utf8).write(to: fixture.folder.appendingPathComponent("initial.txt"))
        try await waitForHint(hints)
        consumer.cancel()
        await consumer.value
        #expect(stopped.value == 1)
        let count = await hints.values.count
        try Data("after cancel".utf8).write(to: fixture.folder.appendingPathComponent("later.txt"))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(await hints.values.count == count)
        withExtendedLifetime(stream) {}
        #expect(stopped.value == 1)
    }

    @Test
    func testAbandoningUnconsumedSequenceReleasesNativeStream() throws {
        let fixture = try ObservationFixture()
        let stopped = StopCount()
        var stream: AsyncThrowingStream<DirectoryChange, Error>? = try LocalDirectoryObserver(onStop: {
            stopped.increment()
        }).events(for: fixture.folder)
        withExtendedLifetime(stream) { #expect(stopped.value == 0) }
        stream = nil
        #expect(stopped.value == 1)
    }

    private func consume(_ stream: AsyncThrowingStream<DirectoryChange, Error>, into hints: ObservedHints) -> Task<Void, Never> {
        Task {
            do { for try await event in stream { await hints.append(event) } }
            catch is CancellationError {} // Cancellation is an expected end of observation.
            catch { Issue.record("Native observation failed: \(error)") }
        }
    }
    private func waitForHint(_ hints: ObservedHints, after count: Int = 0,
                             requiring expected: DirectoryChange? = nil) async throws {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let values = await hints.values
            if values.count > count, expected == nil || values.dropFirst(count).contains(expected!) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("No expected native filesystem event arrived within six seconds")
    }
    private func settle(_ hints: ObservedHints) async throws {
        // Test-only quiet boundary separates distinct real mutations; production never polls.
        var count = await hints.values.count
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let current = await hints.values.count
            if current == count { return }
            count = current
        }
    }
}
