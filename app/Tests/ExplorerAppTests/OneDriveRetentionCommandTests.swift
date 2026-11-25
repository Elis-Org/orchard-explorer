import AppKit
import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

private final class RetentionCommandProvider: OneDriveRetentionProviding, @unchecked Sendable {
    private let lock = NSLock()
    var running = false
    var runningStateUnavailable = false
    private var pending: CheckedContinuation<OneDriveRetentionOutcome, Error>?
    private var actions: [OneDriveRetentionAction] = []
    private var control: TransferControl?
    private var taskCancelled = false
    var syncIsRunning: Bool { running }
    var syncState: OneDriveSyncState { runningStateUnavailable ? .unknown : (running ? .running : .stopped) }
    var isBusy: Bool { lock.withLock { pending != nil } }
    var calls: [OneDriveRetentionAction] { lock.withLock { actions } }
    var cancelled: Bool {
        lock.withLock {
            guard taskCancelled, let control else { return false }
            do { try control.checkpoint(); return false } catch { return true }
        }
    }
    func perform(_ action: OneDriveRetentionAction, on entry: TransferEntry,
                 control: TransferControl) async throws -> OneDriveRetentionOutcome {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.control = control; pending = continuation; actions.append(action) }
            }
        }, onCancel: { self.lock.withLock { self.taskCancelled = true } })
    }
    func finish(_ outcome: OneDriveRetentionOutcome) {
        let value = lock.withLock { let value = pending; pending = nil; return value }
        value?.resume(returning: outcome)
    }
    func stop() {
        let value = lock.withLock { let value = pending; pending = nil; return value }
        value?.resume(throwing: CancellationError())
    }
}

private actor RetentionCommandLoader: DirectoryListing {
    var snapshotValue: DirectorySnapshot
    private(set) var reads = 0
    init(_ value: DirectorySnapshot) { snapshotValue = value }
    func set(_ value: DirectorySnapshot) { snapshotValue = value }
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { snapshotValue.items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        reads += 1; return snapshotValue
    }
}

private actor RetentionContentProvider: ItemContentProviding {
    private(set) var requests: [ContentRequest] = []
    private var pending: [CheckedContinuation<any MaterializedContentLease, Error>] = []
    var failImmediately = false
    func setFailImmediately() { failImmediately = true }
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        requests.append(request)
        if failImmediately { throw ItemContentError.cloudNotDownloaded }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func stop() {
        let values = pending; pending.removeAll()
        values.forEach { $0.resume(throwing: CancellationError()) }
    }
    func finish(_ lease: any MaterializedContentLease) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: lease)
    }
}

private final class RetentionDelayedLease: MaterializedContentLease, @unchecked Sendable {
    let physicalEntry: TransferEntry
    let isBorrowed = true
    var fileURL: URL { physicalEntry.item.url }
    var sourceURL: URL { fileURL }
    var archiveRevision: ArchiveRevision? { nil }
    var byteCount: UInt64 { 65_536 }
    private let lock = NSLock()
    private var pending: CheckedContinuation<ContentLeaseReleaseResult, Never>?
    private var count = 0
    var releaseCalls: Int { lock.withLock { count } }
    init(_ entry: TransferEntry) { physicalEntry = entry }
    func validateForUse() async throws {}
    func release() async -> ContentLeaseReleaseResult {
        await withCheckedContinuation { continuation in
            lock.withLock { count += 1; pending = continuation }
        }
    }
    func finishRelease() {
        let value = lock.withLock { let value = pending; pending = nil; return value }
        value?.resume(returning: .init(disposition: .released))
    }
}

