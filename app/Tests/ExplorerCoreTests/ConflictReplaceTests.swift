import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

// NATIVE-P16 / MAC-070–073 / FR-FILE-009 core tests. Every replaced item goes
// to a disposable disk image's own Trash, so no test touches the user's Trash;
// the images and everything in them are detached and deleted afterwards.

private final class P16Folder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerP16-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func p16Folder(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func p16Context(_ url: URL) async throws -> FileOperationContext {
    let snapshot = try await LocalDirectoryLoader().snapshot(of: url)
    return FileOperationContext(directoryURL: url, directoryIdentity: try #require(snapshot.directoryIdentity))
}

private func p16Item(_ name: String, in url: URL) async throws -> FileItem {
    try #require(try await LocalDirectoryLoader().snapshot(of: url, showHidden: true).items.first { $0.name == name })
}

private func p16Text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func p16Identity(_ url: URL) throws -> LocalFileIdentity? { try LocalFileIdentity.read(at: url, ifLocal: true) }

private func p16Exists(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0
}

private func p16NoStaging(_ url: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: url.path).allSatisfy { !$0.hasPrefix(".explorer-transfer-") }
}

/// Source and Destination folders on one disposable APFS image.
private final class P16Volume {
    let volume: DiskImageVolume
    let source: URL
    let destination: URL
    init() throws {
        volume = try DiskImageVolume()
        source = try p16Folder(volume.mount.appendingPathComponent("Source", isDirectory: true))
        destination = try p16Folder(volume.mount.appendingPathComponent("Destination", isDirectory: true))
    }
    func write(_ text: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    func compared(_ name: String) async throws -> ConflictEntry {
        try await LocalConflictInspector().inspect(name: name, in: try await p16Context(destination))
    }
}

private struct P16InjectedFailure: Error {}

private final class P16Log: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []
    func append(_ value: TransferProgress) { lock.withLock { values.append(value) } }
    var all: [TransferProgress] { lock.withLock { values } }
}

private func p16TrashEntries(_ volume: DiskImageVolume) -> [String] {
    let trash = volume.mount.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
    return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).filter { $0 != ".DS_Store" }
}

