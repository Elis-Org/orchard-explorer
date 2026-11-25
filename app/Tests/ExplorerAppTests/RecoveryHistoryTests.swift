import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Session-owned receipt and cross-window claim policy; not a whole-Trash inventory.
/// Context: FR-FILE-007 / EV-0453 / AT-FILE-007, with an explicit native scope.
@MainActor
final class RecoveryHistoryTests {
    private func receipt(id: UUID = UUID(), name: String = "delete-me.txt") -> TrashReceipt {
        let originalURL = URL(fileURLWithPath: "/tmp/explorer-recovery-history/Source", isDirectory: true)
        let trashURL = URL(fileURLWithPath: "/tmp/explorer-recovery-history/Trash", isDirectory: true)
        func identity(_ inode: UInt64) -> LocalFileIdentity {
            LocalFileIdentity(device: 1, inode: inode, birthSeconds: 100, birthNanoseconds: 1)
        }
        func item(_ directory: URL) -> FileItem {
            FileItem(url: directory.appendingPathComponent(name), name: name,
                     isDirectory: false, isSymbolicLink: false, size: 26, modifiedAt: nil,
                     kind: "Text Document", identity: identity(101))
        }
        return TrashReceipt(id: id, original: item(originalURL),
                            originalContext: FileOperationContext(directoryURL: originalURL, directoryIdentity: identity(100)),
                            trashed: item(trashURL),
                            trashContext: FileOperationContext(directoryURL: trashURL, directoryIdentity: identity(200)),
                            trashedAt: Date(timeIntervalSince1970: 100))
    }

    @Test
    func recordingDeduplicatesReceiptIDsWithoutReplacingTheirCapturedIdentity() throws {
        let history = RecoveryHistory(), original = receipt()
        #expect(history.entries.isEmpty && history.claimedIDs.isEmpty)
        history.record(original)
        history.record(receipt(id: original.id, name: "different.txt"))
        #expect(history.entries.count == 1)
        let retained = try #require(history.entries.first)
        #expect(retained.id == original.id && retained.original == original.original)
        #expect(retained.originalContext == original.originalContext)
        #expect(retained.trashed == original.trashed && retained.trashContext == original.trashContext)
    }

    @Test
    func onlyOneClaimCanOwnAReceiptUntilItIsReleased() throws {
        let history = RecoveryHistory(), entry = receipt(), other = receipt(name: "other.txt")
        history.record(entry)
        history.record(other)
        #expect(history.entries.map(\.id) == [other.id, entry.id])
        #expect(history.claim(entry.id)?.id == entry.id)
        #expect(history.claim(entry.id) == nil)
        #expect(history.claim(other.id)?.id == other.id)
        #expect(history.claimedIDs == [entry.id, other.id])
        history.release(entry.id)
        #expect(history.claimedIDs == [other.id])
        #expect(history.claim(entry.id)?.id == entry.id)
        #expect(history.entries.count == 2)
    }

    @Test
    func removalRetiresTheReceiptAndItsClaimWithoutAffectingOtherEntries() {
        let history = RecoveryHistory(), first = receipt(), second = receipt(name: "second.txt")
        history.record(first)
        history.record(second)
        _ = history.claim(first.id)
        _ = history.claim(second.id)
        history.remove(first.id)
        #expect(history.entries.map(\.id) == [second.id])
        #expect(history.claimedIDs == [second.id])
        #expect(history.claim(first.id) == nil)
        history.remove(first.id)
        history.release(UUID())
        #expect(history.entries.map(\.id) == [second.id] && history.claimedIDs == [second.id])
    }

    @Test
    func unknownAndAnotherSessionsReceiptsCannotBeClaimed() {
        let history = RecoveryHistory(), anotherSession = RecoveryHistory(), entry = receipt()
        history.record(entry)
        #expect(history.claim(UUID()) == nil)
        #expect(anotherSession.claim(entry.id) == nil)
        #expect(anotherSession.entries.isEmpty && anotherSession.claimedIDs.isEmpty)
        #expect(history.entries.map(\.id) == [entry.id] && history.claimedIDs.isEmpty)
    }
}