@Suite(.serialized)
@MainActor
struct OneDriveRetentionCommandTests {
    private func source(_ suffix: String = UUID().uuidString, availability: FileAvailability = .availableLocally,
                        regular: Bool? = true, identity: LocalFileIdentity? = nil) -> TransferEntry {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/OneDrive-RetentionTests", isDirectory: true)
        let name = "synthetic-\(suffix).txt"
        let item = FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 65_536, modifiedAt: nil, kind: "Text",
            identity: identity ?? LocalFileIdentity(device: 1, inode: 9_001, birthSeconds: 1, birthNanoseconds: 0),
            availability: availability, isRegularFile: regular,
            statusVersion: .init(size: 65_536, modificationSeconds: 1, modificationNanoseconds: 0))
        return TransferEntry(source: .init(directoryURL: root,
            directoryIdentity: LocalFileIdentity(device: 1, inode: 9_000, birthSeconds: 1, birthNanoseconds: 0)), item: item)
    }
    private func outcome(_ action: OneDriveRetentionAction, dataless: Bool? = false, confirmed: Bool = true,
                         message: String = "Unconfirmed provider result.",
                         mode: OneDriveRetentionMode = .stopped) -> OneDriveRetentionOutcome {
        .init(policy: action == .keep ? .pinned : .unpinned, isDataless: dataless,
              providerVersion: "synthetic", isConfirmed: confirmed, message: message, mode: mode)
    }
    private func directoryAlias(of entry: TransferEntry, birthNanoseconds: Int64 = 6) -> TransferEntry {
        let root = URL(fileURLWithPath: "/tmp/retention-directory-alias-\(UUID().uuidString)", isDirectory: true)
        let captured = entry.item.identity!
        let item = FileItem(url: root.appendingPathComponent(entry.item.name), name: entry.item.name,
            isDirectory: false, isSymbolicLink: false, size: entry.item.size, modifiedAt: nil, kind: "Text",
            identity: LocalFileIdentity(device: captured.device, inode: captured.inode,
                birthSeconds: captured.birthSeconds, birthNanoseconds: birthNanoseconds),
            availability: entry.item.availability, isRegularFile: true, statusVersion: entry.item.statusVersion)
        return TransferEntry(source: .init(directoryURL: root, directoryIdentity: entry.source.directoryIdentity), item: item)
    }
    private func waitFor(_ stage: String = "retention command", diagnostics: (() async -> String)? = nil,
                         _ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            if Date() >= deadline {
                if let diagnostics { print("RETENTION_WAIT \(stage): \(await diagnostics())") }
                try #require(Date() < deadline, "Timed out waiting for \(stage)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func setup(_ entry: TransferEntry, provider: RetentionCommandProvider,
                       content: RetentionContentProvider = RetentionContentProvider()) async throws
        -> (ExplorerStore, RetentionCommandLoader) {
        let loader = RetentionCommandLoader(.init(items: [entry.item], directoryIdentity: entry.source.directoryIdentity))
        let store = ExplorerStore(initialURL: entry.source.directoryURL, loader: loader,
            contentProvider: content, oneDriveRetentionProvider: provider)
        try await waitFor { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.setSelection([entry.item.id], focusedID: entry.item.id)
        store.validateRoutingTarget = { _ in true }; store.validateRoutingFolder = { _, _ in true }
        return (store, loader)
    }
    private func settle(_ store: ExplorerStore, provider: RetentionCommandProvider) async throws {
        store.cancelLoads(); provider.stop()
        try await waitFor { !OneDriveRetentionActivity.shared.isBusy }
    }

    @Test(arguments: [OneDriveRetentionAction.keep, .freeSpace], ["nativeMenu", "accessibility"])
    func realBoundMenuDispatchesExactlyOnce(_ action: OneDriveRetentionAction, _ route: String) async throws {
        _ = NSApplication.shared
        let entry = source(), provider = RetentionCommandProvider()
        let (store, loader) = try await setup(entry, provider: provider)
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        let identifier = action == .keep ? "context-oneDriveKeep" : "context-oneDriveFreeSpace"
        let row = try #require(menu.items.first { $0.identifier?.rawValue == identifier })
        #expect(row.isEnabled && row.state == .off && row.target is ContextMenuBinding && row.image != nil)
        #expect(provider.calls.isEmpty, "Menu construction cannot query the provider")
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        if route == "nativeMenu" {
            menu.performActionForItem(at: menu.index(of: row)); menu.performActionForItem(at: menu.index(of: row))
        } else {
            let button = ContextActionButton(title: row.title, identifier: identifier)
            button.invoke = { session.activate(row) }
            #expect(button.accessibilityPerformPress()); #expect(!button.accessibilityPerformPress())
        }
        try await waitFor { provider.calls.count == 1 }
        #expect(provider.calls == [action])
        #expect(store.cloudCommandProgress?.statusText == "Updating offline retention…")
        provider.finish(outcome(action))
        try await waitFor { store.cloudCommandProgress == nil && !store.activeTab.isRefreshing }
        #expect(store.operationNotice == OneDriveRetentionCommand.notice(outcome(action), action: action, name: entry.item.name))
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        #expect(await loader.reads == 2)
        try await settle(store, provider: provider)
    }

    @Test(arguments: [OneDriveRetentionAction.keep, .freeSpace], ["nativeMenu", "accessibility"])
    func runningSyncBoundMenuDispatchesExactlyOnce(_ action: OneDriveRetentionAction, _ route: String) async throws {
        _ = NSApplication.shared
        let entry = source(), provider = RetentionCommandProvider()
        provider.running = true
        let (store, loader) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); provider.stop() }
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        let identifier = action == .keep ? "context-oneDriveKeep" : "context-oneDriveFreeSpace"
        let row = try #require(menu.items.first { $0.identifier?.rawValue == identifier })
        try #require(row.isEnabled, "Known running OneDrive must admit the captured retention command")
        #expect(row.toolTip == nil && row.state == .off && row.target is ContextMenuBinding)
        #expect(provider.calls.isEmpty, "Menu construction cannot submit a provider command")
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        if route == "nativeMenu" {
            menu.performActionForItem(at: menu.index(of: row)); menu.performActionForItem(at: menu.index(of: row))
        } else {
            let button = ContextActionButton(title: row.title, identifier: identifier)
            button.invoke = { session.activate(row) }
            #expect(button.accessibilityPerformPress()); #expect(!button.accessibilityPerformPress())
        }
        try await waitFor("running retention admission") { provider.calls.count == 1 }
        #expect(provider.calls == [action])
        provider.finish(outcome(action, dataless: action == .freeSpace, mode: .running))
        try await waitFor("running retention refresh") {
            guard store.cloudCommandProgress == nil, !store.activeTab.isRefreshing else { return false }
            return await loader.reads == 2
        }
        #expect(store.operationNotice == OneDriveRetentionCommand.notice(
            outcome(action, dataless: action == .freeSpace, mode: .running), action: action, name: entry.item.name))
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        try await settle(store, provider: provider)
    }

    @Test(arguments: [false, true], ["loading", "refreshing"])
    func knownSyncStatesPreserveLoadingGuards(_ running: Bool, _ phase: String) async throws {
        let entry = source(), provider = RetentionCommandProvider()
        provider.running = running
        let (store, _) = try await setup(entry, provider: provider)
        let controller = FileContextMenuController(store: store)
        let before = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        if phase == "loading" { store.tabs[0].isLoading = true }
        else { store.tabs[0].isRefreshing = true }
        let disabled = controller.menu(for: entry.item)
        for identifier in ["context-oneDriveKeep", "context-oneDriveFreeSpace"] {
            let current = disabled.items.first { $0.identifier?.rawValue == identifier }
            if phase == "loading" {
                #expect(current == nil && store.oneDriveRetentionSelectionAvailability == nil)
            } else {
                let row = try #require(current)
                #expect(!row.isEnabled && row.state == .off)
                #expect(row.toolTip == "Finish the current action first.")
            }
            let old = try #require(before.items.first { $0.identifier?.rawValue == identifier })
            #expect(!controller.commandIsEnabled(old, in: before))
            before.performActionForItem(at: before.index(of: old))
        }
        store.performOneDriveRetention(.freeSpace)
        #expect(provider.calls.isEmpty && store.cloudCommandProgress == nil)
        store.tabs[0].isLoading = false; store.tabs[0].isRefreshing = false
        try await settle(store, provider: provider)
    }

    @Test func unverifiedSyncStateDisablesBothCommandsAndRevalidatesOldMenu() async throws {
        let entry = source(), provider = RetentionCommandProvider()
        let (store, _) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); provider.stop() }
        let controller = FileContextMenuController(store: store)
        let old = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        provider.runningStateUnavailable = true
        let reason = "OneDrive’s running state could not be verified. Try again, or manage this file in Finder."
        #expect(store.oneDriveRetentionSelectionAvailability?.isEnabled == false)
        #expect(store.oneDriveRetentionSelectionAvailability?.disabledReason == reason)
        let current = controller.menu(for: entry.item)
        for identifier in ["context-oneDriveKeep", "context-oneDriveFreeSpace"] {
            let row = try #require(current.items.first { $0.identifier?.rawValue == identifier })
            #expect(!row.isEnabled && row.toolTip == reason)
            let prior = try #require(old.items.first { $0.identifier?.rawValue == identifier })
            #expect(!controller.commandIsEnabled(prior, in: old))
        }
        let keep = try #require(old.items.first { $0.identifier?.rawValue == "context-oneDriveKeep" })
        old.performActionForItem(at: old.index(of: keep))
        #expect(provider.calls.isEmpty && store.cloudCommandProgress == nil)
    }

    @Test func submittedKeepReplacementRefreshesWithoutAdoptionThenFreshSelectionCanFree() async throws {
        let suffix = UUID().uuidString
        let entry = source(suffix, availability: .onlineOnly), provider = RetentionCommandProvider()
        provider.running = true
        let content = RetentionContentProvider()
        let (store, loader) = try await setup(entry, provider: provider, content: content)
        defer { store.cancelLoads(); provider.stop() }
        let controller = FileContextMenuController(store: store)
        let oldMenu = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        let oldFree = try #require(oldMenu.items.first { $0.identifier?.rawValue == "context-oneDriveFreeSpace" })
        store.performOneDriveRetention(.keep)
        try await waitFor("Keep before replacement") { provider.calls == [.keep] }
        let replacement = source(suffix,
            identity: LocalFileIdentity(device: 1, inode: 9_002, birthSeconds: 1, birthNanoseconds: 0))
        #expect(replacement.item.id == entry.item.id && replacement.item.identity != entry.item.identity)
        await loader.set(.init(items: [replacement.item], directoryIdentity: entry.source.directoryIdentity))
        let submitted = "The retention request was submitted, but the file changed during the request. Refresh to observe its current policy and availability."
        provider.finish(.init(policy: nil, isDataless: nil, providerVersion: "synthetic", isConfirmed: false,
                              message: submitted, mode: .running))
        try await waitFor("fresh replacement listing") {
            store.cloudCommandProgress == nil && !store.activeTab.isRefreshing
                && store.activeTab.items.first?.identity == replacement.item.identity
        }
        #expect(store.operationNotice == submitted)
        #expect(store.currentSelection.selectedIDs.isEmpty, "A refreshed pathname cannot adopt the original selection authority")
        #expect(await loader.reads == 2)
        #expect(await content.requests.isEmpty, "Retention refresh cannot implicitly hydrate a replacement")
        store.setSelection([replacement.item.id], focusedID: replacement.item.id)
        #expect(!controller.commandIsEnabled(oldFree, in: oldMenu), "The original context menu cannot target the replacement")
        oldMenu.performActionForItem(at: oldMenu.index(of: oldFree))
        #expect(provider.calls == [.keep])
        let freshMenu = try #require(controller.menu(for: replacement.item) as? ContextCommandMenu)
        let free = try #require(freshMenu.items.first { $0.identifier?.rawValue == "context-oneDriveFreeSpace" })
        try #require(free.isEnabled)
        freshMenu.performActionForItem(at: freshMenu.index(of: free))
        try await waitFor("Free on newly selected replacement") { provider.calls == [.keep, .freeSpace] }
        let online = source(suffix,
                            availability: .onlineOnly, identity: replacement.item.identity)
        await loader.set(.init(items: [online.item], directoryIdentity: entry.source.directoryIdentity))
        provider.finish(outcome(.freeSpace, dataless: true, mode: .running))
        try await waitFor("Free metadata refresh") {
            guard store.cloudCommandProgress == nil, !store.activeTab.isRefreshing else { return false }
            return await loader.reads == 3
        }
        #expect(store.currentSelection.selectedIDs == [replacement.item.id])
        #expect(store.activeTab.items.first?.availability == .onlineOnly)
        #expect(store.operationNotice == "‘\(entry.item.name)’ is online-only.")
        #expect(await content.requests.isEmpty)
        #expect(provider.calls == [.keep, .freeSpace])
        try await settle(store, provider: provider)
    }

    @Test func cancelledLiveWorkerKeepsContentBlockedUntilActualCompletion() async throws {
        let entry = source(availability: .onlineOnly), provider = RetentionCommandProvider()
        provider.running = true
        let content = RetentionContentProvider(); await content.setFailImmediately()
        let (owner, _) = try await setup(entry, provider: provider)
        let (other, _) = try await setup(entry, provider: provider, content: content)
        defer { owner.cancelLoads(); other.cancelLoads(); provider.stop(); Task { await content.stop() } }
        owner.performOneDriveRetention(.freeSpace)
        try await waitFor("live worker admission") { provider.calls.count == 1 }
        owner.cancelCloudCommand()
        #expect(owner.cloudCommandProgress == nil && provider.cancelled && provider.isBusy)
        #expect(OneDriveRetentionActivity.shared.isBusy)
        #expect(!other.canDownloadSelection && !other.canChangeOneDriveRetention)
        other.togglePreviewPane(); other.setPreviewSurfaceVisible(true)
        other.downloadSelection(); other.performOneDriveRetention(.keep)
        #expect(other.preview.admittedRequest == nil && other.cloudCommandProgress == nil)
        #expect(await content.requests.isEmpty)
        #expect(provider.calls == [.freeSpace])
        #expect(owner.operationNotice == OneDriveRetentionCommand.stoppedNotice)
        provider.finish(outcome(.freeSpace, dataless: true, mode: .running))
        try await waitFor("actual live worker completion") {
            guard !OneDriveRetentionActivity.shared.isBusy else { return false }
            return await content.requests.count >= 1
        }
        #expect(await content.requests.allSatisfy { $0.hydrationPolicy == .residentOnly })
        #expect(owner.operationNotice == OneDriveRetentionCommand.stoppedNotice, "A late provider result cannot become UI success")
        #expect(provider.calls == [.freeSpace])
        try await settle(owner, provider: provider)
    }

    @Test(arguments: [false, true])
    func ownedRetentionBusyPrecedesVisibleUnregisteredChildOrUnknownState(_ unknown: Bool) async throws {
        let entry = source(), provider = RetentionCommandProvider()
        let (owner, _) = try await setup(entry, provider: provider)
        let (other, _) = try await setup(entry, provider: provider)
        defer { owner.cancelLoads(); other.cancelLoads(); provider.stop() }
        owner.performOneDriveRetention(.keep)
        try await waitFor("owned retention admission") { provider.calls.count == 1 }
        // Models the census interval after a child starts but before its PID is
        // excluded. The App must report its existing reservation, not tell the
        // user to quit that child or invalidate the already-admitted command.
        provider.running = !unknown; provider.runningStateUnavailable = unknown
        for store in [owner, other] {
            #expect(store.oneDriveRetentionSelectionAvailability?.disabledReason == "A OneDrive command is still running.")
            let menu = FileContextMenuController(store: store).menu(for: entry.item)
            for identifier in ["context-oneDriveKeep", "context-oneDriveFreeSpace"] {
                let row = try #require(menu.items.first { $0.identifier?.rawValue == identifier })
                #expect(!row.isEnabled && row.toolTip == "A OneDrive command is still running.")
            }
            store.performOneDriveRetention(.freeSpace)
        }
        #expect(provider.calls == [.keep] && !provider.cancelled)
        #expect(owner.cloudCommandProgress?.phase == .updatingRetention)
        provider.running = false; provider.runningStateUnavailable = false
        provider.finish(outcome(.keep))
        try await waitFor("owned retention completion") { owner.cloudCommandProgress == nil }
        #expect(owner.operationNotice == OneDriveRetentionCommand.notice(outcome(.keep), action: .keep, name: entry.item.name))
    }

    @Test(arguments: ["unknown", "regularity", "multiple", "selection", "identity"])
    func unsupportedOrStaleMenuDoesNotDispatch(_ change: String) async throws {
        let entry = source(), provider = RetentionCommandProvider()
        let (store, _) = try await setup(entry, provider: provider)
        let controller = FileContextMenuController(store: store)
        let old = try #require(controller.menu(for: entry.item) as? ContextCommandMenu)
        let row = try #require(old.items.first { $0.identifier?.rawValue == "context-oneDriveFreeSpace" })
        if change == "selection" { store.setSelection([], focusedID: nil) }
        else if change == "multiple" {
            let second = source("second")
            store.tabs[0].items.append(second.item)
            store.setSelection([entry.item.id, second.item.id], focusedID: second.item.id)
        } else {
            store.tabs[0].items[0] = FileItem(url: entry.item.url, name: entry.item.name, isDirectory: false,
                isSymbolicLink: false, size: 65_536, modifiedAt: nil, kind: "Text",
                identity: change == "identity" ? LocalFileIdentity(device: 1, inode: 9_002, birthSeconds: 1, birthNanoseconds: 0) : entry.item.identity,
                availability: change == "unknown" ? .unknown : .availableLocally,
                isRegularFile: change == "regularity" ? nil : true, statusVersion: entry.item.statusVersion)
        }
        #expect(!controller.commandIsEnabled(row, in: old))
        old.performActionForItem(at: old.index(of: row))
        #expect(provider.calls.isEmpty && store.cloudCommandProgress == nil)
        if change != "identity" { #expect(store.oneDriveRetentionSelectionAvailability == nil) }
        try await settle(store, provider: provider)
    }

    @Test(arguments: ["cancel", "selection", "navigation", "refresh", "teardown"])
    func invalidationCancelsBothTaskAndControlAndIgnoresLateResult(_ intent: String) async throws {
        let entry = source(), provider = RetentionCommandProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls.count == 1 }
        switch intent {
        case "cancel": store.cancelCloudCommand()
        case "selection": store.setSelection([], focusedID: nil)
        case "navigation": store.navigate(to: entry.source.directoryURL.appendingPathComponent("other"))
        case "refresh": store.refresh()
        default: store.cancelLoads()
        }
        #expect(provider.cancelled && store.cloudCommandProgress == nil)
        #expect(OneDriveRetentionActivity.shared.isBusy, "Native ownership outlives the cancelled UI wait")
        let notice = store.operationNotice
        if intent == "cancel" || intent == "selection" { #expect(notice == OneDriveRetentionCommand.stoppedNotice) }
        provider.finish(outcome(.freeSpace, dataless: true))
        try await waitFor { !OneDriveRetentionActivity.shared.isBusy }
        #expect(store.operationNotice == notice)
        try await settle(store, provider: provider)
    }

    @Test(arguments: ["preview", "download"], [false, true])
    func contentInAnotherStorePreventsRetention(_ kind: String, _ running: Bool) async throws {
        let entry = source(availability: .onlineOnly), provider = RetentionCommandProvider()
        provider.running = running
        let content = RetentionContentProvider()
        let (first, _) = try await setup(entry, provider: provider, content: content)
        let (second, _) = try await setup(entry, provider: provider)
        if kind == "preview" { first.togglePreviewPane(); first.setPreviewSurfaceVisible(true) }
        else { first.downloadSelection() }
        try await waitFor { await content.requests.count == 1 }
        #expect(second.oneDriveRetentionSelectionAvailability?.isEnabled == false)
        second.performOneDriveRetention(.freeSpace)
        #expect(provider.calls.isEmpty)
        first.cancelLoads()
        #expect(!second.canChangeOneDriveRetention, "Cancelled materialization still owns physical content")
        await content.stop()
        try await waitFor { second.canChangeOneDriveRetention }
        try await settle(second, provider: provider)
    }

    @Test(arguments: ["preview", "download"])
    func closedStoreLateLeaseKeepsRetentionBlockedUntilActualRelease(_ kind: String) async throws {
        let entry = source(availability: .onlineOnly), provider = RetentionCommandProvider()
        let content = RetentionContentProvider()
        var first: ExplorerStore? = try await setup(entry, provider: provider, content: content).0
        weak var observed = first
        let (second, _) = try await setup(entry, provider: provider)
        if kind == "preview" { first?.togglePreviewPane(); first?.setPreviewSurfaceVisible(true) }
        else { first?.downloadSelection() }
        try await waitFor { await content.requests.count == 1 }
        first?.cancelLoads(); first = nil
        try await waitFor { observed == nil }
        #expect(!second.canChangeOneDriveRetention)
        second.performOneDriveRetention(.freeSpace)
        #expect(provider.calls.isEmpty)
        let lease = RetentionDelayedLease(entry)
        await content.finish(lease)
        try await waitFor { lease.releaseCalls == 1 }
        #expect(!second.canChangeOneDriveRetention, "A lease release that has started is not finished")
        second.performOneDriveRetention(.freeSpace)
        #expect(provider.calls.isEmpty)
        lease.finishRelease()
        try await waitFor { second.canChangeOneDriveRetention }
        #expect(lease.releaseCalls == 1)
        try await settle(second, provider: provider)
    }

    // Review m1 RED uses existing Store APIs: one physical file, two captured
    // parent spellings, and the small birth drift already observed on hydration.
    @Test(arguments: ["preview", "download"])
    func directoryAliasContentUseBlocksCanonicalRetentionAfterStoreCloses(_ kind: String) async throws {
        let entry = source(availability: .onlineOnly), alias = directoryAlias(of: entry)
        let provider = RetentionCommandProvider(), content = RetentionContentProvider()
        var first: ExplorerStore? = try await setup(alias, provider: provider, content: content).0
        let (canonical, _) = try await setup(entry, provider: provider)
        defer { first?.cancelLoads(); canonical.cancelLoads(); provider.stop(); Task { await content.stop() } }
        #expect(first?.oneDriveRetentionSelectionAvailability == nil, "An alias does not gain retention menu authority")
        if kind == "preview" { first?.togglePreviewPane(); first?.setPreviewSurfaceVisible(true) }
        else { first?.downloadSelection() }
        try await waitFor("alias content admission") { await content.requests.count == 1 }
        #expect(!canonical.canChangeOneDriveRetention, "The canonical candidate must see alias content use")
        first?.cancelLoads(); first = nil
        #expect(!canonical.canChangeOneDriveRetention, "A closed alias store still owns cancelled materialization")
        let lease = RetentionDelayedLease(alias)
        await content.finish(lease)
        try await waitFor("late alias lease release") { lease.releaseCalls == 1 }
        #expect(!canonical.canChangeOneDriveRetention, "Alias cleanup must finish before canonical retention can start")
        lease.finishRelease()
        try await waitFor("alias content cleanup") { canonical.canChangeOneDriveRetention }
    }

    @Test func canonicalRetentionBlocksAliasDownloadAndPreviewThenKeepsAliasResidentOnly() async throws {
        let entry = source(availability: .onlineOnly), alias = directoryAlias(of: entry)
        let provider = RetentionCommandProvider(), content = RetentionContentProvider()
        await content.setFailImmediately()
        let (canonical, _) = try await setup(entry, provider: provider)
        let (aliased, _) = try await setup(alias, provider: provider, content: content)
        defer { canonical.cancelLoads(); aliased.cancelLoads(); provider.stop(); Task { await content.stop() } }
        #expect(aliased.oneDriveRetentionSelectionAvailability == nil)
        canonical.performOneDriveRetention(.freeSpace)
        try await waitFor("canonical retention admission") { provider.calls.count == 1 }
        #expect(!aliased.canDownloadSelection)
        aliased.downloadSelection()
        #expect(aliased.cloudCommandProgress == nil, "Alias Download must not start during canonical retention")
        aliased.togglePreviewPane(); aliased.setPreviewSurfaceVisible(true)
        #expect(aliased.preview.admittedRequest == nil, "Alias Preview must not acquire the protected source")
        #expect(await content.requests.isEmpty)
        provider.finish(outcome(.freeSpace, dataless: true))
        try await waitFor("alias Preview after retention") {
            await content.requests.contains { $0.source.item.identity == alias.item.identity }
        }
        #expect(await content.requests.allSatisfy { $0.hydrationPolicy == .residentOnly })
        #expect(aliased.currentSelection.selectedIDs == [alias.item.id])
    }

    @Test func retentionBlocksOtherStoreContentAndKeepsResidentOnlyBarrierAfterBirthDrift() async throws {
        let entry = source(availability: .onlineOnly), provider = RetentionCommandProvider()
        let content = RetentionContentProvider(); await content.setFailImmediately()
        let (first, _) = try await setup(entry, provider: provider)
        let (second, loader) = try await setup(entry, provider: provider, content: content)
        defer { first.cancelLoads(); second.cancelLoads(); provider.stop(); Task { await content.stop() } }
        let diagnostics: () async -> String = {
            let requests = await content.requests
            return "calls=\(provider.calls.count), reservation=\(OneDriveRetentionActivity.shared.isBusy), "
                + "contentUse=\(PhysicalContentUse.shared.isInUse(of: entry.item.url)), "
                + "requests=\(requests.map { String(describing: $0.source.item.identity) + ":" + String(describing: $0.hydrationPolicy) }), "
                + "preview=\(second.preview.state), refreshing=\(second.activeTab.isRefreshing), "
                + "reads=\(await loader.reads), row=\(String(describing: second.activeTab.items.first?.identity))"
        }
        first.performOneDriveRetention(.freeSpace)
        try await waitFor("retention admission", diagnostics: diagnostics) { provider.calls.count == 1 }
        #expect(!second.canDownloadSelection && !second.canChangeOneDriveRetention)
        second.togglePreviewPane(); second.setPreviewSurfaceVisible(true)
        second.downloadSelection()
        #expect(await content.requests.isEmpty)
        provider.finish(outcome(.freeSpace, dataless: true))
        try await waitFor("first resident-only request", diagnostics: diagnostics) {
            await content.requests.contains { $0.source.item.identity == entry.item.identity }
        }
        #expect(await content.requests.allSatisfy { $0.hydrationPolicy == .residentOnly })
        // The provider records a request before Preview handles its failure and
        // refreshes metadata. Settle that load before changing the fixture; its
        // loader must return the same changed identity as the displayed row.
        try await waitFor("initial Preview failure and metadata refresh", diagnostics: diagnostics) {
            guard case .failed = second.preview.state, !second.activeTab.isRefreshing else { return false }
            return await loader.reads >= 2
        }
        let changed = FileItem(url: entry.item.url, name: entry.item.name, isDirectory: false,
            isSymbolicLink: false, size: 65_536, modifiedAt: nil, kind: "Text",
            identity: LocalFileIdentity(device: 1, inode: 9_001, birthSeconds: 1, birthNanoseconds: 6),
            availability: .onlineOnly, isRegularFile: true, statusVersion: entry.item.statusVersion)
        await loader.set(.init(items: [changed], directoryIdentity: entry.source.directoryIdentity))
        second.tabs[0].items[0] = changed
        second.setPreviewSurfaceVisible(false); second.setPreviewSurfaceVisible(true)
        try await waitFor("resident-only request after birth drift and remount", diagnostics: diagnostics) {
            await content.requests.contains { $0.source.item.identity == changed.identity }
        }
        #expect(await content.requests.allSatisfy { $0.hydrationPolicy == .residentOnly })
        try await settle(first, provider: provider); second.cancelLoads(); await content.stop()
    }

    @Test(arguments: [OneDriveRetentionAction.keep, .freeSpace], [false, true])
    func confirmedPolicyCopyDistinguishesResidency(_ action: OneDriveRetentionAction, _ dataless: Bool) {
        let result = OneDriveRetentionCommand.notice(outcome(action, dataless: dataless), action: action, name: "synthetic.txt")
        switch (action, dataless) {
        case (.keep, false): #expect(result == "Always kept on this device: ‘synthetic.txt’.")
        case (.keep, true): #expect(result == "Pinned ‘synthetic.txt’. Local contents are not downloaded yet.")
        case (.freeSpace, false): #expect(result == "Released offline retention for ‘synthetic.txt’. Local contents are still present.")
        case (.freeSpace, true): #expect(result == "Released offline retention for ‘synthetic.txt’. Local contents were removed.")
        }
        #expect(OneDriveRetentionCommand.notice(outcome(action, dataless: nil), action: action, name: "synthetic.txt")
            .contains("Local availability is unconfirmed."))
    }

    @Test func unconfirmedResultPreservesWarningAndDoesNotClaimSuccess() async throws {
        let entry = source(), provider = RetentionCommandProvider()
        let (store, _) = try await setup(entry, provider: provider)
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls.count == 1 }
        let warning = "The file changed after submission. The command may have affected the item now at that name."
        provider.finish(outcome(.freeSpace, dataless: true, confirmed: false, message: warning))
        try await waitFor { store.cloudCommandProgress == nil }
        #expect(store.operationNotice == warning)
        try await settle(store, provider: provider)
    }

    private var deferredNotice: String {
        "OneDrive has unpinned this file. It is still on this device. OneDrive may finish removing the local copy in the background."
    }
    private func deferredOutcome(_ deferred: Bool = true) -> OneDriveRetentionOutcome {
        .init(policy: .unpinned, isDataless: false, providerVersion: "synthetic", isConfirmed: false,
              message: deferredNotice, mode: .running, removalDeferred: deferred)
    }
    private func badgeScope(_ store: ExplorerStore) -> OneDriveBadgeCache.Scope {
        .init(tab: store.activeTabID, folder: store.activeTab.url,
              load: store.contextMenuLoadGeneration, searchGeneration: store.activeTab.search?.generation)
    }

    @Test func deferredFreeCompletesFromFreshBadgeAfterResidencyReload() async throws {
        let suffix = UUID().uuidString, entry = source(suffix), provider = RetentionCommandProvider()
        provider.running = true
        let content = RetentionContentProvider()
        let (store, loader) = try await setup(entry, provider: provider, content: content)
        defer { store.cancelLoads(); provider.stop() }
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls == [.freeSpace] }
        provider.finish(deferredOutcome())
        try await waitFor { store.cloudCommandProgress == nil && !store.activeTab.isRefreshing }
        #expect(store.operationNotice == deferredNotice)
        let previousLoad = store.contextMenuLoadGeneration
        let online = source(suffix, availability: .onlineOnly, identity: entry.item.identity)
        await loader.set(.init(items: [online.item], directoryIdentity: entry.source.directoryIdentity))
        store.refreshAfterActivation()
        try await waitFor { !store.activeTab.isRefreshing && store.activeTab.items.first?.availability == .onlineOnly }
        #expect(store.contextMenuLoadGeneration != previousLoad)
        #expect(store.operationNotice == deferredNotice, "A listing alone does not confirm current pin policy")
        #expect(store.pinBadgeEntry(online.item) != nil, "Online-only rows still supply visible policy demand")
        let scope = badgeScope(store), owner = UUID()
        let cache = OneDriveBadgeCache(debounce: .zero) { _ in .init(policy: .unpinned, isDataless: true) }
        cache.update(owner, scope: scope, entries: [online], changed: {}, observed: { entry, observation in
            store.receivedOneDriveBadgeObservation(observation, for: entry, scope: scope)
        })
        try await waitFor { store.operationNotice == "‘\(entry.item.name)’ is online-only." }
        cache.remove(owner)
        #expect(store.currentSelection.selectedIDs == [entry.item.id])
        #expect(provider.calls == [.freeSpace], "Observation cannot reissue a setter")
        #expect(await content.requests.isEmpty, "Late completion cannot hydrate the file")
        try await settle(store, provider: provider)
    }

    @Test(arguments: ["none", "pinned", "resident", "untyped", "dismiss", "selection", "navigation",
                      "new-notice", "replacement", "parent", "size", "mtime", "raw-nanosecond",
                      "observed-nanosecond", "foreign-scope"])
    func deferredFreeRejectsUnrelatedOrSupersededEvidence(_ change: String) async throws {
        let entry = source(), provider = RetentionCommandProvider()
        provider.running = true
        let (store, _) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); provider.stop() }
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls == [.freeSpace] }
        provider.finish(deferredOutcome(change != "untyped"))
        try await waitFor { store.cloudCommandProgress == nil && !store.activeTab.isRefreshing }
        var observedEntry = entry
        var scope = badgeScope(store)
        var observation = OneDriveBadgeObservation(policy: .unpinned, isDataless: true)
        switch change {
        case "none": observation = .init(policy: .none, isDataless: true)
        case "pinned": observation = .init(policy: .pinned, isDataless: true)
        case "resident": observation = .init(policy: .unpinned, isDataless: false)
        case "dismiss": store.dismissOperationNotice()
        case "selection": store.setSelection([], focusedID: nil)
        case "navigation": store.navigate(to: URL(fileURLWithPath: "/tmp/deferred-other-folder"))
        case "new-notice": store.noteContextRouteRefusal(changedNames: ["other.txt"])
        case "replacement", "size", "mtime", "raw-nanosecond", "observed-nanosecond":
            let item = entry.item
            let stamp = try #require(item.statusVersion)
            let changedStamp = LocalFileStatusVersion(size: stamp.size, modificationSeconds: stamp.modificationSeconds,
                                                      modificationNanoseconds: stamp.modificationNanoseconds + 1)
            let changed = FileItem(url: item.url, name: item.name, isDirectory: false, isSymbolicLink: false,
                size: change == "size" ? item.size! + 1 : item.size,
                modifiedAt: change == "mtime" ? Date(timeIntervalSince1970: 5) : item.modifiedAt, kind: item.kind,
                identity: change == "replacement" ? .init(device: 1, inode: 99_999, birthSeconds: 1, birthNanoseconds: 0) : item.identity,
                availability: .onlineOnly, isRegularFile: true,
                statusVersion: change == "raw-nanosecond" || change == "observed-nanosecond" ? changedStamp : stamp)
            if change == "observed-nanosecond" {
                observedEntry = TransferEntry(source: entry.source, item: changed)
            } else {
                store.tabs[0].items = [changed]
                // Restoring the old stamp cannot revive the abandoned completion.
                store.tabs[0].items = [item]
            }
        case "parent":
            observedEntry = .init(source: .init(directoryURL: entry.source.directoryURL,
                directoryIdentity: .init(device: 1, inode: 99_998, birthSeconds: 1, birthNanoseconds: 0)), item: entry.item)
        case "foreign-scope":
            scope = .init(tab: UUID(), folder: scope.folder, load: scope.load, searchGeneration: nil)
        default: break
        }
        let noticeBefore = store.operationNotice
        if ["dismiss", "selection", "navigation", "replacement", "size", "mtime", "raw-nanosecond"].contains(change) {
            #expect(noticeBefore == nil, "Retiring this intent removes only its own pending notice")
        }
        store.receivedOneDriveBadgeObservation(observation, for: observedEntry, scope: scope)
        #expect(store.operationNotice == (change == "pinned" ? nil : noticeBefore))
        if change == "pinned" {
            store.receivedOneDriveBadgeObservation(.init(policy: .unpinned, isDataless: true),
                for: entry, scope: scope)
            #expect(store.operationNotice == nil, "A later policy change cannot reclaim the retired request")
        }
        #expect(store.operationNotice != "‘\(entry.item.name)’ is online-only.")
        #expect(provider.calls == [.freeSpace])
        try await settle(store, provider: provider)
    }

    @Test func deferredFreeCannotReclaimIdenticalTextFromANewerCommand() async throws {
        let entry = source(), provider = RetentionCommandProvider()
        provider.running = true
        let (store, _) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); provider.stop() }
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls.count == 1 }
        provider.finish(deferredOutcome())
        try await waitFor { store.cloudCommandProgress == nil && !store.activeTab.isRefreshing }
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls.count == 2 }
        provider.finish(deferredOutcome(false))
        try await waitFor { store.cloudCommandProgress == nil && !store.activeTab.isRefreshing }
        #expect(store.operationNotice == deferredNotice)
        store.receivedOneDriveBadgeObservation(.init(policy: .unpinned, isDataless: true),
            for: entry, scope: badgeScope(store))
        #expect(store.operationNotice == deferredNotice, "Text equality does not restore the old notice owner")
        try await settle(store, provider: provider)
    }

    @Test func cancelledFreeCannotRegisterLateDeferredCompletion() async throws {
        let entry = source(), provider = RetentionCommandProvider()
        provider.running = true
        let (store, _) = try await setup(entry, provider: provider)
        defer { store.cancelLoads(); provider.stop() }
        store.performOneDriveRetention(.freeSpace)
        try await waitFor { provider.calls.count == 1 }
        store.cancelCloudCommand()
        try await waitFor { provider.cancelled }
        provider.finish(deferredOutcome())
        try await waitFor { !OneDriveRetentionActivity.shared.isBusy && !store.activeTab.isRefreshing }
        store.receivedOneDriveBadgeObservation(.init(policy: .unpinned, isDataless: true),
            for: entry, scope: badgeScope(store))
        #expect(store.operationNotice == OneDriveRetentionCommand.stoppedNotice)
        try await settle(store, provider: provider)
    }

    @Test(arguments: [OneDriveRetentionPolicy.none, .unpinned], [false, true])
    func liveFreeNoticeRequiresObservedRemoval(_ policy: OneDriveRetentionPolicy, _ dataless: Bool) {
        let message = "The original file’s Unpinned policy was confirmed. Local removal was not confirmed."
        let value = OneDriveRetentionOutcome(policy: policy, isDataless: dataless, providerVersion: "synthetic",
            isConfirmed: true, message: message, mode: .running)
        let notice = OneDriveRetentionCommand.notice(value, action: .freeSpace, name: "synthetic.txt")
        // None plus dataless can be an already-online-only no-op. The same copy
        // also describes confirmed Unpinned without inventing a prior pinned state.
        #expect(notice == (dataless ? "‘synthetic.txt’ is online-only." : message))
    }

    @Test(arguments: [OneDriveRetentionPolicy?.none, .some(.pinned), .some(.none), .some(.unpinned)],
          [Bool?.none, .some(false), .some(true)])
    func liveFreeUnknownPolicyOrResidencyDoesNotProjectSuccess(_ policy: OneDriveRetentionPolicy?, _ dataless: Bool?) {
        guard policy == nil || policy == .pinned || dataless != true else { return }
        let message = "The retention result could not be verified. Refresh to observe its current state."
        let value = OneDriveRetentionOutcome(policy: policy, isDataless: dataless, providerVersion: "synthetic",
            isConfirmed: true, message: message, mode: .running)
        #expect(OneDriveRetentionCommand.notice(value, action: .freeSpace, name: "synthetic.txt") == message)
    }

    @Test func livePartialOutcomePreservesMessageWithoutProjectingSuccess() {
        let message = "The original file’s Unpinned policy was confirmed, but the file changed before eviction. Refresh to observe its current state."
        let value = OneDriveRetentionOutcome(policy: nil, isDataless: nil, providerVersion: "synthetic",
            isConfirmed: false, message: message, mode: .running)
        #expect(OneDriveRetentionCommand.notice(value, action: .freeSpace, name: "synthetic.txt") == message)
        for policy in [OneDriveRetentionPolicy.none, .unpinned] {
            let uncertain = OneDriveRetentionOutcome(policy: policy, isDataless: true, providerVersion: "synthetic",
                isConfirmed: false, message: message, mode: .running)
            #expect(OneDriveRetentionCommand.notice(uncertain, action: .freeSpace, name: "synthetic.txt") == message)
        }
    }
}
