import AppKit
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite(.serialized)
struct OneDriveRetentionTests {
    @Test func verifiedActionStatusBindsRawVersionAndCapturedRoute() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let outcome = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        let proof = try #require(outcome.verifiedStatus)
        #expect(proof.matches(fixture.entry))
        #expect(proof.sampledVersion == fixture.entry.item.statusVersion)
        #expect(proof.policy == .pinned && proof.isDataless == false)
        let redirected = TransferEntry(source: FileOperationContext(directoryURL: fixture.folder.appendingPathComponent("other"),
            directoryIdentity: fixture.entry.source.directoryIdentity), item: fixture.entry.item)
        #expect(!proof.matches(redirected))
        let stamp = try #require(fixture.entry.item.statusVersion)
        let changed = Self.replacingStamp(fixture.entry, with: .init(size: stamp.size,
            modificationSeconds: stamp.modificationSeconds, modificationNanoseconds: stamp.modificationNanoseconds + 1))
        #expect(!proof.matches(changed))
        #expect(!proof.matches(Self.replacingStamp(fixture.entry, with: nil)))
    }

    @Test(arguments: ["missing", "contents", "nanosecond"])
    func explicitAdmissionIsUnchangedWhenListedStampCannotSeed(change: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        var entry = fixture.entry
        if change == "missing" { entry = Self.replacingStamp(entry, with: nil) }
        if change == "contents" { try Data("new synthetic bytes with another size".utf8).write(to: fixture.file) }
        if change == "nanosecond" {
            var raw = stat()
            try #require(lstat(fixture.file.path, &raw) == 0)
            var times = [raw.st_atimespec, raw.st_mtimespec]
            times[1].tv_nsec = (times[1].tv_nsec + 1) % 1_000_000_000
            try #require(fixture.file.withUnsafeFileSystemRepresentation { utimensat(AT_FDCWD, $0!, &times, 0) } == 0)
        }
        #expect(try LocalFileIdentity.read(at: fixture.file, ifLocal: true) == entry.item.identity)
        let outcome = try await fixture.service(state).perform(.keep, on: entry, control: TransferControl())
        #expect(outcome.isConfirmed && outcome.policy == .pinned)
        #expect(state.commands == [.query, .keep, .query])
        #expect(outcome.verifiedStatus == nil, "A display optimization must not silently change mutation admission")
    }

    @Test func finalDeferredFreeSeedsOnlyVerifiedResidentUnpinnedFacts() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = { throw POSIXError(.EBUSY) }
        let outcome = try await fixture.service(state, retryWait: { _, _, _ in })
            .perform(.freeSpace, on: fixture.entry, control: TransferControl())
        let proof = try #require(outcome.verifiedStatus)
        #expect(outcome.removalDeferred && !outcome.isConfirmed)
        #expect(proof.matches(fixture.entry) && proof.policy == .unpinned && proof.isDataless == false)
    }

    @Test func uncertainOutcomeOrNativeResidencyDisagreementNeverSeeds() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.ignoreSetter = true
        let uncertain = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!uncertain.isConfirmed && uncertain.verifiedStatus == nil)
        state.ignoreSetter = false; state.dataless = true
        let disagrees = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(disagrees.isConfirmed && disagrees.isDataless == true)
        #expect(disagrees.verifiedStatus == nil, "An injected inspection flag cannot override the final raw native sample")
        let loose = OneDriveRetentionOutcome(policy: .pinned, isDataless: false,
            providerVersion: "synthetic", isConfirmed: true, message: "confirmed fields alone")
        #expect(loose.verifiedStatus == nil)
    }

    @Test func passiveQueryWithoutRawStampStartsNoProvider() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        await #expect(throws: OneDriveBadgeReadError.staleTarget) {
            try await fixture.service(state).badgeObservation(for: Self.replacingStamp(fixture.entry, with: nil))
        }
        #expect(state.commands.isEmpty)
    }

    private static func replacingStamp(_ entry: TransferEntry, with stamp: LocalFileStatusVersion?) -> TransferEntry {
        let item = entry.item
        return TransferEntry(source: entry.source, item: FileItem(url: item.url, name: item.name,
            isDirectory: item.isDirectory, isSymbolicLink: item.isSymbolicLink, size: item.size,
            modifiedAt: item.modifiedAt, kind: item.kind, identity: item.identity,
            archiveRevision: item.archiveRevision, availability: item.availability,
            isRegularFile: item.isRegularFile, statusVersion: stamp))
    }

    @Test func passiveQueryRejectsContentChangedSinceListingBeforeNativeAdmission() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let listed = LocalDirectoryLoader.sample(for: fixture.file, displayedIn: fixture.folder,
            supportsLocalIdentity: true, cloudMembership: { _ in true }).item
        let entry = TransferEntry(source: fixture.entry.source, item: listed)
        try Data("changed synthetic payload with a different size".utf8).write(to: fixture.file)
        #expect(try LocalFileIdentity.read(at: fixture.file, ifLocal: true) == listed.identity)
        await #expect(throws: OneDriveBadgeReadError.staleTarget) {
            try await fixture.service(state).badgeObservation(for: entry)
        }
        #expect(state.commands.isEmpty, "A listed-version mismatch needs no provider process")
    }

    @Test func runningFreeRepeatsDefiniteBusyEvictionWithoutRepeatingUnpin() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = {
            if state.evictionCount == 1 { throw POSIXError(.EBUSY) }
        }
        let started = ContinuousClock.now
        let outcome = try await fixture.service(state, timeout: 10).perform(
            .freeSpace, on: fixture.entry, control: TransferControl())
        #expect(outcome.isConfirmed && outcome.mode == .running && outcome.isDataless == true)
        #expect(outcome.policy == OneDriveRetentionPolicy.unpinned)
        #expect(state.evictionCount == 2)
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
        #expect(state.operationEvents == ["/getpin", "/unpin", "/getpin", "evict",
                                          "/getpin", "evict", "/getpin"])
        #expect(ContinuousClock.now - started >= .milliseconds(1_800))
        #expect(try Data(contentsOf: fixture.file) == Data("owned synthetic payload".utf8))
    }

    @Test func evictionBusyClassifierAcceptsOnlyTheApprovedSingleCauseShapes() {
        let busy = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        func cocoa(_ info: [String: Any] = [:]) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileLockingError, userInfo: info)
        }
        let accepted: [NSError] = [busy, cocoa(), cocoa([NSUnderlyingErrorKey: busy])]
        for error in accepted { #expect(OneDriveEvictionFailure(error).isRetryable) }
        let refused: [NSError] = [
            denied, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError),
            NSError(domain: "private provider/path", code: Int(EBUSY)),
            cocoa([NSUnderlyingErrorKey: denied]),
            cocoa([NSUnderlyingErrorKey: "not an error"]),
            cocoa([NSUnderlyingErrorKey: cocoa([NSUnderlyingErrorKey: busy])]),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: [NSUnderlyingErrorKey: busy]),
            cocoa([NSMultipleUnderlyingErrorsKey: []]),
            cocoa([NSMultipleUnderlyingErrorsKey: [busy]]),
            cocoa([NSMultipleUnderlyingErrorsKey: [busy, denied]]),
            cocoa([NSUnderlyingErrorKey: busy, NSMultipleUnderlyingErrorsKey: [busy]]),
            cocoa([NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY),
                                                userInfo: [NSMultipleUnderlyingErrorsKey: [denied]])])
        ]
        for error in refused { #expect(!OneDriveEvictionFailure(error).isRetryable) }
        let secret = NSError(domain: "private provider/path", code: 999, userInfo: [
            NSLocalizedDescriptionKey: "private content", NSFilePathErrorKey: "/private/file"])
        #expect(OneDriveEvictionFailure(cocoa([NSUnderlyingErrorKey: secret])).diagnostic ==
                "chain=cocoa:255>other:999 singleCause=true retryable=false")
        #expect(OneDriveEvictionFailure(cocoa([NSUnderlyingErrorKey: busy])).diagnostic ==
                "chain=cocoa:255>posix:16 singleCause=true retryable=true")
        #expect(OneDriveEvictionFailure.retryDelays == [2, 6])
    }

    @Test(arguments: [false, true])
    func busyEvictionUsesAtMostThreeCallsAndKeepsTheOriginalUnpin(succeedsOnThird: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = {
            if !succeedsOnThird || state.evictionCount < 3 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileLockingError,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.EBUSY)])
            }
        }
        let result = try await fixture.service(state, retryWait: { seconds, attempt, control in
            state.recordRetryWait(seconds); try attempt.checkpoint(control)
        }).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(state.retryWaits == [2, 6] && state.evictionCount == 3)
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
        #expect(result.isConfirmed == succeedsOnThird)
        #expect(result.removalDeferred == !succeedsOnThird)
        if succeedsOnThird {
            #expect(result.policy == .unpinned && result.isDataless == true)
        } else {
            #expect(result.policy == .unpinned && result.isDataless == false)
            #expect(result.message.contains("OneDrive may finish removing the local copy in the background."))
        }
        #expect(state.operationEvents == ["/getpin", "/unpin", "/getpin", "evict", "/getpin", "evict", "/getpin", "evict", "/getpin"])
    }

    @Test(arguments: ["dataless", "repinned", "unrecognized", "previously-unpinned"])
    func finalBusyReadbackCanObserveEvictionOrChangedPolicy(change: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true
        state.policy = change == "previously-unpinned" ? "Unpinned" : "Pinned"
        state.duringEviction = {
            if state.evictionCount == 3 {
                switch change {
                case "dataless": state.dataless = true
                case "repinned": state.policy = "Pinned"
                case "unrecognized": state.queryOverride = TestRetentionState.query("Unrecognized")
                default: break
                }
            }
            throw POSIXError(.EBUSY)
        }
        let result = try await fixture.service(state, retryWait: { _, _, _ in })
            .perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(state.evictionCount == 3)
        #expect(state.commands.filter { $0 == .freeSpace }.count == (change == "previously-unpinned" ? 0 : 1))
        #expect(result.isConfirmed == (change == "dataless"))
        #expect(!result.removalDeferred)
        switch change {
        case "dataless": #expect(result.policy == .unpinned && result.isDataless == true)
        case "repinned": #expect(result.policy == .pinned)
        case "previously-unpinned": #expect(!result.message.contains("Close applications"))
        default: #expect(result.policy == nil)
        }
    }

    @Test(arguments: ["unrelated", "contradictory", "success-resident", "success-unknown"])
    func uncertainOrSuccessfulEvictionNeverEntersBusyRetry(resultKind: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = {
            if resultKind == "unrelated" { throw POSIXError(.EACCES) }
            if resultKind == "contradictory" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileLockingError,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
            }
        }
        state.evictionBecomesDataless = false
        if resultKind == "success-unknown" {
            state.afterEviction = { state.queryOverride = TestRetentionState.query("Unrecognized") }
        }
        let result = try await fixture.service(state, retryWait: { seconds, _, _ in state.recordRetryWait(seconds) })
            .perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && !result.removalDeferred)
        #expect(state.evictionCount == 1 && state.retryWaits.isEmpty)
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
        #expect(result.message.contains("OneDrive confirmed the file’s unpinned policy."))
    }

    @Test(arguments: ["dataless", "repinned", "none-policy", "unknown-policy", "replacement", "parent", "contents", "mode",
                       "content-use", "upload", "signature", "stopped", "unknown"])
    func busyRetryRevalidatesAllPreconditionsAfterItsWait(change: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let activity = RetentionTestActivity(fixture.file)
        defer { activity.end() }
        state.running = true; state.policy = "Pinned"
        state.duringEviction = { throw POSIXError(.EBUSY) }
        let result = try await fixture.service(state, retryWait: { seconds, attempt, control in
            state.recordRetryWait(seconds)
            switch change {
            case "dataless": state.dataless = true
            case "repinned": state.policy = "Pinned"
            case "none-policy": state.policy = "None"
            case "unknown-policy": state.queryOverride = TestRetentionState.query("Unrecognized")
            case "replacement": try fixture.replaceLeaf()
            case "parent": try fixture.replaceParent()
            case "contents": try Data("OWNED synthetic payload".utf8).write(to: fixture.file)
            case "mode":
                var value = stat()
                guard lstat(fixture.file.path, &value) == 0,
                      chmod(fixture.file.path, value.st_mode ^ mode_t(S_IXUSR)) == 0 else {
                    throw OneDriveRetentionError.staleTarget
                }
            case "content-use": activity.begin()
            case "upload": state.uploaded = false
            case "signature": state.untrusted = true
            case "stopped": state.running = false
            default: state.unknown = true
            }
            try attempt.checkpoint(control)
        }).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(state.retryWaits == [2] && state.evictionCount == 1)
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
        #expect(result.isConfirmed == (change == "dataless"))
        if change == "dataless" {
            #expect(result.policy == OneDriveRetentionPolicy.unpinned && result.isDataless == true)
        } else if change == "repinned" {
            #expect(result.policy == .pinned && result.isDataless == false)
            #expect(result.message.contains("pinned again"))
        } else if change == "none-policy" {
            #expect(result.policy == OneDriveRetentionPolicy.none && result.isDataless == false)
            #expect(result.message.contains("OneDrive confirmed the file’s unpinned policy."))
        } else {
            #expect(result.policy == nil && result.isDataless == nil)
            #expect(result.message.contains("OneDrive confirmed the file’s unpinned policy."))
            if change == "upload" {
                #expect(result.message.contains("No further local-removal request was made"))
                #expect(!result.message.contains("No local removal was attempted"))
            }
        }
    }

    @Test(arguments: [1, 2], [false, true])
    func cancellationOrDeadlineDuringEachBusyWaitStopsLaterCalls(waitNumber: Int, cancel: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let control = TransferControl()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = { throw POSIXError(.EBUSY) }
        let service = fixture.service(state, timeout: cancel ? 10 : (waitNumber == 1 ? 1 : 3),
            retryWait: { seconds, attempt, control in
                state.recordRetryWait(seconds)
                try attempt.waitAfterBusy(seconds: seconds, control: control)
            })
        let task = Task { try await service.perform(.freeSpace, on: fixture.entry, control: control) }
        defer { task.cancel(); control.cancel() }
        try await waitUntil { state.retryWaits.count == waitNumber }
        #expect(service.isBusy)
        await #expect(throws: OneDriveRetentionError.busy) {
            try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        }
        await #expect(throws: OneDriveBadgeReadError.busy) { try await service.badgeObservation(for: fixture.entry) }
        if cancel { task.cancel() }
        await #expect(throws: cancel ? OneDriveRetentionError.cancelledAfterClear
                                    : OneDriveRetentionError.timedOutAfterClear) { try await task.value }
        try await waitUntil { !service.isBusy }
        #expect(state.evictionCount == waitNumber && state.retryWaits.count == waitNumber)
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
        #expect(state.commands.filter { $0 == .query }.count == waitNumber + 1)
        #expect(try Data(contentsOf: fixture.file) == Data("owned synthetic payload".utf8))
    }

    @Test func runningKeepUsesTrustedCommandAndConfirmsOriginalTarget() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true
        let result = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.policy == .pinned && result.isDataless == false)
        #expect(state.commands == [.query, .keep, .query])
        #expect(try Data(contentsOf: fixture.file) == Data("owned synthetic payload".utf8))
    }

    @Test func runningKeepReplacementStopsWithoutAdoptingTheNewFile() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true
        state.afterCommand = { command in if command == .keep { try fixture.replaceLeaf() } }
        let result = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && result.policy == nil && result.isDataless == nil)
        #expect(result.message.localizedCaseInsensitiveContains("submitted"))
        #expect(state.commands == [.query, .keep])
        #expect(try Data(contentsOf: fixture.file) == Data("replacement".utf8))
    }

    @Test func runningKeepAlreadyPinnedDoesNotSubmitAgain() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        let result = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.mode == .running && result.policy == .pinned)
        #expect(state.commands == [.query] && state.evictionCount == 0)
    }

    @Test(arguments: ["Pinned", "None", "Unpinned"], [false, true])
    func runningFreeOrdersOnlyNecessaryPhases(policy: String, dataless: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = policy; state.dataless = dataless
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.mode == .running && result.isDataless == true)
        #expect(result.policy == (policy == "None" && dataless ? OneDriveRetentionPolicy.none : .unpinned))
        var expected = ["/getpin"]
        let needsUnpin = policy == "Pinned" || (policy == "None" && !dataless)
        if needsUnpin { expected += ["/unpin", "/getpin"] }
        if !dataless { expected += ["evict", "/getpin"] }
        #expect(state.operationEvents == expected)
        #expect(state.commands.filter { $0 == .freeSpace }.count == (needsUnpin ? 1 : 0))
    }

    @Test(arguments: ["Pinned", "None"])
    func runningFreeUnpinCanCompleteLocalRemovalWithoutFoundation(initial: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = initial
        state.afterCommand = { command in if command == .freeSpace { state.dataless = true } }
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.policy == .unpinned && result.isDataless == true)
        #expect(state.commands == [.query, .freeSpace, .query])
        #expect(state.evictionCount == 0 && state.retryWaits.isEmpty)
    }

    @Test(arguments: ["during-failing-call", "before-wait-returns"])
    func providerCompletionDuringBusyFallbackPreventsDuplicateEviction(completionPoint: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.duringEviction = {
            if completionPoint == "during-failing-call" { state.dataless = true }
            throw POSIXError(.EBUSY)
        }
        let result = try await fixture.service(state, retryWait: { seconds, attempt, control in
            state.recordRetryWait(seconds)
            if completionPoint == "before-wait-returns" { state.dataless = true }
            try attempt.checkpoint(control)
        }).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.policy == .unpinned && result.isDataless == true)
        #expect(state.evictionCount == 1 && state.retryWaits == [2])
        #expect(state.operationEvents == ["/getpin", "/unpin", "/getpin", "evict", "/getpin"])
    }

    @Test(arguments: ["Pinned", "None", "Unpinned"], [false, true])
    func freshUploadInspectionCanObserveProviderCompletionBeforeEviction(initial: String, afterBusy: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = initial
        state.beforeInspection = { needsUpload in
            let unpinWasObserved = initial == "Unpinned" || state.commands.contains(.freeSpace)
            if needsUpload && unpinWasObserved && (!afterBusy || state.evictionCount == 1) {
                state.dataless = true
            }
        }
        if afterBusy { state.duringEviction = { throw POSIXError(.EBUSY) } }
        let result = try await fixture.service(state, retryWait: { seconds, attempt, control in
            state.recordRetryWait(seconds); try attempt.checkpoint(control)
        }).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed && result.policy == .unpinned && result.isDataless == true)
        #expect(state.evictionCount == (afterBusy ? 1 : 0))
        #expect(state.retryWaits == (afterBusy ? [2] : []))
        #expect(state.commands.filter { $0 == .freeSpace }.count == (initial == "Unpinned" ? 0 : 1))
    }

    @Test(arguments: ["None", "Pinned", "Unpinned"], [false, true])
    func runningFreeRequiresObservedDatalessAfterEviction(policy: String, dataless: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.evictionPolicy = policy; state.evictionBecomesDataless = dataless
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(result.isConfirmed == (policy == "Unpinned" && dataless) && result.isDataless == dataless)
        #expect(result.policy?.rawValue == policy.lowercased())
        #expect(state.evictionCount == 1)
    }

    @Test(arguments: ["Pinned", "None"], [false, true])
    func runningFreeRejectsUnsafeUploadBeforeUnpinning(policy: String, dataless: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = policy; state.dataless = dataless; state.uploaded = false
        if policy == "None" && dataless {
            let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
            #expect(result.isConfirmed && result.policy == OneDriveRetentionPolicy.none && result.isDataless == true)
            #expect(state.commands == [.query] && state.evictionCount == 0)
            return
        }
        await #expect(throws: OneDriveRetentionError.uploadUnconfirmed) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands == [.query] && state.evictionCount == 0)
    }

    @Test(arguments: ["Pinned", "None"], ["rejected", "unknown-setter", "none-readback", "pinned-readback", "unknown-readback"])
    func runningFreeUncertainUnpinNeverEvicts(initial: String, refusal: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = initial
        switch refusal {
        case "rejected":
            state.setterOverride = .init(exitCode: 0, stdout: Data(), stderr: Data("Failed operation=3\n".utf8))
        case "unknown-setter": state.setterOverride = TestRetentionState.query("Unpinned")
        default:
            state.afterCommand = { command in
                guard command == .freeSpace else { return }
                switch refusal {
                case "none-readback": state.policy = "None"
                case "pinned-readback": state.policy = "Pinned"
                default: state.queryOverride = TestRetentionState.query("Unrecognized")
                }
            }
        }
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && state.evictionCount == 0)
        let accepted = refusal != "rejected" && refusal != "unknown-setter"
        #expect(state.commands == (accepted ? [.query, .freeSpace, .query] : [.query, .freeSpace]))
        #expect(!result.message.contains("OneDrive confirmed the file’s unpinned policy."))
        #expect(!result.message.contains("No local removal was attempted"))
    }

    @Test(arguments: ["replacement", "contents", "mode", "content-use", "upload", "stopped", "unknown"])
    func runningFreeStopsWhenUnpinChangesItsPreconditions(change: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let actualActivity = RetentionTestActivity(fixture.file)
        defer { actualActivity.end() }
        state.running = true; state.policy = "Pinned"
        state.afterCommand = { command in
            guard command == .freeSpace else { return }
            switch change {
            case "replacement": try fixture.replaceLeaf()
            case "contents": try Data("OWNED synthetic payload".utf8).write(to: fixture.file)
            case "mode":
                var value = stat()
                guard lstat(fixture.file.path, &value) == 0,
                      chmod(fixture.file.path, value.st_mode ^ mode_t(S_IXUSR)) == 0 else {
                    throw OneDriveRetentionError.staleTarget
                }
            case "content-use": actualActivity.begin()
            case "upload": state.uploaded = false
            case "stopped": state.running = false
            default: state.unknown = true
            }
        }
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && state.evictionCount == 0)
        #expect(result.policy == nil && result.isDataless == nil)
        if change == "upload" {
            #expect(result.message.contains("OneDrive confirmed the file’s unpinned policy."))
            #expect(result.message.contains("No additional local-removal request was made"))
            #expect(!result.message.contains("No retention change was submitted"))
        }
    }

    @Test(arguments: ["throw", "replacement", "mode-drift", "unknown", "pinned-readback"])
    func runningFreePreservesVerifiedUnpinnedPolicyAfterEvictionFailure(change: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.policy = "Pinned"
        state.afterEviction = {
            switch change {
            case "throw": throw OneDriveRetentionError.providerRejected
            case "replacement": try fixture.replaceLeaf()
            case "mode-drift": state.running = false
            case "unknown": state.unknown = true
            default: state.policy = "Pinned"
            }
        }
        let result = try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && state.evictionCount == 1)
        #expect(result.message.contains("OneDrive confirmed the file’s unpinned policy."))
        if change != "pinned-readback" { #expect(result.policy == nil && result.isDataless == nil) }
        #expect(state.commands.filter { $0 == .freeSpace }.count == 1)
    }

    @Test(arguments: ["Pinned", "None"], [false, true])
    func stalledEvictionRetainsOwnershipAfterCallerStops(initial: String, cancel: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), gate = RetentionTestGate()
        state.running = true; state.policy = initial; state.duringEviction = { gate.wait() }
        let slot = OneDriveRetentionSlot()
        let service = fixture.service(state, slot: slot, timeout: cancel ? 3 : 1)
        let control = TransferControl()
        let task = Task { try await service.perform(.freeSpace, on: fixture.entry, control: control) }
        defer { gate.release(); control.cancel(); task.cancel() }
        try await waitUntil { gate.hasEntered }
        if cancel { task.cancel() }
        let expectedError = cancel ? OneDriveRetentionError.cancelledAfterClear : .timedOutAfterClear
        await #expect(throws: expectedError) { try await task.value }
        #expect(expectedError.localizedDescription.contains("OneDrive confirmed the file’s unpinned policy."))
        #expect(!expectedError.localizedDescription.contains("Offline retention was cleared"))
        #expect(service.isBusy && !gate.isReleased && state.evictionCount == 1)
        await #expect(throws: OneDriveRetentionError.busy) {
            try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        }
        await #expect(throws: OneDriveBadgeReadError.busy) { try await service.badgeObservation(for: fixture.entry) }
        #expect(state.commands == [.query, .freeSpace, .query])
        gate.release()
        try await waitUntil { !service.isBusy }
        #expect(state.evictionCount == 1 && state.commands == [.query, .freeSpace, .query])
        _ = try await service.badgeObservation(for: fixture.entry)
        _ = try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!service.isBusy)
    }

    @Test func cancellationAfterUnpinPreventsEvictionAndKeepsSubmissionFact() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), control = TransferControl()
        state.running = true; state.policy = "Pinned"
        state.afterCommand = { command in if command == .freeSpace { control.cancel() } }
        await #expect(throws: OneDriveRetentionError.cancelled(setterSubmitted: true)) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: control)
        }
        #expect(state.commands == [.query, .freeSpace] && state.evictionCount == 0)
    }

    @Test func cancellationAfterEvictionReturnsNeverQueriesOrClaimsConfirmation() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), control = TransferControl()
        state.running = true; state.policy = "Pinned"
        state.afterEviction = { control.cancel() }
        await #expect(throws: OneDriveRetentionError.cancelledAfterClear) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: control)
        }
        #expect(state.commands == [.query, .freeSpace, .query] && state.evictionCount == 1)
    }

    @Test func submissionIsStickyAcrossLaterLaunchFailureAndThrowingEviction() throws {
        let control = TransferControl(), attempt = OneDriveRetentionAttempt(control: control)
        #expect(throws: OneDriveRetentionError.providerRejected) {
            try attempt.submit(.freeSpace, control: control) { throw OneDriveRetentionError.providerRejected }
        }
        #expect(!attempt.setterSubmitted)
        try attempt.submit(.freeSpace, control: control) {}
        #expect(throws: OneDriveRetentionError.providerRejected) {
            try attempt.submit(.keep, control: control) { throw OneDriveRetentionError.providerRejected }
        }
        #expect(attempt.setterSubmitted)
        let fresh = OneDriveRetentionAttempt(control: control)
        #expect(throws: OneDriveRetentionError.providerRejected) {
            try fresh.submitEviction(control: control) { throw OneDriveRetentionError.providerRejected }
        }
        #expect(fresh.setterSubmitted)
    }

    @Test func explicitBudgetExceedsTwentySecondsWithoutChangingPassiveBudget() {
        #expect(OneDriveRetentionAttempt.boundedTimeout(45) == 45)
        #expect(OneDriveRetentionAttempt.boundedTimeout(60) == 60)
        #expect(OneDriveRetentionAttempt.boundedTimeout(100) == 60)
        #expect(OneDriveRetentionAttempt.boundedTimeout(10) == 10)
        #expect(OneDriveRetentionAttempt.boundedTimeout(0.05) == 0.05)
    }

    @Test(arguments: ["None", "Pinned", "Unpinned"])
    func badgeQueryWorksWithRunningSyncWithoutUploadOrMutation(policy: String) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.running = true; state.uploaded = false; state.forbidInspection = true
        state.dataless = true // Passive residency must come from actual lstat, not this action seam.
        state.queryOverride = TestRetentionState.query(policy)
        let service = fixture.service(state)
        let result = try await service.badgeObservation(for: fixture.entry)
        #expect(result.policy.rawValue == policy.lowercased())
        #expect(!result.isDataless)
        #expect(state.commands == [.query])
        #expect(!service.isBusy)
        #expect(try Data(contentsOf: fixture.file) == Data("owned synthetic payload".utf8))
    }

    @Test func historyNamespaceRequiresThePhysicalRootAndCurrentTrustedProvider() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), service = fixture.service(state)
        let root = try #require(OneDriveRetentionService.accountRoot(in: fixture.folder, homeURL: fixture.home))
        let initial = try #require(await service.policyHistoryNamespace(for: root))
        #expect(initial.root == root)
        #expect(initial.identity == (try LocalFileIdentity.read(at: root, ifLocal: true)))
        #expect(initial.providerIdentifier == "com.microsoft.OneDrive")
        #expect(await service.policyHistoryNamespace(for: fixture.folder) == nil)
        state.signingStamp = "updated provider"
        let updated = try #require(await service.policyHistoryNamespace(for: root))
        #expect(initial.providerStamp != updated.providerStamp)
        state.signingStamp = "untrusted"; state.untrusted = true
        #expect(await service.policyHistoryNamespace(for: root) == nil)
        let other = root.deletingLastPathComponent().appendingPathComponent("OneDrive-Other", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: root)
        state.signingStamp = "trusted"; state.untrusted = false
        #expect(await service.policyHistoryNamespace(for: other) == nil)
        #expect(state.commands.isEmpty)
    }

    @Test func passiveTrustCacheRevalidatesChangedInputsButNeverAuthorizesMutation() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), service = fixture.service(state)
        _ = try await service.badgeObservation(for: fixture.entry)
        _ = try await service.badgeObservation(for: fixture.entry)
        #expect(state.verifications == 1)
        state.signingStamp = "replacement signing resources"
        _ = try await service.badgeObservation(for: fixture.entry)
        #expect(state.verifications == 2)
        _ = try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(state.verifications == 6) // initial + each of query/setter/readback, all strict.
        state.signingStamp = "untrusted replacement"; state.untrusted = true
        await #expect(throws: OneDriveBadgeReadError.installationUntrusted) {
            try await service.badgeObservation(for: fixture.entry)
        }
        let count = state.commands.count
        state.untrusted = false
        _ = try await service.badgeObservation(for: fixture.entry)
        #expect(state.verifications == 8 && state.commands.count == count + 1)
    }

    @Test func itemRejectionAndUnknownProtocolHaveDistinctPassiveOutcomes() async throws {
        let fixture = try RetentionFixture()
        let unsupported = TestRetentionState.query("UnknownPolicy")
        let rejected = OneDriveRetentionTranscript(exitCode: 0, stdout: Data(), stderr: Data("no configured scope owns path".utf8))
        for (transcript, reason) in [(unsupported, OneDriveBadgeReadError.incompatibleResponse), (rejected, .itemRejected)] {
            let state = TestRetentionState()
            state.queryOverride = transcript
            await #expect(throws: reason) { try await fixture.service(state).badgeObservation(for: fixture.entry) }
        }
        #expect(OneDriveBadgeReadError.classify(FileOperationError.systemFailure(operation: "stat", code: EACCES)) == .itemUnavailable)
        #expect(OneDriveBadgeReadError.classify(FileOperationError.staleParent) == .staleTarget)
    }

    @Test func passiveQueryDiscardsChangedSigningInputsAndUnfamiliarProviderOutput() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.afterCommand = { _ in state.signingStamp = "changed during child" }
        await #expect(throws: OneDriveBadgeReadError.installationUntrusted) {
            try await fixture.service(state).badgeObservation(for: fixture.entry)
        }
        #expect(state.commands == [.query])
        let contradictory = OneDriveRetentionTranscript(exitCode: 1, stdout: Data(),
            stderr: TestRetentionState.query("Pinned").stderr + Data(TestRetentionState.line("pin state=None").utf8))
        let partial = OneDriveRetentionTranscript(exitCode: 1, stdout: Data(),
            stderr: TestRetentionState.query("Pinned").stderr, truncated: true)
        for transcript in [TestRetentionState.query("FuturePolicy"), contradictory, partial] {
            let unknown = TestRetentionState(); unknown.queryOverride = transcript
            await #expect(throws: OneDriveBadgeReadError.incompatibleResponse) {
                try await fixture.service(unknown).badgeObservation(for: fixture.entry)
            }
            #expect(unknown.commands == [.query])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func passiveQueryRefusesStaleLeafAndParent(parent: Bool, afterQuery: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let replace: @Sendable () throws -> Void = {
            if parent { try fixture.replaceParent() } else { try fixture.replaceLeaf() }
        }
        if afterQuery { state.afterCommand = { _ in try replace() } } else { try replace() }
        await #expect(throws: OneDriveBadgeReadError.staleTarget) {
            try await fixture.service(state).badgeObservation(for: fixture.entry)
        }
        #expect(state.commands == (afterQuery ? [.query] : []))
    }

    @Test func foregroundActionHasPriorityOverFurtherPassiveQueries() async throws {
        let fixture = try RetentionFixture(), passive = TestRetentionState(), active = TestRetentionState()
        let slot = OneDriveRetentionSlot(), gate = RetentionTestGate()
        passive.afterCommand = { _ in gate.wait() }
        let first = fixture.service(passive, slot: slot), second = fixture.service(active, slot: slot)
        let query = Task { try await first.badgeObservation(for: fixture.entry) }
        defer { gate.release(); query.cancel() }
        try await waitUntil { gate.hasEntered }
        #expect(!first.isBusy) // The menu may accept an explicit intent while passive work owns the child.
        let action = Task { try await second.perform(.keep, on: fixture.entry, control: TransferControl()) }
        defer { action.cancel() }
        try await waitUntil { second.isBusy }
        await #expect(throws: OneDriveBadgeReadError.busy) {
            try await first.badgeObservation(for: fixture.entry)
        }
        #expect(active.commands.isEmpty)
        gate.release()
        _ = try await query.value
        let outcome = try await action.value
        #expect(outcome.isConfirmed && active.commands == [.query, .keep, .query])
        #expect(!first.isBusy)
    }

    @Test(arguments: [false, true])
    func abandonedPassiveWaitRetainsNativeOwnerAndBoundsForegroundWait(cancel: Bool) async throws {
        let fixture = try RetentionFixture(), passive = TestRetentionState(), active = TestRetentionState()
        let slot = OneDriveRetentionSlot(), gate = RetentionTestGate()
        passive.afterCommand = { _ in slot.child(987654, started: true); gate.wait() }
        let first = fixture.service(passive, slot: slot, passiveTimeout: cancel ? 3 : 0.15)
        let second = fixture.service(active, slot: slot, priorityWait: 0.1)
        let query = Task { try await first.badgeObservation(for: fixture.entry) }
        defer { gate.release(); query.cancel() }
        try await waitUntil { gate.hasEntered }
        if cancel { query.cancel() }
        if cancel {
            await #expect(throws: CancellationError.self) { try await query.value }
        } else {
            await #expect(throws: OneDriveBadgeReadError.timedOut) { try await query.value }
        }
        #expect(slot.ownedPIDs == [987654] && !first.isBusy)
        await #expect(throws: OneDriveBadgeReadError.busy) {
            try await first.badgeObservation(for: fixture.entry)
        }
        await #expect(throws: OneDriveRetentionError.busy) {
            try await second.perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(!second.isBusy && active.commands.isEmpty && slot.ownedPIDs == [987654])
        #expect(OneDriveRetentionError.busy.localizedDescription.contains("Finder"))
        gate.release()
        try await waitUntil { slot.ownedPIDs.isEmpty }
        _ = try await second.badgeObservation(for: fixture.entry)
        #expect(active.commands == [.query])
    }

    @Test func cancellingQueuedForegroundActionNeverSubmitsItLater() async throws {
        let fixture = try RetentionFixture(), passive = TestRetentionState(), active = TestRetentionState()
        let slot = OneDriveRetentionSlot(), gate = RetentionTestGate()
        passive.afterCommand = { _ in gate.wait() }
        let first = fixture.service(passive, slot: slot), second = fixture.service(active, slot: slot)
        let query = Task { try await first.badgeObservation(for: fixture.entry) }
        defer { gate.release(); query.cancel() }
        try await waitUntil { gate.hasEntered }
        let action = Task { try await second.perform(.keep, on: fixture.entry, control: TransferControl()) }
        try await waitUntil { second.isBusy }
        action.cancel()
        await #expect(throws: OneDriveRetentionError.cancelled(setterSubmitted: false)) { try await action.value }
        try await waitUntil { !second.isBusy }
        gate.release(); _ = try await query.value
        #expect(active.commands.isEmpty)
    }

    @Test func unresolvedOwnedLaunchNeverReportsProofOfStoppedSync() throws {
        let fixture = try RetentionFixture(), slot = OneDriveRetentionSlot()
        let service = fixture.service(TestRetentionState(), slot: slot)
        slot.beginLaunch()
        #expect(service.syncState == .unknown)
        slot.child(987654, started: true); slot.endLaunch()
        #expect(service.syncState == .stopped)
        slot.child(987654, started: false)
    }

    @Test func transcriptRequiresExactObservedGrammarAndNotExitCodeAlone() {
        for (text, expected) in [("None", OneDriveRetentionPolicy.none), ("Pinned", .pinned), ("Unpinned", .unpinned)] {
            #expect(OneDriveRetentionTranscript.query(TestRetentionState.query(text)) == .policy(expected))
        }
        #expect(OneDriveRetentionTranscript.setter(TestRetentionState.setter) == .accepted)
        #expect(OneDriveRetentionTranscript.query(.init(exitCode: 0, stdout: Data(), stderr: Data(
            "2026-11-20 17:49:58.321 OneDrive[10125:44379581] Pin command: no configured scope owns path=system://tmp/control\n".utf8))) == .rejected)
        let valid = TestRetentionState.query("Pinned")
        #expect(OneDriveRetentionTranscript.query(.init(exitCode: 0, stdout: valid.stdout, stderr: valid.stderr)) == .unknown)
        #expect(OneDriveRetentionTranscript.query(.init(exitCode: 1, stdout: Data("unexpected".utf8), stderr: valid.stderr)) == .unknown)
        #expect(OneDriveRetentionTranscript.query(.init(exitCode: 1, stdout: Data(), stderr: valid.stderr, truncated: true)) == .unknown)
        for text in ["FuturePolicy", "Pinned\n", "Pinned\n" + TestRetentionState.line("pin state=Unpinned")] {
            #expect(OneDriveRetentionTranscript.query(TestRetentionState.query(text)) == .unknown)
        }
        #expect(OneDriveRetentionTranscript.setter(valid) == .unknown)
        #expect(OneDriveRetentionTranscript.setter(.init(exitCode: 1, stdout: Data(), stderr: Data())) == .unknown)
    }

    @Test(arguments: [OneDriveRetentionAction.keep, .freeSpace], [false, true])
    func policyAndResidencyRemainIndependent(action: OneDriveRetentionAction, dataless: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.dataless = dataless
        let service = fixture.service(state)
        let outcome = try await service.perform(action, on: fixture.entry, control: TransferControl())
        #expect(outcome.isConfirmed)
        #expect(outcome.policy == (action == .keep ? .pinned : .unpinned))
        #expect(outcome.isDataless == dataless)
        #expect(outcome.providerVersion == "26.212.1029 (26212.1029.0006)")
        #expect(state.commands == [.query, action == .keep ? .keep : .freeSpace, .query])
        #expect(!service.isBusy)
        #expect(try Data(contentsOf: fixture.file) == Data("owned synthetic payload".utf8))
    }

    @Test func noSetterForNegativeProviderOrUnconfirmedUpload() async throws {
        let fixture = try RetentionFixture(), negative = TestRetentionState()
        negative.queryOverride = .init(exitCode: 0, stdout: Data(), stderr: Data("Failed operation=3\n".utf8))
        await #expect(throws: OneDriveRetentionError.providerRejected) {
            try await fixture.service(negative).perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(negative.commands == [.query])
        let dirty = TestRetentionState(); dirty.uploaded = false
        await #expect(throws: OneDriveRetentionError.uploadUnconfirmed) {
            try await fixture.service(dirty).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(!dirty.commands.contains(.freeSpace))
    }

    @Test func uploadGateRequiresKnownSettledAndConflictFreeMetadata() {
        let good: [URLResourceKey: Any] = [.ubiquitousItemIsUploadedKey: NSNumber(value: true),
            .ubiquitousItemIsUploadingKey: NSNumber(value: false),
            .ubiquitousItemHasUnresolvedConflictsKey: NSNumber(value: false)]
        #expect(OneDriveRetentionObservation.uploadIsSafe(good))
        for key in good.keys {
            var absent = good; absent.removeValue(forKey: key)
            #expect(!OneDriveRetentionObservation.uploadIsSafe(absent))
        }
        for key in [URLResourceKey.ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey] {
            var pending = good; pending[key] = NSNumber(value: true)
            #expect(!OneDriveRetentionObservation.uploadIsSafe(pending))
        }
        for key in [URLResourceKey.ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey] {
            var failed = good; failed[key] = NSError(domain: "Synthetic", code: 1)
            #expect(!OneDriveRetentionObservation.uploadIsSafe(failed))
        }
    }

    @Test func unexpectedSetterOutputAndReadbackMismatchNeverConfirm() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.setterOverride = TestRetentionState.query("Pinned")
        let outcome = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!outcome.isConfirmed)
        #expect(state.commands == [.query, .keep])
        let mismatch = TestRetentionState(); mismatch.ignoreSetter = true
        let second = try await fixture.service(mismatch).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!second.isConfirmed && second.policy == .unpinned)
    }

    @Test func runningSyncIsAdmittedButUntrustedBinaryRefusesBeforeAnyProcess() async throws {
        let fixture = try RetentionFixture(), running = TestRetentionState(); running.running = true
        let outcome = try await fixture.service(running).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(outcome.isConfirmed && outcome.mode == .running)
        #expect(running.commands == [.query, .keep, .query])
        let unsigned = TestRetentionState(); unsigned.untrusted = true
        await #expect(throws: OneDriveRetentionError.untrustedApplication) {
            try await fixture.service(unsigned).perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(unsigned.commands.isEmpty)
    }

    @Test func liveGateFindsUnregisteredOneDriveProcessAndExcludesOnlyOwnedPIDs() async throws {
        let fixture = try RetentionFixture()
        // A copied system sleep executable creates the exact kernel name without
        // registering an app or calling, quitting, or modifying the real provider.
        let executable = fixture.home.appendingPathComponent("OneDrive")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let child = Process()
        child.executableURL = executable; child.arguments = ["2"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.waitUntilExit() }
        let childPID = child.processIdentifier
        let snapshot = try Self.currentUserProcesses()
        let childRecord = try #require(snapshot.first { $0.pid == childPID })
        try #require(childRecord.name == "OneDrive")
        let registered = ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        }
        try #require(!registered.contains(childPID))
        // Isolate this owned synthetic process from any real provider already
        // running. The production fallback must see it despite empty AppKit data.
        let ignored = Set(snapshot.map(\.pid).filter { $0 != childPID }).union(registered)
        #expect(OneDriveRetentionEnvironment.live.syncState(ignored) == .running)
        #expect(OneDriveRetentionEnvironment.live.syncState(ignored.union([childPID])) == .stopped)
        let state = TestRetentionState()
        let service = fixture.service(state, syncState: { owned in
            OneDriveRetentionEnvironment.live.syncState(ignored.union(owned))
        })
        let outcome = try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(outcome.mode == .running && outcome.isConfirmed)
        #expect(state.commands == [.query, .keep, .query])
        #expect(child.isRunning)
    }

    @Test func kernelCensusRequiresExactTerminatedNameAndCountsZombies() {
        for (bytes, expected) in [
            (Array("OneDrive\0".utf8), OneDriveSyncState.running),
            (Array("OneDriveX\0".utf8), .stopped),
            (Array("onedrive\0".utf8), .stopped),
            (Array("OneDrive".utf8) + [255], .stopped),
            (Array("OneDrive Finder\0".utf8), .stopped)
        ] {
            let record = RetentionCensusScript.record(pid: 123, name: bytes, zombie: true)
            let script = RetentionCensusScript(records: [record])
            #expect(script.census.state(excluding: []) == expected)
        }
        let owned = RetentionCensusScript.record(pid: 123, name: Array("OneDrive\0".utf8))
        #expect(RetentionCensusScript(records: [owned]).census.state(excluding: [123]) == .stopped)
        #expect(RetentionCensusScript(records: [owned]).census.state(excluding: [124]) == .running)
    }

    @Test func kernelCensusRejectsIncompleteAndOversizedSamplesWithinThreeAttempts() {
        let stride = MemoryLayout<kinfo_proc>.stride
        let ceiling = OneDriveProcessCensus.maximumRecords * stride
        let hint = RetentionCensusScript.Reply(error: 0, bytes: stride)
        for replies in [
            [.init(error: EACCES, bytes: 0)],
            [.init(error: 0, bytes: 0)],
            [.init(error: 0, bytes: stride + 1)],
            [.init(error: 0, bytes: ceiling + stride)],
            [hint, .init(error: 0, bytes: 1)],
            [hint, .init(error: 0, bytes: 0)],
            [hint, .init(error: 0, bytes: 66 * stride)],
            [hint, .init(error: EACCES, bytes: stride)]
        ] as [[RetentionCensusScript.Reply]] {
            let script = RetentionCensusScript(replies: replies)
            #expect(script.census.state(excluding: []) == .unknown)
            #expect(script.calls == replies.count)
        }
        let repeated = RetentionCensusScript(replies: Array(repeating: [hint,
            .init(error: ENOMEM, bytes: 66 * stride)], count: 3).flatMap { $0 })
        #expect(repeated.census.state(excluding: []) == .unknown)
        #expect(repeated.calls == 6)
        let failedSizing = RetentionCensusScript(replies: Array(repeating: .init(error: ENOMEM, bytes: 0), count: 3))
        #expect(failedSizing.census.state(excluding: []) == .unknown)
        #expect(failedSizing.calls == 3)
        let other = RetentionCensusScript.record(pid: 77, name: Array("unrelated\0".utf8))
        let recovered = RetentionCensusScript(replies: [hint, .init(error: ENOMEM, bytes: 66 * stride),
            hint, .init(error: 0, bytes: stride, records: [other])])
        #expect(recovered.census.state(excluding: []) == .stopped)
        #expect(recovered.calls == 4)
    }

    @Test func syncGateReportsTheActualDecisionSourceWithoutCaching() {
        let record = RetentionCensusScript.record(pid: 123, name: Array("OneDrive\0".utf8))
        let script = RetentionCensusScript(records: [record]), trace = RetentionGateTrace()
        let gate = OneDriveSyncGate(appKitPIDs: { [456] }, census: script.census, trace: { trace.append($0) })
        #expect(gate.state(excluding: []) == .running)
        #expect(script.calls == 0 && trace.values == [.appkitRunning])
        #expect(gate.state(excluding: [456]) == .running)
        #expect(trace.values == [.appkitRunning, .kernelRunning])
        // A second decision must not reuse the earlier positive census.
        #expect(gate.state(excluding: [456]) == .unknown)
        #expect(trace.values.last == .unknown)
        let ownScript = RetentionCensusScript(records: [record]), ownTrace = RetentionGateTrace()
        let ownGate = OneDriveSyncGate(appKitPIDs: { [123] }, census: ownScript.census, trace: { ownTrace.append($0) })
        #expect(ownGate.state(excluding: [123]) == .stopped)
        #expect(ownTrace.values == [.kernelStopped])
    }

    @Test func unknownSyncStateRefusesBeforeSubmissionAndWarnsDistinctlyAfterwards() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.unknown = true
        await #expect(throws: OneDriveRetentionError.syncStateUnknown) {
            try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands.isEmpty)
        state.unknown = false
        state.afterCommand = { command in if command == .keep { state.unknown = true } }
        let outcome = try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!outcome.isConfirmed && outcome.message.contains("could not be verified after the request"))
        #expect(!outcome.message.contains("OneDrive started"))
        #expect(state.commands == [.query, .keep])
    }

    @Test func actualContentOwnershipPreventsAdmissionAndMidflightSetter() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let hold = PhysicalContentUse.shared.retain(fixture.file)
        await #expect(throws: OneDriveRetentionError.contentInUse) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands.isEmpty)
        hold.end()
        let activity = RetentionTestActivity(fixture.file)
        defer { activity.end() }
        state.afterCommand = { command in if command == .query { activity.begin() } }
        await #expect(throws: OneDriveRetentionError.contentInUse) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands == [.query])
    }

    @Test func actualContentOwnershipMatchesAnAliasedDirectory() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let alias = fixture.home.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.folder)
        let aliasedItem = FileItem(url: alias.appendingPathComponent(fixture.file.lastPathComponent),
            name: fixture.file.lastPathComponent, isDirectory: false, isSymbolicLink: false,
            size: 23, modifiedAt: nil, kind: "Text", identity: fixture.entry.item.identity,
            availability: .availableLocally, isRegularFile: true)
        let aliasedEntry = TransferEntry(source: FileOperationContext(directoryURL: alias,
            directoryIdentity: fixture.entry.source.directoryIdentity), item: aliasedItem)
        let hold = PhysicalContentUse.shared.retain(PhysicalContentTarget(aliasedEntry))
        defer { hold.end() }
        await #expect(throws: OneDriveRetentionError.contentInUse) {
            try await fixture.service(state).perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands.isEmpty)
    }

    @Test func cancellationBeforeNativeAdmissionStartsNoCommand() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), control = TransferControl()
        control.cancel()
        await #expect(throws: (any Error).self) {
            try await fixture.service(state).perform(.keep, on: fixture.entry, control: control)
        }
        #expect(state.commands.isEmpty)
        let beforeSetter = TestRetentionState(), other = TransferControl()
        beforeSetter.afterCommand = { command in if command == .query { other.cancel() } }
        await #expect(throws: (any Error).self) {
            try await fixture.service(beforeSetter).perform(.keep, on: fixture.entry, control: other)
        }
        #expect(beforeSetter.commands == [.query])
    }

    @Test func timeoutReleasesWaitButKeepsCrossStoreReservationUntilNativeExit() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), gate = RetentionTestGate()
        let slot = OneDriveRetentionSlot()
        state.afterCommand = { command in if command == .keep { gate.wait() } }
        let first = fixture.service(state, slot: slot, timeout: 0.15)
        let second = fixture.service(TestRetentionState(), slot: slot)
        let task = Task { try await first.perform(.keep, on: fixture.entry, control: TransferControl()) }
        defer { gate.release(); task.cancel() }
        try await waitUntil { state.commands.contains(.keep) }
        await #expect(throws: OneDriveRetentionError.timedOut(setterSubmitted: true)) { try await task.value }
        #expect(first.isBusy && second.isBusy)
        await #expect(throws: OneDriveRetentionError.busy) {
            try await second.perform(.keep, on: fixture.entry, control: TransferControl())
        }
        gate.release()
        try await waitUntil { !first.isBusy }
        #expect(state.commands == [.query, .keep])
    }

    @Test func cancelledWaitKeepsReservationAndSuppressesLaterSetter() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState(), gate = RetentionTestGate()
        state.afterCommand = { command in if command == .query { gate.wait() } }
        let service = fixture.service(state)
        let task = Task { try await service.perform(.freeSpace, on: fixture.entry, control: TransferControl()) }
        defer { gate.release(); task.cancel() }
        try await waitUntil { state.commands == [.query] }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(service.isBusy)
        gate.release()
        try await waitUntil { !service.isBusy }
        #expect(state.commands == [.query])
    }

    @Test func deadlineCanReleaseWaitWhileOSLaunchIsBlocked() async throws {
        let control = TransferControl(), attempt = OneDriveRetentionAttempt(control: control)
        let gate = RetentionTestGate()
        // A finite rescue makes the old lock-around-spawn implementation fail
        // this assertion instead of hanging the test runner.
        let rescue = Task.detached { try await Task.sleep(for: .seconds(1)); gate.release() }
        defer { gate.release(); rescue.cancel() }
        let result: Result<OneDriveRetentionOutcome, Error> = await withCheckedContinuation { continuation in
            Task {
                do {
                    let outcome: OneDriveRetentionOutcome = try await withCheckedThrowingContinuation { waiter in
                        attempt.install(waiter, timeoutSeconds: 0.05)
                        DispatchQueue.global().async {
                            do { try attempt.submit(.keep, control: control) { gate.wait() } }
                            catch { attempt.finish(.failure(error)) }
                        }
                    }
                    continuation.resume(returning: .success(outcome))
                } catch { continuation.resume(returning: .failure(error)) }
            }
        }
        #expect(!gate.isReleased)
        switch result {
        case .failure(let error): #expect(error as? OneDriveRetentionError == .timedOut(setterSubmitted: true))
        case .success: Issue.record("A blocked spawn unexpectedly completed")
        }
    }

    @Test func cancellationDuringLaunchRemainsConservativeWithoutWaitingForSpawn() async throws {
        let control = TransferControl(), attempt = OneDriveRetentionAttempt(control: control)
        let gate = RetentionTestGate()
        let rescue = Task.detached { try await Task.sleep(for: .seconds(2)); gate.release() }
        defer { gate.release(); rescue.cancel() }
        let task = Task<OneDriveRetentionOutcome, Error> {
            try await withCheckedThrowingContinuation { waiter in
                attempt.install(waiter, timeoutSeconds: 3)
                DispatchQueue.global().async {
                    do { try attempt.submit(.keep, control: control) { gate.wait() } }
                    catch { attempt.finish(.failure(error)) }
                }
            }
        }
        try await waitUntil { gate.hasEntered }
        attempt.cancel()
        await #expect(throws: OneDriveRetentionError.cancelled(setterSubmitted: true)) { try await task.value }
        #expect(!gate.isReleased)
    }

    @Test(arguments: [false, true])
    func staleLeafOrParentBeforeSubmissionStartsNoSetter(parent: Bool) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        state.afterCommand = { command in
            if command == .query {
                if parent { try fixture.replaceParent() } else { try fixture.replaceLeaf() }
            }
        }
        await #expect(throws: OneDriveRetentionError.staleTarget) {
            try await fixture.service(state).perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(state.commands == [.query])
    }

    @Test func changedAfterSetterOrNewSyncProcessReportsUnconfirmed() async throws {
        let fixture = try RetentionFixture(), changed = TestRetentionState()
        changed.afterCommand = { command in if command == .keep { try fixture.replaceLeaf() } }
        let result = try await fixture.service(changed).perform(.keep, on: fixture.entry, control: TransferControl())
        #expect(!result.isConfirmed && result.message.contains("submitted") && result.policy == nil && result.isDataless == nil)
        #expect(changed.commands == [.query, .keep])
        let next = try RetentionFixture(), running = TestRetentionState()
        running.afterCommand = { command in if command == .freeSpace { running.running = true } }
        let outcome = try await next.service(running).perform(.freeSpace, on: next.entry, control: TransferControl())
        #expect(!outcome.isConfirmed && outcome.message.contains("running state changed"))
        #expect(running.commands == [.query, .freeSpace])
    }

    @Test(arguments: [OneDriveRetentionError.syncRunning, .contentInUse, .syncStateUnknown])
    func preSpawnGuardFailureDoesNotClaimASetterWasSubmitted(refusal: OneDriveRetentionError) async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let absentExecutable = fixture.home.appendingPathComponent("absent-setter")
        let service = fixture.service(state, nativeSetter: absentExecutable, beforeNativeSetter: { throw refusal })
        await #expect(throws: refusal) {
            try await service.perform(.keep, on: fixture.entry, control: TransferControl())
        }
        #expect(state.nativeLaunchAttempts == 1)
        #expect(state.commands == [.query])
        #expect(!service.isBusy)
    }

    @Test func failedNativeSpawnDoesNotClaimSubmissionOrReissueTheCommand() async throws {
        let fixture = try RetentionFixture(), state = TestRetentionState()
        let absentExecutable = fixture.home.appendingPathComponent("absent-setter")
        #expect(!FileManager.default.fileExists(atPath: absentExecutable.path))
        let service = fixture.service(state, nativeSetter: absentExecutable)
        await #expect(throws: (any Error).self) {
            try await service.perform(.freeSpace, on: fixture.entry, control: TransferControl())
        }
        #expect(state.nativeLaunchAttempts == 1)
        #expect(state.commands == [.query])
        #expect(!service.isBusy)
    }

    @Test func candidateHintIsComponentBoundedAndNeverGrantsProviderAuthority() throws {
        let fixture = try RetentionFixture()
        #expect(OneDriveRetentionService.isCandidate(fixture.entry.item, homeURL: fixture.home))
        #expect(!OneDriveRetentionService.isCandidate(fixture.entry.item, homeURL: fixture.home.appendingPathComponent("elsewhere")))
        let local = FileItem(url: fixture.file, name: fixture.file.lastPathComponent, isDirectory: false,
                             isSymbolicLink: false, size: 23, modifiedAt: nil, kind: "Text",
                             identity: fixture.entry.item.identity, availability: .unknown, isRegularFile: true)
        #expect(!OneDriveRetentionService.isCandidate(local, homeURL: fixture.home))
        #expect(OneDriveRetentionService.isBadgeCandidate(local, homeURL: fixture.home))
        #expect(OneDriveRetentionService.isBadgeLocation(fixture.folder, homeURL: fixture.home))
        #expect(OneDriveRetentionService.isBadgeLocation(fixture.folder.deletingLastPathComponent(), homeURL: fixture.home))
        for path in ["Library/CloudStorage/OneDrive-", "Library/CloudStorage/OtherProvider",
                     "Library/CloudStorage/OneDriveOutside", "Library/CloudStorageFake/OneDrive-Test", "Documents"] {
            #expect(!OneDriveRetentionService.isBadgeLocation(fixture.home.appendingPathComponent(path), homeURL: fixture.home))
        }
    }

    @Test func actualProcessCollectsSeparatePipesAndCapsCombinedOutput() async throws {
        let fixture = try RetentionFixture()
        let script = fixture.home.appendingPathComponent("diagnostic-fixture")
        let fixed = "#!/bin/sh\nprintf '%s\\n' '2026-11-20 17:49:58.321 OneDrive[10125:44379581] Init preferences from: UBF8T346G9.OneDriveStandaloneSuite' '2026-11-20 17:49:58.321 OneDrive[10125:44379581] pin state=Pinned' >&2\nexit 1\n"
        try Data(fixed.utf8).write(to: script)
        #expect(chmod(script.path, 0o700) == 0)
        let application = OneDriveRetentionApplication(executableURL: script, version: "test", stamp: "test")
        let slot = OneDriveRetentionSlot()
        let value = try await BlockingIO.run(on: .read) { _ in
            let control = TransferControl()
            return try OneDriveRetentionProcess.run(application, .query, fixture.file.path,
                OneDriveRetentionAttempt(control: control), control, slot, {})
        }
        #expect(value.stdout.isEmpty && !value.truncated && value.exitCode == 1)
        #expect(OneDriveRetentionTranscript.query(value) == .policy(.pinned))
        let pid = try #require(value.ownedPID)
        #expect(slot.ownedPIDs == [pid])
        var exitStatus: Int32 = 0
        let reap = waitpid(pid, &exitStatus, WNOHANG)
        #expect(reap == -1 && errno == ECHILD)
        slot.child(pid, started: false)
        try Data("#!/bin/sh\nprintf '%020000d' 1\nprintf '%020000d' 2 >&2\nexit 1\n".utf8).write(to: script)
        let noisy = try await BlockingIO.run(on: .read) { _ in
            let control = TransferControl()
            return try OneDriveRetentionProcess.run(application, .query, fixture.file.path,
                OneDriveRetentionAttempt(control: control), control, OneDriveRetentionSlot(), {})
        }
        #expect(noisy.truncated && noisy.stdout.count + noisy.stderr.count == 16_384)
        #expect(OneDriveRetentionTranscript.query(noisy) == .unknown)
        let control = TransferControl(), attempt = OneDriveRetentionAttempt(control: control)
        #expect(throws: OneDriveRetentionError.syncRunning) {
            try OneDriveRetentionProcess.run(application, .keep, fixture.file.path, attempt, control,
                                            OneDriveRetentionSlot(), { throw OneDriveRetentionError.syncRunning })
        }
        // The guard refused before Process.run; no actual executable ran.
        #expect(!attempt.setterSubmitted)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }

    private static func currentUserProcesses() throws -> [(pid: Int32, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(geteuid())]
        var byteCount = 0
        let sizeResult = sysctl(&mib, 4, nil, &byteCount, nil, 0)
        try #require(sizeResult == 0)
        let stride = MemoryLayout<kinfo_proc>.stride
        try #require(byteCount > 0 && byteCount <= 8 * 1_024 * 1_024)
        var records = [kinfo_proc](repeating: kinfo_proc(), count: byteCount / stride + 64)
        byteCount = records.count * stride
        let readResult = records.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &byteCount, nil, 0) }
        try #require(readResult == 0 && byteCount % stride == 0 && byteCount <= records.count * stride)
        return records.prefix(byteCount / stride).map { source in
            var record = source
            let name = withUnsafeBytes(of: &record.kp_proc.p_comm) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return (pid: record.kp_proc.p_pid, name: name)
        }
    }
}

