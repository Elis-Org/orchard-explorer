import CryptoKit
import Darwin
import Security
import Foundation
import Testing
@testable import ExplorerCore

/// A disposable APFS disk image mounted privately (`-nobrowse`) under its own
/// temporary directory. It is the second local volume for NATIVE-P15 tests.
final class DiskImageVolume {
    let directory: URL
    let mount: URL
    private let image: URL
    private var attached = false

    init(sizeMB: Int = 64, readOnly: Bool = false, populate: ((URL) throws -> Void)? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerVolume-\(UUID().uuidString)", isDirectory: true)
        mount = directory.appendingPathComponent("mount", isDirectory: true)
        image = directory.appendingPathComponent("volume.sparseimage")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try Self.hdiutil(["create", "-quiet", "-size", "\(sizeMB)m", "-fs", "APFS", "-volname", "ExplorerP15",
                              "-type", "SPARSE", image.path])
            try attach(readOnly: false)
            if let populate {
                try populate(mount)
                if readOnly {
                    try detach()
                    try attach(readOnly: true)
                }
            }
        } catch {
            try? detach(force: true)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        try? detach(force: true)
        try? FileManager.default.removeItem(at: directory)
    }

    func attach(readOnly: Bool) throws {
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen"] + (readOnly ? ["-readonly"] : [])
                         + ["-mountpoint", mount.path, image.path])
        attached = true
    }

    func detach(force: Bool = false) throws {
        guard attached else { return }
        try Self.hdiutil(["detach", "-quiet"] + (force ? ["-force"] : []) + [mount.path])
        attached = false
    }

    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError.unsupported("hdiutil \(arguments.first ?? "") failed (\(process.terminationStatus)).")
        }
    }
}

private final class LocalFolder {
    let url: URL
    init(_ name: String = "ExplorerP15-") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        _ = chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }
}

