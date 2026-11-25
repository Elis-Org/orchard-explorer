import ExplorerCore
import Foundation

struct ItemTransferOutcome: Sendable {
    var physicalResults: [FileOperationResult] = []
    var archiveResults: [ArchiveMutationResult] = []
    var trashReceipts: [TrashReceipt] = []
    var copied = 0
    var moved = 0
    var skipped = 0
    var messages: [String] = []
    var summary: String {
        var text = "Copied \(copied) item\(copied == 1 ? "" : "s")."
        if moved > 0 { text += " Moved \(moved) after verifying the destination." }
        if skipped > 0 { text += " Skipped \(skipped)." }
        return ([text] + messages).joined(separator: " ")
    }
}

/// Coordinates only cross-boundary operations. Existing physical services keep
/// their contracts; all archive sources retain their original logical authority.
struct ItemOperationCoordinator: Sendable {
    let archives: any ArchiveModifying
    let transfers: any FileTransferring
    let recovery: any FileRecovering
    let loader: any DirectoryListing
    let conflicts: any ConflictInspecting
    let registry: ContentLeaseRegistry
    typealias Progress = @Sendable (TransferProgress) -> Void
    typealias ProgressFactory = @MainActor @Sendable () -> Progress
    typealias Conflict = @MainActor @Sendable (TransferConflictInfo) async -> TransferConflictChoice

    func copyOut(_ payload: TransferClipboardPayload, to destination: FileOperationContext,
                 moving: Bool, control: TransferControl, progress: @escaping ProgressFactory,
                 conflict: @escaping Conflict) async -> ItemTransferOutcome {
        var outcome = ItemTransferOutcome()
        var cleanupCandidates: [(ArchiveMemberTarget, ArchiveCopiedDestination)] = []
        do {
            guard payload.hasArchiveOrigin, payload.logicalEntries.count == payload.entries.count,
                  payload.leases.count == payload.entries.count else { throw ArchiveOperationError.changed }
            for index in payload.entries.indices {
                try control.checkpoint()
                let logical = payload.logicalEntries[index]
                guard let target = logical.archiveTarget,
                      await target.revision.isCurrent(at: target.location.archiveURL) else { throw ArchiveOperationError.changed }
                try await payload.leases[index].validateForUse()
                let entry = payload.entries[index]
                var naming = TransferConflictNaming(item: logical.item, mode: .archive)
                var replacing: ReplacementTarget?
                var skipped = false
                while true {
                    try control.checkpoint()
                    let name = naming.name
                    do {
                        let result = try await transfers.transfer(entry.item, from: entry.source, to: destination,
                            name: name, kind: .copy, replacing: replacing, control: control, onProgress: await progress())
                        outcome.physicalResults.append(result)
                        outcome.copied += 1
                        if let receipt = result.replacedReceipt { outcome.trashReceipts.append(receipt) }
                        if let warning = result.warning { outcome.messages.append(warning) }
                        if moving {
                            if let claim = await copiedDestinationClaim(result, source: logical.item, destination: destination, expectedName: name) {
                                cleanupCandidates.append((target, claim))
                            } else { outcome.messages.append("“\(logical.item.name)” was copied, but its destination could not be verified; the ZIP original was retained.") }
                        }
                        break
                    } catch {
                        let isCollision: Bool
                        if case FileOperationError.collision = error { isCollision = true }
                        else if error is TransferReplacementError { isCollision = true }
                        else { throw error }
                        guard isCollision else { throw error }
                        var info = TransferConflictInfo(name: name, incoming: logical.item,
                            incomingLocation: logical.context.directoryURL, destinationLocation: destination.directoryURL)
                        do { info.existing = try await conflicts.inspect(name: name, in: destination) }
                        catch { info.inspectionError = error.localizedDescription }
                        info.changedSinceCompared = replacing != nil
                        let choice = await conflict(info)
                        switch choice {
                        case .replace:
                            guard info.canReplace else { throw CancellationError() }
                            replacing = info.existing?.target
                        case .skip: skipped = true; outcome.skipped += 1
                        case .keepBoth:
                            try naming.keepBoth()
                            replacing = nil
                        case .cancel: throw CancellationError()
                        }
                        if skipped { break }
                    }
                }
            }
        } catch let error as ReplacementRecoveryError {
            outcome.trashReceipts.append(error.receipt)
            outcome.messages.append(error.localizedDescription)
        } catch is CancellationError {
            outcome.messages.append("Cancelled; completed copies and their originals were retained.")
            return outcome
        } catch { outcome.messages.append("Stopped. \(error.localizedDescription)") }

        // A publication identity is only a claim. Core verifies each destination
        // against its captured archive manifest immediately before source swap.
        // Cut cannot fall back to the explicit-Delete .remove operation.
        if moving, !cleanupCandidates.isEmpty {
            do {
                try control.checkpoint()
                let targets = cleanupCandidates.map(\.0)
                guard let first = targets.first,
                      targets.allSatisfy({ $0.revision == first.revision && $0.location.archiveURL == first.location.archiveURL }),
                      await first.revision.isCurrent(at: first.location.archiveURL),
                      let parent = ArchiveLocation(url: first.location.parentURL) else { throw ArchiveOperationError.changed }
                let edits = cleanupCandidates.map { ArchiveEdit.removeAfterVerifiedCopy(source: $0.0, destination: $0.1) }
                let result = try await archives.modify(edits,
                    in: ArchiveOperationContext(location: parent, revision: first.revision), control: control, onProgress: await progress())
                outcome.archiveResults.append(result)
                if result.revision != nil, result.recovery == nil, result.warning == nil { outcome.moved = targets.count }
                if let warning = result.warning { outcome.messages.append(warning) }
                if let receipt = result.recovery { outcome.messages.append(receipt.reason + " " + receipt.retainedURLs.map(\.path).joined(separator: ", ")) }
            } catch { outcome.messages.append("The destination copies were retained. ZIP source cleanup did not complete: \(error.localizedDescription)") }
        }
        return outcome
    }