private final class RetentionGateTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [OneDriveSyncGate.Decision] = []
    var values: [OneDriveSyncGate.Decision] { lock.withLock { history } }
    func append(_ value: OneDriveSyncGate.Decision) { lock.withLock { history.append(value) } }
}

private final class RetentionCensusScript: @unchecked Sendable {
    struct Reply {
        let error: Int32, bytes: Int
        var records: [kinfo_proc] = []
    }
    private let lock = NSLock(), replies: [Reply]
    private var count = 0
    var calls: Int { lock.withLock { count } }
    var census: OneDriveProcessCensus { .init(read: { [self] buffer, bytes in read(buffer, &bytes) }) }
    init(replies: [Reply]) { self.replies = replies }
    convenience init(records: [kinfo_proc]) {
        let bytes = records.count * MemoryLayout<kinfo_proc>.stride
        self.init(replies: [.init(error: 0, bytes: bytes), .init(error: 0, bytes: bytes, records: records)])
    }
    private func read(_ buffer: UnsafeMutableRawPointer?, _ bytes: inout Int) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let index = count; count += 1
        guard index < replies.count else { return EIO }
        let reply = replies[index]
        if let buffer {
            reply.records.withUnsafeBytes { source in
                if let base = source.baseAddress { buffer.copyMemory(from: base, byteCount: min(bytes, source.count)) }
            }
        }
        bytes = reply.bytes
        return reply.error
    }
    static func record(pid: Int32, name: [UInt8], zombie: Bool = false) -> kinfo_proc {
        var value = kinfo_proc()
        value.kp_proc.p_pid = pid
        value.kp_proc.p_stat = Int8(zombie ? SZOMB : SRUN)
        withUnsafeMutableBytes(of: &value.kp_proc.p_comm) { bytes in
            for (index, byte) in name.prefix(bytes.count).enumerated() { bytes[index] = byte }
        }
        return value
    }
}