private func folder(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func context(_ url: URL) async throws -> FileOperationContext {
    let snapshot = try await LocalDirectoryLoader().snapshot(of: url)
    return FileOperationContext(directoryURL: url, directoryIdentity: try #require(snapshot.directoryIdentity))
}

private func item(_ name: String, in url: URL) async throws -> FileItem {
    try #require(try await LocalDirectoryLoader().snapshot(of: url, showHidden: true).items.first { $0.name == name })
}

private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func exists(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0
}

private func noStaging(_ url: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: url.path).allSatisfy { !$0.hasPrefix(".explorer-transfer-") }
}

/// Incompressible-enough synthetic bytes: a random 64 KiB block repeated.
private func randomData(_ count: Int) -> Data {
    var block = [UInt8](repeating: 0, count: 65_536)
    _ = SecRandomCopyBytes(kSecRandomDefault, block.count, &block)
    var data = Data(capacity: count)
    while data.count < count { data.append(contentsOf: block.prefix(count - data.count)) }
    return data
}

private func setXattr(_ url: URL, _ name: String, _ value: String) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func xattr(_ url: URL, _ name: String) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = getxattr(url.path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
    return length < 0 ? nil : String(decoding: buffer.prefix(length), as: UTF8.self)
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []
    func append(_ value: TransferProgress) { lock.withLock { values.append(value) } }
    var all: [TransferProgress] { lock.withLock { values } }
}

/// NATIVE-P15 / MAC-066/067 with two real local volumes (system temporary
/// folder and a disposable APFS disk image). FR-FILE-014/015 / EV-0102 /
/// AT-FILE-014/015 supply the byte/hash postcondition; cross-volume semantics
/// are native policy.
/// Serialized: concurrent disk images and bulk writes starved timing-sensitive
/// observation/search tests in the canonical parallel run.
@Suite(.serialized)
final class CrossVolumeTransferTests {
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func fileMovePublishesVerifiedCopyWithDeclaredMetadataAndRemovesTheOriginal() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let file = local.url.appendingPathComponent("moved.txt")
        let bytes = Data("cross-volume payload 26 b".utf8)
        try bytes.write(to: file)
        try setXattr(file, "com.example.explorer.p15", "kept")
        _ = chmod(file.path, 0o640)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let expected = try sha(file)
        let from = try await context(local.url), to = try await context(volume.mount)
        #expect(from.directoryIdentity.device != to.directoryIdentity.device)

        let result = try await LocalFileTransfers().transfer(try await item("moved.txt", in: local.url), from: from, to: to,
            name: "moved.txt", kind: .move, control: TransferControl(), onProgress: { _ in })
        let destination = volume.mount.appendingPathComponent("moved.txt")
        #expect(result.sourceRetention == nil)
        #expect(!exists(file), "A completed cross-volume move removes the original")
        #expect(try sha(destination) == expected)
        #expect(result.identity?.device == to.directoryIdentity.device)
        let values = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((values[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(values[.modificationDate] as? Date == modified)
        #expect(xattr(destination, "com.example.explorer.p15") == "kept")
        #expect(try noStaging(volume.mount))
    }

    @Test
    func folderTreeMovesFromTheImageVolumeAndReportsEntriesAndRemovalPhase() async throws {
        let local = try LocalFolder()
        let payload = randomData(1_048_576)
        let volume = try DiskImageVolume { mount in
            let tree = try folder(mount.appendingPathComponent("Tree", isDirectory: true))
            try Data("alpha".utf8).write(to: tree.appendingPathComponent("a.txt"))
            let sub = try folder(tree.appendingPathComponent("sub", isDirectory: true))
            try payload.write(to: sub.appendingPathComponent("b.bin"))
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a.txt")
            _ = try folder(tree.appendingPathComponent("empty", isDirectory: true))
        }
        let source = volume.mount.appendingPathComponent("Tree", isDirectory: true)
        let payloadHash = try sha(source.appendingPathComponent("sub/b.bin"))
        let log = ProgressLog()
        let result = try await LocalFileTransfers().transfer(try await item("Tree", in: volume.mount),
            from: try await context(volume.mount), to: try await context(local.url),
            name: "Tree", kind: .move, control: TransferControl(), onProgress: { log.append($0) })
        let moved = local.url.appendingPathComponent("Tree", isDirectory: true)
        #expect(result.sourceRetention == nil)
        #expect(!exists(source))
        #expect(try String(contentsOf: moved.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha")
        #expect(try sha(moved.appendingPathComponent("sub/b.bin")) == payloadHash)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("link").path) == "a.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.appendingPathComponent("empty").path).isEmpty)
        let progress = log.all
        #expect(progress.last?.phase == .removingOriginals)
        #expect(progress.filter { $0.phase == .copying }.map(\.itemsCompleted).max() == 6)
        #expect(progress.map(\.bytesCopied).max() == Int64(5 + payload.count))
    }

    @Test
    func lowSpaceFailsBeforePublicationAndKeepsTheOriginal() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume(sizeMB: 32)
        let file = local.url.appendingPathComponent("large.bin")
        try randomData(48 * 1_048_576).write(to: file)
        let expected = try sha(file)
        await #expect(throws: (any Error).self) {
            _ = try await LocalFileTransfers().transfer(try await item("large.bin", in: local.url),
                from: try await context(local.url), to: try await context(volume.mount),
                name: "large.bin", kind: .move, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try sha(file) == expected)
        #expect(!exists(volume.mount.appendingPathComponent("large.bin")))
        #expect(try noStaging(volume.mount))
    }

    @Test
    func cancellationBeforePublicationKeepsTheOriginalAndNoDestination() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let file = local.url.appendingPathComponent("cancel.bin")
        try randomData(8 * 1_048_576).write(to: file)
        let expected = try sha(file)
        let control = TransferControl()
        await #expect(throws: CancellationError.self) {
            _ = try await LocalFileTransfers().transfer(try await item("cancel.bin", in: local.url),
                from: try await context(local.url), to: try await context(volume.mount),
                name: "cancel.bin", kind: .move, control: control,
                onProgress: { progress in if progress.bytesCopied > 0 { control.cancel() } })
        }
        #expect(try sha(file) == expected)
        #expect(!exists(volume.mount.appendingPathComponent("cancel.bin")))
        #expect(try noStaging(volume.mount))
    }

    @Test
    func originalsChangedAddedReplacedOrUnremovableAfterCopyAreKept() async throws {
        for scenario in ["changed", "added", "replaced", "permission"] {
            let local = try LocalFolder(), volume = try DiskImageVolume()
            let tree = try folder(local.url.appendingPathComponent("Tree", isDirectory: true))
            try Data("first".utf8).write(to: tree.appendingPathComponent("first.txt"))
            try Data("second".utf8).write(to: tree.appendingPathComponent("second.txt"))
            let from = try await context(local.url), to = try await context(volume.mount)
            let movedItem = try await item("Tree", in: local.url)
            let transfers = LocalFileTransfers(afterCommit: { _ in
                switch scenario {
                case "changed": try? Data("second, edited after copy".utf8).write(to: tree.appendingPathComponent("second.txt"))
                case "added": try? Data("new".utf8).write(to: tree.appendingPathComponent("added.txt"))
                case "replaced":
                    try? FileManager.default.moveItem(at: tree, to: local.url.appendingPathComponent("Tree-original"))
                    try? FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
                    try? Data("replacement".utf8).write(to: tree.appendingPathComponent("replacement.txt"))
                default: _ = chmod(local.url.path, 0o555)
                }
            })
            let result = try await transfers.transfer(movedItem, from: from, to: to, name: "Tree", kind: .move,
                                                      control: TransferControl(), onProgress: { _ in })
            _ = chmod(local.url.path, 0o755)
            let retention = try #require(result.sourceRetention, "\(scenario): a copy must not be reported as a move")
            #expect(retention.contains(local.url.path), "\(scenario): the retention names the original location")
            let published = volume.mount.appendingPathComponent("Tree", isDirectory: true)
            #expect(try String(contentsOf: published.appendingPathComponent("first.txt"), encoding: .utf8) == "first")
            #expect(try String(contentsOf: published.appendingPathComponent("second.txt"), encoding: .utf8) == "second")
            switch scenario {
            case "changed":
                #expect(try String(contentsOf: tree.appendingPathComponent("second.txt"), encoding: .utf8) == "second, edited after copy")
            case "added":
                #expect(exists(tree.appendingPathComponent("added.txt")) && exists(tree))
            case "replaced":
                #expect(try String(contentsOf: tree.appendingPathComponent("replacement.txt"), encoding: .utf8) == "replacement")
                #expect(exists(local.url.appendingPathComponent("Tree-original/first.txt")))
            default:
                #expect(exists(tree), "Without write permission on its parent the original folder remains")
            }
        }
    }

    /// Review 8f1afb6d finding 1 (Blocking): an incomplete published tree, or a
    /// source folder whose own metadata changed (finding 2), keeps every original.
    @Test(arguments: ["destination-deleted", "source-folder-xattr"])
    func incompletePublicationOrChangedSourceFolderKeepsAllOriginals(_ scenario: String) async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let tree = try folder(local.url.appendingPathComponent("Tree", isDirectory: true))
        try Data("a".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: tree.appendingPathComponent("b.txt"))
        let published = volume.mount.appendingPathComponent("Tree", isDirectory: true)
        let transfers = LocalFileTransfers(afterCommit: { _ in
            if scenario == "destination-deleted" {
                try? FileManager.default.removeItem(at: published.appendingPathComponent("a.txt"))
            } else {
                try? setXattr(tree, "com.apple.metadata:_kMDItemUserTags", "tag-added-after-copy")
            }
        })
        let result = try await transfers.transfer(try await item("Tree", in: local.url), from: try await context(local.url),
            to: try await context(volume.mount), name: "Tree", kind: .move, control: TransferControl(), onProgress: { _ in })
        #expect(result.sourceRetention != nil)
        #expect(result.retainedOriginalLocation?.path == local.url.path)
        #expect(try String(contentsOf: tree.appendingPathComponent("a.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOf: tree.appendingPathComponent("b.txt"), encoding: .utf8) == "b")
    }

    /// Review finding 3: hard links inside a moved folder are removed without a
    /// false "changed" refusal; both names arrive with the original content.
    @Test
    func hardLinkedFilesMoveCompletely() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let tree = try folder(local.url.appendingPathComponent("Linked", isDirectory: true))
        try Data("shared".utf8).write(to: tree.appendingPathComponent("one.txt"))
        try FileManager.default.linkItem(at: tree.appendingPathComponent("one.txt"), to: tree.appendingPathComponent("two.txt"))
        let result = try await LocalFileTransfers().transfer(try await item("Linked", in: local.url),
            from: try await context(local.url), to: try await context(volume.mount),
            name: "Linked", kind: .move, control: TransferControl(), onProgress: { _ in })
        #expect(result.sourceRetention == nil)
        #expect(!exists(tree))
        let moved = volume.mount.appendingPathComponent("Linked", isDirectory: true)
        #expect(try String(contentsOf: moved.appendingPathComponent("one.txt"), encoding: .utf8) == "shared")
        #expect(try String(contentsOf: moved.appendingPathComponent("two.txt"), encoding: .utf8) == "shared")
    }

    /// Review findings 4 and 6: the committed phase is announced right after
    /// publication, before removal; results carry authoritative work.
    @Test
    func committedPhaseFollowsPublicationAndResultsCarryAuthoritativeWork() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume(), other = try LocalFolder()
        let tree = try folder(local.url.appendingPathComponent("Work", isDirectory: true))
        try Data(repeating: 7, count: 300).write(to: tree.appendingPathComponent("x.bin"))
        try Data(repeating: 8, count: 200).write(to: tree.appendingPathComponent("y.bin"))
        let log = ProgressLog()
        let moved = try await LocalFileTransfers().transfer(try await item("Work", in: local.url),
            from: try await context(local.url), to: try await context(volume.mount),
            name: "Work", kind: .move, control: TransferControl(), onProgress: { log.append($0) })
        let phases = log.all.map(\.phase)
        let finalizing = try #require(phases.firstIndex(of: .finalizing))
        let removing = try #require(phases.firstIndex(of: .removingOriginals))
        #expect(finalizing < removing && phases[..<finalizing].allSatisfy { $0 == .copying })
        #expect(moved.transferredBytes == 500 && moved.transferredEntries == 3)
        try Data("r".utf8).write(to: local.url.appendingPathComponent("rename.txt"))
        let renamed = try await LocalFileTransfers().transfer(try await item("rename.txt", in: local.url),
            from: try await context(local.url), to: try await context(other.url),
            name: "rename.txt", kind: .move, control: TransferControl(), onProgress: { _ in })
        #expect(renamed.transferredEntries == 1 && renamed.transferredBytes == 0)
    }

    /// Follow-up 3c27ebcf finding 1: after the first hard-link name is removed,
    /// an external change to the shared inode keeps the remaining name.
    @Test
    func externalChangeBetweenHardLinkUnlinksKeepsTheRemainingName() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let tree = try folder(local.url.appendingPathComponent("Linked", isDirectory: true))
        try Data("shared".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try FileManager.default.linkItem(at: tree.appendingPathComponent("a.txt"), to: tree.appendingPathComponent("b.txt"))
        let transfers = LocalFileTransfers(afterSourceUnlink: { name in
            // Another process tags the inode through the name that remains.
            for other in ["a.txt", "b.txt"] where other != name && exists(tree.appendingPathComponent(other)) {
                try? setXattr(tree.appendingPathComponent(other), "com.example.external", "changed")
            }
        })
        let result = try await transfers.transfer(try await item("Linked", in: local.url),
            from: try await context(local.url), to: try await context(volume.mount),
            name: "Linked", kind: .move, control: TransferControl(), onProgress: { _ in })
        #expect(result.sourceRetention != nil, "An externally changed hard-link name must not be removed")
        let remaining = ["a.txt", "b.txt"].filter { exists(tree.appendingPathComponent($0)) }
        #expect(remaining.count == 1)
        if let name = remaining.first {
            #expect(xattr(tree.appendingPathComponent(name), "com.example.external") == "changed")
        }
        // Without an external change, both names are removed (see hardLinkedFilesMoveCompletely).
    }

    /// Follow-up finding 6: a same-volume rename announces the committed phase.
    @Test
    func sameVolumeRenameAnnouncesTheCommittedPhase() async throws {
        let local = try LocalFolder(), other = try LocalFolder()
        try Data("r".utf8).write(to: local.url.appendingPathComponent("r.txt"))
        let log = ProgressLog()
        _ = try await LocalFileTransfers().transfer(try await item("r.txt", in: local.url),
            from: try await context(local.url), to: try await context(other.url),
            name: "r.txt", kind: .move, control: TransferControl(), onProgress: { log.append($0) })
        #expect(log.all.last?.phase == .finalizing)
    }

    @Test
    func readOnlySourceVolumeIsRefusedBeforeAnyWrite() async throws {
        let local = try LocalFolder()
        let volume = try DiskImageVolume(readOnly: true) { mount in
            try Data("read only".utf8).write(to: mount.appendingPathComponent("locked.txt"))
        }
        let source = volume.mount.appendingPathComponent("locked.txt")
        let entry = TransferEntry(source: try await context(volume.mount), item: try await item("locked.txt", in: volume.mount))
        let destination = try await context(local.url)
        await #expect(throws: FileOperationError.self) {
            _ = try await LocalTransferCounter().count([entry], destination: destination, kind: .move)
        }
        await #expect(throws: FileOperationError.self) {
            _ = try await LocalFileTransfers().transfer(entry.item, from: entry.source, to: destination,
                name: "locked.txt", kind: .move, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.url.path).isEmpty)
        #expect(exists(source))
        let copyTotals = try await LocalTransferCounter().count([entry], destination: destination, kind: .copy)
        #expect(copyTotals == TransferTotals(entries: [TransferEntryTotals(items: 1, bytes: 9)]))
    }

    @Test
    func collisionOnTheOtherVolumeIsRefusedBeforeAnyWrite() async throws {
        let local = try LocalFolder(), volume = try DiskImageVolume()
        let file = local.url.appendingPathComponent("same.txt")
        try Data("source".utf8).write(to: file)
        try Data("existing".utf8).write(to: volume.mount.appendingPathComponent("same.txt"))
        await #expect(throws: FileOperationError.collision("same.txt")) {
            _ = try await LocalFileTransfers().transfer(try await item("same.txt", in: local.url),
                from: try await context(local.url), to: try await context(volume.mount),
                name: "same.txt", kind: .move, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "source")
        #expect(try String(contentsOf: volume.mount.appendingPathComponent("same.txt"), encoding: .utf8) == "existing")
    }

    @Test
    func disconnectingTheSourceVolumeAfterPublicationReportsTheOriginalAsKept() async throws {
        let local = try LocalFolder()
        let volume = try DiskImageVolume { mount in
            try Data("detach me".utf8).write(to: mount.appendingPathComponent("detach.txt"))
        }
        let transfers = LocalFileTransfers(afterCommit: { _ in try? volume.detach(force: true) })
        let result = try await transfers.transfer(try await item("detach.txt", in: volume.mount),
            from: try await context(volume.mount), to: try await context(local.url),
            name: "detach.txt", kind: .move, control: TransferControl(), onProgress: { _ in })
        #expect(result.sourceRetention != nil, "A source that disappears mid-removal is never reported as moved")
        #expect(try String(contentsOf: local.url.appendingPathComponent("detach.txt"), encoding: .utf8) == "detach me")
    }

    @Test
    func countingNestedTreePreservesTotalsThroughDescriptorHandoffs() async throws {
        let local = try LocalFolder(), other = try LocalFolder()
        var leaf = try folder(local.url.appendingPathComponent("Tree", isDirectory: true))
        for _ in 0..<12 { leaf = try folder(leaf.appendingPathComponent("level", isDirectory: true)) }
        try Data(repeating: 4, count: 9).write(to: leaf.appendingPathComponent("end"))
        let entry = TransferEntry(source: try await context(local.url), item: try await item("Tree", in: local.url))
        let destination = try await context(other.url)
        let totals = try await LocalTransferCounter(maximumEntries: 14).count([entry], destination: destination, kind: .copy)
        #expect(totals == TransferTotals(entries: [TransferEntryTotals(items: 14, bytes: 9)]))
        #expect(try Data(contentsOf: leaf.appendingPathComponent("end")) == Data(repeating: 4, count: 9))
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.url.path).isEmpty)
    }

    @Test
    func countingSharesEntryBudgetAcrossTopLevelTrees() async throws {
        let local = try LocalFolder(), other = try LocalFolder()
        let first = try folder(local.url.appendingPathComponent("First", isDirectory: true))
        let second = try folder(local.url.appendingPathComponent("Second", isDirectory: true))
        try Data(repeating: 1, count: 9).write(to: first.appendingPathComponent("a"))
        try Data(repeating: 2, count: 13).write(to: second.appendingPathComponent("b"))
        let source = try await context(local.url)
        let entries = [
            TransferEntry(source: source, item: try await item("First", in: local.url)),
            TransferEntry(source: source, item: try await item("Second", in: local.url))
        ]
        let destination = try await context(other.url)

        let firstOnly = try await LocalTransferCounter(maximumEntries: 2).count([entries[0]], destination: destination, kind: .copy)
        let secondOnly = try await LocalTransferCounter(maximumEntries: 2).count([entries[1]], destination: destination, kind: .copy)
        #expect(firstOnly == TransferTotals(entries: [TransferEntryTotals(items: 2, bytes: 9)]))
        #expect(secondOnly == TransferTotals(entries: [TransferEntryTotals(items: 2, bytes: 13)]))
        let exact = try await LocalTransferCounter(maximumEntries: 4).count(entries, destination: destination, kind: .copy)
        #expect(exact == TransferTotals(entries: [TransferEntryTotals(items: 2, bytes: 9), TransferEntryTotals(items: 2, bytes: 13)]))
        let insufficient = try await LocalTransferCounter(maximumEntries: 3).count(entries, destination: destination, kind: .copy)
        #expect(insufficient == nil, "The entry limit is shared across the whole batch, not reset for each tree")
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.url.path).isEmpty)
    }

    @Test
    func countingIncludesHiddenUnicodeNamesWithoutTraversingAnOutsideLink() async throws {
        let local = try LocalFolder(), other = try LocalFolder(), outside = try LocalFolder()
        let tree = try folder(local.url.appendingPathComponent("Tree", isDirectory: true))
        let unicode = try folder(tree.appendingPathComponent("Café 日本語 🗂", isDirectory: true))
        let hidden = tree.appendingPathComponent(".hidden")
        let leaf = unicode.appendingPathComponent("cafe\u{301}.txt")
        let outsideFile = outside.url.appendingPathComponent("outside.txt")
        try Data(repeating: 1, count: 3).write(to: hidden)
        try Data(repeating: 2, count: 7).write(to: leaf)
        try Data(repeating: 3, count: 4_096).write(to: outsideFile)
        let observedOutsideIdentity = try LocalFileIdentity.read(at: outsideFile, ifLocal: true)
        let outsideIdentity = try #require(observedOutsideIdentity)
        let outsideHash = try sha(outsideFile)
        let link = tree.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.url.path)
        let entry = TransferEntry(source: try await context(local.url), item: try await item("Tree", in: local.url))
        let destination = try await context(other.url)
        let totals = try await LocalTransferCounter(maximumEntries: 5).count([entry], destination: destination, kind: .copy)

        #expect(totals == TransferTotals(entries: [TransferEntryTotals(items: 5, bytes: 10)]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.url.path)
        #expect(try LocalFileIdentity.read(at: outsideFile, ifLocal: true) == outsideIdentity)
        #expect(try sha(outsideFile) == outsideHash)
        #expect(try Data(contentsOf: hidden) == Data(repeating: 1, count: 3))
        #expect(try Data(contentsOf: leaf) == Data(repeating: 2, count: 7))
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.url.path).isEmpty)
    }

    @Test
    func countingTotalsEntriesAndBytesAndReportsUnknownForUnreadableTrees() async throws {
        let local = try LocalFolder(), other = try LocalFolder()
        let tree = try folder(local.url.appendingPathComponent("Tree", isDirectory: true))
        try Data(repeating: 1, count: 100).write(to: tree.appendingPathComponent("a"))
        let sub = try folder(tree.appendingPathComponent("sub", isDirectory: true))
        try Data(repeating: 2, count: 50).write(to: sub.appendingPathComponent("b"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a")
        let entry = TransferEntry(source: try await context(local.url), item: try await item("Tree", in: local.url))
        let destination = try await context(other.url)
        #expect(try await LocalTransferCounter().count([entry], destination: destination, kind: .copy)
                == TransferTotals(entries: [TransferEntryTotals(items: 5, bytes: 150)]))
        #expect(try await LocalTransferCounter().count([entry], destination: destination, kind: .move)
                == TransferTotals(entries: [TransferEntryTotals(items: 1, bytes: 0)]), "A same-volume move is one rename")
        #expect(try await LocalTransferCounter(maximumEntries: 3).count([entry], destination: destination, kind: .copy) == nil)
        _ = chmod(sub.path, 0o000)
        defer { _ = chmod(sub.path, 0o755) }
        #expect(try await LocalTransferCounter().count([entry], destination: destination, kind: .copy) == nil)
    }
}
