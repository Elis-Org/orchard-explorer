import CryptoKit
import Darwin
import Foundation

/// Narrow race/error seams; production defaults always use atomic exchange.
struct ArchiveMutationHooks: Sendable {
    var beforeSwap: @Sendable (URL, URL) throws -> Void = { _, _ in }
    var afterSwap: @Sendable (URL, URL) throws -> Void = { _, _ in }
    var beforeRollback: @Sendable (URL, URL) throws -> Void = { _, _ in }
    var copyMetadata: @Sendable (Int32, Int32) -> Int32 = { source, destination in
        ZIPMemberOrigins.copyMetadata(source: source, destination: destination)
    }
    var flushParent: @Sendable (Int32) -> Int32 = { fsync($0) }
    var availableSpace: @Sendable (Int32) -> UInt64? = { descriptor in
        var value = statfs()
        guard fstatfs(descriptor, &value) == 0, value.f_bsize > 0 else { return nil }
        let bytes = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_bsize))
        return bytes.overflow ? nil : bytes.partialValue
    }
    var swap: @Sendable (Int32, String, Int32, String) -> Int32 = { first, a, second, b in
        renameatx_np(first, a, second, b, UInt32(RENAME_SWAP))
    }
}

enum ArchiveMutationTransaction {
    static func run(edits: [ArchiveEdit], context: ArchiveOperationContext, hooks: ArchiveMutationHooks,
                    checkpoint: @escaping () throws -> Void,
                    onProgress: @escaping @Sendable (TransferProgress) -> Void) throws -> ArchiveMutationResult {
        try checkpoint()
        guard !edits.isEmpty else { throw ArchiveOperationError.invalidName("No archive items were selected.") }
        let archiveURL = context.location.archiveURL, parentURL = archiveURL.deletingLastPathComponent()
        guard let parentIdentity = try LocalFileIdentity.read(at: parentURL, ifLocal: true) else { throw ArchiveOperationError.changed }
        let parentContext = FileOperationContext(directoryURL: parentURL, directoryIdentity: parentIdentity)
        return try LocalFileOperations.withParent(parentContext) { parent, resolved in
            let name = archiveURL.lastPathComponent
            try LocalFileOperations.validateName(name)
            var sourceStat = stat()
            guard fstatat(parent, name, &sourceStat, AT_SYMLINK_NOFOLLOW) == 0,
                  sourceStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ZIPListingError.notRegularFile }
            let sourceFD = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(sourceFD) }
            let reader = try ZIPFileReader(duplicating: sourceFD, url: archiveURL)
            guard reader.revision == context.revision else { throw ArchiveOperationError.changed }
            guard reader.length <= 2 * 1_024 * 1_024 * 1_024 else {
                throw ArchiveOperationError.limitExceeded("Archive operations support ZIP files up to 2 GiB.")
            }
            guard fstat(sourceFD, &sourceStat) == 0, let sourceIdentity = LocalFileIdentity.fromStat(sourceStat) else { throw ArchiveOperationError.changed }
            let originBudget = ZIPOriginBudget()
            let sourceOrigins = try reader.originAttributes(budget: originBudget)
            let manifest = try ZIPArchiveManifest.read(from: reader, checkpoint: checkpoint)
            let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation, checkpoint: checkpoint)
            let additions = try ZIPPhysicalAdditions(edits: edits, context: context, manifest: manifest, originBudget: originBudget, checkpoint: checkpoint)
            let copiedDestinations = try ZIPCopiedDestinationVerification(edits: edits, context: context, manifest: manifest,
                maximumBytes: 4 * 1_024 * 1_024 * 1_024 - additions.uncompressedBytes,
                maximumEntries: 100_000 - additions.count, checkpoint: checkpoint)
            let structuralEdits = edits.filter { if case .add = $0 { return false }; return true } + additions.replacementEdits
            let plan: ZIPStructuralPlan
            if structuralEdits.isEmpty { plan = ZIPStructuralPlan() }
            else {
                var checkedCompanions: Set<Int> = []
                plan = try ZIPStructuralPlan(edits: structuralEdits, context: context, manifest: manifest, checkpoint: checkpoint, validateCompanion: { record in
                    guard checkedCompanions.insert(record.id).inserted else { return }
                    guard record.kind == .file, record.uncompressedSize <= UInt64(originBudget.maximumCompanionBytes),
                          let memberLayout = layout.records[record.id] else { throw ZIPListingError.limitExceeded }
                    try originBudget.charge(Int(record.uncompressedSize))
                    var data = Data()
                    _ = try ZIPContentExtraction.extract(record: record, layout: memberLayout, reader: reader,
                        maximumBytes: UInt64(originBudget.maximumCompanionBytes), checkpoint: checkpoint, consume: { data.append($0) })
                    try ZIPMemberOrigins.validateOriginCompanion(data)
                })
            }
            try additions.validateDestinations(manifest: manifest, removed: plan.removed, renamed: plan.renamed, checkpoint: checkpoint)
            let minimumSize = try plan.minimumCandidateBytes(manifest: manifest, layout: layout,
                addedRecords: additions.count, additionHeaders: additions.minimumHeaderBytes)
            guard minimumSize <= 2 * 1_024 * 1_024 * 1_024 else { throw ZIPListingError.limitExceeded }
            // This is a lower bound, never an uncompressed source-size guess.
            // An unavailable advisory is not a write failure; ENOSPC remains authoritative.
            if let available = hooks.availableSpace(parent), available < minimumSize { throw POSIXError(.ENOSPC) }
            let stage = try ServiceStage(parent: parent, url: resolved, prefix: ".maxplorer-zip-")
            let (candidate, createdIdentity) = try stage.createFile("payload")
            var candidateIdentity = createdIdentity
            let candidateURL = stage.url.appendingPathComponent("payload")
            var canClean = true
            func stageExists() -> Bool { (try? LocalFileOperations.identity(of: stage.name, in: parent)) == stage.identity }
            func exact(_ expected: LocalFileIdentity, _ child: String, _ directory: Int32) -> Bool {
                (try? LocalFileOperations.identity(of: child, in: directory)) == expected
            }
            func clean(_ expected: LocalFileIdentity) -> Bool {
                guard stageExists(), exact(expected, "payload", stage.descriptor),
                      (try? ContentFileIO.names(stage.descriptor)) == ["payload"] else { return false }
                guard unlinkat(stage.descriptor, "payload", 0) == 0 else { return false }
                return unlinkat(parent, stage.name, AT_REMOVEDIR) == 0
            }
            func recovery(_ reason: String) -> ArchiveRecoveryReceipt {
                ArchiveRecoveryReceipt(archiveURL: archiveURL, retainedURLs: [archiveURL, stage.url], reason: reason)
            }
            do {
                var outputOffset: UInt64 = 0
                let rewrite = try ZIPStructuralRewrite.write(manifest: manifest, layout: layout, plan: plan, reader: reader,
                    output: { bytes in
                        try DescriptorIO.writeAll(bytes, to: candidate.fileDescriptor, at: outputOffset)
                        outputOffset += UInt64(bytes.count)
                        onProgress(TransferProgress(currentName: name, bytesCopied: Int64(outputOffset)))
                    }, checkpoint: checkpoint)
                let baseReader = try ZIPFileReader(duplicating: candidate.fileDescriptor, url: candidateURL, validatesPath: false)
                let baseManifest = try ZIPArchiveManifest.read(from: baseReader, checkpoint: checkpoint)
                let baseLayout = try ZIPRecordValidation.validate(manifest: baseManifest, reader: baseReader, scope: .mutation, checkpoint: checkpoint)
                try ZIPStructuralRewrite.verify(manifest: manifest, layout: layout, plan: plan, reader: reader,
                    candidate: baseManifest, candidateLayout: baseLayout, candidateReader: baseReader, checkpoint: checkpoint)
                var candidateLength = rewrite.candidateLength, candidateDigest = rewrite.candidateDigest
                var expectedKeys = baseManifest.records.map(\.pathKey)
                if !additions.locations.isEmpty {
                    try additions.validate(checkpoint: checkpoint)
                    let entries = try additions.entries(scratchDirectory: stage.descriptor, checkpoint: checkpoint)
                    let added = try ZIPFoundationAddAdapter.add(entries, to: candidate.fileDescriptor,
                                                               diagnosticURL: candidateURL, checkpoint: checkpoint)
                    try additions.validate(checkpoint: checkpoint)
                    let addedReader = try ZIPFileReader(duplicating: candidate.fileDescriptor, url: candidateURL, validatesPath: false)
                    candidateLength = addedReader.length
                    candidateDigest = try ZIPStructuralRewrite.digest(reader: addedReader,
                        range: ZIPByteRange(offset: 0, length: addedReader.length), checkpoint: checkpoint)
                    try addedReader.validateUnchanged()
                    expectedKeys = added.manifest.records.map(\.pathKey)
                }
                // Preserve outer metadata through descriptors. Failure leaves the original untouched.
                let metadataResult = hooks.copyMetadata(sourceFD, candidate.fileDescriptor)
                let metadataError = errno
                candidateIdentity = try LocalFileIdentity.afterMetadataCopy(of: createdIdentity, descriptor: candidate.fileDescriptor,
                                                                            parent: stage.descriptor, name: "payload")
                guard metadataResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: metadataError) ?? .EIO) }
                let appliedOrigins = try ZIPMemberOrigins.capture(from: candidate.fileDescriptor, budget: originBudget)
                guard sourceOrigins.quarantine == nil || appliedOrigins.quarantine != nil,
                      sourceOrigins.whereFroms == appliedOrigins.whereFroms else {
                    throw ArchiveOperationError.unsupported("The system could not preserve the ZIP's origin information.")
                }
                guard fsync(candidate.fileDescriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let candidateReader = try ZIPFileReader(duplicating: candidate.fileDescriptor, url: candidateURL, validatesPath: false)
                guard candidateReader.length == candidateLength else { throw ZIPListingError.corrupt }
                let resultManifest = try ZIPArchiveManifest.read(from: candidateReader, checkpoint: checkpoint)
                _ = try ZIPRecordValidation.validate(manifest: resultManifest, reader: candidateReader, scope: .mutation, checkpoint: checkpoint)
                guard resultManifest.records.map(\.pathKey) == expectedKeys,
                      resultManifest.archiveComment == manifest.archiveComment else { throw ZIPListingError.corrupt }
                guard try ZIPStructuralRewrite.digest(reader: candidateReader,
                    range: ZIPByteRange(offset: 0, length: candidateReader.length), checkpoint: checkpoint) == candidateDigest else { throw ZIPListingError.corrupt }
                try additions.validate(checkpoint: checkpoint)
                try checkpoint(); try reader.validateUnchanged()
                try LocalFileOperations.revalidateRoute(parentContext, resolved: resolved)
                guard stageExists(), exact(candidateIdentity, "payload", stage.descriptor), exact(sourceIdentity, name, parent) else {
                    throw ArchiveOperationError.changed
                }
                try hooks.beforeSwap(archiveURL, candidateURL)
                try additions.validate(checkpoint: checkpoint)
                try copiedDestinations.verify(checkpoint: checkpoint)
                // Destination reads can take time. Refresh every archive-side
                // witness after them, with no caller callback before exchange.
                try checkpoint()
                do { try reader.validateUnchanged(); try candidateReader.validateUnchanged() }
                catch ZIPListingError.changed { throw ArchiveOperationError.changed }
                try LocalFileOperations.revalidateRoute(parentContext, resolved: resolved)
                guard stageExists(), exact(candidateIdentity, "payload", stage.descriptor), exact(sourceIdentity, name, parent) else {
                    throw ArchiveOperationError.changed
                }
                guard try ZIPMemberOrigins.capture(from: sourceFD, budget: originBudget) == sourceOrigins,
                      try ZIPMemberOrigins.capture(from: candidate.fileDescriptor, budget: originBudget) == appliedOrigins else { throw ArchiveOperationError.changed }
                // No cancellation after this boundary: report the actual commit/rollback outcome.
                guard hooks.swap(stage.descriptor, "payload", parent, name) == 0 else {
                    let code = errno
                    if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL || code == EXDEV {
                        throw ArchiveOperationError.unsupported("This filesystem cannot atomically exchange the archive. No fallback replacement was attempted.")
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                canClean = false
                onProgress(TransferProgress(currentName: name, bytesCopied: Int64(outputOffset), phase: .finalizing))
                do {
                    try hooks.afterSwap(archiveURL, candidateURL)
                    try additions.validate(checkpoint: {})
                    try LocalFileOperations.revalidateRoute(parentContext, resolved: resolved)
                    guard stageExists(), exact(candidateIdentity, name, parent), exact(sourceIdentity, "payload", stage.descriptor) else {
                        throw ArchiveOperationError.changed
                    }
                    let displaced = try descriptorSnapshot(sourceFD, url: candidateURL)
                    guard sameOriginal(displaced.revision, context.revision),
                          try hash(displaced) == rewrite.originalDigest else { throw ArchiveOperationError.changed }
                    // The candidate must remain the exact bytes validated before publication.
                    let committed = try ZIPFileReader(duplicating: candidate.fileDescriptor, url: archiveURL)
                    guard sameOriginal(committed.revision, candidateReader.revision),
                          try hash(committed) == candidateDigest else { throw ArchiveOperationError.changed }
                    try committed.validateUnchanged()
                    guard try ZIPMemberOrigins.capture(from: sourceFD, budget: originBudget) == sourceOrigins,
                          try ZIPMemberOrigins.capture(from: candidate.fileDescriptor, budget: originBudget) == appliedOrigins else { throw ArchiveOperationError.changed }
                    // A failed directory flush leaves a committed, verified
                    // candidate and retains the old copy for reported recovery.
                    let flushed = hooks.flushParent(parent) == 0
                    let cleaned = flushed && clean(sourceIdentity)
                    return ArchiveMutationResult(archiveURL: archiveURL, previousRevision: context.revision,
                        revision: committed.revision, changedLocations: plan.changedLocations + additions.locations.map(\.url), renamedLocations: plan.mappings,
                        warning: cleaned ? nil : "The archive was changed, but directory durability or staging cleanup could not be verified. Inspect the reported recovery locations.",
                        recovery: cleaned ? nil : recovery("The archive changed successfully. Staging resources require inspection."),
                        verifiedDestination: cleaned && !additions.locations.isEmpty
                            ? ArchiveVerifiedDestinationReceipt(archiveURL: archiveURL, revision: committed.revision, locations: additions.locations) : nil)
                } catch {
                    // Swap back only while both locations still contain the sampled files.
                    // An unexpected displaced file is restored, never deleted.
                    let reason = error
                    if stageExists(), exact(candidateIdentity, name, parent),
                       let displacedIdentity = try? LocalFileOperations.identity(of: "payload", in: stage.descriptor) {
                        var before = stat(), after = stat()
                        if fstatat(stage.descriptor, "payload", &before, AT_SYMLINK_NOFOLLOW) == 0,
                           (try? hooks.beforeRollback(archiveURL, candidateURL)) != nil,
                           fstatat(stage.descriptor, "payload", &after, AT_SYMLINK_NOFOLLOW) == 0,
                           sameStat(before, after), stageExists(), exact(candidateIdentity, name, parent),
                           exact(displacedIdentity, "payload", stage.descriptor),
                           hooks.swap(stage.descriptor, "payload", parent, name) == 0,
                           exact(displacedIdentity, name, parent), exact(candidateIdentity, "payload", stage.descriptor) {
                            canClean = true
                            throw reason
                        }
                    }
                    throw ArchiveOperationError.recoveryRequired(recovery("The archive changed during publication and automatic restoration could not be verified. Both copies were retained; inspect the reported locations."))
                }
            } catch {
                if canClean {
                    guard clean(candidateIdentity) else {
                        throw ArchiveOperationError.recoveryRequired(recovery("The archive operation stopped, and staging files could not be safely removed. Inspect the reported locations. " + error.localizedDescription))
                    }
                }
                throw error
            }
        }
    }

    private static func sameOriginal(_ actual: ArchiveRevision, _ expected: ArchiveRevision) -> Bool {
        actual.device == expected.device && actual.inode == expected.inode && actual.size == expected.size
            && actual.modifiedSeconds == expected.modifiedSeconds && actual.modifiedNanoseconds == expected.modifiedNanoseconds
    }
    private static func sameStat(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_size == b.st_size && a.st_flags == b.st_flags
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func descriptorSnapshot(_ fd: Int32, url: URL) throws -> ZIPFileReader {
        try ZIPFileReader(duplicating: fd, url: url, validatesPath: false)
    }
    static func hash(_ reader: any ZIPPositionalReading) throws -> Data {
        var hash = SHA256(), position: UInt64 = 0
        while position < reader.length {
            let count = Int(min(65_536, reader.length - position))
            let bytes = try reader.read(offset: position, count: count)
            guard bytes.count == count else { throw ZIPListingError.changed }
            hash.update(data: bytes); position += UInt64(bytes.count)
        }
        try reader.validateUnchanged(); return Data(hash.finalize())
    }
}
