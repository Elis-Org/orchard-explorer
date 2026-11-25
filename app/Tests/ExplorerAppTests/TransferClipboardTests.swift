import AppKit
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Private, uniquely named pasteboards only; no general clipboard or filesystem writes.
/// Clipboard representation/ownership are native policy, not Windows format assertions.
/// Context: FR-FILE-003/004, EV-0252/0255, AT-FILE-003/004.
@MainActor
final class TransferClipboardTests {
    private let root = URL(fileURLWithPath: "/tmp/explorer-clipboard-model", isDirectory: true)

    private func identity(_ inode: UInt64) -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
    }
    private var context: FileOperationContext {
        FileOperationContext(directoryURL: root, directoryIdentity: identity(100))
    }
    private func item(_ name: String = "copy-me.txt", under directory: URL? = nil,
                      inode: UInt64? = 101, url: URL? = nil) -> FileItem {
        FileItem(url: url ?? (directory ?? root).appendingPathComponent(name), name: name,
                 isDirectory: false, isSymbolicLink: false, size: 24, modifiedAt: nil,
                 kind: "Text Document", identity: inode.map { identity($0) })
    }
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ExplorerClipboardTests-\(UUID().uuidString)"))
    }
    private func urls(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?
            .map { $0 as URL } ?? []
    }

    @Test
    func captureExportsFileURLsAndKeepsIdentityAndIntentOnlyInMemory() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let entries = [item(), item("second space.txt", inode: 102)]
        #expect(clipboard.payload == nil && clipboard.version == 0)
        clipboard.capture(items: entries, source: context, kind: .copy)
        let first = try #require(clipboard.payload)
        #expect(first.items == entries && first.entries.allSatisfy { $0.source == context } && first.kind == .copy)
        #expect(urls(board) == entries.map(\.url))
        #expect(board.pasteboardItems?.count == entries.count)
        #expect(clipboard.version == 1)
        clipboard.refresh()
        clipboard.refresh()
        #expect(clipboard.payload?.id == first.id && clipboard.version == 1)
        clipboard.capture(items: entries, source: context, kind: .move)
        let next = try #require(clipboard.payload)
        #expect(next.id != first.id && next.kind == .move && next.entries.allSatisfy { $0.source == context })
        #expect(clipboard.version == 2)
        #expect(urls(board) == entries.map(\.url))
    }

    @Test
    func externalReplacementInvalidatesImmediatelyAndRefreshPublishesOnce() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        clipboard.capture(items: [item()], source: context, kind: .copy)
        _ = try #require(clipboard.payload)
        let version = clipboard.version
        board.clearContents()
        try #require(board.setString("external text", forType: .string))
        #expect(clipboard.payload == nil)
        #expect(clipboard.version == version)
        clipboard.refresh()
        #expect(clipboard.version == version + 1)
        clipboard.refresh()
        clipboard.refresh()
        #expect(clipboard.version == version + 1)
        #expect(board.string(forType: .string) == "external text")
    }

    @Test
    func consumingAnOldIntentCannotClearANewerCapture() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        clipboard.capture(items: [item()], source: context, kind: .move)
        let old = try #require(clipboard.payload)
        let newItem = item("newer.txt", inode: 102)
        clipboard.capture(items: [newItem], source: context, kind: .copy)
        let current = try #require(clipboard.payload), count = board.changeCount, version = clipboard.version
        clipboard.consume(old.id)
        clipboard.consume(UUID())
        #expect(clipboard.payload?.id == current.id)
        #expect(clipboard.version == version && board.changeCount == count)
        #expect(urls(board) == [newItem.url])
    }

    @Test
    func consumeClearsOnlyItsOwnedIntentAndIsIdempotent() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        clipboard.capture(items: [item()], source: context, kind: .move)
        let payload = try #require(clipboard.payload), count = board.changeCount, version = clipboard.version
        clipboard.consume(payload.id)
        #expect(clipboard.payload == nil && clipboard.version == version + 1)
        #expect(board.changeCount != count && urls(board).isEmpty)
        #expect(board.types?.isEmpty != false)
        let consumedCount = board.changeCount
        clipboard.consume(payload.id)
        clipboard.refresh()
        #expect(clipboard.version == version + 1 && board.changeCount == consumedCount)
    }

    @Test
    func consumingAStaleIntentPreservesAnExternalClipboard() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        clipboard.capture(items: [item()], source: context, kind: .move)
        let payload = try #require(clipboard.payload)
        board.clearContents()
        try #require(board.setString("do not clear", forType: .string))
        let count = board.changeCount
        clipboard.consume(payload.id)
        #expect(clipboard.payload == nil && board.changeCount == count)
        #expect(board.string(forType: .string) == "do not clear")
    }

    @Test
    func foreignAndReplayedPasteboardDataNeverBecomeTransferAuthority() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let owner = TransferClipboard(pasteboard: board)
        owner.capture(items: [item()], source: context, kind: .copy)
        _ = try #require(owner.payload)
        let stranger = TransferClipboard(pasteboard: board)
        #expect(stranger.payload == nil && stranger.version == 0)
        #expect(stranger.archivePasteRefusal(isManagedURL: { _ in false }) == .unverifiedPrivateToken)
        stranger.refresh()
        #expect(stranger.payload == nil && stranger.version == 0)
        let originalItems = try #require(board.pasteboardItems)
        let replay = originalItems.map { original -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        board.clearContents()
        try #require(board.writeObjects(replay))
        #expect(urls(board) == [item().url])
        // Even a byte-for-byte replay of the private token has a different generation.
        #expect(owner.payload == nil && stranger.payload == nil)
        #expect(owner.archivePasteRefusal(isManagedURL: { _ in false }) == .unverifiedPrivateToken)
        owner.refresh()
        #expect(owner.payload == nil)
    }

    @Test
    func archivePasteRefusalPreservesMarkerOwnershipAndManagedPathPrecedence() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let owner = TransferClipboard(pasteboard: board)
        owner.capture(items: [item()], source: context, kind: .copy)
        let prepared = try #require(owner.payload)
        #expect(owner.archivePasteRefusal(isManagedURL: { _ in false }) == nil)
        #expect(owner.archivePasteRefusal(isManagedURL: { _ in true }) == .managedExport)

        let recreated = TransferClipboard(pasteboard: board)
        #expect(recreated.payload == nil)
        // A prepared physical payload does not erase the current unowned token.
        #expect(recreated.archivePasteRefusal(for: prepared, isManagedURL: { _ in true }) == .unverifiedPrivateToken)
        let archiveType = NSPasteboard.PasteboardType("com.native-explorer.archive-export-origin")
        board.addTypes([archiveType], owner: nil)
        try #require(board.setString("archive-export", forType: archiveType))
        #expect(recreated.archivePasteRefusal(for: prepared, isManagedURL: { _ in true }) == .archiveOrigin)

        board.clearContents()
        try #require(board.writeObjects([item().url as NSURL]))
        #expect(recreated.archivePasteRefusal(isManagedURL: { _ in false }) == nil)
        // External URL import supplies physical entries only after identity capture.
        #expect(recreated.archivePasteRefusal(for: prepared, isManagedURL: { _ in true }) == .managedExport)
        #expect(recreated.archivePasteRefusal(for: prepared, isManagedURL: { _ in false }) == nil)
        #expect(recreated.payload == nil && urls(board) == [item().url])
    }

    @Test
    func changingThePrivateTokenInvalidatesOwnershipWithoutClearingTheBoard() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        clipboard.capture(items: [item()], source: context, kind: .copy)
        _ = try #require(clipboard.payload)
        let tokenType = try #require(board.types?.first { type in
            board.string(forType: type).flatMap { UUID(uuidString: $0) } != nil
        })
        let count = board.changeCount
        try #require(board.setString(UUID().uuidString, forType: tokenType))
        // Updating data for an existing type retains the pasteboard ownership generation.
        #expect(board.changeCount == count)
        #expect(clipboard.payload == nil)
        clipboard.refresh()
        #expect(clipboard.version == 2 && urls(board) == [item().url])
    }

    @Test
    func invalidCapturesAreAllOrNothingAndLeaveAnExistingIntentUntouched() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let original = item()
        clipboard.capture(items: [original], source: context, kind: .copy)
        let payload = try #require(clipboard.payload), count = board.changeCount
        let outside = root.appendingPathComponent("nested", isDirectory: true)
        let invalidSelections: [[FileItem]] = [
            [], [item(inode: nil)], [original, item("unknown.txt", inode: nil)],
            [item(under: outside)], [original, original],
            [item("different.txt", url: original.url)],
            [item(url: URL(string: "https://example.invalid/copy-me.txt")!)]
        ]
        for selection in invalidSelections {
            clipboard.capture(items: selection, source: context, kind: .move)
            #expect(clipboard.payload?.id == payload.id)
            #expect(clipboard.version == 1 && board.changeCount == count)
        }
        let noncanonical = FileOperationContext(directoryURL: root.appendingPathComponent("nested/.."),
                                                directoryIdentity: identity(100))
        clipboard.capture(items: [original], source: noncanonical, kind: .move)
        #expect(clipboard.payload?.id == payload.id && clipboard.version == 1)
        #expect(board.changeCount == count && urls(board) == [original.url])
    }

    @Test
    func canonicalUnicodeURLSpellingPreservesTheSampledSourceName() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let decomposed = "Cafe\u{301}.txt"
        let entry = item(decomposed, url: root.appendingPathComponent("Café.txt"))
        clipboard.capture(items: [entry], source: context, kind: .copy)
        let payload = try #require(clipboard.payload)
        #expect(Array(payload.items[0].name.utf8) == Array(decomposed.utf8))
        #expect(payload.items == [entry] && payload.entries.allSatisfy { $0.source == context })
        #expect(urls(board) == [entry.url])
    }
}