extension CrossVolumeTransferTests {
    @Test
    func inspectorReadsExistingItemNoFollowAndOnlyNonFoldersAreReplaceable() async throws {
        let fixture = try P16Volume()
        _ = try fixture.write("existing", "a.txt", in: fixture.destination)
        _ = try p16Folder(fixture.destination.appendingPathComponent("Folder", isDirectory: true))
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.appendingPathComponent("link").path,
                                                   withDestinationPath: "Folder")
        let file = try await fixture.compared("a.txt")
        #expect(file.kind == .file && file.size == 8 && file.target.isReplaceable)
        #expect(file.target.identity == (try p16Identity(fixture.destination.appendingPathComponent("a.txt"))))
        // Desktop finding MAC-0581: Kind matches the listing's Kind column.
        #expect(file.kindDescription == (try await p16Item("a.txt", in: fixture.destination)).kind)
        let folder = try await fixture.compared("Folder")
        #expect(folder.kind == .folder && folder.size == nil && !folder.target.isReplaceable)
        let link = try await fixture.compared("link")
        #expect(link.kind == .symbolicLink && link.target.isReplaceable, "A link to a folder is a link, never followed")
    }

    @Test
    func copyReplaceTrashesTheComparedItemAndPublishesTheIncomingCopy() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming version", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        let result = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: fixture.source),
            from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
            name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        #expect(try p16Text(existing) == "incoming version")
        #expect(try p16Text(incoming) == "incoming version", "Copy leaves the source")
        let receipt = try #require(result.replacedReceipt, "The replaced item joins Recently Trashed")
        #expect(receipt.original.name == "a.txt" && receipt.originalContext.directoryURL == fixture.destination)
        #expect(receipt.trashed.identity == existingIdentity)
        #expect(try p16Text(receipt.trashed.url) == "existing")
        #expect(try p16NoStaging(fixture.destination))

        // The receipt restores the replaced version once its name is free (Restore As otherwise).
        let restored = try await LocalFileRecovery().restore(receipt, as: "a (previous).txt")
        #expect(try p16Text(restored.url) == "existing")
        #expect(restored.identity == existingIdentity)
    }

    @Test
    func sameVolumeMoveReplaceRenamesTheOriginalOverTheTrashedName() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("moved version", "a.txt", in: fixture.source)
        let incomingIdentity = try p16Identity(incoming)
        _ = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        let result = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: fixture.source),
            from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
            name: "a.txt", kind: .move, replacing: target, control: TransferControl(), onProgress: { _ in })
        let destination = fixture.destination.appendingPathComponent("a.txt")
        #expect(!p16Exists(incoming))
        #expect(try p16Identity(destination) == incomingIdentity, "A same-volume move is one rename")
        #expect(result.transferredEntries == 1)
        let receipt = try #require(result.replacedReceipt)
        #expect(try p16Text(receipt.trashed.url) == "existing")
    }

    @Test
    func crossVolumeMoveReplacePublishesBeforeRemovingTheOriginal() async throws {
        let local = try P16Folder(), fixture = try P16Volume()
        let incoming = local.url.appendingPathComponent("a.txt")
        try Data("from the other volume".utf8).write(to: incoming)
        _ = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        let result = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: local.url),
            from: try await p16Context(local.url), to: try await p16Context(fixture.destination),
            name: "a.txt", kind: .move, replacing: target, control: TransferControl(), onProgress: { _ in })
        #expect(result.sourceRetention == nil)
        #expect(!p16Exists(incoming), "MAC-066/067: the verified copy authorises removing the original")
        #expect(try p16Text(fixture.destination.appendingPathComponent("a.txt")) == "from the other volume")
        let receipt = try #require(result.replacedReceipt)
        #expect(try p16Text(receipt.trashed.url) == "existing")
        let destinationDevice = try await p16Context(fixture.destination).directoryIdentity.device
        #expect(receipt.trashContext.directoryIdentity.device == destinationDevice, "Trashed on the destination volume")
        #expect(try p16NoStaging(fixture.destination))
    }

    @Test
    func changedDestinationIsRefusedBeforeAnythingIsTrashed() async throws {
        let fixture = try P16Volume()
        _ = try fixture.write("incoming", "a.txt", in: fixture.source)
        _ = try fixture.write("incoming", "b.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        // Same identity, new size.
        let handle = try FileHandle(forWritingTo: existing)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" + edit".utf8)); try handle.close()
        await #expect(throws: TransferReplacementError.destinationChanged("a.txt")) {
            _ = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(existing) == "existing + edit")
        #expect(try p16Text(fixture.source.appendingPathComponent("a.txt")) == "incoming")
        #expect(try p16NoStaging(fixture.destination))

        // Same size and date, different item: still refused (identity is compared).
        let b = try fixture.write("existing", "b.txt", in: fixture.destination)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let bTarget = try await fixture.compared("b.txt").target
        try FileManager.default.removeItem(at: b)
        _ = try fixture.write("EXISTING", "b.txt", in: fixture.destination)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        await #expect(throws: TransferReplacementError.destinationChanged("b.txt")) {
            _ = try await LocalFileTransfers().transfer(try await p16Item("b.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "b.txt", kind: .move, replacing: bTarget, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(b) == "EXISTING")
        #expect(p16Exists(fixture.source.appendingPathComponent("b.txt")))

        // Removed after comparison: also a fresh decision, never a silent publish.
        try FileManager.default.removeItem(at: existing)
        await #expect(throws: TransferReplacementError.destinationChanged("a.txt")) {
            _ = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(!p16Exists(existing))
    }

    @Test
    func foldersAreNeverReplacedOrMerged() async throws {
        let fixture = try P16Volume()
        let folder = try p16Folder(fixture.destination.appendingPathComponent("Item", isDirectory: true))
        _ = try fixture.write("kept", "inside.txt", in: folder)
        _ = try fixture.write("incoming file", "Item", in: fixture.source)
        let folderTarget = try await fixture.compared("Item").target
        await #expect(throws: TransferReplacementError.notReplaceable("Item")) {
            _ = try await LocalFileTransfers().transfer(try await p16Item("Item", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "Item", kind: .copy, replacing: folderTarget, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(folder.appendingPathComponent("inside.txt")) == "kept")

        let incomingFolder = try p16Folder(fixture.source.appendingPathComponent("Docs", isDirectory: true))
        _ = try fixture.write("incoming", "x.txt", in: incomingFolder)
        let existingFile = try fixture.write("existing", "Docs", in: fixture.destination)
        let fileTarget = try await fixture.compared("Docs").target
        await #expect(throws: TransferReplacementError.notReplaceable("Docs")) {
            _ = try await LocalFileTransfers().transfer(try await p16Item("Docs", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "Docs", kind: .move, replacing: fileTarget, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(existingFile) == "existing")
        #expect(try p16Text(incomingFolder.appendingPathComponent("x.txt")) == "incoming")
        #expect(try p16NoStaging(fixture.destination))
    }

    @Test
    func publicationFailureAfterTrashingRestoresTheExistingItem() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        for kind in [TransferKind.copy, .move] {
            let target = try await fixture.compared("a.txt").target
            let writer = LocalFileTransfers(afterReplacementRetired: { url in
                #expect(!p16Exists(url), "The compared item is in the Trash at this point")
                throw P16InjectedFailure()
            })
            await #expect(throws: P16InjectedFailure.self) {
                _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                    from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                    name: "a.txt", kind: kind, replacing: target, control: TransferControl(), onProgress: { _ in })
            }
            #expect(try p16Identity(existing) == existingIdentity, "MAC-072: restored to its own name")
            #expect(try p16Text(existing) == "existing")
            #expect(try p16Text(incoming) == "incoming")
            #expect(try p16NoStaging(fixture.destination))
        }
    }

    @Test
    func failedRestoreReportsTheTrashReceiptAndKeepsTheReplacedItem() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        // Another process takes the name between Trash and publication.
        let writer = LocalFileTransfers(afterReplacementRetired: { url in
            try Data("someone else".utf8).write(to: url, options: .withoutOverwriting)
        })
        var recovery: ReplacementRecoveryError?
        do {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
            Issue.record("A blocked publication must not report success")
        } catch let error as ReplacementRecoveryError {
            recovery = error
        }
        let receipt = try #require(recovery?.receipt)
        #expect(try p16Text(existing) == "someone else", "Never overwritten")
        #expect(try p16Text(incoming) == "incoming")
        #expect(receipt.trashed.identity == existingIdentity)
        #expect(try p16Text(receipt.trashed.url) == "existing")
        #expect(recovery?.errorDescription?.contains("Trash") == true)
        #expect(try p16NoStaging(fixture.destination))
        let restored = try await LocalFileRecovery().restore(receipt, as: "a restored.txt")
        #expect(try p16Text(restored.url) == "existing")
    }

    @Test
    func cancelledReplaceLeavesBothOriginals() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        for kind in [TransferKind.copy, .move] {
            let control = TransferControl()
            control.cancel()
            await #expect(throws: (any Error).self) {
                _ = try await LocalFileTransfers().transfer(try await p16Item("a.txt", in: fixture.source),
                    from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                    name: "a.txt", kind: kind, replacing: target, control: control, onProgress: { _ in })
            }
            #expect(try p16Text(existing) == "existing")
            #expect(try p16Text(incoming) == "incoming")
            #expect(try p16NoStaging(fixture.destination))
        }
    }

    @Test
    func transfersWithoutReplaceSupportRefuseATargetWithoutChangingAnything() async throws {
        struct Plain: FileTransferring {
            func transfer(_ item: FileItem, from: FileOperationContext, to: FileOperationContext, name: String,
                          kind: TransferKind, control: TransferControl,
                          onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> FileOperationResult {
                Issue.record("Must not be reached with a replacement target")
                return FileOperationResult(url: to.directoryURL.appendingPathComponent(name), identity: nil, warning: nil)
            }
        }
        let fixture = try P16Volume()
        _ = try fixture.write("incoming", "a.txt", in: fixture.source)
        _ = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        await #expect(throws: FileOperationError.self) {
            _ = try await Plain().transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
    }

    // MARK: Review d0a87c9e corrections

    /// #1 (and follow-up 55b3f24a): a Trash outcome without a verified receipt
    /// never publishes; when the reported location still holds the exact item
    /// it is put back, so nothing changes.
    @Test(arguments: ["copy", "same-volume-move", "cross-volume-move"])
    func unverifiedTrashReceiptPutsTheExactItemBackAndPublishesNothing(_ scenario: String) async throws {
        let fixture = try P16Volume()
        let local = try P16Folder()
        let sourceFolder = scenario == "cross-volume-move" ? local.url : fixture.source
        let incoming = sourceFolder.appendingPathComponent("a.txt")
        try Data("incoming".utf8).write(to: incoming)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        let writer = LocalFileTransfers(replacementHooks: ReplacementHooks(trash: { item, context, cancellation in
            let real = try LocalFileRecovery().trashNow(item, in: context, cancellation: cancellation)
            // Carries the Trash service's real instruction, which must not survive a put-back.
            return TrashResult(receipt: nil, warning: "Simulated unverifiable receipt. Use Finder to inspect Trash.",
                               trashedURL: real.trashedURL)
        }))
        var stopped: ReplacementTrashError?
        do {
            _ = try await writer.transfer(try await p16Item("a.txt", in: sourceFolder),
                from: try await p16Context(sourceFolder), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: scenario == "copy" ? .copy : .move, replacing: target,
                control: TransferControl(), onProgress: { _ in })
            Issue.record("Replace must not complete without a verified receipt")
        } catch let error as ReplacementTrashError { stopped = error }
        guard case .putBack(let name, _) = try #require(stopped) else {
            Issue.record("Expected the exact item to be put back"); return
        }
        #expect(name == "a.txt")
        #expect(try p16Identity(existing) == existingIdentity && (try p16Text(existing)) == "existing")
        #expect(p16TrashEntries(fixture.volume).isEmpty)
        #expect(try p16Text(incoming) == "incoming", "The incoming item, including a Move's original, is unchanged")
        #expect(try p16NoStaging(fixture.destination))
        #expect(stopped?.errorDescription?.contains("nothing was replaced") == true)
        #expect(stopped?.errorDescription?.contains("inspect Trash") == false, "No obsolete Trash instructions")
    }

    /// #1: when the item cannot be found again, the outcome and any known
    /// location are reported; nothing is published and nothing claims Recently Trashed.
    @Test
    func unverifiedTrashWithoutALocationIsReportedAndPublishesNothing() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        let writer = LocalFileTransfers(replacementHooks: ReplacementHooks(trash: { item, context, cancellation in
            _ = try LocalFileRecovery().trashNow(item, in: context, cancellation: cancellation)
            return TrashResult(receipt: nil, warning: "Simulated missing location.", accessFailure: .permissionDenied)
        }))
        var stopped: ReplacementTrashError?
        do {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        } catch let error as ReplacementTrashError { stopped = error }
        guard case .unverified(_, let location, _, let failure) = try #require(stopped) else {
            Issue.record("Expected an unverified Trash outcome"); return
        }
        #expect(location == nil && failure == .permissionDenied)
        #expect(FileAccessFailure.classify(try #require(stopped)) == .permissionDenied, "Access Help keeps the classification")
        #expect(!p16Exists(existing), "Nothing was published in its place")
        #expect(p16TrashEntries(fixture.volume) == ["a.txt"], "The existing item is in that volume's Trash")
        #expect(try p16Text(incoming) == "incoming")
        #expect(try p16NoStaging(fixture.destination))
        #expect(stopped?.errorDescription?.contains("not listed in Recently Trashed") == true)
    }

    /// #1: an uncertain native Trash outcome is reported, never published over.
    @Test
    func uncertainTrashOutcomeStopsBeforePublishing() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        let writer = LocalFileTransfers(replacementHooks: ReplacementHooks(trash: { _, _, _ in
            throw FileRecoveryError.outcomeUncertain("Simulated native error.")
        }))
        await #expect(throws: ReplacementTrashError.self) {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(existing) == "existing")
        #expect(try p16Text(incoming) == "incoming")
        #expect(try p16NoStaging(fixture.destination))
    }

    /// #2: publication, restore and staging cleanup all fail; the receipt survives.
    @Test
    func receiptSurvivesFailedRestoreAndFailedStagingCleanup() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        let destinationPath = fixture.destination.path
        let writer = LocalFileTransfers(afterReplacementRetired: { _ in
            // The destination folder becomes unwritable after the Trash step.
            guard chmod(destinationPath, 0o555) == 0 else { throw POSIXError(.EPERM) }
        })
        var recovery: ReplacementRecoveryError?
        do {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
            Issue.record("An unwritable destination must not report success")
        } catch let error as ReplacementRecoveryError { recovery = error }
        _ = chmod(destinationPath, 0o755)
        let receipt = try #require(recovery?.receipt, "The typed receipt is kept despite the cleanup failure")
        #expect(recovery?.cause.contains("staging could not be safely removed") == true)
        #expect(receipt.trashed.identity == existingIdentity)
        #expect(try p16Text(receipt.trashed.url) == "existing")
        #expect(try p16Text(incoming) == "incoming")
        let restored = try await LocalFileRecovery().restore(receipt, as: "a.txt")
        #expect(try p16Text(restored.url) == "existing")
    }

    /// #3: a source substituted while the existing item was being trashed is
    /// never renamed into place; the existing item is restored.
    @Test
    func sourceSubstitutedDuringRetirementIsNotPublished() async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("original source", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        let aside = fixture.source.appendingPathComponent("a-aside.txt")
        let writer = LocalFileTransfers(afterReplacementRetired: { _ in
            try FileManager.default.moveItem(at: incoming, to: aside)
            try Data("substitute".utf8).write(to: incoming)
        })
        await #expect(throws: FileOperationError.staleSource) {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: .move, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Identity(existing) == existingIdentity, "Restored to its own name")
        #expect(try p16Text(incoming) == "substitute")
        #expect(try p16Text(aside) == "original source")
        #expect(p16TrashEntries(fixture.volume).isEmpty)
    }

    /// #4: Cancel up to the Trash step changes nothing, and the committed phase
    /// is announced before the existing item is trashed.
    @Test(arguments: [TransferKind.copy, .move])
    func cancelBeforeTrashChangesNothingAndCommitIsAnnouncedFirst(_ kind: TransferKind) async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let target = try await fixture.compared("a.txt").target
        let cancelling = LocalFileTransfers(replacementHooks: ReplacementHooks(beforeTrash: { control in control.cancel() }))
        await #expect(throws: (any Error).self) {
            _ = try await cancelling.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: kind, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Text(existing) == "existing" && (try p16Text(incoming)) == "incoming")
        #expect(p16TrashEntries(fixture.volume).isEmpty)
        #expect(try p16NoStaging(fixture.destination))

        let log = P16Log()
        let observing = LocalFileTransfers(afterReplacementRetired: { _ in
            #expect(log.all.last?.phase == .finalizing, "Uninterruptible before the Trash step")
        })
        _ = try await observing.transfer(try await p16Item("a.txt", in: fixture.source),
            from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
            name: "a.txt", kind: kind, replacing: target, control: TransferControl(), onProgress: { log.append($0) })
        #expect(try p16Text(existing) == "incoming")
    }

    /// Symbolic links are replaced as links: the link goes to the Trash and its
    /// target folder is untouched.
    @Test
    func replacingASymbolicLinkTrashesTheLinkNotItsTarget() async throws {
        let fixture = try P16Volume()
        let folder = try p16Folder(fixture.destination.appendingPathComponent("Folder", isDirectory: true))
        _ = try fixture.write("kept", "inside.txt", in: folder)
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.appendingPathComponent("link").path,
                                                   withDestinationPath: "Folder")
        _ = try fixture.write("incoming file", "link", in: fixture.source)
        let target = try await fixture.compared("link").target
        let result = try await LocalFileTransfers().transfer(try await p16Item("link", in: fixture.source),
            from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
            name: "link", kind: .copy, replacing: target, control: TransferControl(), onProgress: { _ in })
        #expect(try p16Text(fixture.destination.appendingPathComponent("link")) == "incoming file")
        #expect(try p16Text(folder.appendingPathComponent("inside.txt")) == "kept")
        let receipt = try #require(result.replacedReceipt)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.trashed.url.path) == "Folder")
    }

    /// Own finding with f7716cbf: a failure and its location are selected together.
    @Test
    func accessFailureAndLocationAreSelectedTogether() {
        let destination = URL(fileURLWithPath: "/tmp/destination"), source = URL(fileURLWithPath: "/tmp/source")
        let kept = LocalFileTransfers.selectAccessFailure(.permissionDenied, at: source,
            current: .permissionDenied, currentLocation: destination)
        #expect(kept.0 == .permissionDenied && kept.1 == destination, "The earlier destination failure stays selected")
        let first = LocalFileTransfers.selectAccessFailure(.permissionDenied, at: source, current: nil, currentLocation: nil)
        #expect(first.0 == .permissionDenied && first.1 == source)
        let stronger = LocalFileTransfers.selectAccessFailure(.readOnlyVolume, at: source,
            current: .permissionDenied, currentLocation: destination)
        #expect(stronger.0 == .readOnlyVolume && stronger.1 == source, "A preferred new failure brings its location")
        let none = LocalFileTransfers.selectAccessFailure(nil, at: source, current: .permissionDenied, currentLocation: destination)
        #expect(none.0 == .permissionDenied && none.1 == destination)
    }

    /// Follow-up 55b3f24a #7: an in-place edit made while the transfer is paused
    /// at the last checkpoint is caught after Resume; nothing is trashed.
    @Test(arguments: [TransferKind.copy, .move])
    func editWhilePausedBeforeTrashNeedsAFreshDecision(_ kind: TransferKind) async throws {
        let fixture = try P16Volume()
        let incoming = try fixture.write("incoming", "a.txt", in: fixture.source)
        let existing = try fixture.write("existing", "a.txt", in: fixture.destination)
        let existingIdentity = try p16Identity(existing)
        let target = try await fixture.compared("a.txt").target
        let path = existing.path
        let writer = LocalFileTransfers(replacementHooks: ReplacementHooks(beforeTrash: { control in
            control.pause()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                // Same inode, new size: edited in place while paused.
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile(); handle.write(Data(" + edited while paused".utf8)); handle.closeFile()
                }
                control.resume()
            }
        }))
        await #expect(throws: TransferReplacementError.destinationChanged("a.txt")) {
            _ = try await writer.transfer(try await p16Item("a.txt", in: fixture.source),
                from: try await p16Context(fixture.source), to: try await p16Context(fixture.destination),
                name: "a.txt", kind: kind, replacing: target, control: TransferControl(), onProgress: { _ in })
        }
        #expect(try p16Identity(existing) == existingIdentity)
        #expect(try p16Text(existing) == "existing + edited while paused")
        #expect(try p16Text(incoming) == "incoming")
        #expect(p16TrashEntries(fixture.volume).isEmpty)
        #expect(try p16NoStaging(fixture.destination))
    }
}