private final class RetentionTestGate: @unchecked Sendable {
    let condition = NSCondition(); var released = false, entered = false
    var isReleased: Bool { condition.lock(); defer { condition.unlock() }; return released }
    var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func wait() { condition.lock(); defer { condition.unlock() }; entered = true; while !released { condition.wait() } }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class RetentionTestActivity: @unchecked Sendable {
    private let lock = NSLock(), url: URL
    private var hold: PhysicalContentUseHold?
    init(_ url: URL) { self.url = url }
    func begin() { lock.withLock { hold = PhysicalContentUse.shared.retain(url) } }
    func end() { lock.withLock { hold?.end(); hold = nil } }
}

private final class TestRetentionState: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [OneDriveRetentionCommand] = []
    private var nativeLaunches = 0
    private var verificationCount = 0, stamp = "synthetic signing inputs"
    private var currentPolicy = "Unpinned", syncRunning = false, syncUnknown = false
    private var events: [String] = [], evictions = 0
    private var waits: [TimeInterval] = []
    var dataless = false, uploaded = true, untrusted = false, ignoreSetter = false, forbidInspection = false
    var queryOverride: OneDriveRetentionTranscript?, setterOverride: OneDriveRetentionTranscript?
    var afterCommand: @Sendable (OneDriveRetentionCommand) throws -> Void = { _ in }
    var beforeInspection: @Sendable (Bool) throws -> Void = { _ in }
    var duringEviction: @Sendable () throws -> Void = {}
    var afterEviction: @Sendable () throws -> Void = {}
    var evictionBecomesDataless = true, evictionPolicy = "Unpinned"
    var policy: String { get { lock.withLock { currentPolicy } } set { lock.withLock { currentPolicy = newValue } } }
    var operationEvents: [String] { lock.withLock { events } }
    var evictionCount: Int { lock.withLock { evictions } }
    var retryWaits: [TimeInterval] { lock.withLock { waits } }
    func recordRetryWait(_ seconds: TimeInterval) { lock.withLock { waits.append(seconds) } }
    var running: Bool { get { lock.withLock { syncRunning } } set { lock.withLock { syncRunning = newValue } } }
    var unknown: Bool { get { lock.withLock { syncUnknown } } set { lock.withLock { syncUnknown = newValue } } }
    var commands: [OneDriveRetentionCommand] { lock.withLock { history } }
    var nativeLaunchAttempts: Int { lock.withLock { nativeLaunches } }
    var verifications: Int { lock.withLock { verificationCount } }
    var signingStamp: String { get { lock.withLock { stamp } } set { lock.withLock { stamp = newValue } } }
    func recordVerification() { lock.withLock { verificationCount += 1 } }
    func recordNativeLaunchAttempt() { lock.withLock { nativeLaunches += 1 } }
    static func line(_ text: String) -> String { "2026-11-20 17:49:58.321 OneDrive[10125:44379581] \(text)\n" }
    static var setter: OneDriveRetentionTranscript {
        .init(exitCode: 1, stdout: Data(), stderr: Data(line("Init preferences from: UBF8T346G9.OneDriveStandaloneSuite").utf8))
    }
    static func query(_ policy: String) -> OneDriveRetentionTranscript {
        .init(exitCode: 1, stdout: Data(), stderr: setter.stderr + Data(line("pin state=" + policy).utf8))
    }
    func run(_ command: OneDriveRetentionCommand, attempt: OneDriveRetentionAttempt,
             control: TransferControl) throws -> OneDriveRetentionTranscript {
        try attempt.submit(command, control: control) { self.lock.withLock {
            self.history.append(command); self.events.append(command.argument)
        } }
        if command != .query, !ignoreSetter {
            lock.withLock { currentPolicy = command == .keep ? "Pinned" : "Unpinned" }
        }
        try afterCommand(command)
        return command == .query ? queryOverride ?? Self.query(lock.withLock { currentPolicy }) : setterOverride ?? Self.setter
    }
    func evict() throws {
        lock.withLock { evictions += 1; events.append("evict") }
        try duringEviction()
        lock.withLock { currentPolicy = evictionPolicy }
        dataless = evictionBecomesDataless
        try afterEviction()
    }
}

