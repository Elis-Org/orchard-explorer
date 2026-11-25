import AppKit
import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// NATIVE-P12 / FR-FILE-003/004 / EV-0252/0255 / AT-FILE-003/004.
/// Representation and ownership checks only, not Finder UI or filesystem acceptance.
/// Every test uses a uniquely named pasteboard; no user's general clipboard is touched.
@MainActor
final class ExternalClipboardTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ExplorerExternalClipboardTests-\(UUID())"))
    }

    private func entry(_ spelling: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(spelling, forType: .fileURL)
        return item
    }

    private func text(_ value: String = "unsupported companion") -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        return item
    }

    private func write(_ items: [NSPasteboardItem], to board: NSPasteboard) throws {
        // Pasteboard items may be bound to their original generation; copy data before
        // replacing the board so repeated test cases never reuse a live item object.
        let copies = items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        board.clearContents()
        try #require(board.writeObjects(copies))
    }

    @Test
    func actualNSURLWriterImportsAllEntriesAcrossParentsAndCopiesRemainReusable() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/explorer-parent-a/space name.txt"),
                    URL(fileURLWithPath: "/tmp/explorer-parent-b/Café.txt"),
                    URL(fileURLWithPath: "/tmp/explorer-parent-b/folder", isDirectory: true)]
        try #require(board.writeObjects(urls.map { $0 as NSURL }))
        let clipboard = TransferClipboard(pasteboard: board)
        #expect(clipboard.hasTransferCandidate && clipboard.payload == nil)
        let exported = try #require(board.pasteboardItems).map { try #require($0.string(forType: .fileURL)) }
        let first = try clipboard.externalSnapshot()
        let again = try clipboard.externalSnapshot()
        #expect(first.urlStrings == exported && again.urlStrings == exported)
        #expect(first.changeCount == again.changeCount && first.id != again.id)
        #expect(clipboard.stillMatches(first) && clipboard.stillMatches(again))
        #expect(board.pasteboardItems?.count == urls.count)
    }

    @Test
    func accompanyingTextAndFakeInternalTokenDoNotSupplyInternalAuthority() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let file = entry("file:///tmp/explorer-external/a.txt")
        file.setString("file description", forType: .string)
        file.setString(UUID().uuidString,
                       forType: NSPasteboard.PasteboardType("com.native-explorer.internal-transfer-token"))
        try write([file], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        #expect(clipboard.payload == nil && clipboard.hasTransferCandidate)
        #expect(try clipboard.externalSnapshot().urlStrings == ["file:///tmp/explorer-external/a.txt"])
        clipboard.refresh()
        #expect(clipboard.payload == nil)
    }

    @Test
    func separateUnsupportedCompanionRejectsEntireBatchRegardlessOfOrder() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        for unsupported in [text(), entry("https://example.invalid/a.txt"),
                            entry("file://remote.invalid/tmp/a.txt"), entry("not a URL")] {
            for invalidFirst in [false, true] {
                let file = entry("file:///tmp/explorer-external/a.txt")
                try write(invalidFirst ? [unsupported, file] : [file, unsupported], to: board)
                #expect(clipboard.hasTransferCandidate)
                #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
                #expect(clipboard.payload == nil)
            }
        }
    }

    @Test
    func promiseOnlyCandidateRefusesWithoutRequestingPromisedContent() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let promiseType = try #require(NSFilePromiseReceiver.readableDraggedTypes.first)
        let promise = NSPasteboardItem()
        promise.setString("public.data", forType: NSPasteboard.PasteboardType(promiseType))
        try write([promise], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        #expect(clipboard.hasTransferCandidate)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
        try write([entry("file:///tmp/explorer-external/a.txt"), promise], to: board)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
    }

    @Test
    func emptyAndPlainTextHaveNoFileCandidate() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        board.clearContents()
        #expect(!clipboard.hasTransferCandidate)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
        try write([text("file:///tmp/a.txt")], to: board)
        #expect(!clipboard.hasTransferCandidate)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
    }

    @Test
    func rejectsNonlocalMalformedNoncanonicalAndRootURLs() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let invalid = ["https://example.invalid/file", "file://remote.invalid/tmp/file",
                       "file://user@localhost/tmp/file", "file://localhost:42/tmp/file",
                       "file:///tmp/file?query", "file:///tmp/file#fragment", "file:///",
                       "file:///tmp/../file", "file:///tmp/./file", "file:///tmp//file",
                       "file:///tmp/file%00tail", "file:///tmp/a%2Fb", "file:///tmp/bad%GG", "file:relative.txt", ""]
        for spelling in invalid {
            try write([entry(spelling)], to: board)
            #expect(clipboard.hasTransferCandidate)
            #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
        }
        let invalidUTF8 = NSPasteboardItem()
        invalidUTF8.setData(Data([0xFF, 0xFE]), forType: .fileURL)
        try write([invalidUTF8], to: board)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
    }

    @Test
    func enforcesItemLimitWithoutFiltering() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        try write((0..<1_024).map { entry("file:///tmp/explorer-external/\($0)") }, to: board)
        #expect(try clipboard.externalSnapshot().urlStrings.count == 1_024)
        try write((0..<1_025).map { entry("file:///tmp/explorer-external/\($0)") }, to: board)
        #expect(clipboard.hasTransferCandidate)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
    }

    @Test
    func enforcesEncodedURLByteLimitIncludingMultibyteEscapesAndWholeBatch() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = TransferClipboard(pasteboard: board)
        let prefix = "file:///tmp/"
        let atLimit = prefix + String(repeating: "a", count: 1_048_576 - prefix.utf8.count)
        try write([entry(atLimit)], to: board)
        #expect(try clipboard.externalSnapshot().urlStrings.count == 1)
        try write([entry(atLimit + "a")], to: board)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
        let individuallyValid = prefix + String(repeating: "%C3%A9", count: 90_000)
        try write([entry(individuallyValid), entry(individuallyValid + "b")], to: board)
        #expect(throws: ExternalClipboardError.self) { try clipboard.externalSnapshot() }
    }

    @Test
    func moveClaimSurvivesResnapshotFailureOrCancellationAndCopyRemainsReusable() throws {
        let board = board()
        defer { board.releaseGlobally() }
        try write([entry("file:///tmp/explorer-external/a.txt")], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        let snapshot = try clipboard.externalSnapshot()
        try clipboard.claimMove(snapshot)
        #expect(clipboard.stillMatches(snapshot))
        let retry = try clipboard.externalSnapshot()
        #expect(retry.urlStrings == snapshot.urlStrings && retry.id != snapshot.id)
        #expect(throws: ExternalClipboardError.moveAlreadyClaimed) { try clipboard.claimMove(retry) }
        #expect(try clipboard.externalSnapshot().urlStrings == snapshot.urlStrings)
        // An unrelated snapshot cannot consume the reserved intent.
        let count = board.changeCount
        #expect(!clipboard.consumeExternalMove(retry))
        #expect(board.changeCount == count)
        #expect(clipboard.consumeExternalMove(snapshot))
        #expect(board.changeCount != count && board.pasteboardItems?.isEmpty != false)
        let clearedCount = board.changeCount
        #expect(!clipboard.consumeExternalMove(snapshot))
        #expect(board.changeCount == clearedCount)
    }

    @Test
    func staleSnapshotCannotClaimOrClearNewerExternalOrInternalClipboard() throws {
        let board = board()
        defer { board.releaseGlobally() }
        try write([entry("file:///tmp/explorer-external/a.txt")], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        let old = try clipboard.externalSnapshot()
        try clipboard.claimMove(old)
        try write([entry("file:///tmp/explorer-external/new.txt")], to: board)
        let newer = try clipboard.externalSnapshot(), newCount = board.changeCount
        #expect(!clipboard.stillMatches(old))
        #expect(throws: ExternalClipboardError.changed) { try clipboard.claimMove(old) }
        #expect(!clipboard.consumeExternalMove(old))
        #expect(board.changeCount == newCount && clipboard.stillMatches(newer))
        try clipboard.claimMove(newer)
        let identity = LocalFileIdentity(device: 1, inode: 100, birthSeconds: 100, birthNanoseconds: 1)
        let directory = URL(fileURLWithPath: "/tmp/explorer-internal", isDirectory: true)
        let item = FileItem(url: directory.appendingPathComponent("copy.txt"), name: "copy.txt",
                            isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil,
                            kind: "Document", identity: identity)
        clipboard.capture(items: [item], source: FileOperationContext(directoryURL: directory,
                                                                     directoryIdentity: identity), kind: .copy)
        let internalID = try #require(clipboard.payload?.id), internalCount = board.changeCount
        #expect(!clipboard.consumeExternalMove(newer))
        #expect(board.changeCount == internalCount && clipboard.payload?.id == internalID)
    }

    @Test
    func sameGenerationURLDataReplacementInvalidatesSnapshot() throws {
        let board = board()
        defer { board.releaseGlobally() }
        try write([entry("file:///tmp/explorer-external/a.txt")], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        let snapshot = try clipboard.externalSnapshot(), count = board.changeCount
        try clipboard.claimMove(snapshot)
        try #require(board.setString("file:///tmp/explorer-external/replaced.txt", forType: .fileURL))
        #expect(board.changeCount == count)
        #expect(!clipboard.stillMatches(snapshot))
        #expect(throws: ExternalClipboardError.changed) { try clipboard.claimMove(snapshot) }
        #expect(!clipboard.consumeExternalMove(snapshot))
        #expect(board.changeCount == count)
        #expect(board.string(forType: .fileURL) == "file:///tmp/explorer-external/replaced.txt")
        // Content changes without a new ownership generation never restore Move Here.
        #expect(throws: ExternalClipboardError.moveAlreadyClaimed) {
            try clipboard.claimMove(clipboard.externalSnapshot())
        }
    }

    @Test
    func externalGenerationsRefreshOnceEvenAfterCandidateQueries() throws {
        let board = board()
        defer { board.releaseGlobally() }
        try write([text()], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        #expect(!clipboard.hasTransferCandidate && clipboard.version == 0)
        clipboard.refresh()
        #expect(clipboard.version == 0)

        try write([entry("file:///tmp/explorer-external/a.txt")], to: board)
        for _ in 0..<3 { #expect(clipboard.hasTransferCandidate) }
        // A view may query before activation's explicit refresh. That read must not
        // publish during rendering or consume the later notification.
        #expect(clipboard.version == 0 && clipboard.payload == nil)
        clipboard.refresh()
        #expect(clipboard.version == 1)
        clipboard.refresh()
        #expect(clipboard.version == 1)

        try write([entry("file:///tmp/explorer-external/b.txt")], to: board)
        #expect(clipboard.hasTransferCandidate && clipboard.version == 1)
        clipboard.refresh()
        #expect(clipboard.version == 2)
        clipboard.refresh()
        #expect(clipboard.version == 2)

        try write([text()], to: board)
        for _ in 0..<3 { #expect(!clipboard.hasTransferCandidate) }
        #expect(clipboard.version == 2)
        clipboard.refresh()
        #expect(clipboard.version == 3)
        clipboard.refresh()
        #expect(clipboard.version == 3)
    }

    @Test
    func fileReferenceURLSnapshotPreservesSpellingWithoutResolvingItsSource() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let spelling = "file:///.file/id=1.2"
        try write([entry(spelling)], to: board)
        let clipboard = TransferClipboard(pasteboard: board)
        #expect(clipboard.hasTransferCandidate)
        let snapshot = try clipboard.externalSnapshot()
        #expect(snapshot.urlStrings == [spelling])
        #expect(clipboard.stillMatches(snapshot))
    }

}
