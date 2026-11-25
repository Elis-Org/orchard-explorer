import Foundation
import Testing
@testable import ExplorerCore

struct PhysicalContentUseTests {
    private func identity(_ inode: UInt64, device: UInt64 = 17, birth: Int64 = 0) -> LocalFileIdentity {
        LocalFileIdentity(device: device, inode: inode, birthSeconds: 1, birthNanoseconds: birth)
    }
    @Test func directoryAliasMatchesCapturedObjectAcrossBirthDriftWithoutGrantingIdentity() {
        let canonical = URL(fileURLWithPath: "/synthetic/provider/folder/item.txt")
        let alias = URL(fileURLWithPath: "/synthetic/folder-alias/item.txt")
        let before = PhysicalContentTarget(url: canonical, identity: identity(100), parentIdentity: identity(99))
        let after = PhysicalContentTarget(url: alias, identity: identity(100, birth: 6), parentIdentity: identity(99))
        #expect(before.conflicts(with: after) && after.conflicts(with: before))
        #expect(identity(100) != identity(100, birth: 6), "Strict identity authorization remains unchanged")
    }
    @Test func unrelatedCapturedObjectsDoNotMatchOnlyByInode() {
        let canonical = PhysicalContentTarget(url: URL(fileURLWithPath: "/synthetic/provider/item.txt"),
            identity: identity(100), parentIdentity: identity(99))
        let sameName = URL(fileURLWithPath: "/synthetic/other/item.txt")
        for other in [
            PhysicalContentTarget(url: sameName, identity: identity(100, device: 18), parentIdentity: identity(99)),
            PhysicalContentTarget(url: sameName, identity: identity(101), parentIdentity: identity(99)),
            PhysicalContentTarget(url: sameName, identity: identity(100), parentIdentity: identity(98)),
            PhysicalContentTarget(url: URL(fileURLWithPath: "/synthetic/other/replacement.txt"),
                identity: identity(100), parentIdentity: identity(99)),
            PhysicalContentTarget(url: sameName),
            PhysicalContentTarget(url: sameName, identity: identity(100))
        ] { #expect(!canonical.conflicts(with: other)) }
    }
    @Test func lexicalFallbackAndMultipleOwnersRemainUntilTheirOwnCleanup() {
        let uses = PhysicalContentUse()
        let url = URL(fileURLWithPath: "/synthetic/provider/item.txt")
        let target = PhysicalContentTarget(url: url, identity: identity(100), parentIdentity: identity(99))
        let alias = PhysicalContentTarget(url: URL(fileURLWithPath: "/synthetic/alias/item.txt"),
            identity: identity(100, birth: 6), parentIdentity: identity(99))
        let first = uses.retain(target), second = uses.retain(alias)
        #expect(uses.isInUse(of: target) && uses.isInUse(of: alias))
        #expect(uses.isInUse(of: url), "Identityless callers preserve lexical conflict detection")
        #expect(target.conflicts(with: PhysicalContentTarget(url: url, identity: identity(200), parentIdentity: identity(99))),
            "A pending pathname command conservatively protects its route after replacement")
        first.end(); first.end()
        #expect(uses.isInUse(of: target))
        second.end()
        #expect(!uses.isInUse(of: target) && !uses.isInUse(of: alias))
        let unknown = uses.retain(url)
        #expect(uses.isInUse(of: target) && !uses.isInUse(of: alias))
        unknown.end()
        #expect(!uses.isInUse(of: url))
    }
}
