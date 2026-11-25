import AppKit
import Foundation
import ExplorerCore
import Testing
@testable import ExplorerApp

@MainActor
struct RecentDocumentTests {
    @Test func recentTracksOnlyAcceptedSingleTypedBatchAndOpenWithLaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["First.txt", "Second.txt", "Third.txt"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let board = NSPasteboard(name: .init("RecentDocumentTests-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        let router = P18Router()
        store.applications = router
        try await p18Wait { store.activeTab.hasLoaded }
        let first = try #require(store.activeTab.items.first { $0.name == "First.txt" })
        let second = try #require(store.activeTab.items.first { $0.name == "Second.txt" })
        let third = try #require(store.activeTab.items.first { $0.name == "Third.txt" })
        store.activate(first)
        try await p18Wait { store.recentDocuments.entries.first?.url == first.url }
        #expect(store.recentDocuments.entries.map(\.url) == [first.url])

        router.failedDefaultURLs = [second.url]
        store.setSelection([second.id, third.id], focusedID: second.id)
        store.openSelection()
        try await p18Wait { router.defaults.count == 2 }
        #expect(store.recentDocuments.entries.map(\.url) == [third.url, first.url])
        store.submitTypedAddress(first.url)
        try await p18Wait { router.defaults == [first.url] }
        #expect(store.recentDocuments.entries.map(\.url) == [first.url, third.url])

        store.setSelection([second.id], focusedID: second.id)
        store.chooseApplicationAndOpen(second) // The picker double returns Cancel.
        #expect(router.openAttempts.isEmpty)
        router.openError = CocoaError(.fileReadNoPermission)
        store.open(second, withApplicationAt: router.choices[0].url)
        try await p18Wait { router.openAttempts == [second.url] }
        #expect(store.recentDocuments.entries.map(\.url) == [first.url, third.url])
        router.openError = nil
        store.open(second, withApplicationAt: router.choices[0].url)
        try await p18Wait { store.recentDocuments.entries.first?.url == second.url }
        #expect(store.recentDocuments.entries.map(\.url) == [second.url, first.url, third.url])
    }

    @Test func replacingAListedFileBeforeOpenCannotRecordOrLaunchItsReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Document.txt")
        try Data([1]).write(to: url)
        let board = NSPasteboard(name: .init("RecentReplacement-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = ExplorerStore(initialURL: root, clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads() }
        let router = P18Router()
        store.applications = router
        try await p18Wait { store.activeTab.hasLoaded }
        let original = try #require(store.activeTab.items.first)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("Original.txt"))
        try Data([2]).write(to: url)
        store.activate(original)
        try await p18Wait { store.operationNotice != nil || !router.defaults.isEmpty }
        #expect(router.defaults.isEmpty && store.recentDocuments.entries.isEmpty)
    }

    enum ReplacementDecision: CaseIterable { case accept, cancel, changesAgain, launchFails, removedFromRecent }

    @Test(arguments: ReplacementDecision.allCases)
    func changedDocumentRequiresConsentForTheExactReplacement(_ decision: ReplacementDecision) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Draft.txt")
        try Data([1]).write(to: file)
        let original = try #require(RecentDocument.capture(file))
        let store = ExplorerStore(initialURL: BrowserPage.home.url)
        defer { store.cancelLoads() }
        store.recentDocuments.record([original], excluding: [])
        let entry = try #require(store.recentDocuments.entries.first)
        let router = ZIPAppRouter()
        let failing = P18Router()
        failing.failsDefaults = true
        if decision == .launchFails { store.applications = failing } else { store.applications = router }
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("First.txt"))
        try Data([2]).write(to: file)
        store.performPageAction(.open, url: file, folder: false, recent: entry)
        try await p18Wait { store.recentOpenConfirmation != nil }
        let confirmation = try #require(store.recentOpenConfirmation)
        #expect(router.opened.isEmpty && failing.defaults.isEmpty)
        if decision == .cancel {
            store.cancelRecentOpen()
            store.confirmRecentOpen(confirmation)
        } else {
            if decision == .changesAgain {
                try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("Second.txt"))
                try Data([3]).write(to: file)
            }
            if decision == .removedFromRecent { store.recentDocuments.remove(entry) }
            store.confirmRecentOpen(confirmation)
        }
        #expect(store.recentOpenConfirmation == nil)
        switch decision {
        case .accept:
            try await p18Wait { router.opened == [file] }
            let accepted = try #require(store.recentDocuments.entries.first)
            #expect(accepted.identity != original.identity)
            #expect(store.recentDocuments.entries.count == 1)
            store.performPageAction(.open, url: file, folder: false, recent: accepted)
            try await p18Wait { router.opened.count == 2 || store.recentOpenConfirmation != nil }
            if accepted.volumeUUID != nil {
                #expect(router.opened == [file, file] && store.recentOpenConfirmation == nil)
            } else {
                #expect(router.opened == [file] && store.recentOpenConfirmation != nil)
            }
        case .changesAgain, .launchFails:
            try await p18Wait { store.operationNotice != nil }
            #expect(router.opened.isEmpty)
            #expect(failing.defaults == (decision == .launchFails ? [file] : []))
            #expect(store.recentDocuments.entries == [entry])
        case .cancel:
            #expect(router.opened.isEmpty && store.recentDocuments.entries == [entry])
        case .removedFromRecent:
            #expect(router.opened.isEmpty && store.recentDocuments.entries.isEmpty)
        }
    }

