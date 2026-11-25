import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite(.serialized)
struct CloudHydrationTests {
    @Test func abandonedInitialMetadataWorkerRetainsPhysicalContentUse() async throws {
        let fixture = try await HydrationFixture(), gate = HydrationTestCoordinator(blocked: true)
        let alias = Self.aliasContentTarget(fixture)
        let access = PhysicalContentAccess(sample: { name, parent in
            try gate.coordinateReading(at: fixture.url) { _ in }
            return try ContentFileIO.sample(name, at: parent)
        })
        let hydrator = LocalPhysicalFileHydrator(access: access, executor: BlockingIOExecutor())
        let task = Task {
            try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 5,
                                       control: TransferControl(), onProgress: { _ in })
        }
        defer { gate.release(); task.cancel() }
        try #require(await waitUntil { gate.calls == 1 })
        task.cancel(); _ = await task.result
        #expect(PhysicalContentUse.shared.isInUse(of: fixture.url))
        #expect(PhysicalContentUse.shared.isInUse(of: alias))
        gate.release()
        #expect(await waitUntil { !PhysicalContentUse.shared.isInUse(of: fixture.url) })
        #expect(!PhysicalContentUse.shared.isInUse(of: alias))
    }

    @Test func nativeCoordinatorOnLocalFixturePreservesAcceptedRouteSpelling() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        // Only sampled metadata is synthetic. The real native coordinator sees
        // an ordinary local file, so this never downloads a provider document.
        let access = Self.access(state)
        let native = NativeHydrationCoordinator()
        let coordinator = HydrationTestCoordinator { url, accessor in
            try native.coordinateReading(at: url) { actualURL in
                state.setDataless(false)
                try accessor(actualURL)
            }
        }
        let original = try fixture.sample()
        try await LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator }).prepare(
            fixture.entry, maximumBytes: 512, timeoutSeconds: 5,
            control: TransferControl(), onProgress: { state.record($0) })
        #expect(state.phases == [.downloading, .preparing])
        #expect(coordinator.calls == 1)
        #expect(LocalFileIdentity.fromStat(try fixture.sample()) == LocalFileIdentity.fromStat(original))
        #expect(try Data(contentsOf: fixture.url) == Data("original contents".utf8))
    }

    @Test func localPreviewNeverEntersCoordinator() async throws {
        let fixture = try await HydrationFixture()
        let coordinator = HydrationTestCoordinator()
        let hydrator = LocalPhysicalFileHydrator(makeCoordinator: { coordinator })
        try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                             control: TransferControl(), onProgress: { _ in })
        #expect(coordinator.calls == 0)
    }

    @Test func downloadUsesResolvedPathAndFreshVersionWithSameIdentity() async throws {
        let fixture = try await HydrationFixture()
        let state = HydrationTestState(dataless: true)
        let access = PhysicalContentAccess(sample: { name, fd in
            var value = try ContentFileIO.sample(name, at: fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        }, sampleDescriptor: { fd in
            var value = try ContentFileIO.sample(fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        })
        let coordinator = HydrationTestCoordinator { url, accessor in
            #expect(url.path == fixture.resolvedURL.path)
            state.setDataless(false)
            // Metadata may change while the same inode is downloaded.
            #expect(chmod(fixture.url.path, 0o640) == 0)
            try accessor(url)
        }
        let hydrator = LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator })
        try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                             control: TransferControl(), onProgress: { state.record($0) })
        #expect(coordinator.calls == 1)
        #expect(state.phases == [.downloading, .preparing])
        let observation = try access.inspect(fixture.entry, purpose: .preview, maximumBytes: 512)
        #expect(observation.version.identity == fixture.entry.item.identity)
        #expect(!observation.isDataless)
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: access,
                                               hydrator: hydrator)
        let lease = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .preview),
                                                   control: TransferControl())
        try await lease.validateForUse()
        _ = await lease.release()
    }

    @Test func heldDescriptorReconcilesHydrationBirthChange() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let original = try #require(fixture.entry.item.identity)
        let held = try LocalFileOperations.withParent(fixture.entry.source) { parent, _ in
            let descriptor = openat(parent, fixture.entry.item.name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ContentFileIO.failure() }
            return descriptor
        }
        defer { close(held) }
        #expect(LocalFileIdentity.fromStat(try ContentFileIO.sample(held)) == original)
        // Only residency is simulated. The descriptor, inode and changed birth
        // time are real; no provider document or network access is involved.
        let access = PhysicalContentAccess(sample: { name, parent in
            var value = try ContentFileIO.sample(name, at: parent)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        }, sampleDescriptor: { fd in
            var value = try ContentFileIO.sample(fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        })
        let coordinator = HydrationTestCoordinator { url, accessor in
            #expect(url.path == fixture.resolvedURL.path)
            try LocalFileOperations.withParent(fixture.entry.source) { parent, _ in
                let writer = openat(parent, fixture.entry.item.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard writer >= 0 else { throw ContentFileIO.failure() }
                defer { close(writer) }
                try #require(LocalFileIdentity.fromStat(try ContentFileIO.sample(writer)) == original)
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
                var creation = timespec(tv_sec: Int(original.birthSeconds - 1),
                                        tv_nsec: Int(original.birthNanoseconds))
                guard fsetattrlist(writer, &attributes, &creation, MemoryLayout<timespec>.size, 0) == 0 else {
                    throw ContentFileIO.failure()
                }
            }
            let descriptorStat = try ContentFileIO.sample(held), pathStat = try fixture.sample()
            let changed = try #require(LocalFileIdentity.fromStat(descriptorStat))
            try #require(changed != original, "The fixture must change its actual birth identity.")
            #expect(changed.device == original.device && changed.inode == original.inode)
            #expect(changed == LocalFileIdentity.fromStat(pathStat))
            #expect(descriptorStat.st_nlink == 1 && descriptorStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            print("HYDRATION_BIRTH_FIXTURE before=\(original.birthSeconds).\(original.birthNanoseconds) after=\(changed.birthSeconds).\(changed.birthNanoseconds) device=\(changed.device) inode=\(changed.inode)")
            state.setDataless(false)
            try accessor(url)
        }
        let hydrator = LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator })
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: access, hydrator: hydrator)
        let lease = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .preview),
                                                   control: TransferControl())
        do {
            try await lease.validateForUse()
            #expect(lease.isBorrowed && lease.fileURL == fixture.url && lease.sourceURL == fixture.url)
            #expect(lease.physicalEntry.item.identity == LocalFileIdentity.fromStat(try fixture.sample()))
            #expect(lease.physicalEntry.item.identity != original)
            #expect(coordinator.calls == 1)
            #expect(try Data(contentsOf: fixture.url) == Data("original contents".utf8))
            #expect(throws: ItemContentError.staleSource) {
                try access.inspect(fixture.entry, purpose: .preview, maximumBytes: 512)
            }
        } catch {
            _ = await lease.release()
            throw error
        }
        _ = await lease.release()
    }

    @Test func oversizeIsRefusedBeforeNetwork() async throws {
        let fixture = try await HydrationFixture()
        let coordinator = HydrationTestCoordinator()
        let hydrator = LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator })
        await #expect(throws: ItemContentError.limitExceeded) {
            try await hydrator.prepare(fixture.entry, maximumBytes: 1, timeoutSeconds: 1,
                                                 control: TransferControl(), onProgress: { _ in })
        }
        #expect(coordinator.calls == 0)
    }

    @Test(arguments: ["replacement", "symlink", "stillDataless", "oversize", "wrongAccessor"])
    func accessorCannotBlessChangedSource(change: String) async throws {
        let fixture = try await HydrationFixture()
        let state = HydrationTestState(dataless: true)
        let access = PhysicalContentAccess(sample: { name, fd in
            var value = try ContentFileIO.sample(name, at: fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        }, sampleDescriptor: { fd in
            var value = try ContentFileIO.sample(fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            return value
        })
        let coordinator = HydrationTestCoordinator { url, accessor in
            state.setDataless(change == "stillDataless")
            switch change {
            case "replacement":
                try FileManager.default.moveItem(at: fixture.url, to: fixture.root.appendingPathComponent("old"))
                try Data("replacement".utf8).write(to: fixture.url)
            case "symlink":
                let moved = fixture.root.appendingPathComponent("old")
                try FileManager.default.moveItem(at: fixture.url, to: moved)
                try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: moved)
            case "oversize":
                let file = try FileHandle(forWritingTo: fixture.url)
                try file.truncate(atOffset: 1_024); try file.close()
            default: break
            }
            try accessor(change == "wrongAccessor" ? fixture.root.appendingPathComponent("other") : url)
        }
        let hydrator = LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator })
        let expected: ItemContentError = change == "stillDataless" ? .cloudNotDownloaded
            : change == "oversize" ? .limitExceeded : .staleSource
        await #expect(throws: expected) {
            try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                                 control: TransferControl(), onProgress: { _ in })
        }
    }

    @Test func providerFailureIsNotSourceChanged() async throws {
        let fixture = try await HydrationFixture()
        let coordinator = HydrationTestCoordinator { _, _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                          userInfo: [NSLocalizedDescriptionKey: "The provider is offline."])
        }
        let hydrator = LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator })
        await #expect(throws: ItemContentError.downloadFailed("The provider is offline.")) {
            try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                                 control: TransferControl(), onProgress: { _ in })
        }
    }

    @Test func movingCapturedParentThenRetargetingItsDisplayedPathIsRefused() async throws {
        let fixture = try await HydrationFixture()
        let moved = fixture.root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        let coordinator = HydrationTestCoordinator { url, accessor in
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: moved)
            // The parent still has the same inode, but the accepted resolved
            // route changed. Identity alone must not bless this redirect.
            try accessor(url)
        }
        let hydrator = LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator })
        await #expect(throws: ItemContentError.staleSource) {
            try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                                 control: TransferControl(), onProgress: { _ in })
        }
        #expect(try Data(contentsOf: moved.appendingPathComponent("document.txt")) == Data("original contents".utf8))
    }

    @Test(arguments: [ContentPurpose.externalOpen, .transfer, .clipboardExport])
    func nonPreviewDatalessGetsTruthfulError(purpose: ContentPurpose) async throws {
        let fixture = try await HydrationFixture()
        let coordinator = HydrationTestCoordinator()
        let hydrator = LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator })
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: .alwaysDataless,
                                               hydrator: hydrator)
        await #expect(throws: ItemContentError.cloudNotDownloaded) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: purpose),
                                               control: TransferControl())
        }
        #expect(coordinator.calls == 0)
    }

    @Test func evictionClassificationStillRequiresSameIdentity() async throws {
        let fixture = try await HydrationFixture()
        var value = try fixture.sample()
        let version = try ContentFileVersion(value)
        value.st_flags |= UInt32(SF_DATALESS)
        #expect(throws: ItemContentError.cloudNotDownloaded) { try version.validateCurrent(value) }
        value.st_ino += 1
        #expect(throws: ItemContentError.staleSource) { try version.validateCurrent(value) }
    }

    @Test func timeoutIncludesQueueAndLocalPreviewBypassesOccupiedWorkers() async throws {
        let fixture = try await HydrationFixture(), executor = BlockingIOExecutor()
        let first = HydrationTestCoordinator(blocked: true), second = HydrationTestCoordinator(blocked: true)
        let a = Task { try await self.run(fixture, executor: executor, coordinator: first, timeout: 5) }
        let b = Task { try await self.run(fixture, executor: executor, coordinator: second, timeout: 5) }
        defer { first.release(); second.release(); a.cancel(); b.cancel() }
        guard await waitUntil({ first.calls == 1 && second.calls == 1 }) else {
            first.release(); second.release(); a.cancel(); b.cancel()
            _ = await a.result; _ = await b.result
            Issue.record("Two cloud calls did not occupy their workers."); return
        }
        let queued = HydrationTestCoordinator()
        await #expect(throws: ItemContentError.downloadQueueTimedOut) {
            try await self.run(fixture, executor: executor, coordinator: queued, timeout: 0.05)
        }
        #expect(queued.calls == 0)
        let local = LocalPhysicalFileHydrator(executor: executor, makeCoordinator: { queued })
        let signals = HydrationTestState(dataless: false)
        let localTask = Task {
            try await local.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: 1,
                                              control: TransferControl(), onProgress: { _ in })
            signals.mark("local")
        }
        let content = Task {
            try await executor.run(on: .content) { _ in signals.mark("content") }
        }
        let mutation = Task {
            try await executor.run(on: .mutation) { _ in signals.mark("mutation") }
        }
        let independent = await waitUntil { signals.contains("local") && signals.contains("content") && signals.contains("mutation") }
        if !independent {
            first.release(); second.release(); localTask.cancel(); content.cancel(); mutation.cancel()
        }
        let localResult = await localTask.result, contentResult = await content.result, mutationResult = await mutation.result
        #expect(independent, "Cloud workers must not block local preparation, content, or short mutation work.")
        if !independent { a.cancel(); b.cancel(); _ = await a.result; _ = await b.result; return }
        try localResult.get(); try contentResult.get(); try mutationResult.get()
        #expect(queued.calls == 0)
        a.cancel(); b.cancel()
        _ = await a.result; _ = await b.result
        #expect(first.cancelCalls > 0 && second.cancelCalls > 0)
        // Cancellation releases callers, but does not free native workers.
        let after = Task { try await self.run(fixture, executor: executor, coordinator: queued, timeout: 1) }
        guard await waitUntil({ executor.pendingCount(on: .hydration) == 1 }) else {
            first.release(); second.release(); after.cancel(); _ = await after.result
            Issue.record("Cancelled native calls released their workers prematurely."); return
        }
        #expect(queued.calls == 0)
        after.cancel(); _ = await after.result
        first.release(); second.release()
        #expect(await waitUntil { first.finished && second.finished })
        #expect(queued.calls == 0, "Cancelled queued attempts must never invoke the native coordinator.")
    }

    @Test func runningCancellationAndDeadlineDiscardLateAccessor() async throws {
        let fixture = try await HydrationFixture()
        let alias = Self.aliasContentTarget(fixture)
        for timedOut in [false, true] {
            let coordinator = HydrationTestCoordinator(blocked: true), state = HydrationTestState(dataless: true)
            let task = Task {
                try await self.run(fixture, executor: BlockingIOExecutor(), coordinator: coordinator,
                                   timeout: timedOut ? 0.1 : 5, onProgress: { state.record($0) })
            }
            defer { coordinator.release(); task.cancel() }
            guard await waitUntil({ coordinator.calls == 1 }) else {
                coordinator.release(); task.cancel(); _ = await task.result
                Issue.record("Cloud operation did not start."); continue
            }
            if !timedOut { task.cancel() }
            let result = await task.result
            switch result {
            case .success: Issue.record("Cancelled or timed-out hydration succeeded.")
            case .failure(let error):
                if timedOut { #expect(error as? ItemContentError == .downloadTimedOut) }
                else { #expect(error is CancellationError) }
            }
            #expect(coordinator.cancelCalls > 0)
            #expect(PhysicalContentUse.shared.isInUse(of: fixture.url), "Cancellation releases only the waiter, not native ownership")
            #expect(PhysicalContentUse.shared.isInUse(of: alias), "The same native ownership blocks a captured directory alias")
            #expect(state.phases == [.downloading])
            coordinator.release()
            #expect(await waitUntil { coordinator.finished })
            #expect(await waitUntil { !PhysicalContentUse.shared.isInUse(of: fixture.url) })
            #expect(!PhysicalContentUse.shared.isInUse(of: alias))
            #expect(state.phases == [.downloading])
        }
    }

    @Test func explicitDownloadUsesOwnBudgetAndProgress() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        var limits = ContentLimits(); limits.previewBytes = 1; limits.downloadBytes = 17
        let registry = ContentLeaseRegistry(rootURL: fixture.root.appendingPathComponent("limited"), limits: limits)
        let access = Self.access(state)
        let coordinator = HydrationTestCoordinator { url, accessor in
            state.setDataless(false); try accessor(url)
        }
        let provider = LocalItemContentProvider(registry: registry, physicalAccess: access,
            hydrator: LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator }))
        let lease = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .download,
            onProgress: { state.record($0) }), control: TransferControl())
        #expect(lease.byteCount == 17 && lease.isBorrowed)
        #expect(state.phases == [.queued, .downloading, .preparing])
        _ = await lease.release()
        state.setDataless(true)
        await #expect(throws: ItemContentError.limitExceeded) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .preview), control: TransferControl())
        }
        #expect(coordinator.calls == 1)
    }

    @Test(arguments: [ContentPurpose.preview, .download])
    func residentOnlyNeverStartsCoordinator(purpose: ContentPurpose) async throws {
        let fixture = try await HydrationFixture(), coordinator = HydrationTestCoordinator()
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: .alwaysDataless,
            hydrator: LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator }))
        await #expect(throws: ItemContentError.cloudNotDownloaded) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: purpose,
                hydrationPolicy: .residentOnly), control: TransferControl())
        }
        #expect(coordinator.calls == 0)
    }

    @Test func downloadBudgetRefusesBeforeCoordinatorAndDuringBorrow() async throws {
        let fixture = try await HydrationFixture(), coordinator = HydrationTestCoordinator()
        var limits = ContentLimits(); limits.downloadBytes = 16
        let registry = ContentLeaseRegistry(rootURL: fixture.root.appendingPathComponent("limited"), limits: limits)
        let provider = LocalItemContentProvider(registry: registry, physicalAccess: .alwaysDataless,
            hydrator: LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator }))
        await #expect(throws: ItemContentError.limitExceeded) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .download), control: TransferControl())
        }
        await #expect(throws: ItemContentError.downloadQueueTimedOut) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .download,
                hydrationTimeoutSeconds: .infinity), control: TransferControl())
        }
        #expect(coordinator.calls == 0)
        let state = HydrationTestState(dataless: false)
        let access = PhysicalContentAccess(sample: { name, parent in
            var value = try ContentFileIO.sample(name, at: parent)
            if state.contains("prepared") { value.st_size = Int64(CloudDownloadPolicy.maximumBytes + 1) }
            return value
        })
        let prepared = DownloadPreparedProbe(access: access, state: state)
        let borrowing = LocalItemContentProvider(registry: fixture.registry, physicalAccess: access, hydrator: prepared)
        await #expect(throws: ItemContentError.limitExceeded) {
            _ = try await borrowing.materialize(ContentRequest(source: fixture.source, purpose: .download), control: TransferControl())
        }
    }

    @Test func downloadBorrowDoesNotRestartExpiredBudget() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: false)
        let preparer = DownloadPreparedProbe(access: PhysicalContentAccess(), state: state, delay: .milliseconds(60))
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: PhysicalContentAccess(), hydrator: preparer)
        await #expect(throws: ItemContentError.deadlineExceeded) {
            _ = try await provider.materialize(ContentRequest(source: fixture.source, purpose: .download,
                hydrationTimeoutSeconds: 0.01), control: TransferControl())
        }
    }

    @Test func downloadRejectsFolderAndUnknownSizeWithoutCoordination() async throws {
        let fixture = try await HydrationFixture(), coordinator = HydrationTestCoordinator()
        let folder = fixture.root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let directory = try #require(snapshot.items.first { $0.url == folder })
        let old = fixture.entry.item
        let unknown = FileItem(url: old.url, name: old.name, isDirectory: false, isSymbolicLink: false,
            size: nil, modifiedAt: old.modifiedAt, kind: old.kind, identity: old.identity)
        let provider = LocalItemContentProvider(registry: fixture.registry, physicalAccess: .alwaysDataless,
            hydrator: LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator }))
        for item in [directory, unknown] {
            await #expect(throws: ItemContentError.unsupportedType) {
                _ = try await provider.materialize(ContentRequest(source: ItemOperationEntry(item: item,
                    context: .filesystem(fixture.entry.source)), purpose: .download), control: TransferControl())
            }
        }
        #expect(coordinator.calls == 0)
    }

    @Test func leaseDoesNotAcceptRetargetedParentAfterHydration() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let lease = try await Self.birthLease(fixture, state: state, requestID: UUID())
        let moved = fixture.root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: moved)
        await #expect(throws: ItemContentError.staleSource) { try await lease.validateForUse() }
        _ = await lease.release()
    }

    @Test(arguments: ["descriptorPath", "afterAccessor"])
    func newVersionMustStaySealed(boundary: String) async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let access = Self.access(state, afterDescriptorSample: {
            if boundary == "descriptorPath", !state.dataless, state.markOnce("changed") {
                #expect(chmod(fixture.url.path, 0o640) == 0)
            }
        })
        let coordinator = HydrationTestCoordinator { url, accessor in
            state.setDataless(false); try accessor(url)
            if boundary == "afterAccessor" { #expect(chmod(fixture.url.path, 0o640) == 0) }
        }
        await #expect(throws: ItemContentError.staleSource) {
            try await LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator }).prepare(
                fixture.entry, maximumBytes: 512, timeoutSeconds: 1, control: TransferControl(), onProgress: { _ in })
        }
    }

    @Test(arguments: [false, true])
    func receiptSurvivesLeaseReleaseAndRejectsReplay(singleChild: Bool) async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true), requestID = UUID()
        let lease = try await Self.birthLease(fixture, state: state, requestID: requestID)
        let receipt = try #require(lease.hydrationReconciliation)
        #expect(lease.originalPhysicalEntry?.item.identity == fixture.entry.item.identity)
        let currentIdentity = try #require(lease.physicalEntry.item.identity)
        _ = await lease.release()
        #expect(state.descriptors.contains { Self.descriptor($0, stillOwns: currentIdentity) })
        let snapshot: DirectorySnapshot
        if singleChild {
            let entry = try await LocalDirectoryLoader.inspectorEntry(at: fixture.url)
            snapshot = DirectorySnapshot(items: [entry.item], directoryIdentity: entry.source.directoryIdentity,
                                         isStructureComplete: false)
        } else {
            snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        }
        var verified: VerifiedHydrationTransition? = try await receipt.claim(requestID: requestID,
            originalEntry: fixture.entry, snapshot: snapshot)
        #expect(verified?.originalEntry.item.identity == fixture.entry.item.identity)
        #expect(verified?.acceptedEntry.item.identity == currentIdentity)
        #expect(verified?.refreshedItem.identity == currentIdentity)
        let raw = try fixture.sample()
        #expect(verified?.acceptedEntry.item.statusVersion == LocalFileStatusVersion(raw))
        #expect(verified?.refreshedItem.statusVersion == LocalFileStatusVersion(raw))
        await #expect(throws: ItemContentError.staleSource) {
            _ = try await receipt.claim(requestID: requestID, originalEntry: fixture.entry, snapshot: snapshot)
        }
        verified = nil
        #expect(await waitUntil { state.descriptors.allSatisfy { !Self.descriptor($0, stillOwns: currentIdentity) } })
    }

    @Test(arguments: [false, true])
    func hydrationReceiptCarriesHeldStampAndRejectsContradictoryListing(mismatched: Bool) async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true), requestID = UUID()
        let lease = try await Self.birthLease(fixture, state: state, requestID: requestID)
        let receipt = try #require(lease.hydrationReconciliation)
        let current = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let item = try #require(current.items.first)
        let raw = LocalFileStatusVersion(try fixture.sample())
        let stamp = mismatched ? LocalFileStatusVersion(size: raw.size, modificationSeconds: raw.modificationSeconds,
            modificationNanoseconds: raw.modificationNanoseconds + 1) : nil
        let row = FileItem(url: item.url, name: item.name, isDirectory: item.isDirectory,
            isSymbolicLink: item.isSymbolicLink, size: item.size, modifiedAt: item.modifiedAt, kind: item.kind,
            identity: item.identity, availability: item.availability, isRegularFile: item.isRegularFile,
            statusVersion: stamp)
        let snapshot = DirectorySnapshot(items: [row], directoryIdentity: current.directoryIdentity)
        _ = await lease.release()
        if mismatched {
            await #expect(throws: ItemContentError.staleSource) {
                _ = try await receipt.claim(requestID: requestID, originalEntry: fixture.entry, snapshot: snapshot)
            }
        } else {
            let verified = try await receipt.claim(requestID: requestID, originalEntry: fixture.entry, snapshot: snapshot)
            #expect(verified.refreshedItem.statusVersion == raw,
                    "A compatible unstamped row receives only the version proved by the held native anchor")
            #expect(verified.refreshedItem.id == item.id && verified.refreshedItem.identity == item.identity)
        }
    }

    @Test(arguments: ["request", "duplicate", "missing", "parent", "invalidate", "laterBirth"])
    func receiptRejectsUnprovenRefreshAndConsumesFailure(change: String) async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true), requestID = UUID()
        let lease = try await Self.birthLease(fixture, state: state, requestID: requestID)
        let receipt = try #require(lease.hydrationReconciliation)
        let current = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        let snapshot = change == "duplicate" ? DirectorySnapshot(items: current.items + current.items, directoryIdentity: current.directoryIdentity)
            : change == "missing" ? DirectorySnapshot(items: [], directoryIdentity: current.directoryIdentity)
            : change == "parent" ? DirectorySnapshot(items: current.items) : current
        if change == "invalidate" { receipt.invalidate() }
        if change == "laterBirth" { try fixture.changeBirth() }
        await #expect(throws: ItemContentError.staleSource) {
            _ = try await receipt.claim(requestID: change == "request" ? UUID() : requestID,
                originalEntry: fixture.entry, snapshot: snapshot)
        }
        await #expect(throws: ItemContentError.staleSource) {
            _ = try await receipt.claim(requestID: requestID, originalEntry: fixture.entry, snapshot: current)
        }
        if change == "laterBirth" {
            await #expect(throws: ItemContentError.staleSource) { try await lease.validateForUse() }
        }
        _ = await lease.release()
    }

    @Test func policyRestorationFailureRefusesAndIsLogged() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let coordinator = HydrationTestCoordinator()
        let policy = HydrationMaterializationPolicy(get: { 37 }, set: { $0 == 37 ? -1 : 0 },
            reportFailure: { _ in state.mark("logged") })
        await #expect(throws: ItemContentError.downloadFailed("The file access policy could not be restored.")) {
            try await LocalPhysicalFileHydrator(access: Self.access(state), policy: policy,
                makeCoordinator: { coordinator }).prepare(fixture.entry, maximumBytes: 512,
                    timeoutSeconds: 1, control: TransferControl(), onProgress: { _ in })
        }
        #expect(state.contains("logged") && coordinator.calls == 0)
    }

    @Test func receiptInvalidationDuringClaimKeepsDescriptorUntilValidationExits() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true), requestID = UUID()
        let gate = HydrationTestCoordinator(blocked: true)
        defer { gate.release() }
        let access = Self.access(state, afterDescriptorSample: {
            if state.contains("claim"), state.markOnce("claimBlocked") {
                try? gate.coordinateReading(at: fixture.url) { _ in }
            }
        })
        let coordinator = HydrationTestCoordinator { url, accessor in
            try fixture.changeBirth(); state.setDataless(false); try accessor(url)
        }
        let lease = try await LocalItemContentProvider(registry: fixture.registry, physicalAccess: access,
            hydrator: LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator })).materialize(
                ContentRequest(source: fixture.source, purpose: .preview, requestID: requestID), control: TransferControl())
        let receipt = try #require(lease.hydrationReconciliation), identity = try #require(lease.physicalEntry.item.identity)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: fixture.root, showHidden: true)
        _ = await lease.release()
        state.mark("claim")
        let claim = Task { try await receipt.claim(requestID: requestID, originalEntry: fixture.entry, snapshot: snapshot) }
        defer { claim.cancel() }
        try #require(await waitUntil { gate.calls == 1 })
        receipt.invalidate()
        #expect(state.descriptors.contains { Self.descriptor($0, stillOwns: identity) })
        gate.release()
        await #expect(throws: ItemContentError.staleSource) { _ = try await claim.value }
        #expect(await waitUntil { state.descriptors.allSatisfy { !Self.descriptor($0, stillOwns: identity) } })
    }

    @Test func abandonedWorkerResultClosesItsLastAnchor() async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let executor = BlockingIOExecutor(), gate = HydrationTestCoordinator(blocked: true)
        let identity = try #require(fixture.entry.item.identity)
        let task = Task {
            try await executor.run(on: .explicitHydration) { _ in
                let policy = HydrationMaterializationPolicy()
                return try policy.disabled { _ in
                    try LocalFileOperations.withParent(fixture.entry.source) { parent, resolved in
                        let anchor = try HydrationIdentityAnchor.capture(fixture.entry, parent: parent, resolved: resolved,
                            access: Self.access(state), maximumBytes: 512, policy: policy)
                        try gate.coordinateReading(at: fixture.url) { _ in }
                        // Deliberately return a real owned result after abandonment.
                        return anchor
                    }
                }
            }
        }
        defer { gate.release(); task.cancel() }
        try #require(await waitUntil { gate.calls == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(state.descriptors.contains { Self.descriptor($0, stillOwns: identity) })
        gate.release()
        #expect(await waitUntil { state.descriptors.allSatisfy { !Self.descriptor($0, stillOwns: identity) } })
    }

    @Test func placeholderWithMultipleLinksIsRefusedBeforeCoordination() async throws {
        let fixture = try await HydrationFixture(), coordinator = HydrationTestCoordinator()
        try FileManager.default.linkItem(at: fixture.url, to: fixture.root.appendingPathComponent("other-name"))
        await #expect(throws: ItemContentError.staleSource) {
            try await LocalPhysicalFileHydrator(access: .alwaysDataless, makeCoordinator: { coordinator }).prepare(
                fixture.entry, maximumBytes: 512, timeoutSeconds: 1, control: TransferControl(), onProgress: { _ in })
        }
        #expect(coordinator.calls == 0)
    }

    @Test(arguments: [false, true])
    func abandonedExplicitAnchorKeepsSlotAndClosesAfterNativeExit(timedOut: Bool) async throws {
        let fixture = try await HydrationFixture(), state = HydrationTestState(dataless: true)
        let alias = Self.aliasContentTarget(fixture)
        let executor = BlockingIOExecutor(), coordinator = HydrationTestCoordinator(blocked: true)
        let hydrator = LocalPhysicalFileHydrator(access: Self.access(state), executor: executor, makeCoordinator: { coordinator })
        let task = Task {
            try await hydrator.prepare(fixture.entry, purpose: .download, maximumBytes: 512,
                timeoutSeconds: timedOut ? 0.1 : 5, control: TransferControl(), onProgress: { state.record($0) })
        }
        defer { coordinator.release(); task.cancel() }
        try #require(await waitUntil { coordinator.calls == 1 })
        if !timedOut { task.cancel() }
        let outcome = await task.result
        switch outcome {
        case .success: Issue.record("An abandoned Download must not publish authority.")
        case .failure(let error):
            if timedOut { #expect(error as? ItemContentError == .downloadTimedOut) }
            else { #expect(error is CancellationError) }
        }
        let identity = try #require(fixture.entry.item.identity)
        #expect(state.descriptors.contains { Self.descriptor($0, stillOwns: identity) })
        #expect(PhysicalContentUse.shared.isInUse(of: fixture.url))
        #expect(PhysicalContentUse.shared.isInUse(of: alias))
        let queued = HydrationTestCoordinator()
        await #expect(throws: ItemContentError.downloadQueueTimedOut) {
            try await LocalPhysicalFileHydrator(access: .alwaysDataless, executor: executor,
                makeCoordinator: { queued }).prepare(fixture.entry, purpose: .download,
                    maximumBytes: 512, timeoutSeconds: 0.03, control: TransferControl(), onProgress: { _ in })
        }
        #expect(queued.calls == 0)
        let previewState = HydrationTestState(dataless: true)
        let previewCoordinator = HydrationTestCoordinator { url, accessor in
            previewState.setDataless(false); try accessor(url)
        }
        _ = try await LocalPhysicalFileHydrator(access: Self.access(previewState), executor: executor,
            makeCoordinator: { previewCoordinator }).prepare(fixture.entry, maximumBytes: 512,
                timeoutSeconds: 1, control: TransferControl(), onProgress: { _ in })
        #expect(previewCoordinator.calls == 1)
        coordinator.release()
        #expect(await waitUntil { state.descriptors.allSatisfy { !Self.descriptor($0, stillOwns: identity) } })
        #expect(await waitUntil { !PhysicalContentUse.shared.isInUse(of: fixture.url) })
        #expect(!PhysicalContentUse.shared.isInUse(of: alias))
        #expect(state.phases == [.queued, .downloading])
    }

    private static func aliasContentTarget(_ fixture: HydrationFixture) -> PhysicalContentTarget {
        let original = fixture.entry.item.identity!
        // Query captured alias metadata only; no filesystem lookup is needed.
        let identity = LocalFileIdentity(device: original.device, inode: original.inode,
            birthSeconds: original.birthSeconds, birthNanoseconds: original.birthNanoseconds + 1)
        return PhysicalContentTarget(url: URL(fileURLWithPath: "/synthetic-directory-alias/\(fixture.entry.item.name)"),
            identity: identity, parentIdentity: fixture.entry.source.directoryIdentity)
    }

    private static func access(_ state: HydrationTestState,
                               afterDescriptorSample: @escaping @Sendable () -> Void = {}) -> PhysicalContentAccess {
        PhysicalContentAccess(sample: { name, parent in
            var value = try ContentFileIO.sample(name, at: parent)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }; return value
        }, sampleDescriptor: { fd in
            state.rememberDescriptor(fd)
            var value = try ContentFileIO.sample(fd)
            if state.dataless { value.st_flags |= UInt32(SF_DATALESS) }
            afterDescriptorSample(); return value
        })
    }

    private static func birthLease(_ fixture: HydrationFixture, state: HydrationTestState,
                                   requestID: UUID) async throws -> any MaterializedContentLease {
        let access = access(state)
        let coordinator = HydrationTestCoordinator { url, accessor in
            try fixture.changeBirth(); state.setDataless(false); try accessor(url)
        }
        return try await LocalItemContentProvider(registry: fixture.registry, physicalAccess: access,
            hydrator: LocalPhysicalFileHydrator(access: access, makeCoordinator: { coordinator })).materialize(
                ContentRequest(source: fixture.source, purpose: .preview, requestID: requestID), control: TransferControl())
    }

    private static func descriptor(_ fd: Int32, stillOwns identity: LocalFileIdentity) -> Bool {
        var value = stat()
        return fstat(fd, &value) == 0 && LocalFileIdentity.fromStat(value) == identity
    }

    private func run(_ fixture: HydrationFixture, executor: BlockingIOExecutor,
                     coordinator: HydrationTestCoordinator, timeout: TimeInterval,
                     onProgress: @escaping @Sendable (ContentPreparationPhase) -> Void = { _ in }) async throws {
        let hydrator = LocalPhysicalFileHydrator(access: .alwaysDataless, executor: executor,
                                               makeCoordinator: { coordinator })
        try await hydrator.prepare(fixture.entry, maximumBytes: 512, timeoutSeconds: timeout,
                                             control: TransferControl(), onProgress: onProgress)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
}

