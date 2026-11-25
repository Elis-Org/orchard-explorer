import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

@MainActor
struct SystemRecentTests {
    private func document(_ name: String, inode: UInt64, used: Date) -> RecentDocument {
        let id = LocalFileIdentity(device: 1, inode: inode, birthSeconds: 1, birthNanoseconds: 0)
        return RecentDocument(url: URL(fileURLWithPath: "/tmp/RecentMerge/\(name)"), identity: id,
            volumeUUID: UUID(uuidString: "4D33E072-5DD7-46D3-B64B-D031A2DEC293"), regularFile: true, openedAt: used)
    }

    @MainActor private final class IndexSource {
        var starts = 0
        var stops = 0
        var sink: AsyncThrowingStream<[RecentDocument], Error>.Continuation?

        func snapshots() -> AsyncThrowingStream<[RecentDocument], Error> {
            starts += 1
            return AsyncThrowingStream { stream in
                sink = stream
                stream.onTermination = { @Sendable [weak self] _ in
                    Task { @MainActor in self?.stops += 1 }
                }
            }
        }
    }

    @Test func visibleWindowsShareAQueryAndTheLastDepartureClearsItsTransientRows() async throws {
        let index = IndexSource()
        let recent = RecentDocumentStore(systemSnapshots: { _ in index.snapshots() })
        let first = Task { await recent.observeSystemRecents() }
        let second = Task { await recent.observeSystemRecents() }
        defer { first.cancel(); second.cancel() }
        try await p18Wait { index.starts == 1 }
        let external = document("External.txt", inode: 8, used: Date())
        index.sink?.yield([external])
        try await p18Wait { recent.entries == [external] }
        first.cancel()
        await first.value
        #expect(index.starts == 1 && index.stops == 0 && recent.entries == [external])
        second.cancel()
        await second.value
        try await p18Wait { index.stops == 1 && recent.entries.isEmpty }
        let stale = index.sink
        let third = Task { await recent.observeSystemRecents() }
        defer { third.cancel() }
        try await p18Wait { index.starts == 2 }
        stale?.yield([external])
        index.sink?.yield([])
        #expect(recent.entries.isEmpty)
        third.cancel()
        await third.value
    }

    @Test func mergedRowsUseLatestDateWithoutReplacingTheAcceptedIdentity() throws {
        let recent = RecentDocumentStore()
        let original = document("A.txt", inode: 1, used: .distantPast)
        recent.record([original], excluding: [])
        let accepted = try #require(recent.entries.first)
        let replacement = document("A.txt", inode: 2, used: accepted.openedAt.addingTimeInterval(10))
        let external = document("B.txt", inode: 3, used: accepted.openedAt.addingTimeInterval(20))
        recent.replaceSystemRecents([replacement, external, external])
        #expect(recent.entries.map(\.url) == [external.url, original.url])
        #expect(recent.entries.last?.identity == original.identity)
        #expect(recent.entries.last?.openedAt == replacement.openedAt)
        recent.replaceSystemRecents([])
        #expect(recent.entries == [accepted])
    }