private final class RetentionFixture: @unchecked Sendable {
    let home: URL, folder: URL, file: URL, entry: TransferEntry
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionTests-\(UUID())").resolvingSymlinksInPath()
        folder = home.appendingPathComponent("Library/CloudStorage/OneDrive-Test/files")
        file = folder.appendingPathComponent("original.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("owned synthetic payload".utf8).write(to: file)
        let sampledParent = try LocalFileIdentity.read(at: folder, ifLocal: true)
        let sampledFile = try LocalFileIdentity.sample(at: file, ifLocal: true)
        let parent = try #require(sampledParent)
        let identity = try #require(sampledFile?.identity)
        entry = TransferEntry(source: FileOperationContext(directoryURL: folder, directoryIdentity: parent),
            item: FileItem(url: file, name: file.lastPathComponent, isDirectory: false, isSymbolicLink: false,
                           size: 23, modifiedAt: nil, kind: "Text", identity: identity,
                           availability: .availableLocally, isRegularFile: true,
                           statusVersion: sampledFile?.statusVersion))
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func replaceLeaf() throws {
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("moved.txt"))
        try Data("replacement".utf8).write(to: file)
    }
    func replaceParent() throws {
        try FileManager.default.moveItem(at: folder, to: folder.deletingLastPathComponent().appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: file)
    }
    func service(_ state: TestRetentionState, slot: OneDriveRetentionSlot = OneDriveRetentionSlot(),
                 timeout: TimeInterval = 3, nativeSetter: URL? = nil,
                 beforeNativeSetter: @escaping @Sendable () throws -> Void = {},
                 syncState: (@Sendable (Set<Int32>) -> OneDriveSyncState)? = nil,
                 passiveTimeout: TimeInterval = 3, priorityWait: TimeInterval = 1,
                 retryWait: (@Sendable (TimeInterval, OneDriveRetentionAttempt, TransferControl) throws -> Void)? = nil) -> OneDriveRetentionService {
        var environment = OneDriveRetentionEnvironment(homeURL: home,
            verifyApplication: {
                state.recordVerification()
                if state.untrusted { throw OneDriveRetentionError.untrustedApplication }
                return OneDriveRetentionApplication(executableURL: URL(fileURLWithPath: "/synthetic/OneDrive"),
                    version: "26.212.1029 (26212.1029.0006)", stamp: "synthetic verified app")
            }, syncState: { owned in
                syncState?(owned) ?? (state.unknown ? .unknown : state.running ? .running : .stopped)
            }, inspect: { target, needsUpload in
                if state.forbidInspection { throw OneDriveRetentionError.uploadUnconfirmed }
                _ = try target.sample()
                try state.beforeInspection(needsUpload)
                return OneDriveRetentionObservation(isDataless: state.dataless, safeToEvict: !needsUpload || state.uploaded)
            }, run: { _, command, path, attempt, control, slot, beforeLaunch in
                if command != .query, let executable = nativeSetter {
                    state.recordNativeLaunchAttempt()
                    return try OneDriveRetentionProcess.run(
                        .init(executableURL: executable, version: "test", stamp: "test"),
                        command, path, attempt, control, slot, {
                            try beforeLaunch()
                            try beforeNativeSetter()
                        })
                }
                try beforeLaunch()
                return try state.run(command, attempt: attempt, control: control)
            }, applicationStamp: { state.signingStamp }, evict: { _ in try state.evict() })
        if let retryWait { environment.waitAfterBusy = retryWait }
        return OneDriveRetentionService(environment: environment, slot: slot, timeoutSeconds: timeout,
                                       passiveTimeoutSeconds: passiveTimeout, priorityWaitSeconds: priorityWait)
    }
}