    enum UnavailableReplacement: CaseIterable { case missing, directory, package }

    @Test(arguments: UnavailableReplacement.allCases)
    func missingOrWrongTypeCannotOfferConfirmation(_ replacement: UnavailableReplacement) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.txt")
        try Data([1]).write(to: file)
        let original = try #require(RecentDocument.capture(file))
        let store = ExplorerStore(initialURL: BrowserPage.home.url)
        defer { store.cancelLoads() }
        store.recentDocuments.record([original], excluding: [])
        let router = ZIPAppRouter()
        store.applications = router
        try FileManager.default.removeItem(at: file)
        if replacement == .directory { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
        if replacement == .package {
            let package = root.appendingPathComponent("Synthetic.app", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: package)
        }
        let entry = try #require(store.recentDocuments.entries.first)
        store.performPageAction(.open, url: file, folder: false, recent: entry)
        try await p18Wait { store.operationNotice != nil }
        #expect(store.activePage == .home && store.recentOpenConfirmation == nil && router.opened.isEmpty)
        #expect(store.recentDocuments.entries.first?.identity == original.identity)
    }

    @Test func logicalAndPhysicalIdentityAreScopedToTheirVolume() throws {
        let url = URL(fileURLWithPath: "/tmp/DocumentIdentityFixture.txt")
        let volume = UUID()
        func entry(device: UInt64 = 1, inode: UInt64 = 2, birth: Int64 = 3,
                   volumeUUID: UUID?, documentID: Int? = nil) -> RecentDocument {
            RecentDocument(url: url, identity: LocalFileIdentity(device: device, inode: inode,
                birthSeconds: birth, birthNanoseconds: 4), volumeUUID: volumeUUID,
                documentID: documentID, regularFile: true, openedAt: .now)
        }
        let first = entry(volumeUUID: volume, documentID: 14)
        let safeSave = entry(device: 6, inode: 7, birth: 8, volumeUUID: volume, documentID: 14)
        #expect(first.identifies(safeSave))
        #expect(!first.isSameCandidate(as: safeSave))
        #expect(!first.identifies(entry(volumeUUID: UUID(), documentID: 14)))
        #expect(!first.identifies(entry(volumeUUID: volume, documentID: 15)))
        #expect(first.identifies(entry(device: 8, volumeUUID: volume)))
        #expect(!first.identifies(entry(inode: 21, volumeUUID: volume)))
        let weak = entry(volumeUUID: nil)
        #expect(!weak.identifies(weak))
        #expect(weak.isSameCandidate(as: weak))
    }

    @Test func foundationSafeSaveUsesTheVolumesObservedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Report.txt")
        let staged = root.appendingPathComponent("Saved.txt")
        try Data([1]).write(to: file)
        try Data([2]).write(to: staged)
        let before = try #require(RecentDocument.capture(file))
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)
        let after = try #require(RecentDocument.capture(file))
        #expect(before.identity != after.identity)
        let preservedDocumentID = before.documentID != nil && before.documentID == after.documentID
        #expect(before.identifies(after) == (before.volumeUUID != nil && before.volumeUUID == after.volumeUUID && preservedDocumentID))
        #expect(!before.isSameCandidate(as: after))
    }

    @Test func persistedLegacyEntriesRequireConfirmationAndUpgradeOnAcceptedOpen() async throws {
        struct Legacy: Codable { let url: URL; let identity: LocalFileIdentity; let openedAt: Date }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Legacy.txt")
        try Data([1]).write(to: file)
        let current = try #require(RecentDocument.capture(file))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([Legacy(url: file, identity: current.identity, openedAt: current.openedAt)]),
                     forKey: "nativeExplorer.recentDocuments.v1")
        let recent = RecentDocumentStore(defaults: defaults)
        let legacy = try #require(recent.entries.first)
        #expect(legacy.volumeUUID == nil && !legacy.identifies(current))
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: recent)
        defer { store.cancelLoads() }
        let router = ZIPAppRouter()
        store.applications = router
        store.performPageAction(.open, url: file, folder: false, recent: legacy)
        try await p18Wait { store.recentOpenConfirmation != nil }
        #expect(router.opened.isEmpty)
        store.confirmRecentOpen(try #require(store.recentOpenConfirmation))
        try await p18Wait { router.opened == [file] }
        let upgraded = try #require(RecentDocumentStore(defaults: defaults).entries.first)
        #expect(upgraded.volumeUUID == current.volumeUUID && upgraded.regularFile == true)
    }

    @Test func acceptedHandoffsPersistInOrderAndRejectAReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let store = RecentDocumentStore(defaults: defaults)
        let a = try #require(RecentDocument.capture(first))
        let b = try #require(RecentDocument.capture(second))
        store.record([a, b], excluding: [b.url])
        #expect(store.entries.map(\.url) == [first])
        store.record([b], excluding: [])
        store.record([a], excluding: [])
        let restored = RecentDocumentStore(defaults: defaults)
        #expect(restored.entries.map(\.url) == [first, second])
        try FileManager.default.moveItem(at: first, to: root.appendingPathComponent("original"))
        try Data([3]).write(to: first)
        #expect(!a.isCurrent)
        #expect(b.isCurrent)
        restored.remove(a)
        #expect(RecentDocumentStore(defaults: defaults).entries.map(\.url) == [second])
    }
}