    @Test func spotlightOnlyReplacementNeedsConsentEvenWhenTheIndexTimestampChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Viewed elsewhere.txt")
        try Data([1]).write(to: file)
        let original = try #require(RecentDocument.capture(file))
        let recent = RecentDocumentStore()
        recent.replaceSystemRecents([original])
        let store = ExplorerStore(initialURL: BrowserPage.home.url, recentDocuments: recent)
        defer { store.cancelLoads() }
        let router = ZIPAppRouter()
        store.applications = router
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("Original.txt"))
        try Data([2]).write(to: file)
        store.performPageAction(.open, url: file, folder: false, recent: original)
        try await p18Wait { store.recentOpenConfirmation != nil }
        let prompt = try #require(store.recentOpenConfirmation)
        var reranked = original
        reranked.openedAt = original.openedAt.addingTimeInterval(1)
        recent.replaceSystemRecents([reranked])
        #expect(router.opened.isEmpty)
        store.confirmRecentOpen(prompt)
        try await p18Wait { router.opened == [file] }
        recent.replaceSystemRecents([])
        #expect(recent.entries.first?.url == file)
        #expect(recent.entries.first?.identity != original.identity)
    }

    @Test func suppressionSurvivesRepeatedSnapshotsButAllowsAnIndependentFileAtTheSamePath() throws {
        let recent = RecentDocumentStore()
        let used = Date().addingTimeInterval(-60)
        let first = document("Same.txt", inode: 1, used: used)
        let second = document("Same.txt", inode: 2, used: used)
        func snapshot(_ item: RecentDocument) -> [RecentDocument] {
            SystemRecentProvider.collect(resultCount: 1, suppressionCount: 1, cancelled: { false },
                                         capture: { _ in item }, candidate: { _ in (item.url, used) })
        }

        recent.replaceSystemRecents(snapshot(first))
        recent.remove(try #require(recent.entries.first))
        recent.replaceSystemRecents(snapshot(first))
        #expect(recent.entries.isEmpty)
        recent.replaceSystemRecents(snapshot(second))
        #expect(recent.entries == [second])
    }

    @Test func removedDocumentStaysHiddenAcrossRemountButDistinctReplacementReturns() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = UUID(), used = Date().addingTimeInterval(-60)
        func row(device: UInt64, inode: UInt64, volumeUUID: UUID?, documentID: Int?) -> RecentDocument {
            RecentDocument(url: URL(fileURLWithPath: "/tmp/RecentMerge/Remounted.txt"),
                identity: LocalFileIdentity(device: device, inode: inode, birthSeconds: 123, birthNanoseconds: 4),
                volumeUUID: volumeUUID, documentID: documentID, regularFile: true, openedAt: used)
        }
        let original = row(device: 1, inode: 42, volumeUUID: volume, documentID: nil)
        let remounted = row(device: 2, inode: 42, volumeUUID: volume, documentID: 7)
        let replacement = row(device: 2, inode: 43, volumeUUID: volume, documentID: 8)
        let recent = RecentDocumentStore(defaults: defaults)
        recent.replaceSystemRecents([original])
        #expect(!recent.contains(remounted))
        #expect(!original.isSameCandidate(as: remounted))
        recent.remove(original)
        let restored = RecentDocumentStore(defaults: defaults)
        restored.replaceSystemRecents([remounted])
        #expect(restored.entries.isEmpty)
        restored.replaceSystemRecents([replacement])
        #expect(restored.entries == [replacement])

        restored.remove(replacement)
        let safeSave = row(device: 3, inode: 81, volumeUUID: volume, documentID: 8)
        restored.replaceSystemRecents([safeSave])
        #expect(restored.entries.isEmpty)
        let differentVolume = row(device: 3, inode: 81, volumeUUID: UUID(), documentID: 8)
        restored.replaceSystemRecents([differentVolume])
        #expect(restored.entries == [differentVolume])
    }

    @Test func collectionBoundsMetadataAndPhysicalSamplesIndependently() {
        var inspected = 0, sampled = 0
        let used = Date()
        let result = SystemRecentProvider.collect(resultCount: 1_000, suppressionCount: 7, cancelled: { false },
            capture: { _ in sampled += 1; return nil }, candidate: { index in
                inspected += 1
                return index < 150 ? nil : (URL(fileURLWithPath: "/tmp/Synthetic-\(index).txt"), used)
            })
        #expect(result.isEmpty && inspected == 207 && sampled == 57)
        inspected = 0
        sampled = 0
        _ = SystemRecentProvider.collect(resultCount: 1_000, suppressionCount: 100, cancelled: { false },
            capture: { _ in sampled += 1; return nil }, candidate: { index in
                inspected += 1
                return (URL(fileURLWithPath: "/tmp/Synthetic-\(index).txt"), used)
            })
        #expect(inspected == 100 && sampled == 100)
    }

    @Test func repeatedIndexedUseNeverRebindsAReplacementWithoutNewActivity() {
        let recent = RecentDocumentStore()
        let first = document("Report.txt", inode: 4, used: Date())
        let replacement = document("Report.txt", inode: 5, used: first.openedAt)
        recent.replaceSystemRecents([first])
        recent.replaceSystemRecents([replacement])
        #expect(recent.contains(first) && !recent.contains(replacement))
        var usedAgain = replacement
        usedAgain.openedAt = first.openedAt.addingTimeInterval(2)
        recent.replaceSystemRecents([usedAgain])
        #expect(recent.contains(usedAgain) && !recent.contains(first))
    }

    @Test func onlyUserDocumentLocationsAndTypesReachIdentitySampling() {
        let home = "/Users/Fake"
        let allowed = ["/Users/Fake/Letters/notes.txt", "/Users/Fake/Library/CloudStorage/OneDrive-Test/a.pdf",
                       "/Users/Fake/Library/Mobile Documents/com~apple~CloudDocs/a.txt", "/Volumes/Removable/Work/doc.pages",
                       "/Users/Shared/Proposal.rtf", "/Users/Fake/Document.pages"]
        let excluded = ["/Users/Fake/.Trash/a.txt", "/Users/Fake/Documents/.secret.txt", "/Users/Fake/Library/Caches/page.pdf",
                        "/Users/Fake/Applications/Editor.app/Contents/Resources/help.pdf", "/Users/Fake/Documents/Old.pages/body.pdf",
                        "/Users/Fake/Documents/Workspace.xcodeproj/data.txt", "/System/Library/help.pdf",
                        "/Volumes/Disk/.Trashes/123/a.txt", "/Volumes/Disk/Library/Caches/a.pdf", "/Users/SomeoneElse/document.pdf"]
        for path in allowed { #expect(SystemRecentProvider.allows(path: path, home: home)) }
        for path in excluded { #expect(!SystemRecentProvider.allows(path: path, home: home)) }
        #expect(SystemRecentProvider.isDocument(["public.content", "public.plain-text"]))
        #expect(SystemRecentProvider.isDocument(["public.content", "com.apple.package", "public.directory"]))
        #expect(!SystemRecentProvider.isDocument(["public.folder", "public.directory"]))
        #expect(!SystemRecentProvider.isDocument(["public.content", "com.apple.application-bundle", "com.apple.package"]))
    }

    @Test func externalLaunchServicesOpenAppearsInProductionSystemRecents() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let receiptPath = environment["MAXPLORER_EXTERNAL_OPEN_RECEIPT"] else { return }
        struct Receipt: Decodable {
            let file: String
            let requested: TimeInterval
            let indexedLastUse: TimeInterval
            let observed: Bool
            let ownedTextEditExited: Bool
            let preservedContent: Bool
        }
        let evidence = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: URL(fileURLWithPath: receiptPath)))
        let file = URL(fileURLWithPath: evidence.file, isDirectory: false).standardizedFileURL
        let folder = file.deletingLastPathComponent(), parent = folder.deletingLastPathComponent()
        let synthetic = file.lastPathComponent.range(of: #"^External open [A-Fa-f0-9]{8}\.txt$"#,
                                                      options: .regularExpression) != nil
        let ownedFolder = parent.lastPathComponent.range(of: #"^Maxplorer-Finder-Tags-[A-Fa-f0-9]{8}$"#,
                                                        options: .regularExpression) != nil
        try #require(synthetic && ownedFolder && folder.lastPathComponent == "Tagged folder"
                     && parent.deletingLastPathComponent().path == FileManager.default.homeDirectoryForCurrentUser.path)
        try #require(evidence.observed && evidence.ownedTextEditExited && evidence.preservedContent)
        try #require(evidence.indexedLastUse >= evidence.requested - 3)

        let started = ProcessInfo.processInfo.systemUptime
        let store = RecentDocumentStore(systemSnapshots: SystemRecentProvider.snapshots)
        let task = Task { await store.observeSystemRecents() }
        defer { task.cancel() }
        var firstReady: Int?
        var matched = false
        repeat {
            if store.systemStatus == .ready {
                if firstReady == nil { firstReady = Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
                matched = store.entries.contains {
                    $0.url.path == file.path && $0.openedAt.timeIntervalSince1970 >= evidence.indexedLastUse - 1
                }
            }
            if matched || store.systemStatus == .unavailable { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime - started < 45
        struct Result: Encodable {
            let foundSyntheticDocument: Bool
            let queryUnavailable: Bool
            let firstSnapshotMilliseconds: Int?
            let elapsedMilliseconds: Int
            let visibleRowCount: Int
        }
        let result = Result(foundSyntheticDocument: matched, queryUnavailable: store.systemStatus == .unavailable,
                            firstSnapshotMilliseconds: firstReady,
                            elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                            visibleRowCount: store.entries.count)
        let data = try JSONEncoder().encode(result)
        if let path = environment["MAXPLORER_RECENT_PROBE_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        print("External-open Spotlight probe", String(decoding: data, as: UTF8.self))
        #expect(matched)
    }

    @Test func indexCaptureNeverFollowsAFileLinkOrAddsADirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.txt"), link = root.appendingPathComponent("Link.txt")
        try Data([1]).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(RecentDocument.capture(file, followingLinks: false) != nil)
        #expect(RecentDocument.capture(link, followingLinks: false) == nil)
        #expect(RecentDocument.capture(root, followingLinks: false) == nil)
        #expect(RecentDocument.capture(link) != nil)
    }

    @Test func systemOnlyHistoryIsEphemeralAndCombinedHistoryHasOneHundredRows() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentDocumentStore(defaults: defaults)
        let indexed = (0..<103).map { index in
            document("\(index).txt", inode: UInt64(index + 1), used: Date(timeIntervalSince1970: Double(index)))
        }
        recent.replaceSystemRecents(indexed)
        #expect(recent.entries.map(\.url) == Array(indexed.reversed().prefix(100)).map(\.url))
        #expect(RecentDocumentStore(defaults: defaults).entries.isEmpty)
    }

    @Test func removedUseStaysHiddenAcrossSnapshotsAndRelaunchUntilANewerUse() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentDocumentStore(defaults: defaults)
        let item = document("C.txt", inode: 4, used: Date().addingTimeInterval(-120))
        recent.replaceSystemRecents([item])
        recent.remove(try #require(recent.entries.first))
        let saved = try #require(defaults.persistentDomain(forName: suite))
        let serialized = try PropertyListSerialization.data(fromPropertyList: saved, format: .xml, options: 0)
        #expect(!String(decoding: serialized, as: UTF8.self).contains("RecentMerge"))
        for case let value as Data in saved.values {
            #expect(value.range(of: Data("RecentMerge".utf8)) == nil)
        }
        recent.replaceSystemRecents([item])
        #expect(recent.entries.isEmpty)
        let restored = RecentDocumentStore(defaults: defaults)
        restored.replaceSystemRecents([item])
        #expect(restored.entries.isEmpty)
        var newer = item
        newer.openedAt = Date().addingTimeInterval(2)
        restored.replaceSystemRecents([newer])
        #expect(restored.entries == [newer])
        restored.remove(newer)
        restored.record([item], excluding: [])
        #expect(restored.entries.map(\.url) == [item.url])
    }
}