private final class HydrationFixture: @unchecked Sendable {
    let root: URL, url: URL, resolvedURL: URL
    let entry: TransferEntry, source: ItemOperationEntry, registry: ContentLeaseRegistry
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudHydration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        url = root.appendingPathComponent("document.txt")
        try Data("original contents".utf8).write(to: url)
        let snapshot = try await LocalDirectoryLoader().snapshot(of: root, showHidden: true)
        let context = FileOperationContext(directoryURL: root, directoryIdentity: try #require(snapshot.directoryIdentity))
        let item = try #require(snapshot.items.first { $0.name == "document.txt" })
        entry = TransferEntry(source: context, item: item)
        source = ItemOperationEntry(item: item, context: .filesystem(context))
        // Content authority uses withParent's identity-checked resolved URL;
        // realpath's /private/var spelling is a different Foundation contract.
        resolvedURL = try LocalFileOperations.withParent(context) { _, resolved in resolved.appendingPathComponent(item.name) }
        registry = ContentLeaseRegistry(rootURL: root.appendingPathComponent("leases"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func sample() throws -> stat {
        try LocalFileOperations.withParent(entry.source) { fd, _ in try ContentFileIO.sample(entry.item.name, at: fd) }
    }
    func changeBirth() throws {
        try LocalFileOperations.withParent(entry.source) { parent, _ in
            let writer = openat(parent, entry.item.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard writer >= 0 else { throw ContentFileIO.failure() }; defer { close(writer) }
            var creation = try ContentFileIO.sample(writer).st_birthtimespec
            creation.tv_sec -= 1
            var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            guard fsetattrlist(writer, &attributes, &creation, MemoryLayout<timespec>.size, 0) == 0 else {
                throw ContentFileIO.failure()
            }
        }
    }
}

private struct DownloadPreparedProbe: PhysicalFileHydrating {
    let access: PhysicalContentAccess
    let state: HydrationTestState
    var delay: Duration = .zero
    func prepare(_ entry: TransferEntry, purpose: ContentPurpose, hydrationPolicy: ContentHydrationPolicy,
                 maximumBytes: UInt64, timeoutSeconds: TimeInterval, requestID: UUID, control: TransferControl,
                 onProgress: @escaping @Sendable (ContentPreparationPhase) -> Void) async throws -> PreparedPhysicalContent {
        let observation = try access.inspect(entry, purpose: purpose, maximumBytes: maximumBytes)
        if delay > .zero { try await Task.sleep(for: delay) }
        state.mark("prepared")
        return PreparedPhysicalContent(resident: entry, observation: observation)
    }
}

private extension PhysicalContentAccess {
    static let alwaysDataless = PhysicalContentAccess(sample: { name, fd in
        var value = try ContentFileIO.sample(name, at: fd)
        value.st_flags |= UInt32(SF_DATALESS)
        return value
    }, sampleDescriptor: { fd in
        var value = try ContentFileIO.sample(fd)
        value.st_flags |= UInt32(SF_DATALESS)
        return value
    })
}

private final class HydrationTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var missing: Bool
    private var recorded: [ContentPreparationPhase] = []
    private var completed: Set<String> = []
    private var sampledDescriptors = Set<Int32>()
    init(dataless: Bool) { missing = dataless }
    var dataless: Bool { lock.lock(); defer { lock.unlock() }; return missing }
    var phases: [ContentPreparationPhase] { lock.lock(); defer { lock.unlock() }; return recorded }
    func mark(_ name: String) { lock.lock(); completed.insert(name); lock.unlock() }
    func markOnce(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return completed.insert(name).inserted }
    var descriptors: Set<Int32> { lock.lock(); defer { lock.unlock() }; return sampledDescriptors }
    func rememberDescriptor(_ descriptor: Int32) { lock.lock(); sampledDescriptors.insert(descriptor); lock.unlock() }
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return completed.contains(name) }
    func setDataless(_ value: Bool) { lock.lock(); missing = value; lock.unlock() }
    func record(_ value: ContentPreparationPhase) { lock.lock(); recorded.append(value); lock.unlock() }
}

private final class HydrationTestCoordinator: HydrationCoordinating, @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Bool, count = 0, cancellations = 0, completed = false
    private let body: @Sendable (URL, (URL) throws -> Void) throws -> Void
    init(blocked: Bool = false,
         body: @escaping @Sendable (URL, (URL) throws -> Void) throws -> Void = { url, accessor in try accessor(url) }) {
        self.blocked = blocked; self.body = body
    }
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    var cancelCalls: Int { condition.lock(); defer { condition.unlock() }; return cancellations }
    var finished: Bool { condition.lock(); defer { condition.unlock() }; return completed }
    func coordinateReading(at url: URL, accessor: (URL) throws -> Void) throws {
        condition.lock(); count += 1
        while blocked { condition.wait() }
        condition.unlock()
        defer { condition.lock(); completed = true; condition.unlock() }
        try body(url, accessor)
    }
    func cancel() { condition.lock(); cancellations += 1; condition.unlock() }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
}
