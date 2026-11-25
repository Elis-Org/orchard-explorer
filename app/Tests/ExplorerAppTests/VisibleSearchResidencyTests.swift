import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private actor VisibleMembershipReader {
    private(set) var starts: [String] = []
    private var completion: CheckedContinuation<FileAvailability, Never>?

    func read(_ entry: TransferEntry) async -> FileAvailability {
        starts.append(entry.item.id)
        return await withCheckedContinuation { completion = $0 }
    }
    func finish(_ availability: FileAvailability) {
        let ended = completion
        completion = nil
        ended?.resume(returning: availability)
    }
}

@MainActor
struct VisibleSearchResidencyTests {
    @Test func unfinishedMetadataStaysBoundToTheVisibleSearchIdentityAndNamespace() async throws {
        let reader = VisibleMembershipReader(), first = UUID(), second = UUID(), search = UUID()
        let probe = VisibleSearchResidency { await reader.read($0) }
        let root = URL(fileURLWithPath: "/Test/OneDrive/", isDirectory: true)
        let parent = LocalFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 1)
        let item = FileItem(url: root.appendingPathComponent("synthetic.txt"), name: "synthetic.txt", isDirectory: false,
            isSymbolicLink: false, size: 8, modifiedAt: nil, kind: "Text",
            identity: .init(device: 1, inode: 2, birthSeconds: 1, birthNanoseconds: 1),
            availability: .unknown, isRegularFile: true, statusVersion: .init(size: 8, modificationSeconds: 1, modificationNanoseconds: 0))
        let row = TransferEntry(source: .init(directoryURL: root, directoryIdentity: parent), item: item)
        let key = try #require(OneDriveStatusKey(row))
        let old = VisibleSearchResidency.Key(entry: key, generation: search, namespaceEpoch: 0)
        let new = VisibleSearchResidency.Key(entry: key, generation: search, namespaceEpoch: 1)
        func wait(_ ready: () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await ready()) {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
        var announcements: [Set<String>] = []
        probe.update(first, entries: [old: row]) { announcements.append($0) }
        try #require(await wait { await reader.starts.count == 1 })
        probe.remove(first)
        probe.update(second, entries: [new: row]) { announcements.append($0) }
        #expect(probe.availability(for: old) == nil && probe.availability(for: new) == nil)
        await reader.finish(.availableLocally)
        try #require(await wait { await reader.starts.count == 2 })
        #expect(announcements.isEmpty && probe.availability(for: old) == nil)
        await reader.finish(.unknown)
        try #require(await wait { probe.availability(for: new) == .some(.unknown) })
        #expect(announcements.isEmpty)
        probe.update(second, entries: [new: row]) { announcements.append($0) }
        #expect(await reader.starts.count == 2, "Repeated publication of unknown membership must not poll")
        probe.remove(second)
        #expect(probe.availability(for: new) == nil)
        probe.update(first, entries: [new: row]) { announcements.append($0) }
        try #require(await wait { await reader.starts.count == 3 })
        await reader.finish(.availableLocally)
        try #require(await wait { probe.availability(for: new) == .availableLocally })
        #expect(announcements == [[item.id]])
        probe.remove(first)
    }
}
