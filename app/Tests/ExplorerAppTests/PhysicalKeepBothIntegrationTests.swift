import AppKit
import CryptoKit
import ExplorerCore
import Testing
@testable import ExplorerApp

/// Records actual comparison requests without replacing inspection or transfer I/O.
private actor PhysicalKeepBothInspector: ConflictInspecting {
    private(set) var names: [String] = []
    func inspect(name: String, in context: FileOperationContext) async throws -> ConflictEntry {
        names.append(name)
        return try await LocalConflictInspector().inspect(name: name, in: context)
    }
}

/// Native filesystem/Store evidence, not a Windows dialog or UI parity claim.
@Suite(.serialized)
@MainActor
struct PhysicalKeepBothIntegrationTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition(), "The real transfer did not settle within its bounded deadline")
    }

    private func withFixture(sameDirectory: Bool = false, hardLink: Bool = false,
                             _ body: (ExplorerStore, URL, URL, PhysicalKeepBothInspector) async throws -> Void) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("PhysicalKeepBoth-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        var setupOwnsRoot = true
        defer { if setupOwnsRoot { try? manager.removeItem(at: root) } }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = sameDirectory ? source : root.appendingPathComponent("Target", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        if !sameDirectory { try manager.createDirectory(at: destination, withIntermediateDirectories: false) }
        try Data("SOURCE: synthetic incoming bytes\n".utf8).write(to: source.appendingPathComponent("report.txt"))
        if hardLink {
            try manager.linkItem(at: source.appendingPathComponent("report.txt"), to: destination.appendingPathComponent("report.txt"))
        } else if !sameDirectory {
            try Data("EXISTING: preserve original destination\n".utf8).write(to: destination.appendingPathComponent("report.txt"))
        }
        let occupied = sameDirectory || hardLink ? ["report - Copy.txt"] : ["report (2).txt", "report (3).txt"]
        for name in occupied {
            try Data(("OCCUPIED: " + name + "\n").utf8).write(to: destination.appendingPathComponent(name))
        }
        let board = NSPasteboard(name: .init("PhysicalKeepBoth-\(UUID())"))
        defer { board.releaseGlobally() }
        let inspector = PhysicalKeepBothInspector()
        let store = ExplorerStore(initialURL: source, loader: LocalDirectoryLoader(), homeURL: root,
            transfers: LocalFileTransfers(), clipboard: TransferClipboard(pasteboard: board), conflictInspector: inspector)
        // From here onward, teardown must drain store work before removing files.
        setupOwnsRoot = false
        do {
            try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
            try await body(store, source, destination, inspector)
        } catch {
            store.cancelTransfer()
            // Drain the real worker/verification before deleting its owned fixture.
            do { try await waitFor { !store.isPerformingOperation } }
            catch {
                store.cancelLoads()
                throw error // Preserve the fixture if the real operation did not drain.
            }
            store.cancelLoads()
            try manager.removeItem(at: root)
            throw error
        }
        store.cancelLoads()
        try manager.removeItem(at: root)
    }

    private func captureSource(_ store: ExplorerStore, destination: URL) async throws {
        let item = try #require(store.activeTab.items.first { $0.name == "report.txt" })
        store.setSelection([item.id], focusedID: item.id)
        store.copySelection()
        try #require(store.clipboard.payload != nil)
        store.navigate(to: destination)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading && !store.activeTab.isRefreshing }
        try #require(store.canPaste)
    }

    private func keepBothOnce(_ store: ExplorerStore, sameIdentity: Bool) async throws {
        store.pasteSelection()
        try await waitFor { store.transfer?.conflictName != nil || !store.isPerformingOperation }
        let conflict = try #require(store.transfer?.conflict)
        let existing = try #require(conflict.existing)
        #expect(conflict.name == "report.txt")
        #expect((existing.target.identity == conflict.incoming.identity) == sameIdentity)
        store.resolveTransferConflict(.keepBoth)
        // A second prompt is deliberately never answered. It must fail finitely.
        try await waitFor { !store.isPerformingOperation }
        #expect(store.transfer == nil)
        #expect(store.operationNotice?.contains("Copied 1 of 1") == true)
        #expect(store.operationNotice?.contains("Stopped") == false)
    }

    private func digest(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    @Test
    func differentItemCopySkipsOccupiedNumericNamesAfterOneChoiceAndPreservesBytes() async throws {
        try await withFixture { store, source, destination, inspector in
            let preserved = [source.appendingPathComponent("report.txt")] +
                ["report.txt", "report (2).txt", "report (3).txt"].map { destination.appendingPathComponent($0) }
            let hashes = try preserved.map { try digest($0) }
            try await captureSource(store, destination: destination)
            try await keepBothOnce(store, sameIdentity: false)
            #expect(store.selectedItemsInOrder.map(\.name) == ["report (4).txt"])
            // Repeating Paste reuses the original captured source, not the selected result.
            try await keepBothOnce(store, sameIdentity: false)
            #expect(store.selectedItemsInOrder.map(\.name) == ["report (5).txt"])
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
            #expect(names == ["report (2).txt", "report (3).txt", "report (4).txt", "report (5).txt", "report.txt"])
            for (url, hash) in zip(preserved, hashes) {
                let actual = try digest(url)
                #expect(actual == hash)
            }
            for name in ["report (4).txt", "report (5).txt"] {
                let actual = try digest(destination.appendingPathComponent(name))
                #expect(actual == hashes[0])
            }
            #expect(await inspector.names == ["report.txt", "report.txt"])
        }
    }

    @Test(arguments: [false, true])
    func sameIdentityCopyRetainsCopySuffixAcrossOccupiedCandidate(hardLink: Bool) async throws {
        try await withFixture(sameDirectory: !hardLink, hardLink: hardLink) { store, source, destination, inspector in
            let original = source.appendingPathComponent("report.txt")
            let occupied = destination.appendingPathComponent("report - Copy.txt")
            let sourceHash = try digest(original), occupiedHash = try digest(occupied)
            try await captureSource(store, destination: destination)
            try await keepBothOnce(store, sameIdentity: true)
            #expect(store.selectedItemsInOrder.map(\.name) == ["report - Copy (2).txt"])
            let sourceAfter = try digest(original), occupiedAfter = try digest(occupied)
            let copyHash = try digest(destination.appendingPathComponent("report - Copy (2).txt"))
            #expect(sourceAfter == sourceHash)
            #expect(occupiedAfter == occupiedHash)
            #expect(copyHash == sourceHash)
            #expect(await inspector.names == ["report.txt"])
        }
    }
}