    private func copiedDestinationClaim(_ result: FileOperationResult, source: FileItem,
                                        destination: FileOperationContext, expectedName: String) async -> ArchiveCopiedDestination? {
        guard result.url.isFileURL, let identity = result.identity, result.warning == nil, result.accessFailure == nil,
              result.url.lastPathComponent.utf8.elementsEqual(expectedName.utf8),
              result.url.deletingLastPathComponent().standardizedFileURL.path.utf8.elementsEqual(destination.directoryURL.standardizedFileURL.path.utf8),
              await RoutingTargetValidation.isCurrentFolder(destination.directoryURL, identity: destination.directoryIdentity) else { return nil }
        let item = FileItem(url: result.url, name: result.url.lastPathComponent, isDirectory: source.isDirectory,
            isSymbolicLink: source.isSymbolicLink, size: source.size, modifiedAt: source.modifiedAt,
            kind: source.kind, identity: identity)
        guard await RoutingTargetValidation.isCurrent(item) else { return nil }
        return ArchiveCopiedDestination(parent: destination, name: result.url.lastPathComponent, identity: identity)
    }

    func add(_ entries: [ItemOperationEntry], to destination: ArchiveOperationContext,
             moving: Bool, control: TransferControl, progress: @escaping ProgressFactory,
             conflict: @escaping Conflict) async throws -> ItemTransferOutcome {
        guard ItemOperationCapabilities(entries: entries).canPaste(into: .archive(destination)),
              entries.allSatisfy({ !registry.containsManagedURL($0.item.url) }) else {
            throw ArchiveOperationError.unsupported("Copy the ZIP contents to an ordinary folder before adding them to a ZIP. Direct ZIP-to-ZIP transfers aren't available.")
        }
        let snapshot = try await loader.snapshot(of: destination.location.url, showHidden: true)
        guard snapshot.archiveRevision == destination.revision else { throw ArchiveOperationError.changed }
        var names = Dictionary(uniqueKeysWithValues: snapshot.items.map { (Data($0.name.utf8), $0) })
        var edits: [ArchiveEdit] = []
        var added: [(TransferEntry, ArchiveLocation)] = []
        var outcome = ItemTransferOutcome()
        for source in entries {
            try control.checkpoint()
            guard let physical = source.physicalEntry else { throw ArchiveOperationError.changed }
            var naming = TransferConflictNaming(item: source.item, mode: .archive)
            var replacing: ArchiveReplacementTarget?
            var skip = false
            while let existing = names[Data(naming.name.utf8)] {
                let name = naming.name
                let existingLocation = try ArchiveLocation(archiveURL: destination.location.archiveURL,
                    components: destination.location.components + [name])
                let wasPresent = snapshot.items.contains { $0.id == existing.id }
                var info = TransferConflictInfo(name: name, incoming: source.item,
                    incomingLocation: source.context.directoryURL, destinationLocation: destination.location.url)
                info.archiveExisting = existing
                if wasPresent { info.archiveTarget = ArchiveReplacementTarget(member:
                    ArchiveMemberTarget(location: existingLocation, revision: destination.revision)) }
                switch await conflict(info) {
                case .replace:
                    guard info.canReplace else { throw CancellationError() }
                    replacing = info.archiveTarget
                case .skip: skip = true; outcome.skipped += 1
                case .keepBoth:
                    try naming.keepBoth()
                    continue
                case .cancel: throw CancellationError()
                }
                break
            }
            if skip { continue }
            let name = naming.name
            let location = try ArchiveLocation(archiveURL: destination.location.archiveURL,
                components: destination.location.components + [name])
            edits.append(.add(source: physical, destination: location, replacing: replacing))
            added.append((physical, location))
            names[Data(name.utf8)] = source.item
        }
        guard !edits.isEmpty else { return outcome }
        let result = try await archives.modify(edits, in: destination, control: control, onProgress: await progress())
        outcome.archiveResults.append(result)
        outcome.copied = added.count
        if let warning = result.warning { outcome.messages.append(warning) }
        if let receipt = result.recovery { outcome.messages.append(receipt.reason + " " + receipt.retainedURLs.map(\.path).joined(separator: ", ")) }
        if moving {
            guard let receipt = result.verifiedDestination, result.recovery == nil, result.warning == nil,
                  receipt.archiveURL == destination.location.archiveURL, receipt.revision == result.revision,
                  added.allSatisfy({ pair in receipt.locations.contains(pair.1) }),
                  await receipt.revision.isCurrent(at: receipt.archiveURL) else {
                outcome.messages.append("The ZIP change completed, but the destination could not be verified. All physical originals were retained.")
                return outcome
            }
            for (source, _) in added {
                do {
                    guard await receipt.revision.isCurrent(at: receipt.archiveURL) else { throw ArchiveOperationError.changed }
                    let removed = try await recovery.trash(source.item, in: source.source)
                    if let receipt = removed.receipt { outcome.trashReceipts.append(receipt); outcome.moved += 1 }
                    else { outcome.messages.append("Source cleanup for “\(source.item.name)” could not be verified. Check its original folder and Trash.") }
                    if let warning = removed.warning { outcome.messages.append(warning) }
                } catch { outcome.messages.append("“\(source.item.name)” was added to the ZIP; its original was retained: \(error.localizedDescription)"); break }
            }
        }
        return outcome
    }
}
