import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private struct IdentityLegacyLoader: DirectoryListing {
    let items: [FileItem]
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { items }
}

/// Native refresh/identity policy. EV-0235 supports retained selection after an
/// app rename only; external reconciliation has its own Mac assertions here.
final class IdentityTests {
    private let base = URL(fileURLWithPath: "/tmp/identity-model", isDirectory: true)

    private func identity(_ inode: UInt64, links: UInt64 = 1) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 1_000,
                          birthNanoseconds: Int64(inode), linkCount: links)
    }

    private func item(_ name: String, identity: LocalFileIdentity?) -> FileItem {
        FileItem(url: base.appendingPathComponent(name), name: name, isDirectory: false,
                 isSymbolicLink: false, size: 22, modifiedAt: nil, kind: "Text", identity: identity)
    }

    private func selection(_ items: [FileItem], focus: FileItem? = nil, anchor: FileItem? = nil) -> SelectionState {
        var state = SelectionState()
        state.selectedIDs = Set(items.map(\.id))
        state.focusedID = focus?.id ?? items.first?.id
        state.anchorID = anchor?.id ?? items.first?.id
        return state
    }

    @Test
    func nonlocalAndUnknownCapabilitySkipPOSIXIdentityProbe() throws {
        // /dev/null is a file: probing a child must fail if lstat is invoked.
        let invalidStatPath = URL(fileURLWithPath: "/dev/null/identity-probe")
        #expect(try LocalFileIdentity.read(at: invalidStatPath, ifLocal: false) == nil)
        #expect(try LocalFileIdentity.read(at: invalidStatPath, ifLocal: nil) == nil)
        #expect(throws: POSIXError.self) {
            try LocalFileIdentity.read(at: invalidStatPath, ifLocal: true)
        }
    }

    @Test
    func uniqueRenameRemapsSelectedFocusAndAnchorIndependently() {
        let first = item("first.txt", identity: identity(1))
        let second = item("second.txt", identity: identity(2))
        let renamedFirst = item("renamed-first.txt", identity: identity(1))
        let renamedSecond = item("renamed-second.txt", identity: identity(2))
        var state = selection([first], focus: second, anchor: first)
        state.reconcile(previous: DirectorySnapshot(items: [first, second], directoryIdentity: identity(90)),
                        current: DirectorySnapshot(items: [renamedSecond, renamedFirst], directoryIdentity: identity(90)))
        #expect(state.selectedIDs == [renamedFirst.id])
        #expect(state.focusedID == renamedSecond.id)
        #expect(state.anchorID == renamedFirst.id)
    }

    @Test
    func replacementAtSamePathDoesNotInheritSelectionOrFocus() {
        let original = item("same.txt", identity: identity(1))
        let replacement = item("same.txt", identity: identity(2))
        var state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original]), current: DirectorySnapshot(items: [replacement]))
        #expect(state.selectedIDs.isEmpty)
        #expect(state.focusedID == nil)
        #expect(state.anchorID == nil)
    }

    @Test
    func replacedPathCanFollowTheOriginalAtItsNewUnambiguousName() {
        let original = item("same.txt", identity: identity(1))
        let moved = item("original-moved.txt", identity: identity(1))
        let replacement = item("same.txt", identity: identity(2))
        var state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original]),
                        current: DirectorySnapshot(items: [replacement, moved]))
        #expect(state.selectedIDs == [moved.id])
        #expect(!state.selectedIDs.contains(replacement.id))
    }

    @Test
    func changingDirectoryScopeClearsEvenEqualChildIdentity() {
        let child = item("child.txt", identity: identity(1))
        var state = selection([child])
        state.reconcile(previous: DirectorySnapshot(items: [child], directoryIdentity: identity(90)),
                        current: DirectorySnapshot(items: [child], directoryIdentity: identity(91)))
        #expect(state.selectedIDs.isEmpty)
        #expect(state.focusedID == nil)
        #expect(state.anchorID == nil)
        state = selection([child])
        state.reconcile(previous: DirectorySnapshot(items: [child], directoryIdentity: identity(90)),
                        current: DirectorySnapshot(items: [child]))
        #expect(state.selectedIDs.isEmpty, "Losing supported root identity must not imply unchanged scope")
    }

    @Test
    func unknownIdentityOnlyRetainsExactPathsAndNeverBridgesKnownUnknown() {
        let original = item("unknown.txt", identity: nil)
        var state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original]), current: DirectorySnapshot(items: [original]))
        #expect(state.selectedIDs == [original.id])
        state.reconcile(previous: DirectorySnapshot(items: [original]),
                        current: DirectorySnapshot(items: [item("renamed.txt", identity: nil)]))
        #expect(state.selectedIDs.isEmpty)
        state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original]),
                        current: DirectorySnapshot(items: [item("unknown.txt", identity: identity(1))]))
        #expect(state.selectedIDs.isEmpty)
    }

    @Test
    func fullSnapshotMultiplicityAndLinkCountEachBlockRenameRemapping() {
        let original = item("selected.txt", identity: identity(1))
        let peer = item("unselected.txt", identity: identity(1))
        let renamed = item("renamed.txt", identity: identity(1))
        var state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original, peer]),
                        current: DirectorySnapshot(items: [renamed, peer]))
        #expect(state.selectedIDs.isEmpty, "Checking only selected entries would incorrectly infer this rename")

        let hardLink = item("selected.txt", identity: identity(1, links: 2))
        let renamedLink = item("renamed.txt", identity: identity(1, links: 2))
        state = selection([hardLink])
        state.reconcile(previous: DirectorySnapshot(items: [hardLink]), current: DirectorySnapshot(items: [renamedLink]))
        #expect(state.selectedIDs.isEmpty, "A second hard link can be hidden or outside the displayed directory")
    }

    @Test
    func linkCountIsMetadataAndDoesNotChangeObjectKeyAtTheSamePath() {
        #expect(identity(1) == identity(1, links: 2))
        #expect(Set([identity(1), identity(1, links: 2)]).count == 1)
        let original = item("same.txt", identity: identity(1))
        let nowLinked = item("same.txt", identity: identity(1, links: 2))
        var state = selection([original])
        state.reconcile(previous: DirectorySnapshot(items: [original]), current: DirectorySnapshot(items: [nowLinked]))
        #expect(state.selectedIDs == [original.id])
    }

    @Test
    func defaultSnapshotKeepsExistingDirectoryListingProvidersCompatible() async throws {
        let entry = item("legacy.txt", identity: nil)
        let loader: any DirectoryListing = IdentityLegacyLoader(items: [entry])
        let result = try await loader.snapshot(of: base, showHidden: false)
        #expect(result.items == [entry])
        #expect(result.directoryIdentity == nil)
    }
}

/// Only these tests mutate files; each test owns an isolated disposable local root.
final class LocalIdentityIntegrationTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerIdentity-" + UUID().uuidString,
                                                                            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    private func renameReplacing(_ source: URL, _ destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath!, destinationPath!)
            }
        }
        try #require(result == 0, "Synthetic POSIX replacement failed")
    }

    @Test
    func nativeEditRetainsIdentityAndRenamePreservesSelectionWithNewLexicalID() async throws {
        let originalURL = root.appendingPathComponent("original.txt")
        try Data("before".utf8).write(to: originalURL)
        let loader = LocalDirectoryLoader()
        let before = try await loader.snapshot(of: root)
        let original = try #require(before.items.first)
        try #require(original.identity != nil)
        try #require(before.directoryIdentity != nil)
        try Data("edited in place".utf8).write(to: originalURL)
        let edited = try await loader.snapshot(of: root)
        #expect(edited.items.first?.identity == original.identity)
        #expect(edited.items.first?.size == 15)
        let renamedURL = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let after = try await loader.snapshot(of: root)
        var state = SelectionState()
        state.select(original.id, orderedIDs: [original.id])
        state.reconcile(previous: before, current: after)
        let renamed = try #require(after.items.first)
        #expect(renamed.url == renamedURL)
        #expect(renamed.id != original.id)
        #expect(renamed.identity == original.identity)
        #expect(state.selectedIDs == [renamed.id])
        #expect(state.focusedID == renamed.id)
        #expect(state.anchorID == renamed.id)
        #expect(try Data(contentsOf: renamedURL) == Data("edited in place".utf8))
    }

    @Test
    func nativeAtomicReplacementDoesNotInheritSelection() async throws {
        let originalURL = root.appendingPathComponent("same.txt")
        try Data("original".utf8).write(to: originalURL)
        let loader = LocalDirectoryLoader()
        let before = try await loader.snapshot(of: root)
        let original = try #require(before.items.first)
        try #require(original.identity != nil)
        let replacement = root.appendingPathComponent("staged.txt")
        try Data("replacement".utf8).write(to: replacement)
        try renameReplacing(replacement, originalURL)
        let after = try await loader.snapshot(of: root)
        #expect(after.items.first?.identity != original.identity)
        var state = SelectionState()
        state.select(original.id, orderedIDs: [original.id])
        state.reconcile(previous: before, current: after)
        #expect(state.selectedIDs.isEmpty)
        #expect(state.focusedID == nil)
        #expect(try Data(contentsOf: originalURL) == Data("replacement".utf8))
    }

    @Test
    func nativeHardLinkRenameDoesNotJumpSelectionToAnAmbiguousEntry() async throws {
        let first = root.appendingPathComponent("first.txt")
        let peer = root.appendingPathComponent("peer.txt")
        try Data("shared inode".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: peer)
        let loader = LocalDirectoryLoader()
        let before = try await loader.snapshot(of: root)
        let original = try #require(before.items.first { $0.name == "first.txt" })
        #expect(original.identity?.linkCount == 2)
        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: first, to: renamed)
        let after = try await loader.snapshot(of: root)
        var state = SelectionState()
        state.select(original.id, orderedIDs: before.items.map(\.id))
        state.reconcile(previous: before, current: after)
        #expect(state.selectedIDs.isEmpty)
        #expect(state.focusedID == nil)
        #expect(try Data(contentsOf: peer) == Data("shared inode".utf8))
    }

    @Test
    func directorySymlinkKeepsLexicalChildPathsAndFileLinkHasOwnIdentity() async throws {
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let file = target.appendingPathComponent("file.txt")
        try Data("untouched".utf8).write(to: file)
        let link = target.appendingPathComponent("file-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let alias = root.appendingPathComponent("Logical", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let loader = LocalDirectoryLoader()
        let physical = try await loader.snapshot(of: target)
        let logical = try await loader.snapshot(of: alias)
        #expect(logical.directoryIdentity == physical.directoryIdentity)
        #expect(logical.items.allSatisfy { $0.url.deletingLastPathComponent().path == alias.path })
        let fileItem = try #require(logical.items.first { $0.name == "file.txt" })
        let linkItem = try #require(logical.items.first { $0.name == "file-link.txt" })
        try #require(fileItem.identity != nil)
        try #require(linkItem.identity != nil)
        #expect(linkItem.identity != fileItem.identity, "lstat must identify the link entry, not follow its target")
        #expect(linkItem.isSymbolicLink)
        #expect(try Data(contentsOf: file) == Data("untouched".utf8))
    }

    @Test
    func removedDirectoryThrowsInsteadOfReturningAnEmptySnapshot() async throws {
        let folder = root.appendingPathComponent("Removed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try await LocalDirectoryLoader().snapshot(of: folder)
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: (any Error).self) {
            try await LocalDirectoryLoader().snapshot(of: folder)
        }
    }
}
