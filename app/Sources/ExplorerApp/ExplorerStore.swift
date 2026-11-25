import AppKit
import Combine
import ExplorerCore
import Foundation
import UniformTypeIdentifiers

enum HomeSection: Hashable { case recent, tags }

/// Per-tab state. Reference FR-TAB-005/006, EV-0290, AT-TAB-005/006.
struct BrowserTab: Identifiable {
    let id: UUID
    var history: NavigationHistory
    var homeSection: HomeSection = .recent
    var homeTag: String?
    var homeTagGeneration = UUID()
    var homeResults = HomeResultSelection()
    var pageFilter = ""
    var items: [FileItem] = []
    var directoryIdentity: LocalFileIdentity?
    var documentsFavoriteAssociation: DocumentsFavoriteAssociation?
    var archiveRevision: ArchiveRevision?
    var hasObservedCloudItems = false
    var navigationSelections = NavigationSelectionMemory()
    var selection = SelectionState()
    var revealVisibilityRequest: RevealVisibilityRequest?
    /// Retained after consumption to invalidate older queued viewport restores.
    var revealVisibilityGeneration: UUID?
    var sort = FileSort()
    var viewMode: FolderViewMode = .details
    var isLoading = false
    var isRefreshing = false
    var hasLoaded = false
    var isUnavailable = false
    var errorMessage: String?
    var accessIssue: FileAccessContext?
    /// NATIVE-P14 / MAC-062: transient results over this committed folder.
    var search: SearchSession?
    var url: URL { history.current }
    var folderTitle: String {
        BrowsingPresentation.title(url)
    }
    var title: String { search?.title ?? folderTitle }

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.history = NavigationHistory(initialURL: url)
    }
}

struct DocumentsFavoriteAssociation: Equatable {
    let sourceURL: URL
    let destinationURL: URL
    let directoryIdentity: LocalFileIdentity
}

/// Owns UI state; filesystem work is performed by DirectoryListing off the UI thread.
/// MAC-065 / MAC-082: after the parent read commits, select exactly these entries
/// (an entry with an identity must still be that entry).
struct ItemReveal: Equatable {
    struct Entry: Equatable {
        let url: URL
        let identity: LocalFileIdentity?
        /// Search reveals require this exact path and identity (MAC-065). Requested
        /// reveals match the path, or else the sampled identity *and* the same name
        /// apart from case and Unicode normalization, so a differently spelled name
        /// still selects its entry while another hard link to the same file (a
        /// different name, hidden or not) is never selected instead (review 3c46ad9e).
        var requiresPath = true
        var archiveRevision: ArchiveRevision? = nil
        func matches(_ item: FileItem) -> Bool {
            if let archiveRevision, item.archiveRevision != archiveRevision { return false }
            let sameLocation: Bool
            if item.url.isFileURL && url.isFileURL { sameLocation = item.url.path == url.path }
            else if let actual = BrowsingLocation(url: item.url), let expected = BrowsingLocation(url: url) {
                sameLocation = actual == expected
            } else { sameLocation = false }
            if sameLocation { return identity == nil || item.identity == identity }
            guard !requiresPath, let identity, item.identity == identity else { return false }
            return Self.folded(item.url.lastPathComponent) == Self.folded(url.lastPathComponent)
        }
        static func folded(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        }
    }
    let entries: [Entry]
    let missingNotice: String?
    var requestsVisibility = false

    /// Open file location from search: only the sampled entry.
    static func searchResult(url: URL, identity: LocalFileIdentity) -> ItemReveal {
        ItemReveal(entries: [Entry(url: url, identity: identity)],
                   missingNotice: "The search result is no longer in this folder.")
    }
    /// Items another application asked Orchard Explorer to show (MAC-082).
    static func requested(_ urls: [URL], identities: [String: LocalFileIdentity] = [:]) -> ItemReveal {
        ItemReveal(entries: urls.map { Entry(url: $0, identity: identities[$0.path], requiresPath: false) },
                   missingNotice: urls.count == 1
                       ? "“\(urls[0].lastPathComponent)” isn’t shown in this folder. It may be hidden or no longer exist."
                        : "Some requested items aren’t shown in this folder. They may be hidden or no longer exist.",
                   requestsVisibility: true)
    }
    static func navigationChild(_ url: URL) -> ItemReveal {
        ItemReveal(entries: [Entry(url: url, identity: nil)], missingNotice: nil)
    }
}

@MainActor
final class ExplorerStore: ObservableObject {
    /// A request survives passive restarts with its explicit navigation intents.
    private struct PendingLoad {
        var history: NavigationHistory
        var preserveSelection: Bool
        var automatic: Bool
        var addressEntry: URL?
        var endsSearch: Bool
        var reveal: ItemReveal?
        var selectionIntent: NavigationSelectionIntent
        var grantsSidebarAccess = false
        var cloudHandoff: CloudContentHandoff? = nil
        var documentsFavorite = false
        var clearsDocumentsFavoriteAssociation = false
    }

    @Published var tabs: [BrowserTab] {
        didSet {
            validateDeferredRemovalNotice()
            updatePreviewRequest()
            // MAC-076: any change to the active tab's location or selection
            // invalidates a pending second-click rename.
            guard pointerRename.isPending else { return }
            let before = oldValue.first { $0.id == activeTabID }, after = tabs.first { $0.id == activeTabID }
            if before?.url != after?.url || before?.selection.selectedIDs != after?.selection.selectedIDs
                || before?.search?.id != after?.search?.id || before?.items.map(\.id) != after?.items.map(\.id) {
                pointerRename.cancel()
            }
        }
    }
    @Published var activeTabID: UUID { didSet { if activeTabID != oldValue { cancelHomeDestination(); invalidateCloudCommandForNewIntent(); pointerRename.cancel(); updatePreviewRequest() } } }
    @Published var addressFocusRequest = 0
    @Published var showHidden = false
    @Published private(set) var inspectorPane = InspectorPaneState()
    var showsDetailsPane: Bool { inspectorPane.mode == .details }
    var showsPreviewPane: Bool { inspectorPane.mode == .preview }
    private var previewSurfaceVisible = false
    let homeFileOperations = HomeFileOperationState()
    var readHomeOperationEntry: HomeInspector.ReadEntry = { try await LocalDirectoryLoader.operationEntry(at: $0) }
    func reportHomeOperationFailure(_ error: Error) { operationNotice = error.localizedDescription }
    var readHomeInspectorEntry: HomeInspector.ReadEntry = { try await LocalDirectoryLoader.inspectorEntry(at: $0) }
    private var homeInspectionOrigin: HomeInspectionOrigin?
    private var homeInspectionTask: Task<Void, Never>?
    private var homeInspectionFailed = false
    private var homeInspectionEntry: ItemOperationEntry?
    let contentProvider: any ItemContentProviding
    let oneDriveRetentionProvider: any OneDriveRetentionProviding
    let cloudStatusOwner = UUID()
    let searchBadgeResidency = VisibleSearchResidency()
    var archiveModifier: any ArchiveModifying = LocalArchiveOperations()
    let contentRegistry: ContentLeaseRegistry
    let archiveBroadcaster: ArchiveMutationBroadcaster
    var externalOpenContents = ExternalOpenContents.shared
    let preview: ItemPreviewModel
    @Published private(set) var cloudCommandProgress: CloudCommandProgress?
    private var cloudCommand: CloudCommandSession?
    private var retentionCommand: OneDriveRetentionCommand?
    private var deferredRemovalNotice: DeferredOneDriveRemoval?
    private var operationNoticeGeneration = UUID()
    // Conservative after a pathname-based provider handoff: an identity drift
    // must not turn a passive refresh into permission to hydrate a replacement.
    private var retentionPreviewBarriers: [UUID: CloudContentOrigin] = [:]
    var cloudCommandTimeoutSeconds = CloudDownloadPolicy.timeoutSeconds
    private var contentIntentIDs: [UUID: UUID] = [:]
    private var contentBarriers: [UUID: CloudContentOrigin] = [:]
    private var previewOrigins: [UUID: CloudContentOrigin] = [:]
    private var contentHandoffs: [UUID: CloudContentHandoff] = [:]
    private var previewUpdateDepth = 0
    private var previewUpdatePending = false
    @Published private(set) var observationWarning: String?
    @Published private(set) var shortcutDraft: ShortcutDraft? {
        didSet { if shortcutDraft != nil { invalidateCloudCommandForNewIntent(); cancelRevealVisibility() } }
    }
    private var shortcutValidation: Task<Void, Never>?
    @Published private(set) var nameEdit: NameEditSession? {
        didSet {
            if nameEdit != nil {
                invalidateCloudCommandForNewIntent()
                cancelRevealVisibility()
                pointerRename.cancel()
                address.cancelPendingSubmission()
            }
            updatePreviewRequest()
        }
    }
    /// Any write (including Restore/Undo, whose completion navigates without
    /// prepareForNavigation) supersedes a result activation still revalidating.
    @Published private(set) var isPerformingOperation = false {
        didSet {
            if isPerformingOperation {
                invalidateCloudCommandForNewIntent()
                cancelRevealVisibility()
                cancelSearchActivation()
                pointerRename.cancel()
                address.cancelPendingSubmission()
            }
            updatePreviewRequest()
        }
    }
    @Published private(set) var operationNotice: String? {
        didSet {
            operationNoticeGeneration = UUID()
            deferredRemovalNotice = nil
        }
    }
    @Published private(set) var transfer: TransferSession?
    @Published private(set) var trashProgress: TrashProgress?
    @Published private(set) var isShowingRecovery = false {
        didSet {
            if isShowingRecovery { invalidateCloudCommandForNewIntent(); cancelRevealVisibility() }
            updatePreviewRequest()
        }
    }
    @Published private(set) var recoveryError: String?
    @Published private(set) var operationAccessIssue: FileAccessContext?
    @Published private(set) var recoveryAccessIssue: FileAccessContext?
    @Published private var renameRecovery: RenameRecovery?
    @Published private(set) var searchFocusRequest = 0
    let clipboard: TransferClipboard
    /// MAC-076: the pending second-click rename candidate (tests may replace the scheduler).
    var pointerRename = PointerRenameIntent()
    /// NATIVE-P18A services (tests replace them with doubles).
    var fileCreator: any FileCreating = LocalFileCreator()
    var archiver: any ArchiveCreating = LocalArchiveCreator()
    var aliasCreator: any AliasCreating = LocalAliasCreator()
    lazy var applications: any ApplicationRouting = LocalApplicationRouter()
    private var openWithAssociations: Set<String> = []
    private let openWithTypeReservations: OpenWithTypeReservations
    @Published private(set) var archiveProgress: ArchiveProgress?
    struct RecentOpenConfirmation {
        let id = UUID()
        let original: RecentDocument
        let candidate: RecentDocument
        let tabID: UUID
        let epoch: UUID?
        var rowIsCurrent: @MainActor () -> Bool = { true }
    }
    @Published private(set) var recentOpenConfirmation: RecentOpenConfirmation?
    @Published var finderTagEditor: FinderTagEditor?
    @Published private(set) var archiveDeleteConfirmation: ArchiveDeleteConfirmation?
    private var archiveControl: TransferControl?
    let recoveryHistory: RecoveryHistory
    let homeURL: URL
    let pins: PinnedFolderStore
    let recentDocuments: RecentDocumentStore
    let tagShortcuts: FinderTagShortcuts
    let focus = ExplorerFocusCoordinator()
    let address: AddressNavigationModel
    var onShowAccessHelp: ((FileAccessContext?) -> Void)?
    var onShowProperties: ((FileItem) -> Void)?
    var onChooseHomeFolder: ((@escaping (URL?) -> Void) -> Void)?
    var onCancelHomeFolder: (() -> Void)?
    @Published private(set) var pendingHomeDestination: UUID?
    private var homePasteRequest: UUID?
    var onShowMultipleProperties: (([FileItem]) -> Void)?
    var onOpenWindow: ((URL, String?) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onDetachTab: ((BrowserTab, NSPoint?) -> Void)?
    private let loader: any DirectoryListing
    private let observer: (any DirectoryObserving)?
    private let operations: any FileOperating
    private let transfers: any FileTransferring
    private let transferImporter: any FileTransferImporting
    private let transferCounter: any TransferCounting
    private let conflictInspector: any ConflictInspecting
    private let recovery: any FileRecovering
    private let searcher: any FilenameSearching
    private let validateSearchResult: @Sendable (FilenameSearchResult) async throws -> Bool
    var resolvePhysicalAddress: @Sendable (URL) async throws -> FileActivationTarget = {
        try await FileActivationTarget.resolvePhysicalAddress($0)
    }
    private var searchTasks: [UUID: Task<Void, Never>] = [:]
    private var searchActivation: Task<Void, Never>?
    private var searchActivationToken: UUID?
    private var clipboardSubscription: AnyCancellable?
    private var homeDeparturesSubscription: AnyCancellable?
    private var recoverySubscription: AnyCancellable?
    private var previewSubscription: AnyCancellable?
    private var deferredPreviewLoads: [UUID: PendingLoad] = [:]
    private var previewMetadataTasks: [UUID: Task<Void, Never>] = [:]
    private var previewMetadataTokens: [UUID: UUID] = [:]
    private struct TransferRuntime {
        let id: UUID
        let control = TransferControl()
        var task: Task<Void, Never>?
        var progressID: UUID?
        var conflictReply: CheckedContinuation<TransferConflictChoice, Never>?
        var conflictInspection: ConflictInspectionWaiter?
        var pauseWaiter: CheckedContinuation<Void, Never>?
    }
    private var transferRuntime: TransferRuntime?
    /// MAC-074: view-presentation state that must survive an interface-size
    /// rebuild of the window's views (review 7a1a7cf8 #2/#3).
    private var ownedSidebarModel: SidebarModel?
    private let sidebarBackgroundCheckPreferences: SidebarBackgroundCheckPreferences
    private let sidebarLocations: SidebarLocationCatalog?
    private var sidebarSettingsSubscription: AnyCancellable?
    private var tagShortcutChanges: AnyCancellable?
    private let sidebarPresenceChecker: any FolderChildPresenceChecking
    private let sidebarPresenceNow: @MainActor () -> TimeInterval
    var sidebarModel: SidebarModel {
        if let ownedSidebarModel { return ownedSidebarModel }
        let model = SidebarModel(homeURL: homeURL, pins: pins, showHidden: showHidden,
                                 presenceChecker: sidebarPresenceChecker, presenceNow: sidebarPresenceNow,
                                 backgroundCheckOptions: sidebarBackgroundCheckPreferences.options, locations: sidebarLocations)
        ownedSidebarModel = model
        return model
    }
    let searchFieldDraft = SearchFieldDraft()
    /// Details column widths in reference points (divide by the scale when stored).
    var detailsColumnWidths: [String: CGFloat] = [:]
    private var operationTask: Task<Void, Never>?
    private var operationResult: (tabID: UUID, context: FileOperationContext, results: [FileOperationResult])?
    private struct ActiveLoad {
        enum Request { case directory(PendingLoad), archiveReconciliation }
        let token = UUID()
        let request: Request
        var task: Task<Void, Never>?
    }
    private struct TabLoadState {
        // Authorization for the committed snapshot is independent of a worker's
        // permission to publish. Deferring a read revokes only its work token.
        let authorizationEpoch = UUID()
        var work: ActiveLoad?
    }
    private var tabLoads: [UUID: TabLoadState] = [:]
    /// Read-only invocation token; refresh/navigation invalidates an open context surface.
    var contextMenuLoadGeneration: UUID? { tabLoads[activeTabID]?.authorizationEpoch }
    /// Retry replays the complete failed intent, including search exit/reveal (MAC-062/065).
    private var failedLoads: [UUID: PendingLoad] = [:]
    private var observationTask: Task<Void, Never>?
    private var observationEpoch = UUID()
    private var observationTarget: (tabID: UUID, url: URL)?
    private var observationDebounce: Task<Void, Never>?
    private var retiredBadgeSearch: UUID?
    private var retiredBadgeHits = Set<OneDriveStatusKey>()
    private var observationDirty = false
    private var observationNeedsRebind = false

    convenience init(initialURL: URL, initialSidebarKey: String? = nil, loader: any DirectoryListing = BrowsingDirectoryLoader(),
                     homeURL: URL? = nil, pins: PinnedFolderStore? = nil,
                     observer: (any DirectoryObserving)? = nil,
                     operations: any FileOperating = LocalFileOperations(),
                     transfers: any FileTransferring = LocalFileTransfers(),
                     transferImporter: any FileTransferImporting = LocalFileTransferImporter(),
                     clipboard: TransferClipboard? = nil,
                     recovery: any FileRecovering = LocalFileRecovery(),
                     recoveryHistory: RecoveryHistory? = nil,
                     searcher: any FilenameSearching = LocalFilenameSearcher(),
                     validateSearchResult: @escaping @Sendable (FilenameSearchResult) async throws -> Bool
                        = FilenameSearchValidation.isCurrent,
                     transferCounter: any TransferCounting = LocalTransferCounter(),
                     conflictInspector: any ConflictInspecting = LocalConflictInspector(),
                     contentRegistry: ContentLeaseRegistry = .shared,
                     contentProvider: (any ItemContentProviding)? = nil,
                     oneDriveRetentionProvider: any OneDriveRetentionProviding = OneDriveRetentionService.shared,
                     archiveBroadcaster: ArchiveMutationBroadcaster? = nil,
                     recentAddressHistory: RecentAddressHistory? = nil, recentDocuments: RecentDocumentStore? = nil,
                     tagShortcuts: FinderTagShortcuts? = nil,
                     openWithTypeReservations: OpenWithTypeReservations? = nil,
                     sidebarPresenceChecker: any FolderChildPresenceChecking = LocalFolderChildPresenceChecker(),
                     sidebarPresenceNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sidebarBackgroundCheckPreferences: SidebarBackgroundCheckPreferences? = nil,
                     sidebarLocations: SidebarLocationCatalog? = nil) {
        self.init(tab: BrowserTab(url: initialURL), initialSidebarKey: initialSidebarKey, loader: loader,
                  homeURL: homeURL, pins: pins, observer: observer, operations: operations,
                  transfers: transfers, transferImporter: transferImporter, clipboard: clipboard,
                  recovery: recovery, recoveryHistory: recoveryHistory, searcher: searcher,
                  validateSearchResult: validateSearchResult, transferCounter: transferCounter,
                  conflictInspector: conflictInspector, contentRegistry: contentRegistry,
                  contentProvider: contentProvider, oneDriveRetentionProvider: oneDriveRetentionProvider,
                  archiveBroadcaster: archiveBroadcaster,
                  recentAddressHistory: recentAddressHistory, recentDocuments: recentDocuments, tagShortcuts: tagShortcuts,
                  openWithTypeReservations: openWithTypeReservations,
                  sidebarPresenceChecker: sidebarPresenceChecker, sidebarPresenceNow: sidebarPresenceNow,
                  sidebarBackgroundCheckPreferences: sidebarBackgroundCheckPreferences, sidebarLocations: sidebarLocations)
    }

    init(tab: BrowserTab, initialSidebarKey: String? = nil, loader: any DirectoryListing = BrowsingDirectoryLoader(),
         homeURL: URL? = nil, pins: PinnedFolderStore? = nil, showHidden: Bool = false,
         observer: (any DirectoryObserving)? = nil,
         operations: any FileOperating = LocalFileOperations(),
         transfers: any FileTransferring = LocalFileTransfers(),
         transferImporter: any FileTransferImporting = LocalFileTransferImporter(),
         clipboard: TransferClipboard? = nil,
         recovery: any FileRecovering = LocalFileRecovery(),
         recoveryHistory: RecoveryHistory? = nil,
         searcher: any FilenameSearching = LocalFilenameSearcher(),
         validateSearchResult: @escaping @Sendable (FilenameSearchResult) async throws -> Bool
            = FilenameSearchValidation.isCurrent,
         transferCounter: any TransferCounting = LocalTransferCounter(),
         conflictInspector: any ConflictInspecting = LocalConflictInspector(),
         contentRegistry: ContentLeaseRegistry = .shared,
         contentProvider: (any ItemContentProviding)? = nil,
         oneDriveRetentionProvider: any OneDriveRetentionProviding = OneDriveRetentionService.shared,
         archiveBroadcaster: ArchiveMutationBroadcaster? = nil,
         addressSuggester: (any FolderSuggesting)? = nil,
         recentAddressHistory: RecentAddressHistory? = nil, recentDocuments: RecentDocumentStore? = nil,
         tagShortcuts: FinderTagShortcuts? = nil,
         openWithTypeReservations: OpenWithTypeReservations? = nil,
         sidebarPresenceChecker: any FolderChildPresenceChecking = LocalFolderChildPresenceChecker(),
         sidebarPresenceNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sidebarBackgroundCheckPreferences: SidebarBackgroundCheckPreferences? = nil,
         sidebarLocations: SidebarLocationCatalog? = nil) {
        self.openWithTypeReservations = openWithTypeReservations ?? .shared
        self.recentDocuments = recentDocuments ?? RecentDocumentStore()
        self.tagShortcuts = tagShortcuts ?? FinderTagShortcuts()
        self.sidebarPresenceChecker = sidebarPresenceChecker
        self.sidebarPresenceNow = sidebarPresenceNow
        self.sidebarLocations = sidebarLocations
        let sidebarPreferences = sidebarBackgroundCheckPreferences ?? SidebarBackgroundCheckPreferences()
        self.sidebarBackgroundCheckPreferences = sidebarPreferences
        self.contentRegistry = contentRegistry
        let provider = RetentionAwareContentProvider(base: contentProvider ?? LocalItemContentProvider(registry: contentRegistry))
        self.contentProvider = provider
        self.oneDriveRetentionProvider = oneDriveRetentionProvider
        self.preview = ItemPreviewModel(provider: provider)
        self.archiveBroadcaster = archiveBroadcaster ?? .shared
        self.loader = loader
        self.address = AddressNavigationModel(suggester: addressSuggester ?? BrowsingFolderSuggester(loader: loader),
                                              recentHistory: recentAddressHistory)
        self.transferCounter = transferCounter
        self.conflictInspector = conflictInspector
        self.searcher = searcher
        self.validateSearchResult = validateSearchResult
        self.observer = observer
        self.operations = operations
        self.transfers = transfers
        self.transferImporter = transferImporter
        self.recovery = recovery
        self.recoveryHistory = recoveryHistory ?? RecoveryHistory()
        self.clipboard = clipboard ?? TransferClipboard()
        let resolvedHome = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.homeURL = resolvedHome
        self.pins = pins ?? PinnedFolderStore(homeURL: resolvedHome)
        self.showHidden = showHidden
        tabs = [tab]
        activeTabID = tab.id
        clipboardSubscription = self.clipboard.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        homeDeparturesSubscription = self.recentDocuments.departedSources.sink { [weak self] entries in
            self?.retireDepartedHomeRows(entries)
        }
        recoverySubscription = self.recoveryHistory.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        previewSubscription = self.preview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.preview.onCloudAttemptStarted = { [weak self] attempt in self?.previewAttemptStarted(attempt) }
        self.preview.onHydrationPrepared = { [weak self] prepared in
            guard let self else { prepared.receipt?.invalidate(); return }
            self.previewHydrationPrepared(prepared)
        }
        self.preview.onRetryRequested = { [weak self] intent in self?.retryPreview(intent) }
        self.preview.onCloudAttemptEnded = { [weak self] result in
            // Renderer admission must finish its synchronous lease handoff before
            // a coalesced read can replace its presentation.
            Task { @MainActor [weak self] in self?.cloudAttemptEnded(result) }
        }
        sidebarSettingsSubscription = sidebarPreferences.$options.dropFirst().sink { [weak self] options in
            self?.ownedSidebarModel?.setBackgroundCheckOptions(options)
        }
        tagShortcutChanges = self.tagShortcuts.changes.sink { [weak self] change in
            self?.applyTagShortcutChange(change)
        }
        self.archiveBroadcaster.observe(self)
        OneDriveRetentionActivity.shared.observe(self)
        if isDocumentsFavorite(key: initialSidebarKey, url: tab.url) {
            load(tabID: tab.id, history: tab.history, preserveSelection: false,
                 grantsSidebarAccess: true, documentsFavorite: true)
        } else {
            refresh(grantingSidebarAccess: false)
        }
    }

    deinit {
        let statusOwner = cloudStatusOwner
        Task { @MainActor in OneDriveBadgeCache.shared.cancelFollowUp(owner: statusOwner) }
        // The session's deinit cancels its tasks; their closures retain it
        // weakly. Store teardown only touches the Sendable cancellation token.
        cloudCommand?.control.cancel()
        retentionCommand?.control.cancel()
        contentHandoffs.values.forEach { $0.receipt?.invalidate() }
        shortcutValidation?.cancel()
        transferRuntime?.task?.cancel()
        transferRuntime?.control.cancel()
        observationTask?.cancel()
        observationDebounce?.cancel()
        tabLoads.values.forEach { $0.work?.task?.cancel() }
        searchTasks.values.forEach { $0.cancel() }
        searchActivation?.cancel()
        previewMetadataTasks.values.forEach { $0.cancel() }
        homeInspectionTask?.cancel()
    }

    var activeTab: BrowserTab { tabs.first(where: { $0.id == activeTabID }) ?? tabs[0] }
    var activePage: BrowserPage? { BrowserPage(url: activeTab.url) }

    func selectHomeSection(_ section: HomeSection) {
        guard let index = activeIndex, activePage == .home, isCommandIdle,
              tabs[index].homeSection != section else { return }
        address.cancelPendingSubmission()
        tabs[index].homeSection = section
        tabs[index].homeTag = nil
        tabs[index].homeTagGeneration = UUID()
        tabs[index].pageFilter = ""
    }

    func selectHomeTag(_ name: String?) {
        guard let index = activeIndex, activePage == .home, tabs[index].homeSection == .tags, isCommandIdle else { return }
        let tag = name?.precomposedStringWithCanonicalMapping
        if let tag, !tagShortcuts.isVisible(tag) { return }
        let drillDown = tabs[index].homeTag == tag ? nil : tag
        guard tabs[index].homeTag != drillDown else { return }
        address.cancelPendingSubmission()
        tabs[index].homeTag = drillDown
        tabs[index].homeTagGeneration = UUID()
    }

    private func applyTagShortcutChange(_ change: FinderTagShortcuts.Change) {
        if let removed = change.removedName, activePage == .home,
           activeTab.homeSection == .tags, activeTab.homeTag == removed {
            address.cancelPendingSubmission()
        }
        var updated = tabs
        var affected = false
        for index in updated.indices where updated[index].homeSection == .tags {
            if let name = updated[index].homeTag {
                guard name == change.removedName else { continue }
                updated[index].homeTag = nil
            } else if !change.defaultChanged { continue }
            // Pending actions and open tag editors validate this generation at dispatch.
            updated[index].homeTagGeneration = UUID()
            affected = true
        }
        if affected { tabs = updated }
    }

    func matchesPageFilter(_ name: String) -> Bool {
        activeTab.pageFilter.isEmpty || name.localizedCaseInsensitiveContains(activeTab.pageFilter)
    }

    var physicalFolderURL: URL? {
        guard activeTab.archiveRevision == nil else { return nil }
        return BrowsingLocation(url: activeTab.url)?.physicalURL
    }
    var hasPhysicalSelection: Bool {
        let items = selectedItemsInOrder
        return !items.isEmpty && items.allSatisfy(BrowsingPresentation.isPhysical)
    }
    var isCommandIdle: Bool {
        shortcutDraft == nil && nameEdit == nil && !isPerformingOperation && !isShowingRecovery && pendingHomeDestination == nil
            && recentOpenConfirmation == nil && finderTagEditor == nil
    }
    var canShareSelection: Bool {
        guard isCommandIdle else { return false }
        guard homeResultScope != nil else { return hasPhysicalSelection }
        guard let entries = homeOperationEntries, !entries.isEmpty else { return false }
        return entries.allSatisfy { $0.item.isRegularFile == true && !$0.item.isSymbolicLink }
    }
    func canPinFolder(_ url: URL) -> Bool {
        BrowsingLocation(url: url)?.physicalURL != nil && !isPerformingOperation && !isShowingRecovery
    }
    var canPinCurrentFolder: Bool { physicalFolderURL != nil && canPinFolder(activeTab.url) }
    func pinCurrentFolder() { if canPinCurrentFolder { pins.pin(activeTab.url) } }
    var sortedItems: [FileItem] { activeTab.sort.sorted(activeTab.items) }
    var showsCloudStatusColumn: Bool { activeTab.search?.hasObservedCloudItems ?? activeTab.hasObservedCloudItems }
    var downloadingItemID: String? {
        if let command = cloudCommand, command.phase == .downloading { return command.acceptedEntry.item.id }
        return preview.downloadingItemID
    }
    /// Metadata describes selected rows in the committed snapshot, never the
    /// focused-but-unselected row or a proposed New Folder placeholder.
    var presentationSelection: [FileItem] {
        guard isCommandIdle else { return [] }
        if let search = activeTab.search { return search.selectedResults.map(\.item) }
        guard activeTab.hasLoaded, !activeTab.isLoading, !activeTab.isUnavailable else { return [] }
        return activeTab.items.filter { activeTab.selection.selectedIDs.contains($0.id) }
    }
    var detailSelection: [FileItem] { presentationSelection }
    /// Pane-only selection. Home supplies no operation authority to menus or shortcuts.
    var inspectorDetails: HomeInspectorDetails {
        guard !tabs.isEmpty, isCommandIdle else { return .empty }
        if let targets = homeInspectorTargets {
            guard !targets.isEmpty else { return .empty }
            guard targets.count == 1 else { return .multiple(targets.count) }
            guard let origin = homeInspectionOrigin, isHomeInspectionCurrent(origin),
                  !homeInspectionFailed else { return homeInspectionFailed ? .unavailable : .preparing }
            return homeInspectionEntry.map { .single($0.item) } ?? .preparing
        }
        let items = detailSelection
        if items.count == 1, let item = items.first { return .single(item) }
        return items.isEmpty ? .empty : .multiple(items.count)
    }

    private func isHomeInspectionCurrent(_ origin: HomeInspectionOrigin) -> Bool {
        guard !tabs.isEmpty, activeTabID == origin.tab, homeInspectorGeneration == origin.generation,
              previewSurfaceVisible, inspectorPane.mode != .none, isCommandIdle,
              let targets = homeInspectorTargets, targets.count == 1, let target = targets.first else { return false }
        return target.recent.map { recentDocuments.contains($0) } ?? (target.identity != nil)
    }

    private func updateHomeInspection() {
        let targets = tabs.isEmpty ? nil : homeInspectorTargets
        let generation = tabs.isEmpty ? nil : homeInspectorGeneration
        let origin = generation.flatMap { generation in
            previewSurfaceVisible && inspectorPane.mode != .none && isCommandIdle && targets?.count == 1
                ? HomeInspectionOrigin(tab: activeTabID, generation: generation) : nil
        }
        if let origin, origin == homeInspectionOrigin, !isHomeInspectionCurrent(origin) {
            homeInspectionTask?.cancel(); homeInspectionTask = nil
            homeInspectionEntry = nil; homeInspectionFailed = true
            return
        }
        guard origin != homeInspectionOrigin else { return }
        if let prior = homeInspectionOrigin {
            previewMetadataTasks.removeValue(forKey: prior.tab)?.cancel()
            previewMetadataTokens.removeValue(forKey: prior.tab)
            let obsolete = contentHandoffs.values.filter { $0.origin.tabID == prior.tab && $0.origin.homeGeneration == prior.generation }
            for handoff in obsolete { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            previewOrigins = previewOrigins.filter { $0.value.tabID != prior.tab || $0.value.homeGeneration != prior.generation }
        }
        homeInspectionTask?.cancel(); homeInspectionTask = nil
        homeInspectionEntry = nil; homeInspectionFailed = false
        homeInspectionOrigin = origin
        guard let origin, let target = targets?.first else { return }
        guard isHomeInspectionCurrent(origin) else { homeInspectionFailed = true; return }
        let read = readHomeInspectorEntry
        homeInspectionTask = Task { [weak self] in
            let entry = try? await HomeInspector.sample(target, reading: read)
            guard !Task.isCancelled, let self, self.homeInspectionOrigin == origin,
                  self.isHomeInspectionCurrent(origin) else { return }
            self.objectWillChange.send()
            self.homeInspectionTask = nil
            self.homeInspectionEntry = entry
            self.homeInspectionFailed = entry == nil
            self.updatePreviewRequest()
        }
    }
    var currentOperationContext: ItemOperationContext? {
        guard activeTab.hasLoaded, !activeTab.isLoading, !activeTab.isUnavailable else { return nil }
        if let location = ArchiveLocation(url: activeTab.url), let revision = activeTab.archiveRevision {
            guard !activeTab.isRefreshing else { return nil }
            return .archive(ArchiveOperationContext(location: location, revision: revision))
        }
        // Physical commands use the committed snapshot while a passive read is
        // pending; starting a draft/mutation defers that read before acting.
        guard activeTab.url.isFileURL, let identity = activeTab.directoryIdentity else { return nil }
        return .filesystem(FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity))
    }
    func operationEntry(for item: FileItem) -> ItemOperationEntry? {
        if let search = activeTab.search {
            guard search.selectedResults.contains(where: { $0.item == item }),
                  let entry = selectedSearchOperationEntries?.first(where: { $0.item == item }) else { return nil }
            return ItemOperationEntry(entry)
        }
        guard let context = currentOperationContext, listsEntry(item) else { return nil }
        let entry = ItemOperationEntry(item: item, context: context)
        return entry.isValid ? entry : nil
    }
    var selectedOperationEntries: [ItemOperationEntry]? {
        let items = selectedItemsInOrder
        guard !items.isEmpty else { return nil }
        let entries = items.compactMap(operationEntry)
        return entries.count == items.count ? entries : nil
    }
    var previewRequest: PreviewRequest? {
        guard !tabs.isEmpty, !activeTab.isRefreshing else { return nil }
        return selectedPreviewRequest
    }
    private var selectedPreviewRequest: PreviewRequest? {
        guard !tabs.isEmpty, previewSurfaceVisible, showsPreviewPane else { return nil }
        if let generation = homeInspectorGeneration, homeInspectorTargets != nil {
            var request = PreviewRequest(tabID: activeTabID, generation: contextMenuLoadGeneration,
                searchGeneration: nil, items: homeInspectionEntry.map { [$0.item] } ?? [],
                entry: homeInspectionEntry, homeGeneration: generation)
            switch inspectorDetails {
            case .empty: return nil
            case .single: break
            case .multiple: request.placeholder = .multiple
            case .preparing: request.placeholder = .preparing
            case .unavailable: request.placeholder = .failed(HomeInspectorDetails.unavailableMessage)
            }
            return request
        }
        let items = presentationSelection
        return PreviewRequest(tabID: activeTabID, generation: tabLoads[activeTabID]?.authorizationEpoch,
            searchGeneration: activeTab.search?.generation, items: items,
            entry: items.count == 1 ? items.first.flatMap(operationEntry) : nil,
            searchSessionID: activeTab.search?.id)
    }
    func setPreviewSurfaceVisible(_ visible: Bool) { previewSurfaceVisible = visible; updatePreviewRequest() }
    private func updatePreviewRequest() {
        updateHomeOperationSelection()
        guard previewUpdateDepth == 0 else { previewUpdatePending = true; return }
        updateHomeInspection()
        guard !tabs.isEmpty else { preview.show(nil); return }
        var request = selectedPreviewRequest
        if let request, contentHandoffs.values.contains(where: { handoff in
            handoff.owner == .preview(handoff.requestID) && handoff.receipt != nil && !handoff.invalidated
                && preview.hasAcceptedPresentation(for: handoff.requestID)
                && isContentOriginCurrent(handoff.origin) && samePreviewSource(handoff.request, request)
        }) {
            // The renderer already owns this exact terminal attempt. Its one-use
            // receipt refresh may publish loading flags before atomically adopting
            // the new identity; those flags must not tear down the presentation.
            // Hiding, changing source, remounting or invalidating proof still wins.
            return
        }
        if let entry = request?.entry, let physical = entry.physicalEntry, let origin = contentOrigin(for: entry) {
            if OneDriveRetentionActivity.shared.blocks(PhysicalContentTarget(physical)) {
                retentionPreviewBarriers[activeTabID] = origin
                preview.show(nil); return
            }
            if let command = cloudCommand, command.origin == origin, command.waitingPreviewID == nil {
                preview.show(nil); return
            }
            if let admitted = preview.admittedRequest, preview.activeCloudAttempt != nil,
               samePreviewSource(admitted, request) {
                request?.hydrationPolicy = admitted.hydrationPolicy
            } else if contentBarriers[activeTabID] == origin || retentionBarrierMatches(origin) {
                request?.hydrationPolicy = .residentOnly
            }
        }
        if activeTab.isRefreshing { preview.suspendForAutomaticRefresh(request) }
        else { preview.show(request) }
    }

    var downloadSelectionAvailability: CloudDownloadAvailability? {
        guard let entries = selectedOperationEntries, entries.count == 1, let entry = entries.first,
              let physical = entry.physicalEntry, entry.item.isRegularFile == true,
              !entry.item.isDirectory, !entry.item.isSymbolicLink, entry.item.availability == .onlineOnly else { return nil }
        let reason: String?
        if !isCommandIdle || cloudCommand != nil || retentionCommand != nil { reason = "Finish the current action first." }
        else if OneDriveRetentionActivity.shared.blocks(PhysicalContentTarget(physical)) {
            reason = "A OneDrive command is still running for this file."
        }
        else if let size = entry.item.size, size >= 0 {
            reason = UInt64(size) > CloudDownloadPolicy.maximumBytes ? "Download supports files up to 1 GiB." : nil
        } else { reason = "The file size is unavailable." }
        return CloudDownloadAvailability(isEnabled: reason == nil, disabledReason: reason)
    }
    var canDownloadSelection: Bool { downloadSelectionAvailability?.isEnabled == true }
    private var onlySelectedOperationEntry: ItemOperationEntry? {
        guard let entries = selectedOperationEntries, entries.count == 1 else { return nil }
        return entries[0]
    }

    var oneDriveRetentionSelectionAvailability: CloudDownloadAvailability? {
        guard activeTab.search == nil, let entry = onlySelectedOperationEntry, let physical = entry.physicalEntry,
              OneDriveRetentionService.isCandidate(entry.item) else { return nil }
        let reason: String?
        // An owned CLI child can become visible before its PID is registered.
        // The already-owned operation is the useful fact in every window.
        if retentionCommand != nil || OneDriveRetentionActivity.shared.isBusy || oneDriveRetentionProvider.isBusy {
            reason = "A OneDrive command is still running."
        } else {
            switch oneDriveRetentionProvider.syncState {
            case .unknown:
                reason = "OneDrive’s running state could not be verified. Try again, or manage this file in Finder."
            case .running, .stopped:
                if !isCommandIdle || activeTab.isLoading || activeTab.isRefreshing || cloudCommand != nil {
                    reason = "Finish the current action first."
                } else if OneDriveRetentionActivity.shared.hasContentUse(of: PhysicalContentTarget(physical)) {
                    reason = "Close Preview or wait for the download of this file to finish."
                } else { reason = nil }
            }
        }
        return CloudDownloadAvailability(isEnabled: reason == nil, disabledReason: reason)
    }
    var canChangeOneDriveRetention: Bool { oneDriveRetentionSelectionAvailability?.isEnabled == true }

    func performOneDriveRetention(_ action: OneDriveRetentionAction) {
        retireDeferredRemovalNotice()
        guard canChangeOneDriveRetention, let entry = onlySelectedOperationEntry,
              let physical = entry.physicalEntry, let origin = contentOrigin(for: entry) else { return }
        let command = OneDriveRetentionCommand(action: action, entry: entry, origin: origin)
        guard OneDriveRetentionActivity.shared.begin(command, provider: oneDriveRetentionProvider) else { return }
        OneDriveBadgeCache.shared.cancelFollowUp(owner: cloudStatusOwner)
        retentionCommand = command
        retentionPreviewBarriers[origin.tabID] = origin
        operationNotice = nil
        cloudCommandProgress = CloudCommandProgress(itemName: entry.item.name, phase: .updatingRetention)
        let provider = oneDriveRetentionProvider, control = command.control
        command.task = Task { [weak self, weak command] in
            do {
                try Task.checkCancellation()
                let outcome = try await provider.perform(action, on: physical, control: control)
                try Task.checkCancellation()
                guard let self, let command, self.retentionCommand === command else { return }
                guard self.isContentOriginCurrent(command.origin) else {
                    self.finishOneDriveRetention(command, notice: nil, refresh: false); return
                }
                self.finishOneDriveRetention(command,
                    notice: OneDriveRetentionCommand.notice(outcome, action: action, name: entry.item.name), refresh: true,
                    deferredOutcome: outcome)
            } catch {
                guard let self, let command, self.retentionCommand === command else { return }
                self.finishOneDriveRetention(command,
                    notice: self.isContentOriginCurrent(command.origin) ? error.localizedDescription : nil,
                    refresh: self.isContentOriginCurrent(command.origin))
            }
        }
    }
    private func finishOneDriveRetention(_ command: OneDriveRetentionCommand, notice: String?,
                                        refresh: Bool, resumePreview: Bool = true,
                                        deferredOutcome: OneDriveRetentionOutcome? = nil) {
        guard retentionCommand === command else { return }
        retentionCommand = nil; cloudCommandProgress = nil
        command.cancel()
        let originIsCurrent = isContentOriginCurrent(command.origin)
        let verifiedStatus = originIsCurrent ? deferredOutcome?.verifiedStatus : nil
        OneDriveBadgeCache.shared.finishOperation(command.statusToken, verified: verifiedStatus)
        if let notice { operationNotice = notice }
        if let outcome = deferredOutcome, outcome.removalDeferred,
           command.action == .freeSpace, outcome.mode == .running, !outcome.isConfirmed,
           outcome.policy == .unpinned, outcome.isDataless == false,
           let notice, let physical = command.entry.physicalEntry, isContentOriginCurrent(command.origin) {
            // Install before releasing the reservation, which makes fresh badge
            // queries eligible. A cancelled waiter never enters this branch.
            deferredRemovalNotice = DeferredOneDriveRemoval(origin: command.origin, entry: physical,
                noticeGeneration: operationNoticeGeneration, notice: notice)
        }
        if refresh, isContentOriginCurrent(command.origin) {
            let tab = activeTab
            deferredPreviewLoads[tab.id] = PendingLoad(history: tab.history, preserveSelection: true,
                automatic: true, addressEntry: nil, endsSearch: false, reveal: nil, selectionIntent: .ordinary)
        }
        if originIsCurrent, let outcome = deferredOutcome, let physical = command.entry.physicalEntry,
           (command.action == .keep && verifiedStatus?.policy == .pinned && verifiedStatus?.isDataless == true)
            || (command.action == .freeSpace && outcome.removalDeferred) {
            OneDriveBadgeCache.shared.followUp(owner: cloudStatusOwner, entry: physical, action: command.action)
        }
        OneDriveRetentionActivity.shared.finish(command.id)
        if resumePreview { _ = drainDeferredPreviewLoad(tabID: command.origin.tabID); updatePreviewRequest() }
    }
    private func retireDeferredRemovalNotice() {
        guard let pending = deferredRemovalNotice else { return }
        deferredRemovalNotice = nil
        if operationNoticeGeneration == pending.noticeGeneration, operationNotice == pending.notice {
            operationNotice = nil
        }
    }
    private func validateDeferredRemovalNotice() {
        guard let pending = deferredRemovalNotice else { return }
        let origin = pending.origin
        // A pending passive load still owns its committed rows. Do not compare
        // the load epoch, availability, or other provider-updated metadata.
        guard activeTabID == origin.tabID, contentIntentIDs[origin.tabID] == origin.intentID,
              activeTab.url == origin.location, activeTab.search?.id == origin.searchID,
              activeTab.search?.generation == origin.searchGeneration,
              selectedItemsInOrder.count == 1, let item = selectedItemsInOrder.first,
              let entry = pinBadgeEntry(item), pending.matches(entry) else {
            retireDeferredRemovalNotice(); return
        }
    }
    func receivedOneDriveBadgeObservation(_ observation: OneDriveBadgeObservation, for entry: TransferEntry,
                                         scope: OneDriveBadgeCache.Scope) {
        guard let pending = deferredRemovalNotice,
              scope.tab == activeTabID, scope.folder == activeTab.url,
              scope.searchGeneration == activeTab.search?.generation,
              operationNoticeGeneration == pending.noticeGeneration, operationNotice == pending.notice,
              isContentOriginCurrent(pending.origin),
              let current = onlySelectedOperationEntry?.physicalEntry,
              pending.matches(current), pending.matches(entry) else { return }
        if observation.policy == .pinned {
            retireDeferredRemovalNotice(); return
        }
        guard observation.policy == .unpinned, observation.isDataless else { return }
        operationNotice = OneDriveRetentionCommand.onlineOnlyNotice(name: current.item.name)
    }
    private func retentionBarrierMatches(_ origin: CloudContentOrigin) -> Bool {
        guard let barrier = retentionPreviewBarriers[origin.tabID] else { return false }
        return barrier.intentID == origin.intentID && barrier.location == origin.location
            && barrier.searchID == origin.searchID && barrier.searchGeneration == origin.searchGeneration
            && barrier.url == origin.url && barrier.homeGeneration == origin.homeGeneration
    }
    func hasContentUseForRetention(of target: PhysicalContentTarget) -> Bool {
        if let entry = cloudCommand?.entry.physicalEntry,
           PhysicalContentTarget(entry).conflicts(with: target) { return true }
        guard let entry = preview.admittedRequest?.entry?.physicalEntry,
              PhysicalContentTarget(entry).conflicts(with: target) else { return false }
        switch preview.state {
        case .preparing, .downloading, .ready: return true
        default: return false
        }
    }
    func retentionActivityChanged(blocking target: PhysicalContentTarget?) {
        if let target, let pending = deferredRemovalNotice,
           PhysicalContentTarget(pending.entry).conflicts(with: target) { retireDeferredRemovalNotice() }
        if let target, !tabs.isEmpty, let entry = homeInspectionEntry ?? onlySelectedOperationEntry, let physical = entry.physicalEntry,
           PhysicalContentTarget(physical).conflicts(with: target),
           let origin = contentOrigin(for: entry) { retentionPreviewBarriers[origin.tabID] = origin }
        objectWillChange.send()
        updatePreviewRequest()
    }

    private func contentOrigin(for entry: ItemOperationEntry, tabID: UUID? = nil) -> CloudContentOrigin? {
        let id = tabID ?? activeTabID
        guard let tab = tabs.first(where: { $0.id == id }), entry.physicalEntry != nil else { return nil }
        if contentIntentIDs[id] == nil { contentIntentIDs[id] = UUID() }
        return CloudContentOrigin(tabID: id, location: tab.url, searchID: tab.search?.id,
            searchGeneration: tab.search?.generation, intentID: contentIntentIDs[id]!,
            url: entry.item.url.absoluteString, identity: entry.item.identity, context: entry.context,
            homeGeneration: homeInspectionOrigin?.tab == id ? homeInspectionOrigin?.generation : nil)
    }
    private func isContentOriginCurrent(_ origin: CloudContentOrigin) -> Bool {
        guard !tabs.isEmpty, activeTabID == origin.tabID, contentIntentIDs[origin.tabID] == origin.intentID,
              activeTab.url == origin.location, activeTab.search?.id == origin.searchID,
              activeTab.search?.generation == origin.searchGeneration else { return false }
        let selected: ItemOperationEntry?
        if let generation = origin.homeGeneration {
            let represented = HomeInspectionOrigin(tab: origin.tabID, generation: generation)
            guard homeInspectionOrigin == represented, isHomeInspectionCurrent(represented),
                  let target = homeInspectorTargets?.first, let entry = homeInspectionEntry,
                  target.url.standardizedFileURL.path == entry.item.url.standardizedFileURL.path else { return false }
            selected = entry
        } else { selected = onlySelectedOperationEntry }
        guard let entry = selected else { return false }
        return entry.item.url.absoluteString == origin.url && entry.item.identity == origin.identity && entry.context == origin.context
    }
    private func samePreviewSource(_ lhs: PreviewRequest?, _ rhs: PreviewRequest?) -> Bool {
        guard let lhs, let rhs, let a = lhs.entry, let b = rhs.entry else { return false }
        return lhs.tabID == rhs.tabID && lhs.homeGeneration == rhs.homeGeneration && lhs.searchSessionID == rhs.searchSessionID
            && lhs.searchGeneration == rhs.searchGeneration && a.item.url.absoluteString == b.item.url.absoluteString
            && a.item.identity == b.item.identity && a.context == b.context
    }
    private func previewAttemptStarted(_ attempt: PreviewAttempt) {
        guard let entry = attempt.request.entry, let origin = contentOrigin(for: entry, tabID: attempt.request.tabID),
              isContentOriginCurrent(origin) else { return }
        previewOrigins[attempt.id] = origin
        if attempt.request.hydrationPolicy == .whenNeeded { contentBarriers[origin.tabID] = origin }
    }
    private func previewHydrationPrepared(_ prepared: PreviewHydrationPrepared) {
        let attempt = prepared.attempt
        guard let origin = previewOrigins[attempt.id], isContentOriginCurrent(origin),
              preview.activeCloudAttempt?.id == attempt.id else { prepared.receipt?.invalidate(); return }
        contentHandoffs[attempt.id]?.invalidate()
        contentHandoffs[attempt.id] = CloudContentHandoff(owner: .preview(attempt.id), requestID: attempt.id,
            request: attempt.request, origin: origin, receipt: prepared.receipt)
    }
    private func retryPreview(_ intent: PreviewRetryIntent) {
        guard preview.isCurrent(intent), cloudCommand == nil, retentionCommand == nil, isCommandIdle,
              previewSurfaceVisible, showsPreviewPane, let current = selectedPreviewRequest,
              samePreviewSource(current, intent.request), let entry = current.entry, let physical = entry.physicalEntry,
              let origin = contentOrigin(for: entry), isContentOriginCurrent(origin),
              !OneDriveRetentionActivity.shared.blocks(PhysicalContentTarget(physical)) else { return }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        var fresh = current; fresh.hydrationPolicy = .whenNeeded
        preview.restartAfterExplicitRetry(intent, request: fresh)
    }
    func downloadSelection() {
        retireDeferredRemovalNotice()
        guard canDownloadSelection, let entry = onlySelectedOperationEntry,
              let origin = contentOrigin(for: entry) else { return }
        let timeout = min(CloudDownloadPolicy.timeoutSeconds, cloudCommandTimeoutSeconds)
        guard timeout.isFinite, timeout > 0 else { return }
        let session = CloudCommandSession(entry: entry, origin: origin, timeout: timeout)
        OneDriveBadgeCache.shared.cancelFollowUp(owner: cloudStatusOwner)
        retentionPreviewBarriers.removeValue(forKey: origin.tabID)
        operationNotice = nil
        cloudCommand = session
        contentBarriers[origin.tabID] = origin
        session.timer = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, let session, self.cloudCommand === session else { return }
            self.finishCloudCommand(session, notice: session.timeoutNotice)
        }
        if let attempt = preview.activeCloudAttempt, samePreviewSource(attempt.request, selectedPreviewRequest) {
            session.waitingPreviewID = attempt.id; session.phase = .waitingForPreview
            publishCloudProgress(session)
        } else { startCloudCommand(session, policy: .whenNeeded) }
    }
    private func publishCloudProgress(_ session: CloudCommandSession) {
        guard cloudCommand === session else { return }
        cloudCommandProgress = CloudCommandProgress(itemName: session.entry.item.name, phase: session.phase)
    }
    private func startCloudCommand(_ session: CloudCommandSession, policy: ContentHydrationPolicy) {
        guard cloudCommand === session else { return }
        guard isContentOriginCurrent(session.origin) else { finishCloudCommand(session, notice: nil); return }
        guard session.remaining > 0 else { finishCloudCommand(session, notice: session.timeoutNotice); return }
        session.waitingPreviewID = nil; session.phase = .queued; publishCloudProgress(session)
        let provider = contentProvider, entry = session.acceptedEntry, control = session.control
        let execution = session.execution
        let requestID = session.id, remaining = session.remaining
        session.task = Task { [weak self, weak session] in
            var owned: (any MaterializedContentLease)?
            do {
                let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .download,
                    requestID: requestID, hydrationPolicy: policy, hydrationTimeoutSeconds: remaining,
                    onProgress: { [weak self] phase in
                        execution.record(phase)
                        Task { @MainActor [weak self] in self?.cloudCommandProgressed(requestID, phase: phase) }
                    }), control: control)
                owned = lease
                try Task.checkCancellation()
                guard entry.acceptsContent(lease, for: .download) else { throw ItemContentError.staleSource }
                try await lease.validateForUse()
                try Task.checkCancellation()
                guard let self, let session, self.cloudCommand === session else { _ = await lease.release(); return }
                guard self.isContentOriginCurrent(session.origin) else {
                    _ = await lease.release()
                    self.finishCloudCommand(session, notice: nil)
                    return
                }
                session.lease = lease; owned = nil
                session.phase = .verifying; self.publishCloudProgress(session)
                if policy == .residentOnly, lease.hydrationReconciliation == nil {
                    self.finishCloudCommand(session, notice: "Downloaded ‘\(session.entry.item.name)’.")
                    return
                }
                let request = PreviewRequest(tabID: session.origin.tabID,
                    generation: self.tabLoads[session.origin.tabID]?.authorizationEpoch,
                    searchGeneration: session.origin.searchGeneration, items: [entry.item], entry: entry,
                    searchSessionID: session.origin.searchID, hydrationPolicy: .residentOnly)
                let handoff = CloudContentHandoff(owner: .download(session.id), requestID: session.id,
                    request: request, origin: session.origin, receipt: lease.hydrationReconciliation)
                self.contentHandoffs[session.id] = handoff
                self.queueCloudRefresh(handoff)
            } catch {
                if let owned { _ = await owned.release() }
                guard let self, let session, self.cloudCommand === session else { return }
                guard self.isContentOriginCurrent(session.origin) else {
                    self.finishCloudCommand(session, notice: nil); return
                }
                guard !Task.isCancelled else { return }
                self.finishCloudCommand(session, notice: error.localizedDescription)
            }
        }
    }
    private func cloudCommandProgressed(_ id: UUID, phase: ContentPreparationPhase) {
        guard let session = cloudCommand, session.id == id, isContentOriginCurrent(session.origin) else { return }
        switch phase {
        case .queued: break
        case .downloading:
            if session.phase != .verifying { session.phase = .downloading }
        case .preparing: session.phase = .verifying
        }
        publishCloudProgress(session)
    }
    func cancelCloudCommand() {
        if let command = retentionCommand {
            finishOneDriveRetention(command, notice: OneDriveRetentionCommand.stoppedNotice, refresh: true)
            return
        }
        guard let session = cloudCommand else { return }
        finishCloudCommand(session, notice: "Stopped waiting for the download.")
    }
    private func finishCloudCommand(_ session: CloudCommandSession, notice: String?, resumePreview: Bool = true) {
        guard cloudCommand === session else { return }
        cloudCommand = nil; cloudCommandProgress = nil
        contentHandoffs.removeValue(forKey: session.id)?.invalidate()
        session.cancel(); session.releaseLease()
        if let notice { operationNotice = notice }
        if resumePreview { updatePreviewRequest(); scheduleObservedRefresh() }
    }
    func invalidateCloudCommandForNewIntent(clearBarrier: Bool = false, selectionChanged: Bool = false) {
        OneDriveBadgeCache.shared.cancelFollowUp(owner: cloudStatusOwner)
        retireDeferredRemovalNotice()
        if let command = retentionCommand {
            finishOneDriveRetention(command, notice: selectionChanged ? OneDriveRetentionCommand.stoppedNotice : nil,
                                    refresh: false, resumePreview: false)
        }
        if let session = cloudCommand {
            finishCloudCommand(session, notice: selectionChanged ? "Stopped waiting for the download." : nil, resumePreview: false)
        }
        for handoff in contentHandoffs.values { handoff.invalidate() }
        contentHandoffs.removeAll(); previewOrigins.removeAll()
        if clearBarrier {
            contentIntentIDs[activeTabID] = UUID()
            contentBarriers.removeValue(forKey: activeTabID)
            retentionPreviewBarriers.removeValue(forKey: activeTabID)
        }
    }
    private func blocksAutomaticContentRefresh(tabID: UUID, allowing handoff: CloudContentHandoff? = nil) -> Bool {
        if retentionCommand?.origin.tabID == tabID { return true }
        if preview.blocksAutomaticRefresh(tabID: tabID) { return true }
        guard let session = cloudCommand, session.origin.tabID == tabID else { return false }
        if let handoff, !handoff.invalidated, contentHandoffs[handoff.requestID] === handoff {
            if handoff.owner == .download(session.id), session.phase == .verifying { return false }
            if let waiting = session.waitingPreviewID, handoff.owner == .preview(waiting) { return false }
        }
        return true
    }
    private func queueCloudRefresh(_ handoff: CloudContentHandoff) {
        let request = handoff.request
        guard !handoff.invalidated, isContentOriginCurrent(handoff.origin),
              let entry = request.entry, case .filesystem(let parent) = entry.context,
              let tab = tabs.first(where: { $0.id == request.tabID }) else {
            finishCloudHandoff(handoff, snapshot: nil, transition: nil); return
        }
        if request.homeGeneration != nil { refreshHomePreviewMetadata(parent: parent, handoff: handoff) }
        else if request.searchSessionID != nil { refreshPreviewSearchMetadata(request, parent: parent, handoff: handoff) }
        else {
            if let previous = deferredPreviewLoads[tab.id]?.cloudHandoff, previous !== handoff { previous.invalidate() }
            deferredPreviewLoads[tab.id] = PendingLoad(history: tab.history, preserveSelection: true,
                automatic: true, addressEntry: nil, endsSearch: false, reveal: nil,
                selectionIntent: .ordinary, cloudHandoff: handoff)
            _ = drainDeferredPreviewLoad(tabID: tab.id)
        }
    }
    private func finishCloudHandoff(_ handoff: CloudContentHandoff, snapshot: DirectorySnapshot?, transition: VerifiedHydrationTransition?) {
        guard contentHandoffs[handoff.requestID] === handoff else { handoff.invalidate(); return }
        contentHandoffs.removeValue(forKey: handoff.requestID)
        previewOrigins.removeValue(forKey: handoff.requestID)
        let original = handoff.request.entry
        let row = transition?.refreshedItem ?? snapshot?.items.first(where: {
            $0.url.absoluteString == original?.item.url.absoluteString && $0.identity == original?.item.identity
        })
        if let row, let original, !handoff.invalidated {
            let accepted = ItemOperationEntry(item: row, context: original.context)
            if contentBarriers[handoff.origin.tabID] == handoff.origin {
                contentBarriers[handoff.origin.tabID] = handoff.origin.replacingEntry(accepted)
            }
            if let transition { preview.adoptHydrationTransition(transition, loadGeneration: tabLoads[handoff.origin.tabID]?.authorizationEpoch) }
            if let session = cloudCommand, let waiting = session.waitingPreviewID,
               handoff.owner == .preview(waiting), session.origin == handoff.origin {
                session.acceptedEntry = accepted; session.origin = session.origin.replacingEntry(accepted)
                startCloudCommand(session, policy: .residentOnly)
            }
        } else if let session = cloudCommand, let waiting = session.waitingPreviewID, handoff.owner == .preview(waiting) {
            finishCloudCommand(session, notice: "Stopped waiting for the download.")
        }
        if let session = cloudCommand, handoff.owner == .download(session.id) {
            finishCloudCommand(session, notice: "Downloaded ‘\(session.entry.item.name)’." + (row == nil ? " The folder could not be refreshed." : ""))
        }
        handoff.invalidate()
    }
    private func cloudAttemptEnded(_ result: PreviewAttemptEnded) {
        let request = result.attempt.request
        if result.outcome == .cancelled {
            if let handoff = contentHandoffs[result.attempt.id] { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            else if let session = cloudCommand, session.waitingPreviewID == result.attempt.id {
                finishCloudCommand(session, notice: "Stopped waiting for the download.")
            }
            previewOrigins.removeValue(forKey: result.attempt.id)
            return
        }
        if let origin = previewOrigins[result.attempt.id], isContentOriginCurrent(origin), result.refreshMetadata {
            let handoff = contentHandoffs[result.attempt.id] ?? CloudContentHandoff(owner: .preview(result.attempt.id),
                requestID: result.attempt.id, request: request, origin: origin, receipt: nil)
            contentHandoffs[result.attempt.id] = handoff
            queueCloudRefresh(handoff)
            return
        }
        contentHandoffs.removeValue(forKey: result.attempt.id)?.invalidate()
        previewOrigins.removeValue(forKey: result.attempt.id)
        guard request.homeGeneration == nil else { return }
        guard let tab = tabs.first(where: { $0.id == request.tabID }) else {
            deferredPreviewLoads.removeValue(forKey: request.tabID); return
        }
        if result.refreshMetadata, request.generation == tabLoads[request.tabID]?.authorizationEpoch,
           let entry = request.entry, case .filesystem(let parent) = entry.context {
            if let searchID = request.searchSessionID, tab.search?.id == searchID,
               tab.search?.generation == request.searchGeneration {
                refreshPreviewSearchMetadata(request, parent: parent)
            } else if request.searchSessionID == nil, tab.url == parent.directoryURL,
                      tab.directoryIdentity == parent.directoryIdentity {
                deferredPreviewLoads[tab.id] = PendingLoad(history: tab.history, preserveSelection: true,
                    automatic: true, addressEntry: nil, endsSearch: false, reveal: nil, selectionIntent: .ordinary)
            }
        }
        if !drainDeferredPreviewLoad(tabID: tab.id) { scheduleObservedRefresh() }
    }

    @discardableResult
    private func drainDeferredPreviewLoad(tabID: UUID) -> Bool {
        guard let pending = deferredPreviewLoads[tabID],
              !blocksAutomaticContentRefresh(tabID: tabID, allowing: pending.cloudHandoff), tabLoads[tabID]?.work == nil,
              shortcutDraft == nil, nameEdit == nil, !isPerformingOperation,
              let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        deferredPreviewLoads.removeValue(forKey: tabID)
        guard pending.history.current == tab.url else {
            if let handoff = pending.cloudHandoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            return false
        }
        // This read also consumes watcher hints accumulated by hydration.
        if tabID == activeTabID { observationDirty = false }
        load(tabID: tabID, request: pending)
        return true
    }

    private func refreshHomePreviewMetadata(parent: FileOperationContext, handoff: CloudContentHandoff) {
        let origin = handoff.origin
        guard let entry = handoff.request.entry else {
            finishCloudHandoff(handoff, snapshot: nil, transition: nil); return
        }
        let tabID = origin.tabID
        previewMetadataTasks.removeValue(forKey: tabID)?.cancel()
        let token = UUID()
        let read = readHomeInspectorEntry
        previewMetadataTokens[tabID] = token
        previewMetadataTasks[tabID] = Task { [weak self] in
            defer { self?.finishPreviewMetadataTask(tabID: tabID, token: token) }
            do {
                let refreshed = try await read(entry.item.url)
                guard !Task.isCancelled, self?.previewMetadataTokens[tabID] == token,
                      self?.isContentOriginCurrent(origin) == true, !handoff.invalidated,
                      refreshed.source == parent else { throw ItemContentError.staleSource }
                // A claim needs the refreshed child and the real parent identity.
                // This is never a complete folder snapshot or a listing commit.
                let snapshot = DirectorySnapshot(items: [refreshed.item], directoryIdentity: parent.directoryIdentity,
                                                 isStructureComplete: false)
                let transition = try await handoff.claim(snapshot: snapshot)
                guard !Task.isCancelled, let self, self.previewMetadataTokens[tabID] == token,
                      self.isContentOriginCurrent(origin), !handoff.invalidated,
                      transition != nil || refreshed.item.identity == entry.item.identity else {
                    throw ItemContentError.staleSource
                }
                self.objectWillChange.send()
                self.homeInspectionEntry = ItemOperationEntry(item: transition?.refreshedItem ?? refreshed.item,
                                                             context: .filesystem(parent))
                self.finishCloudHandoff(handoff, snapshot: snapshot, transition: transition)
                self.updatePreviewRequest()
            } catch {
                guard let self else { return }
                let current = !Task.isCancelled && self.previewMetadataTokens[tabID] == token
                    && self.isContentOriginCurrent(origin) && !handoff.invalidated
                self.finishCloudHandoff(handoff, snapshot: nil, transition: nil)
                if current {
                    self.objectWillChange.send()
                    self.homeInspectionEntry = nil
                    self.homeInspectionFailed = true
                    self.updatePreviewRequest()
                }
            }
        }
    }

    private func refreshPreviewSearchMetadata(_ request: PreviewRequest, parent: FileOperationContext, handoff: CloudContentHandoff? = nil) {
        // Retry owns a newer preparation. Its terminal reconciliation refreshes
        // this row; an older metadata read must not cancel that preparation.
        guard !blocksAutomaticContentRefresh(tabID: request.tabID, allowing: handoff),
              let original = request.entry?.item else {
            if let handoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            return
        }
        previewMetadataTasks.removeValue(forKey: request.tabID)?.cancel()
        let metadataToken = UUID()
        previewMetadataTokens[request.tabID] = metadataToken
        let loader = self.loader, hidden = showHidden
        previewMetadataTasks[request.tabID] = Task { [weak self] in
            // Every exit releases only this read's task handle; a superseding
            // read keeps its different token and cancellation ownership.
            defer { self?.finishPreviewMetadataTask(tabID: request.tabID, token: metadataToken) }
            do {
                let statusSequence = OneDriveBadgeCache.shared.beginListingSnapshot(for: parent.directoryURL)
                let snapshot = try await loader.snapshot(of: parent.directoryURL, showHidden: hidden)
                guard !Task.isCancelled, self?.previewMetadataTokens[request.tabID] == metadataToken else {
                    if let handoff { self?.finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
                    return
                }
                if let handoff {
                    guard self?.isContentOriginCurrent(handoff.origin) == true, !handoff.invalidated else { throw ItemContentError.staleSource }
                }
                let transition = try await handoff?.claim(snapshot: snapshot)
                guard !Task.isCancelled, let self,
                  self.previewMetadataTokens[request.tabID] == metadataToken,
                  !self.blocksAutomaticContentRefresh(tabID: request.tabID, allowing: handoff),
                  let index = self.tabs.firstIndex(where: { $0.id == request.tabID }),
                  self.tabs[index].search?.id == request.searchSessionID,
                  self.tabs[index].search?.generation == request.searchGeneration,
                  snapshot.directoryIdentity == parent.directoryIdentity else {
                    if let handoff { self?.finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
                    return
                }
                if let handoff, !self.isContentOriginCurrent(handoff.origin) { throw ItemContentError.staleSource }
                self.previewUpdateDepth += 1
                defer { self.finishDeferredPreviewUpdate() }
                let sort = self.tabs[index].sort
                if let transition {
                    self.tabs[index].search?.applyHydrationTransition(transition, sort: sort)
                } else if let item = snapshot.items.first(where: { $0.id == original.id && $0.identity == original.identity }) {
                    self.tabs[index].search?.refreshMetadata(item, parent: parent, sort: sort)
                } else { throw ItemContentError.staleSource }
                if let accepted = self.tabs[index].search?.result(id: original.id),
                   accepted.parent == parent, OneDriveRetentionService.isBadgeCandidate(accepted.item) {
                    OneDriveBadgeCache.shared.mergeListing([TransferEntry(source: parent, item: accepted.item)], startedAt: statusSequence)
                }
                if let handoff { self.finishCloudHandoff(handoff, snapshot: snapshot, transition: transition) }
            } catch {
                if let handoff { self?.finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            }
        }
    }
    private func finishPreviewMetadataTask(tabID: UUID, token: UUID) {
        guard previewMetadataTokens[tabID] == token else { return }
        previewMetadataTokens.removeValue(forKey: tabID)
        previewMetadataTasks.removeValue(forKey: tabID)
    }
    private func finishDeferredPreviewUpdate() {
        previewUpdateDepth -= 1
        guard previewUpdateDepth == 0 else { return }
        // Always flush on exit, including a refused handoff (N4).
        previewUpdatePending = false
        updatePreviewRequest()
    }
    var canToggleDetailsPane: Bool { isCommandIdle }
    var canShowProperties: Bool {
        if homeResultScope != nil { return canAttemptHomeOperation }
        return !detailSelection.isEmpty && detailSelection.allSatisfy(BrowsingPresentation.isPhysical)
    }
    var canChangeViewMode: Bool { activePage == nil && isCommandIdle }
    var canSortItems: Bool { activePage == nil && shortcutDraft == nil && nameEdit == nil && !isPerformingOperation }
    var canUseAddress: Bool { isCommandIdle }

    func requestAddressEditing() {
        guard shortcutDraft == nil, !isPerformingOperation, !isShowingRecovery else { return }
        cancelNameEdit()
        address.beginEditing(at: activeTab.url)
        addressFocusRequest &+= 1
    }

    /// Address-entry recents are recorded only by the generation-checked load
    /// success below. Popup selections are always folder-navigation intents.
    func submitAddress(_ url: URL) {
        guard canUseAddress, let location = BrowsingLocation(url: url), BrowserPage(url: url) == nil else { return }
        guard location.physicalURL == nil || LocalPathInput.isValidFileURL(url) else { return }
        guard prepareForNavigation() else { return }
        let destination = location.url
        cancelRevealVisibility()
        var history = activeTab.history
        history.navigate(to: destination)
        load(tabID: activeTabID, history: history, preserveSelection: false, addressEntry: destination,
             endsSearch: true, grantsSidebarAccess: true, clearsDocumentsFavoriteAssociation: true)
    }

    /// Only explicit typed text can activate a physical document. The existing
    /// address cancellation boundary owns this lookup as well as popup work.
    func submitTypedAddress(_ url: URL) {
        guard canUseAddress, let location = BrowsingLocation(url: url) else { return }
        if case .archive = location { submitAddress(url); return }
        guard location.physicalURL != nil else { return }
        guard prepareForNavigation() else { return }
        let tabID = activeTabID
        let origin = activeTab.url
        let searchGeneration = activeSearch?.generation
        abandonPendingSearchExit(tabID: tabID)
        let resolve = resolvePhysicalAddress
        address.resolveSubmission(url, using: { url in
            let target = try await resolve(url)
            if case .ordinaryFile(let file) = target { return (target, await RecentDocument.sample(file)) }
            return (target, nil as RecentDocument?)
        }) { [weak self] result in
            guard let self, self.activeTabID == tabID, self.activeTab.url == origin,
                  self.activeSearch?.generation == searchGeneration, self.isCommandIdle else { return }
            switch result {
            case .success(let (target, document)):
                if let destination = target.browsingURL { self.submitAddress(destination) }
                else if case .ordinaryFile(let file) = target { self.openPhysicalFile(file, captured: document) }
            case .failure(let error):
                self.operationNotice = "Couldn’t open \(url.path). \(error.localizedDescription)"
                self.operationAccessIssue = nil
            }
        }
    }

    private func openPhysicalFile(_ url: URL, captured: RecentDocument?) {
        let failures = applications.openWithDefaultApplications([url])
        if let captured { recentDocuments.record([captured], excluding: failures) }
        guard !failures.isEmpty else { return }
        operationNotice = "macOS could not open \(url.lastPathComponent)."
        operationAccessIssue = nil
    }

    enum PageItemAction { case open, newTab, newWindow, reveal, copyPath, togglePin, editTags }

    /// Page rows can represent paths from many directories. Resolve the
    /// selected row independently of the tab's ordinary listing and selection.
    func performPageAction(_ action: PageItemAction, url: URL, folder: Bool,
                           pinKey: String? = nil, recent: RecentDocument? = nil,
                           representedIdentity: LocalFileIdentity? = nil,
                           rowIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard let page = activePage, isCommandIdle, url.isFileURL, rowIsCurrent() else { return }
        if action == .togglePin, pinKey != nil, pins.contains(url) { pins.unpin(url); return }
        let tabID = activeTabID
        let opensLocation = action == .open || action == .newTab || action == .newWindow
        if opensLocation {
            guard prepareForNavigation() else { return }
            abandonPendingSearchExit(tabID: tabID)
        }
        let epoch = contextMenuLoadGeneration
        let section = activeTab.homeSection
        let tagGeneration = activeTab.homeTagGeneration
        let isTagResult: Bool = switch page {
        case .tag: true
        case .home: section == .tags && pinKey == nil && recent == nil
        case .thisMac: false
        }
        if action == .editTags {
            guard page != .thisMac, let expected = representedIdentity,
                  pinKey != nil || recent != nil || isTagResult,
                  recent.map({ $0.identity == expected && $0.url == url }) != false else { return }
            let isCurrent = { [weak self] in
                guard rowIsCurrent(), let self, self.activeTabID == tabID, self.activePage == page,
                      self.contextMenuLoadGeneration == epoch, self.activeTab.homeTagGeneration == tagGeneration else { return false }
                if let pinKey { return self.pins.entries.contains { $0.id == pinKey && $0.url == url } }
                if let recent {
                    return self.recentDocuments.contains(recent)
                }
                return true
            }
            guard isCurrent() else { return }
            finderTagEditor = FinderTagEditor(targets: [.init(url: url, identity: expected)], originIsCurrent: isCurrent)
            return
        }
        if isTagResult && representedIdentity == nil { return }
        let resolve = resolvePhysicalAddress
        let needsIdentity = recent != nil || (action == .open && !folder)
        typealias PageTarget = (FileActivationTarget?, RecentDocument?)
        let inspect: @Sendable (URL) async -> PageTarget = { url in
            if isTagResult, (try? await FinderTagFile.identity(at: url)) != representedIdentity { return (nil, nil) }
            let target = try? await resolve(url)
            let document = needsIdentity && !Task.isCancelled ? await RecentDocument.sample(url) : nil
            if isTagResult, (try? await FinderTagFile.identity(at: url)) != representedIdentity { return (nil, nil) }
            return (target, document)
        }
        let perform: @MainActor (PageTarget) -> Void = { [weak self] sample in
            let (target, document) = sample
            guard rowIsCurrent(), let self, activeTabID == tabID, activePage == page, contextMenuLoadGeneration == epoch,
                  activeTab.homeSection == section, activeTab.homeTagGeneration == tagGeneration, isCommandIdle else { return }
            guard let target else {
                operationNotice = recent == nil ? "This item is no longer available." : Self.unavailableRecentNotice
                operationAccessIssue = nil
                return
            }
            if let recent {
                guard recentDocuments.contains(recent) else { return }
                guard let document else {
                    operationNotice = Self.unavailableRecentNotice
                    operationAccessIssue = nil
                    return
                }
                if !recent.identifies(document) {
                    if action == .open, case .ordinaryFile = target, document.regularFile == true, recent.regularFile != false {
                        operationNotice = nil
                        recentOpenConfirmation = RecentOpenConfirmation(original: recent, candidate: document,
                            tabID: tabID, epoch: epoch, rowIsCurrent: rowIsCurrent)
                    } else { operationNotice = Self.unavailableRecentNotice }
                    operationAccessIssue = nil
                    return
                }
            }
            let directory: Bool
            if case .physicalFolder = target { directory = true } else { directory = false }
            guard directory == folder else { operationNotice = "This item has changed. Refresh and try again."; return }
            switch action {
            case .open, .newTab:
                if let destination = target.browsingURL {
                    activateSidebarItem(key: pinKey ?? "", url: destination, newTab: action == .newTab)
                } else if action == .open, case .ordinaryFile = target { openPhysicalFile(url, captured: document) }
            case .newWindow:
                if let destination = target.browsingURL { onOpenWindow?(destination, pinKey) }
            case .reveal: applications.revealInFinder([url])
            case .copyPath:
                clipboard.pasteboard.clearContents()
                clipboard.pasteboard.setString(url.path, forType: .string)
                clipboard.refresh()
            case .togglePin:
                if directory {
                    if pins.contains(url) { pins.unpin(url) } else { pins.pin(url) }
                }
            case .editTags: break // Handled before navigation or Launch Services resolution.
            }
        }
        if opensLocation {
            address.resolveSubmission(url, using: inspect) { result in
                if case .success(let sample) = result { perform(sample) }
            }
        } else {
            Task { perform(await inspect(url)) }
        }
    }

    private static let unavailableRecentNotice = "This file has moved or changed. You can remove it from Recent."

    func cancelRecentOpen() { recentOpenConfirmation = nil }

    func confirmRecentOpen(_ confirmation: RecentOpenConfirmation) {
        guard recentOpenConfirmation?.id == confirmation.id else { return }
        cancelRecentOpen()
        guard recentOpenOriginIsCurrent(confirmation) else { return }
        address.resolveSubmission(confirmation.original.url, using: { await RecentDocument.sample($0) }) { [weak self] result in
            guard let self, recentOpenOriginIsCurrent(confirmation) else { return }
            guard case .success(let current?) = result, confirmation.candidate.isSameCandidate(as: current) else {
                operationNotice = "The file changed again or is unavailable. Open its Recent entry to check it again."
                operationAccessIssue = nil
                return
            }
            openPhysicalFile(current.url, captured: current)
        }
    }

    private func recentOpenOriginIsCurrent(_ confirmation: RecentOpenConfirmation) -> Bool {
        confirmation.rowIsCurrent() && activeTabID == confirmation.tabID && activePage == .home && activeTab.homeSection == .recent
            && contextMenuLoadGeneration == confirmation.epoch && isCommandIdle && recentDocuments.contains(confirmation.original)
    }

    /// UI-NAV-002 only establishes labels. Native Copy Address exports the local
    /// URL plus POSIX text; Copy Address as Text exports text only. Neither creates
    /// Explorer's identity-backed copy/move intent.
    func copyAddress(asText: Bool, to pasteboard: NSPasteboard = .general) {
        guard canUseAddress else { return }
        let url = activeTab.url
        pasteboard.clearContents()
        if !asText, physicalFolderURL != nil { _ = pasteboard.writeObjects([url as NSURL]) }
        pasteboard.setString(BrowsingPresentation.path(url), forType: .string)
        clipboard.refresh()
    }

    func clearAddressHistory() { address.clearHistory() }

    func setViewMode(_ mode: FolderViewMode) {
        guard canChangeViewMode, let index = activeIndex, tabs[index].viewMode != mode else { return }
        pointerRename.cancel()
        prepareViewReplacement(to: mode)
        tabs[index].viewMode = mode
    }

    private func prepareViewReplacement(to mode: FolderViewMode) {
        if (activeTab.viewMode == .details) != (mode == .details) {
            focus.prepareContentReplacementFocus()
        }
    }

    func toggleDetailsPane() {
        guard canToggleDetailsPane else { return }
        inspectorPane.toggle(.details)
        updatePreviewRequest()
    }
    func togglePreviewPane() {
        guard canToggleDetailsPane else { return }
        inspectorPane.toggle(.preview)
        updatePreviewRequest()
    }
    func toggleInspectorPane() {
        guard canToggleDetailsPane else { return }
        inspectorPane.toggleLast()
        updatePreviewRequest()
    }
    func resizeInspectorPane(to width: CGFloat, available: CGFloat) {
        inspectorPane.resize(to: width, available: available)
    }

    func showProperties() {
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, _ in
                let items = entries.map(\.item)
                if items.count == 1 { store.onShowProperties?(items[0]) }
                else { store.onShowMultipleProperties?(items) }
            }
            return
        }
        let selection = detailSelection
        guard canShowProperties, !selection.isEmpty else { return }
        if selection.count == 1 { onShowProperties?(selection[0]) }
        else { onShowMultipleProperties?(selection) }
    }

    /// Background menu Properties: the current folder itself (NATIVE-P18A).
    var canShowFolderProperties: Bool {
        physicalFolderURL != nil && activeTab.search == nil && activeTab.hasLoaded && !activeTab.isUnavailable
            && isCommandIdle
    }
    func showFolderProperties() {
        guard canShowFolderProperties else { return }
        onShowProperties?(currentFolderItem)
    }

    // MARK: Context-menu commands (NATIVE-P18A)

    /// Selected items in display order (folder view) or selected results (search).
    var selectedItemsInOrder: [FileItem] {
        if let search = activeTab.search { return search.selectedResults.map(\.item) }
        return sortedItems.filter { activeTab.selection.selectedIDs.contains($0.id) }
    }

    var canOpenSelection: Bool {
        guard isCommandIdle, !activeTab.isUnavailable else { return false }
        // MAC-065: search results open one at a time through their validated activation.
        if let search = activeTab.search {
            return search.selectedResults.count == 1 && search.selectedResults.allSatisfy { FileActivationTarget($0.item).canOpen }
        }
        return !selectedItemsInOrder.isEmpty && selectedItemsInOrder.allSatisfy { FileActivationTarget($0).canOpen }
    }

    /// One item activates as Return does; several (folder view only) open files
    /// with their default apps and folders in new tabs once each is revalidated.
    func openSelection() {
        guard canOpenSelection else { return }
        let items = selectedItemsInOrder
        if items.count == 1 { activate(items[0]); return }
        if items.contains(where: { ArchiveLocation(url: $0.url) != nil }) { openArchiveSelection(items); return }
        address.cancelPendingSubmission()
        let files = items.filter { item in
            if case .ordinaryFile = FileActivationTarget(item) { return true }
            return false
        }
        routeAfterRevalidation(items, stillEnabled: { $0.canOpenSelection && Self.sameEntries($0.selectedItemsInOrder, items) },
                               prepare: {
            var documents: [RecentDocument] = []
            for item in files {
                if let document = await RecentDocument.validated(item) { documents.append(document) }
            }
            return documents
        }) { store, captured in
            let external = files.map(\.url)
            let failed = store.applications.openWithDefaultApplications(external)
            store.recentDocuments.record(captured, excluding: failed)
            for item in items {
                if let url = FileActivationTarget(item).browsingURL { store.openTab(at: url) }
            }
            if !failed.isEmpty { store.operationNotice = "macOS could not open \(failed.map(\.lastPathComponent).joined(separator: ", "))." }
        }
    }

    func canOpenInNewTab(_ item: FileItem?) -> Bool {
        guard let item, FileActivationTarget(item).browsingURL != nil else { return false }
        return isCommandIdle
    }
    func openInNewTab(_ item: FileItem) {
        guard canOpenInNewTab(item) else { return }
        routeAfterRevalidation([item], stillEnabled: { $0.canOpenInNewTab(item) && $0.listsEntry(item) }) { store in
            if let url = FileActivationTarget(item).browsingURL { store.openTab(at: url) }
        }
    }
    func openInNewWindow(_ item: FileItem) {
        guard canOpenInNewTab(item) else { return }
        routeAfterRevalidation([item], stillEnabled: { $0.canOpenInNewTab(item) && $0.listsEntry(item) }) { store in
            if let url = FileActivationTarget(item).browsingURL { store.onOpenWindow?(url, nil) }
        }
    }

    /// MAC-078 routing-target check; tests inject an answer.
    var validateRoutingTarget: @Sendable (FileItem) async -> Bool = RoutingTargetValidation.isCurrent

    /// Runs `perform` only if every item its menu captured is still the same entry
    /// and the command is still enabled for the same tab and folder afterwards.
    /// MAC-078 current-folder check for background Open in Terminal; tests inject an answer.
    var validateRoutingFolder: @Sendable (URL, LocalFileIdentity?) async -> Bool = RoutingTargetValidation.isCurrentFolder
    var validateArchiveRevision: @Sendable (URL, ArchiveRevision) async -> Bool = { url, revision in
        await revision.isCurrent(at: url)
    }

    /// Browsing validation has no filesystem-operation authority over a member.
    func validateBrowsingArchive(at url: URL, revision: ArchiveRevision?) async -> Bool {
        guard let archive = ArchiveLocation(url: url), let revision else { return false }
        return await validateArchiveRevision(archive.archiveURL, revision)
    }

    private func validateNavigationItem(_ item: FileItem) async -> Bool {
        if ArchiveLocation(url: item.url) != nil {
            guard FileActivationTarget(item).canOpen, listsEntry(item) else { return false }
            return await validateBrowsingArchive(at: item.url, revision: item.archiveRevision)
        }
        return await validateRoutingTarget(item)
    }

    /// Same entries in the same order: IDs (paths) and identities both match.
    static func sameEntries(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        // Availability changes invalidate captured presentation/menu intent; it
        // never grants filesystem authority or replaces the identity checks.
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.id == $1.id && $0.identity == $1.identity && $0.archiveRevision == $1.archiveRevision
                && $0.availability == $1.availability && $0.isRegularFile == $1.isRegularFile
        }
    }
    /// The listing still holds this exact entry (same path and identity).
    private func listsEntry(_ item: FileItem) -> Bool {
        activeTab.items.contains {
            $0.id == item.id && $0.identity == item.identity && $0.archiveRevision == item.archiveRevision
        } && (ArchiveLocation(url: item.url) == nil || item.archiveRevision == activeTab.archiveRevision)
    }
    static func changedNotice(_ names: [String]) -> String {
        "“\(names.joined(separator: "”, “"))” changed since the menu was opened. Nothing was opened."
    }

    /// MAC-078: a chosen routing command still explains an earlier menu guard refusal.
    func noteContextRouteRefusal(changedNames: [String]) {
        operationNotice = changedNames.isEmpty
            ? "Nothing was opened: the selection or folder changed since the menu was opened."
            : Self.changedNotice(changedNames)
    }

    static let contextActionRefusalNotice = "An item changed or is no longer available. Nothing was done. Refresh and try again."

    /// MAC-MENU-FUP-001: only a still-current chosen action explains failed identity validation.
    func noteContextActionRefusal() {
        operationNotice = Self.contextActionRefusalNotice
    }

    private struct RoutingOrigin: Equatable {
        let tabID: UUID
        let folder: URL
        let archiveRevision: ArchiveRevision?
        var home: HomeOperationOrigin? = nil
    }

    private static let staleRoutingNotice = "Nothing was opened: the selection or folder changed since the menu was opened."

    private var routingOrigin: RoutingOrigin {
        RoutingOrigin(tabID: activeTabID, folder: activeTab.url, archiveRevision: activeTab.archiveRevision)
    }

    private var selectedRoutingOrigin: RoutingOrigin {
        var origin = routingOrigin
        origin.home = homeOperationOrigin
        return origin
    }

    private func routingOriginIsCurrent(_ origin: RoutingOrigin) -> Bool {
        guard activeTabID == origin.tabID, activeTab.url == origin.folder,
              activeTab.archiveRevision == origin.archiveRevision else { return false }
        return origin.home.map(isHomeOperationOriginCurrent) ?? true
    }

    private func verifiedHomeRoutingItems(_ items: [FileItem], origin: HomeOperationOrigin) async -> Bool {
        guard let entries = try? await verifiedHomeOperationEntries(for: origin) else { return false }
        return Self.sameEntries(entries.map(\.item), items) && isHomeOperationOriginCurrent(origin)
    }

    /// Runs `perform` only if every captured item is still the same entry on disk
    /// and, after that check, the command is still enabled for the same tab and
    /// folder with the same captured entries (identity-aware). Any refusal after
    /// the user's choice explains itself.
    private func routeAfterRevalidation(_ items: [FileItem], origin: RoutingOrigin? = nil, refusalPrefix: String = "",
                                        stillEnabled: @escaping @MainActor (ExplorerStore) -> Bool,
                                        perform: @escaping @MainActor (ExplorerStore) -> Void) {
        routeAfterRevalidation(items, origin: origin, refusalPrefix: refusalPrefix, stillEnabled: stillEnabled,
                               prepare: { () }) { store, _ in perform(store) }
    }

    private func routeAfterRevalidation<Value: Sendable>(_ items: [FileItem], origin: RoutingOrigin? = nil,
                                        refusalPrefix: String = "",
                                        stillEnabled: @escaping @MainActor (ExplorerStore) -> Bool,
                                        prepare: @escaping @MainActor () async -> Value,
                                        perform: @escaping @MainActor (ExplorerStore, Value) -> Void) {
        let origin = origin ?? routingOrigin
        Task { [weak self] in
            guard let self else { return }
            var changed: [String] = []
            if let home = origin.home {
                guard await self.verifiedHomeRoutingItems(items, origin: home) else {
                    self.operationNotice = refusalPrefix + Self.staleRoutingNotice
                    return
                }
            } else {
                for item in items where !(await self.validateNavigationItem(item)) { changed.append(item.name) }
            }
            guard changed.isEmpty else { self.operationNotice = refusalPrefix + Self.changedNotice(changed); return }
            let epoch = self.contextMenuLoadGeneration
            let prepared = await prepare()
            guard self.routingOriginIsCurrent(origin), self.contextMenuLoadGeneration == epoch, stillEnabled(self) else {
                self.operationNotice = refusalPrefix + Self.staleRoutingNotice
                return
            }
            perform(self, prepared)
        }
    }

    // MARK: Archive, alias and application commands (NATIVE-P18A, MAC-078)

    private static func sharedSourceParent(_ entries: [TransferEntry]) -> FileOperationContext? {
        guard let first = entries.first?.source else { return nil }
        let path = HomeFileLocations.pathKey(first.directoryURL)
        return entries.allSatisfy {
            $0.source.directoryIdentity == first.directoryIdentity && HomeFileLocations.pathKey($0.source.directoryURL) == path
        } ? first : nil
    }

    /// Home supplies physical source parents. Ordinary Search retains its folder-relative write policy.
    private var canWriteBesideSelection: Bool {
        if homeResultScope != nil {
            guard isCommandIdle, let entries = homeOperationEntries else { return false }
            return Self.sharedSourceParent(entries) != nil
        }
        return activeTab.search == nil && canCopySelection && hasPhysicalSelection
    }

    var canCompressSelection: Bool { canWriteBesideSelection }
    var canMakeAliases: Bool { canWriteBesideSelection }

    private func withSiblingWriteSelection(_ action: @escaping @MainActor (ExplorerStore, [FileItem], FileOperationContext) -> Void) {
        guard canWriteBesideSelection else { return }
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, _ in
                guard let context = Self.sharedSourceParent(entries) else { return }
                action(store, entries.map(\.item), context)
            }
        } else if let identity = activeTab.directoryIdentity {
            let items = sortedItems.filter { activeTab.selection.selectedIDs.contains($0.id) }
            action(self, items, FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity))
        }
    }

    /// Compress to ▸ ZIP File / TAR File: one archive next to the selection; the
    /// new archive is selected afterwards. Cancel publishes nothing.
    func compressSelection(_ format: ArchiveFormat) {
        withSiblingWriteSelection { store, items, context in store.compress(items, in: context, format: format) }
    }

    private func compress(_ items: [FileItem], in context: FileOperationContext, format: ArchiveFormat) {
        let fromHome = homeResultScope != nil
        let tabID = activeTabID
        let archiver = self.archiver
        let control = TransferControl()
        deferBackgroundRefresh()
        renameRecovery = nil
        operationNotice = nil
        operationAccessIssue = nil
        address.cancel()
        archiveControl = control
        archiveProgress = ArchiveProgress(itemCount: items.count, format: format,
                                          firstName: items.first?.name ?? "")
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            var results: [FileOperationResult] = []
            do {
                let result = try await archiver.compress(items, in: context, format: format, control: control)
                results = [result]
                if fromHome { self?.operationNotice = "Created \(result.url.lastPathComponent) in \(context.directoryURL.path)." }
                if let warning = result.warning { self?.appendOperationNotice(warning) }
            } catch is CancellationError {
                self?.operationNotice = "Compression cancelled. No archive was created."
            } catch {
                guard let self else { return }
                self.operationNotice = "Could not compress the selection. No archive was created. \(error.localizedDescription)"
                self.operationAccessIssue = self.accessIssue(for: error, locations: [context.directoryURL], action: "Compress")
            }
            guard let self else { return }
            self.archiveProgress = nil
            self.archiveControl = nil
            self.finishRecoveryWrite(tabID: tabID, context: context, results: results)
        }
    }

    func cancelArchive() {
        guard archiveProgress != nil else { return }
        archiveProgress?.isCancelling = true
        archiveControl?.cancel()
        operationTask?.cancel()
    }

    /// Make Alias: one Finder alias per selected item, selected afterwards.
    func makeAliasesForSelection() {
        withSiblingWriteSelection { store, items, context in store.makeAliases(for: items, in: context) }
    }

    private func makeAliases(for items: [FileItem], in context: FileOperationContext) {
        let fromHome = homeResultScope != nil
        let tabID = activeTabID
        let creator = self.aliasCreator
        deferBackgroundRefresh()
        renameRecovery = nil
        operationNotice = nil
        operationAccessIssue = nil
        address.cancel()
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            var results: [FileOperationResult] = []
            do {
                results = try await creator.makeAliases(for: items, in: context)
                if fromHome {
                    let noun = results.count == 1 ? "alias" : "aliases"
                    self?.operationNotice = "Created \(results.count) \(noun) in \(context.directoryURL.path)."
                }
            } catch let error as AliasCreationError {
                results = error.completed
                let location = fromHome ? " in \(context.directoryURL.path)" : ""
                self?.operationNotice = "Made \(results.count) of \(items.count) aliases\(location). \(error.localizedDescription)"
            } catch {
                self?.operationNotice = "Could not make an alias. \(error.localizedDescription)"
            }
            guard let self else { return }
            let warnings = results.compactMap(\.warning)
            if !warnings.isEmpty { self.appendOperationNotice(warnings.joined(separator: " ")) }
            self.finishRecoveryWrite(tabID: tabID, context: context, results: results)
        }
    }

    /// Open With ▸ applies to one selected file (absent for several, as in Windows).
    var openWithTarget: FileItem? {
        guard let target = eligibleOpenWithTarget, !openWithAssociations.contains(target.id) else { return nil }
        return target
    }

    private var eligibleOpenWithTarget: FileItem? {
        if homeResultScope != nil {
            guard isCommandIdle, let entries = homeOperationEntries, entries.count == 1,
                  let item = entries.first?.item, item.isRegularFile == true, !item.isSymbolicLink else { return nil }
            return item
        }
        let items = selectedItemsInOrder
        guard items.count == 1, BrowsingPresentation.isPhysical(items[0]), !items[0].isDirectory, shortcutDraft == nil, nameEdit == nil, !isPerformingOperation,
              !isShowingRecovery else { return nil }
        return items[0]
    }

    func applicationsToOpen(_ item: FileItem) -> [ApplicationChoice] {
        guard BrowsingPresentation.isPhysical(item) else { return [] }
        return applications.applications(toOpen: item.url)
    }

    /// Open With acts only on the file its menu captured. If the selection now
    /// holds another entry (the file was moved, renamed or replaced, or the selection
    /// changed), nothing opens and the notice says why.
    private func isCapturedOpenWithTarget(_ item: FileItem) -> Bool {
        guard !openWithAssociations.contains(item.id) else {
            operationNotice = "A default application change is already in progress for “\(item.name)”."
            return false
        }
        guard let target = openWithTarget, target.id == item.id, target.identity == item.identity else {
            operationNotice = "“\(item.name)” changed since the menu was opened. Nothing was opened."
            return false
        }
        return true
    }

    func open(_ item: FileItem, withApplicationAt application: URL) {
        guard isCapturedOpenWithTarget(item) else { return }
        routeOpenWith(item, choice: ApplicationPickerSelection(applicationURL: application, scope: .once),
                      origin: selectedRoutingOrigin)
    }

    func chooseApplicationAndOpen(_ item: FileItem) {
        guard isCapturedOpenWithTarget(item) else { return }
        let origin = selectedRoutingOrigin
        let allowsDefaultAssociation = Self.canAssociateOpenWith(item)
        let eligibleType = allowsDefaultAssociation ? applications.eligibleOpenWithType(for: item.url) : nil
        guard let choice = applications.chooseApplication(for: item.url,
            title: "Choose an application to open “\(item.name)”", allowsDefaultAssociation: allowsDefaultAssociation,
            eligibleType: eligibleType) else { return }
        if let type = choice.scope.contentType, type != eligibleType {
            operationNotice = "The file type default was not changed. This file’s type could not be verified."
            return
        }
        guard choice.scope != .file || allowsDefaultAssociation else {
            operationNotice = "The default was not changed. Always Open With is unavailable for symbolic links or files that could not be verified."
            return
        }
        routeOpenWith(item, choice: choice, origin: origin)
    }

    private func routeOpenWith(_ item: FileItem, choice: ApplicationPickerSelection, origin: RoutingOrigin) {
        address.cancelPendingSubmission()
        let router = applications
        let reservations = openWithTypeReservations
        let stillEnabled: @MainActor (ExplorerStore) -> Bool = {
            $0.openWithTarget.map { Self.sameEntries([$0], [item]) } ?? false
        }
        let application = choice.applicationURL
        let type = choice.scope.contentType
        let defaultSetPrefix = type == nil
            ? "The default application was already set. "
            : "The file type default was already set. "
        let refusalPrefix = switch choice.scope {
        case .once: ""
        case .file: "The default was not changed. "
        case .fileType: "The file type default was not changed. "
        }
        routeAfterRevalidation([item], origin: origin, refusalPrefix: refusalPrefix, stillEnabled: stillEnabled) { store in
            guard choice.scope != .once else {
                store.launchOpenWith(item, application: application, router: router, origin: origin)
                return
            }
            store.openWithAssociations.insert(item.id)
            Task { [weak store] in
                guard await store?.admitOpenWithAssociation(item, origin: origin, refusalPrefix: refusalPrefix) == true else { return }
                do {
                    if let type {
                        guard router.eligibleOpenWithType(for: item.url) == type else {
                            store?.openWithAssociations.remove(item.id)
                            store?.operationNotice = refusalPrefix + "This file’s type changed or could not be verified."
                            return
                        }
                        guard reservations.acquire(type) else {
                            store?.openWithAssociations.remove(item.id)
                            store?.operationNotice = refusalPrefix + "A default application change is already in progress for this file type."
                            return
                        }
                        defer { reservations.release(type) }
                        try await router.setDefaultApplication(at: application, forType: type)
                    } else {
                        try await router.setDefaultApplication(at: application, forFile: item.url)
                    }
                } catch {
                    store?.openWithAssociations.remove(item.id)
                    let subject = type == nil ? "“\(item.name)”" : "this file type"
                    store?.operationNotice = "Could not set the default application for \(subject). \(error.localizedDescription)"
                    return
                }
                guard let store else { return }
                store.openWithAssociations.remove(item.id)
                store.routeAfterRevalidation([item], origin: origin, refusalPrefix: defaultSetPrefix,
                                             stillEnabled: stillEnabled) { store in
                    store.launchOpenWith(item, application: application, router: router, origin: origin,
                                         failurePrefix: defaultSetPrefix)
                }
            }
        }
    }

    private static func canAssociateOpenWith(_ item: FileItem) -> Bool {
        item.identity != nil && !item.isSymbolicLink
    }

    private func admitOpenWithAssociation(_ item: FileItem, origin: RoutingOrigin, refusalPrefix: String) async -> Bool {
        if let home = origin.home, !(await verifiedHomeRoutingItems([item], origin: home)) {
            openWithAssociations.remove(item.id)
            operationNotice = refusalPrefix + Self.staleRoutingNotice
            return false
        }
        if routingOriginIsCurrent(origin), let target = eligibleOpenWithTarget,
           Self.canAssociateOpenWith(target), Self.sameEntries([target], [item]) {
            return true
        }
        openWithAssociations.remove(item.id)
        operationNotice = refusalPrefix + Self.staleRoutingNotice
        return false
    }

    private func canLaunchOpenWith(_ item: FileItem, origin: RoutingOrigin) -> Bool {
        guard routingOriginIsCurrent(origin), let target = openWithTarget else { return false }
        return Self.sameEntries([target], [item])
    }

    private func launchOpenWith(_ item: FileItem, application: URL, router: any ApplicationRouting,
                                origin: RoutingOrigin, failurePrefix: String = "") {
        let epoch = contextMenuLoadGeneration
        Task { [weak self] in
            let captured = await RecentDocument.validated(item)
            if let home = origin.home, await self?.verifiedHomeRoutingItems([item], origin: home) != true {
                self?.operationNotice = failurePrefix + Self.staleRoutingNotice
                return
            }
            guard self?.contextMenuLoadGeneration == epoch, self?.canLaunchOpenWith(item, origin: origin) == true else {
                self?.operationNotice = failurePrefix + Self.staleRoutingNotice
                return
            }
            let history = self?.recentDocuments
            do {
                try await router.open([item.url], withApplicationAt: application)
                if let captured { history?.record([captured], excluding: []) }
            }
            catch {
                let name = application.deletingPathExtension().lastPathComponent
                self?.operationNotice = failurePrefix + "Could not open “\(item.name)” with \(name). \(error.localizedDescription)"
            }
        }
    }

    /// Open in Terminal for a selected folder: revalidated like the other routes.
    func canOpenInTerminal(_ folder: FileItem) -> Bool {
        if homeResultScope != nil {
            guard isCommandIdle, folder.isDirectory, !folder.isSymbolicLink, let entries = homeOperationEntries else { return false }
            return Self.sameEntries(entries.map(\.item), [folder])
        }
        return BrowsingPresentation.isPhysical(folder) && folder.isDirectory && shortcutDraft == nil && nameEdit == nil && !isShowingRecovery && !activeTab.isUnavailable
    }
    func openInTerminal(_ folder: FileItem) {
        guard canOpenInTerminal(folder) else { return }
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, origin in
                guard Self.sameEntries(entries.map(\.item), [folder]) else { return }
                store.launchTerminal(at: folder.url, home: origin)
            }
            return
        }
        routeAfterRevalidation([folder], stillEnabled: { $0.canOpenInTerminal(folder) && $0.listsEntry(folder) }) { $0.launchTerminal(at: folder.url) }
    }

    /// The current folder as a menu target (background Properties and Open in Terminal).
    var currentFolderItem: FileItem {
        let url = activeTab.url
        return FileItem(url: url, name: BrowsingPresentation.title(url), isDirectory: true,
                        isSymbolicLink: false, size: nil, modifiedAt: nil, kind: "Folder", identity: activeTab.directoryIdentity,
                        archiveRevision: activeTab.archiveRevision)
    }
    /// Open in Terminal from the background: only while the tab still shows the
    /// folder (same location and identity) its menu captured.
    var canOpenCurrentFolderInTerminal: Bool {
        physicalFolderURL != nil && activeTab.search == nil && activeTab.hasLoaded && !activeTab.isUnavailable && shortcutDraft == nil && nameEdit == nil && !isShowingRecovery
    }
    func openCurrentFolderInTerminal(_ captured: FileItem) {
        guard canOpenCurrentFolderInTerminal else { return }
        let tabID = activeTabID
        func stillShowsCaptured(_ store: ExplorerStore) -> Bool {
            store.activeTabID == tabID && store.activeTab.url == captured.url
                && store.activeTab.directoryIdentity == captured.identity && store.canOpenCurrentFolderInTerminal
        }
        guard stillShowsCaptured(self) else { operationNotice = Self.changedNotice([captured.name]); return }
        // The cached identity can lag a replacement; check the folder on disk too.
        let validate = validateRoutingFolder
        Task { [weak self] in
            let current = await validate(captured.url, captured.identity)
            guard let self else { return }
            guard current, stillShowsCaptured(self) else { self.operationNotice = Self.changedNotice([captured.name]); return }
            self.launchTerminal(at: captured.url)
        }
    }
    private func launchTerminal(at folder: URL, home: HomeOperationOrigin? = nil) {
        let router = applications
        Task { [weak self] in
            guard let self, self.shortcutDraft == nil else { return }
            if let home, !self.isCommandIdle || !self.isHomeOperationOriginCurrent(home) { return }
            do { try await router.openInTerminal(folder) }
            catch { self.operationNotice = "Could not open Terminal at \(folder.path). \(error.localizedDescription)" }
        }
    }

    /// Show in Finder: the selection, or the current folder from the background.
    var canRevealInFinder: Bool {
        if homeResultScope != nil { return canAttemptHomeOperation }
        return physicalFolderURL != nil && nameEdit == nil && !isShowingRecovery
    }
    func revealSelectionInFinder() {
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, _ in store.applications.revealInFinder(entries.map(\.item.url)) }
        } else { revealInFinder(selectedItemsInOrder.map(\.url)) }
    }
    func revealInFinder(_ urls: [URL]) {
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, _ in
                let current = entries.map(\.item.url)
                if current == urls { store.applications.revealInFinder(current) }
            }
            return
        }
        guard canRevealInFinder, !urls.isEmpty, urls.allSatisfy({ BrowsingLocation(url: $0)?.physicalURL != nil }) else { return }
        applications.revealInFinder(urls)
    }

    var canCopyPathnames: Bool {
        if homeResultScope != nil { return canAttemptHomeOperation }
        return nameEdit == nil && !isShowingRecovery && !selectedItemsInOrder.isEmpty
    }

    /// Copy as Pathname (⌥⌘C): POSIX paths, one per line, unquoted (Finder
    /// convention; Windows' Copy as path quotes them). Never creates a transfer intent.
    func copyPathnames(to pasteboard: NSPasteboard? = nil) {
        guard canCopyPathnames else { return }
        // The window's clipboard pasteboard (the general pasteboard in the app).
        let pasteboard = pasteboard ?? clipboard.pasteboard
        if homeResultScope != nil {
            let version = pasteboard.changeCount
            performVerifiedHomeCommand { store, entries, _ in
                guard pasteboard.changeCount == version else { return }
                pasteboard.clearContents()
                pasteboard.setString(entries.map { BrowsingPresentation.path($0.item.url) }.joined(separator: "\n"), forType: .string)
                store.clipboard.refresh()
            }
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(selectedItemsInOrder.map { BrowsingPresentation.path($0.url) }.joined(separator: "\n"), forType: .string)
        clipboard.refresh()
    }
    var displayedItems: [FileItem] {
        if let search = activeTab.search { return search.displayedItems }
        let placeholder = nameEdit.flatMap { $0.tabID == activeTabID ? $0.placeholder : nil }
        return sortedItems + (placeholder.map { [$0] } ?? [])
    }
    /// The selection presented by the content view: search results or folder rows.
    var currentSelection: SelectionState { activeTab.search?.selection ?? activeTab.selection }
    var isSearching: Bool { activeTab.search != nil }
    /// Folder-relative writes (New Folder, Rename, Paste, Move Here) never target results (MAC-065).
    var canCreateFolder: Bool {
        physicalFolderURL != nil && activeTab.search == nil && activeTab.hasLoaded && !activeTab.isLoading && !activeTab.isUnavailable
            && activeTab.directoryIdentity != nil && isCommandIdle
    }
    /// The item Rename edits: the sole selected item, or — with several selected —
    /// the focused one inside the selection (FR-FILE-025 / EV-0488). The selection is kept.
    var renameTarget: FileItem? {
        let selected = activeTab.selection.selectedIDs
        let id = selected.count == 1 ? selected.first
            : activeTab.selection.focusedID.flatMap { selected.contains($0) ? $0 : nil }
        return id.flatMap { id in activeTab.items.first { $0.id == id } }
    }
    var canRenameSelection: Bool {
        if let origin = homeOperationOrigin {
            return isCommandIdle && canAttemptHomeOperation && origin.selectedUniqueCount == 1
        }
        return activeTab.search == nil && isCommandIdle
            && renameTarget.flatMap(operationEntry) != nil
    }

    func beginCreateFolder() { beginCreateItem(.folder) }

    /// New inline drafts share the exclusive physical creation path.
    /// A draft writes nothing until Enter (MAC-025); suggestions avoid displayed names.
    func beginCreateItem(_ kind: NewItemKind) {
        guard canCreateFolder, let identity = activeTab.directoryIdentity else { return }
        address.cancel()
        deferBackgroundRefresh()
        let names = Set(activeTab.items.map(\.name))
        let defaultName = kind.defaultName as NSString
        let base = defaultName.deletingPathExtension
        let suffixText = defaultName.pathExtension.isEmpty ? "" : "." + defaultName.pathExtension
        var name = kind.defaultName
        var suffix = 2
        while names.contains(name) { name = "\(base) (\(suffix))\(suffixText)"; suffix += 1 }
        operationNotice = nil
        operationAccessIssue = nil
        nameEdit = NameEditSession(tabID: activeTabID,
            context: FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity),
            item: nil, name: name, newItemKind: kind)
    }

    func runNewCommand(_ command: NewCommand) {
        if let kind = command.inlineKind { beginCreateItem(kind) }
        else { beginShortcutDraft() }
    }

    private func beginShortcutDraft() {
        guard canCreateFolder, let identity = activeTab.directoryIdentity else { return }
        pointerRename.cancel()
        address.cancel()
        deferBackgroundRefresh()
        dismissOperationNotice()
        shortcutDraft = ShortcutDraft(tabID: activeTabID,
            destination: FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity))
    }

    func updateShortcutTarget(_ value: String, draftID: UUID) {
        guard let draft = shortcutDraft, draft.id == draftID, draft.target == nil, !draft.isWorking else { return }
        shortcutDraft?.targetText = value
        shortcutDraft?.errorMessage = nil
    }

    func advanceShortcutDraft() {
        guard let draft = shortcutDraft, draft.target == nil, draft.canAdvance else { return }
        let url: URL
        do { url = try LocalPathInput.resolve(draft.targetText) }
        catch { shortcutDraft?.errorMessage = error.localizedDescription; return }
        shortcutDraft?.isWorking = true
        shortcutDraft?.errorMessage = nil
        let creator = aliasCreator
        shortcutValidation = Task { [weak self] in
            let result: Result<ShortcutPreparation, Error>
            do { result = .success(try await creator.prepareShortcut(to: url, in: draft.destination)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.shortcutDraft?.id == draft.id else { return }
            self.shortcutValidation = nil
            self.shortcutDraft?.isWorking = false
            switch result {
            case .success(let prepared):
                self.shortcutDraft?.name = prepared.suggestedName
                self.shortcutDraft?.target = prepared.target
            case .failure(let error):
                self.shortcutDraft?.errorMessage = error.localizedDescription
            }
        }
    }

    func updateShortcutName(_ value: String, draftID: UUID) {
        guard let draft = shortcutDraft, draft.id == draftID, draft.target != nil, !draft.isWorking else { return }
        shortcutDraft?.name = value
        shortcutDraft?.errorMessage = nil
    }

    func backShortcutDraft() {
        guard let draft = shortcutDraft, draft.target != nil, !draft.isWorking else { return }
        shortcutDraft?.target = nil
        shortcutDraft?.errorMessage = nil
    }

    func cancelShortcutDraft() {
        guard shortcutDraft != nil, !isPerformingOperation else { return }
        shortcutValidation?.cancel()
        shortcutValidation = nil
        shortcutDraft = nil
        scheduleObservedRefresh()
    }

    func finishShortcutDraft() {
        guard let draft = shortcutDraft, draft.canFinish, let target = draft.target,
              activeTabID == draft.tabID, activeTab.url == draft.destination.directoryURL,
              activeTab.directoryIdentity == draft.destination.directoryIdentity else { return }
        let creator = aliasCreator
        shortcutDraft?.isWorking = true
        shortcutDraft?.errorMessage = nil
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            do {
                let result = try await creator.createAlias(to: target, named: draft.name, in: draft.destination)
                guard let self, self.shortcutDraft?.id == draft.id else { return }
                self.shortcutDraft = nil
                self.operationNotice = result.warning
                if let failure = result.accessFailure {
                    self.operationAccessIssue = FileAccessContext(failure: failure,
                        locations: [draft.destination.directoryURL], action: "Verify completed change")
                }
                self.finishRecoveryWrite(tabID: draft.tabID, context: draft.destination, results: [result])
            } catch {
                guard let self, self.shortcutDraft?.id == draft.id else { return }
                self.operationTask = nil
                self.isPerformingOperation = false
                self.shortcutDraft?.isWorking = false
                self.shortcutDraft?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Second-click rename (MAC-076)

    /// Arms a delayed rename for `itemID`, which must already be the sole selection
    /// in the active folder and renamable. Returns whether a candidate was armed.
    @discardableResult
    func armPointerRename(itemID: String) -> Bool {
        guard canRenameSelection, activeTab.selection.selectedIDs == [itemID],
              let item = activeTab.items.first(where: { $0.id == itemID }) else {
            pointerRename.cancel()
            return false
        }
        let target = PointerRenameIntent.Target(tabID: activeTabID, directoryURL: activeTab.url,
                                                itemID: itemID, identity: item.identity, archiveRevision: item.archiveRevision)
        pointerRename.arm(target) { [weak self] target in self?.firePointerRename(target) }
        return true
    }

    func cancelPointerRename() { pointerRename.cancel() }

    /// MAC-076: counts app-wide interruptions (keys, presses, menu tracking) so a
    /// press held across one cannot arm a rename on release.
    private(set) var pointerInterruptions = 0
    func notePointerInterruption() {
        pointerInterruptions &+= 1
        pointerRename.cancel()
    }

    /// Revalidates the original tab, folder, sole selection and item identity;
    /// `beginRename()` would otherwise act on whatever is selected now.
    func firePointerRename(_ target: PointerRenameIntent.Target) {
        guard activeTabID == target.tabID, activeTab.url == target.directoryURL,
              activeTab.selection.selectedIDs == [target.itemID],
              let item = activeTab.items.first(where: { $0.id == target.itemID }),
              item.identity == target.identity, item.archiveRevision == target.archiveRevision, canRenameSelection else { return }
        beginRename()
    }

    func beginRename() {
        if homeOperationOrigin != nil {
            guard canRenameSelection else { return }
            performVerifiedHomeCommand { store, entries, origin in
                guard entries.count == 1, let entry = entries.first else { return }
                store.address.cancel()
                store.operationNotice = nil
                store.operationAccessIssue = nil
                store.nameEdit = NameEditSession(tabID: store.activeTabID, context: entry.source,
                    item: entry.item, name: entry.item.name, homeOrigin: origin)
            }
            return
        }
        guard canRenameSelection, let item = renameTarget, let entry = operationEntry(for: item) else { return }
        address.cancel()
        deferBackgroundRefresh()
        operationNotice = nil
        operationAccessIssue = nil
        nameEdit = NameEditSession(tabID: activeTabID,
            context: entry.context,
            item: item, name: item.name)
    }

    func updateProposedName(_ value: String, sessionID: UUID) {
        guard nameEdit?.id == sessionID, nameEdit?.isSubmitting == false else { return }
        nameEdit?.proposedName = value
        nameEdit?.errorMessage = nil
        nameEdit?.accessIssue = nil
    }

    func cancelNameEdit(sessionID: UUID? = nil) {
        guard let edit = nameEdit, !edit.isSubmitting,
              sessionID == nil || sessionID == edit.id else { return }
        nameEdit = nil
        scheduleObservedRefresh()
    }

    func dismissOperationNotice() {
        operationNotice = nil
        operationAccessIssue = nil
    }
    func showRetainedZIPFiles(_ artifacts: [RetainedContentArtifact]) {
        operationNotice = "Retained ZIP files\n" + artifacts.map { "\($0.url.path): \($0.reason)" }.joined(separator: "\n")
    }
    func showRetainedZIPReceiptError(_ message: String) {
        operationNotice = "The retained ZIP file record could not be read or saved. \(message)"
    }

    /// Help never changes a draft, pending navigation, recovery receipt or operation.
    func showAccessHelp(_ context: FileAccessContext? = nil) {
        guard !isPerformingOperation else { return }
        onShowAccessHelp?(context)
    }

    private func accessIssue(for error: Error, locations: [URL], action: String) -> FileAccessContext? {
        guard let failure = FileAccessFailure.classify(error) else { return nil }
        return FileAccessContext(failure: failure, locations: locations, action: action)
    }

    func commitNameEdit(sessionID: UUID) {
        guard let edit = nameEdit, edit.id == sessionID, !edit.isSubmitting,
              edit.tabID == activeTabID, !isPerformingOperation else { return }
        if let origin = edit.homeOrigin {
            guard isHomeOperationOriginCurrent(origin) else {
                nameEdit?.errorMessage = FileOperationError.staleSource.localizedDescription
                return
            }
        } else if edit.directoryURL != activeTab.url { return }
        if case .archive = edit.context, let item = edit.item, item.name.utf8.elementsEqual(edit.proposedName.utf8) {
            cancelNameEdit(sessionID: edit.id)
            return
        }
        guard case .filesystem(let physicalContext) = edit.context else {
            if case .archive(let context) = edit.context, let item = edit.item,
               let target = ItemOperationEntry(item: item, context: edit.context).archiveTarget {
                runArchiveMutation([.rename(source: target, newName: edit.proposedName)], context: context,
                    label: "Renaming in ZIP", edit: edit)
            }
            return
        }
        nameEdit?.isSubmitting = true
        nameEdit?.errorMessage = nil
        nameEdit?.accessIssue = nil
        renameRecovery = nil
        address.cancel()
        isPerformingOperation = true
        let operations = self.operations
        let fileCreator = self.fileCreator
        operationTask = Task { [weak self] in
            do {
                let result: FileOperationResult
                if let item = edit.item {
                    if let origin = edit.homeOrigin {
                        guard let self else { return }
                        let entries = try await self.verifiedHomeOperationEntries(for: origin)
                        guard entries.count == 1, let entry = entries.first, entry.item.identity == item.identity,
                              entry.item.url == item.url, entry.source == physicalContext,
                              self.nameEdit?.id == edit.id, self.isHomeOperationOriginCurrent(origin)
                        else { throw FileOperationError.staleSource }
                    }
                    result = try await operations.rename(item, to: edit.proposedName, in: physicalContext)
                } else {
                    switch edit.newItemKind ?? .folder {
                    case .folder:
                        result = try await operations.createFolder(named: edit.proposedName, in: physicalContext)
                    case .file(let template):
                        result = try await fileCreator.createFile(named: edit.proposedName, template: template, in: physicalContext)
                    }
                }
                guard let self else { return }
                // The syscall committed. Never reinterpret later refresh failure as a failed write.
                self.nameEdit = nil
                self.operationNotice = result.warning
                if let failure = result.accessFailure {
                    self.operationAccessIssue = FileAccessContext(failure: failure,
                        locations: [result.url.deletingLastPathComponent()], action: "Verify completed change")
                }
                if let original = edit.item {
                    self.renameRecovery = RenameRecovery(context: physicalContext, original: original,
                                                         renamedName: edit.proposedName, result: result)
                    if edit.homeOrigin != nil {
                        if !original.url.path.utf8.elementsEqual(result.url.path.utf8) {
                            self.homeSourcesDidLeave([TransferEntry(source: physicalContext, item: original)])
                        }
                        self.operationTask = nil
                        self.isPerformingOperation = false
                        return
                    }
                }
                self.operationResult = (edit.tabID, physicalContext, [result])
                self.operationTask = nil
                if let tab = self.tabs.first(where: { $0.id == edit.tabID }) {
                    self.load(tabID: tab.id, history: tab.history, preserveSelection: true)
                } else {
                    self.isPerformingOperation = false
                    self.operationResult = nil
                }
            } catch {
                guard let self else { return }
                self.isPerformingOperation = false
                self.operationTask = nil
                if self.nameEdit?.id == edit.id {
                    self.nameEdit?.isSubmitting = false
                    self.nameEdit?.errorMessage = error.localizedDescription
                    self.nameEdit?.accessIssue = self.accessIssue(for: error,
                        locations: [edit.directoryURL], action: edit.newItemKind?.operationName ?? "Rename")
                }
            }
        }
    }

    private var itemOperationCoordinator: ItemOperationCoordinator {
        ItemOperationCoordinator(archives: archiveModifier, transfers: transfers, recovery: recovery,
            loader: loader, conflicts: conflictInspector, registry: contentRegistry)
    }

    private func archiveProgressHandler(_ sessionID: UUID) -> @Sendable (TransferProgress) -> Void {
        let progressID = UUID()
        transferRuntime?.progressID = progressID
        transfer?.phase = .copying
        transfer?.bytesCopied = 0
        transfer?.currentEntries = 0
        return { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.transfer?.id == sessionID, self.transferRuntime?.progressID == progressID else { return }
                self.transfer?.currentName = progress.currentName
                self.transfer?.bytesCopied = max(self.transfer?.bytesCopied ?? 0, progress.bytesCopied)
                self.transfer?.currentEntries = max(self.transfer?.currentEntries ?? 0, progress.itemsCompleted)
                if let phase = self.transfer?.phase, Self.order(progress.phase) > Self.order(phase) {
                    self.transfer?.phase = progress.phase
                }
            }
        }
    }

    private enum TransferFinish: Equatable { case idle, awaitingResultRefresh }

    private func beginTransferSession(_ session: TransferSession) -> TransferControl {
        deferBackgroundRefresh()
        renameRecovery = nil
        operationNotice = nil; operationAccessIssue = nil
        address.cancel()
        let runtime = TransferRuntime(id: session.id)
        transferRuntime = runtime
        transfer = session
        isPerformingOperation = true
        return runtime.control
    }

    private func beginTransferSession(label: String, count: Int, source: URL, destination: URL,
                                      kind: TransferKind = .copy, preparing: Bool = false) -> (UUID, TransferControl) {
        let session = TransferSession(id: UUID(), kind: kind, sourceURLs: [source], destinationURL: destination,
            totalItems: count, operationLabel: label, isPreparing: preparing)
        return (session.id, beginTransferSession(session))
    }

    private func finishTransferSession(_ id: UUID, disposition: TransferFinish = .idle) {
        guard let runtime = transferRuntime, runtime.id == id, transfer?.id == id else { return }
        // Remove every continuation and authority slot before waking suspended work.
        transferRuntime = nil
        transfer = nil
        runtime.control.cancel()
        runtime.conflictInspection?.abandon()
        runtime.pauseWaiter?.resume()
        runtime.conflictReply?.resume(returning: .cancel)
        if disposition == .idle {
            isPerformingOperation = false
            scheduleObservedRefresh()
        }
    }

    private func openArchiveSelection(_ items: [FileItem]) {
        guard canOpenSelection || (items.count == 1 && shortcutDraft == nil && nameEdit == nil && !isPerformingOperation),
              items.allSatisfy({ listsEntry($0) }),
              items.allSatisfy({ FileActivationTarget($0).canOpen }) else { return }
        let entries = items.compactMap(operationEntry)
        guard entries.count == items.count else { return }
        let invocation = ContextMenuSnapshot(store: self, item: items.first)
        let tabID = activeTabID, generation = tabLoads[activeTabID]?.authorizationEpoch, location = activeTab.url
        let (sessionID, control) = beginTransferSession(label: "Preparing temporary ZIP copies", count: items.count,
            source: location, destination: location, preparing: true)
        let provider = contentProvider
        transferRuntime?.task = Task { [weak self] in
            var leases: [any MaterializedContentLease] = []
            do {
                for entry in entries where !entry.item.isDirectory {
                    let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .externalOpen), control: control)
                    leases.append(lease)
                    try Task.checkCancellation()
                    guard entry.acceptsContent(lease, for: .externalOpen) else { throw ItemContentError.staleSource }
                    try await lease.validateForUse()
                }
                guard let self, self.transfer?.id == sessionID, self.activeTabID == tabID,
                      self.tabLoads[tabID]?.authorizationEpoch == generation, self.activeTab.url == location,
                      items.allSatisfy({ self.listsEntry($0) }) else { throw CancellationError() }
                for entry in entries {
                    guard let target = entry.archiveTarget,
                          await target.revision.isCurrent(at: target.location.archiveURL) else { throw ArchiveOperationError.changed }
                }
                try Task.checkCancellation()
                guard self.transfer?.id == sessionID, self.activeTabID == tabID,
                      self.tabLoads[tabID]?.authorizationEpoch == generation, self.activeTab.url == location,
                      invocation.matches(self), items.allSatisfy({ self.listsEntry($0) }) else { throw CancellationError() }
                let failures = self.applications.openWithDefaultApplications(leases.map(\.fileURL))
                for lease in leases {
                    if failures.contains(lease.fileURL) { _ = await lease.release() }
                    else { self.externalOpenContents.retain(lease) }
                }
                leases.removeAll()
                self.operationNotice = failures.isEmpty
                    ? "Opened a read-only temporary ZIP copy. Save a separate copy to keep edits; changes are not saved back to the ZIP."
                    : "macOS could not open \(failures.map(\.lastPathComponent).joined(separator: ", "))."
                self.finishTransferSession(sessionID)
                for item in items where item.isDirectory { self.openTab(at: item.url) }
            } catch {
                for lease in leases { _ = await lease.release() }
                guard let self, self.transfer?.id == sessionID else { return }
                self.operationNotice = error is CancellationError ? "Opening cancelled." : error.localizedDescription
                self.finishTransferSession(sessionID)
            }
        }
    }

    private func prepareArchiveClipboard(_ entries: [ItemOperationEntry], kind: TransferKind) {
        guard canCopySelection else { return }
        let tabID = activeTabID, generation = tabLoads[activeTabID]?.authorizationEpoch, count = clipboard.pasteboard.changeCount
        let items = entries.map(\.item), location = activeTab.url
        let (sessionID, control) = beginTransferSession(label: "Preparing ZIP contents for the clipboard", count: entries.count,
            source: location, destination: location, kind: kind, preparing: true)
        let provider = contentProvider
        transferRuntime?.task = Task { [weak self] in
            var leases: [any MaterializedContentLease] = []
            do {
                for entry in entries {
                    let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .clipboardExport), control: control)
                    leases.append(lease)
                    try Task.checkCancellation()
                    guard entry.acceptsContent(lease, for: .clipboardExport) else { throw ItemContentError.staleSource }
                    try await lease.validateForUse()
                }
                for entry in entries {
                    guard let target = entry.archiveTarget,
                          await target.revision.isCurrent(at: target.location.archiveURL) else { throw ArchiveOperationError.changed }
                }
                try Task.checkCancellation()
                guard let self, self.transfer?.id == sessionID, self.activeTabID == tabID,
                      self.tabLoads[tabID]?.authorizationEpoch == generation, Self.sameEntries(self.selectedItemsInOrder, items) else {
                    throw CancellationError()
                }
                guard self.clipboard.captureArchive(entries: entries, leases: leases, kind: kind, expectedChangeCount: count) else {
                    throw ExternalClipboardError.changed
                }
                leases.removeAll() // clipboard is now the sole cleanup owner
                self.operationNotice = kind == .move
                    ? "Ready to move in \(AppIdentity.name). Pasting in another app copies the exported files and leaves the ZIP originals."
                    : "ZIP contents copied to the clipboard."
                self.finishTransferSession(sessionID)
            } catch {
                for lease in leases { _ = await lease.release() }
                guard let self, self.transfer?.id == sessionID else { return }
                self.operationNotice = error is CancellationError ? "Clipboard preparation cancelled; the previous clipboard was kept." : error.localizedDescription
                self.finishTransferSession(sessionID)
            }
        }
    }

    private func awaitTransferConflict(_ info: TransferConflictInfo, sessionID: UUID) async -> TransferConflictChoice {
        guard transferRuntime?.id == sessionID, transfer?.id == sessionID,
              transfer?.isCancelling == false, transferRuntime?.conflictReply == nil else { return .cancel }
        transferRuntime?.progressID = nil
        transfer?.phase = .copying
        let choice = await withCheckedContinuation { reply in
            transferRuntime?.conflictReply = reply
            transfer?.conflictName = info.name
            transfer?.conflict = info
        }
        guard transferRuntime?.id == sessionID, transfer?.id == sessionID else { return .cancel }
        transfer?.conflictName = nil; transfer?.conflict = nil
        return choice
    }

    private func beginTypedTransfer(to destination: ItemOperationContext, moving: Bool,
                                    home: HomePasteTarget? = nil) {
        guard isCommandIdle else { return }
        if case .archive = destination,
           let refusal = clipboard.archivePasteRefusal(isManagedURL: contentRegistry.containsManagedURL) {
            operationNotice = refusal.message
            return
        }
        guard home != nil || canPaste else { return }
        let payload = clipboard.payload
        let external: ExternalClipboardSnapshot?
        let kind = moving ? TransferKind.move : payload?.kind ?? .copy
        do {
            external = payload == nil ? try clipboard.externalSnapshot() : nil
            if kind == .move, let external { try clipboard.claimMove(external) }
        } catch { operationNotice = error.localizedDescription; return }
        let tabID = activeTabID
        let (sessionID, control) = beginTransferSession(label: destination.directoryURL.isFileURL ? "Copying ZIP contents" : "Adding to ZIP",
            count: payload?.entries.count ?? external?.urlStrings.count ?? 0,
            source: payload?.logicalEntries.first?.context.directoryURL ?? destination.directoryURL,
            destination: destination.directoryURL, kind: kind, preparing: external != nil || payload?.hasArchiveOrigin == true)
        let generation = tabLoads[tabID]?.authorizationEpoch
        let coordinator = itemOperationCoordinator, importer = transferImporter, provider = contentProvider
        transferRuntime?.task = Task { [weak self] in
            guard let self else { return }
            // A transfer owns independent leases. Clipboard ownership can end
            // before or during a copy, and consuming Cut must retire its public
            // exports without revoking the operation's content.
            var transferLeases: [any MaterializedContentLease] = []
            defer {
                let finished = transferLeases
                if !finished.isEmpty { Task { for lease in finished { _ = await lease.release() } } }
            }
            do {
                let prepared: TransferClipboardPayload
                if let payload, payload.hasArchiveOrigin {
                    for entry in payload.logicalEntries {
                        let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .transfer), control: control)
                        transferLeases.append(lease)
                        try Task.checkCancellation()
                        guard entry.acceptsContent(lease, for: .transfer) else { throw ItemContentError.staleSource }
                        try await lease.validateForUse()
                    }
                    guard self.clipboard.payload?.id == payload.id else { throw ExternalClipboardError.changed }
                    prepared = TransferClipboardPayload(id: payload.id, entries: transferLeases.map(\.physicalEntry), kind: kind,
                        logicalEntries: payload.logicalEntries, leases: transferLeases)
                } else if let payload { prepared = payload }
                else if let external {
                    let entries = try await importer.capture(urlStrings: external.urlStrings)
                    try Task.checkCancellation()
                    guard self.clipboard.stillMatches(external) else { throw ExternalClipboardError.changed }
                    prepared = TransferClipboardPayload(id: external.id, entries: entries, kind: kind)
                } else { throw ExternalClipboardError.changed }
                let destinationIsCurrent = if let home {
                    self.isCurrentHomePasteTarget(home)
                } else {
                    self.tabLoads[tabID]?.authorizationEpoch == generation && self.currentOperationContext == destination
                }
                guard self.transfer?.id == sessionID, self.activeTabID == tabID, destinationIsCurrent else {
                    throw ArchiveOperationError.changed
                }
                if case .archive = destination {
                    if let refusal = self.clipboard.archivePasteRefusal(for: prepared,
                        isManagedURL: self.contentRegistry.containsManagedURL) {
                        throw ArchiveOperationError.unsupported(refusal.message)
                    }
                }
                if kind == .move {
                    if let external {
                        guard self.clipboard.consumeExternalMove(external) else { throw ExternalClipboardError.changed }
                    } else { self.clipboard.consume(prepared.id) }
                }
                self.transfer?.isPreparing = false
                let conflict: ItemOperationCoordinator.Conflict = { [weak self] info in
                    guard let self else { return .cancel }
                    return await self.awaitTransferConflict(info, sessionID: sessionID)
                }
                let outcome: ItemTransferOutcome
                let progress: ItemOperationCoordinator.ProgressFactory = { [weak self] in
                    self?.archiveProgressHandler(sessionID) ?? { _ in }
                }
                switch destination {
                case .filesystem(let context):
                    outcome = await coordinator.copyOut(prepared, to: context, moving: kind == .move,
                        control: control, progress: progress, conflict: conflict)
                case .archive(let context):
                    outcome = try await coordinator.add(prepared.logicalEntries, to: context, moving: kind == .move,
                        control: control, progress: progress, conflict: conflict)
                }
                guard self.transfer?.id == sessionID else { return }
                self.operationNotice = outcome.summary
                for receipt in outcome.trashReceipts { self.recoveryHistory.record(receipt) }
                for result in outcome.archiveResults {
                    self.archiveBroadcaster.publish(result, origin: self, selecting: result.changedLocations)
                }
                if case .filesystem(let context) = destination, home == nil {
                    self.operationResult = (tabID, context, outcome.physicalResults)
                    self.finishTransferSession(sessionID, disposition: .awaitingResultRefresh)
                    if let tab = self.tabs.first(where: { $0.id == tabID }) {
                        self.load(tabID: tabID, history: tab.history, preserveSelection: true)
                    } else { self.operationResult = nil; self.isPerformingOperation = false }
                } else { self.finishTransferSession(sessionID) }
            } catch {
                guard self.transfer?.id == sessionID else { return }
                self.operationNotice = error is CancellationError ? "Transfer cancelled before publication." : error.localizedDescription
                self.finishTransferSession(sessionID)
            }
        }
    }

    func deleteSelection() {
        guard canDeleteSelection else { return }
        guard case .archive(let context)? = currentOperationContext,
              let entries = selectedOperationEntries else { trashSelection(); return }
        archiveDeleteConfirmation = ArchiveDeleteConfirmation(tabID: activeTabID,
            generation: tabLoads[activeTabID]?.authorizationEpoch, context: context, entries: entries)
    }
    func cancelArchiveDelete() { archiveDeleteConfirmation = nil }
    func confirmArchiveDelete() {
        guard let request = archiveDeleteConfirmation else { return }
        archiveDeleteConfirmation = nil
        guard canDeleteSelection, request.tabID == activeTabID,
              request.generation == tabLoads[activeTabID]?.authorizationEpoch, currentOperationContext == .archive(request.context),
              Self.sameEntries(request.entries.map(\.item), selectedItemsInOrder) else {
            operationNotice = "The selection or ZIP changed. Nothing was deleted."; return
        }
        let targets = request.entries.compactMap(\.archiveTarget)
        guard targets.count == request.entries.count else { return }
        runArchiveMutation(targets.map { .remove(source: $0) }, context: request.context, label: "Deleting from ZIP")
    }

    private func runArchiveMutation(_ edits: [ArchiveEdit], context: ArchiveOperationContext,
                                    label: String, edit: NameEditSession? = nil) {
        if edit != nil { nameEdit?.isSubmitting = true; nameEdit?.errorMessage = nil; nameEdit?.accessIssue = nil }
        let (sessionID, control) = beginTransferSession(label: label, count: edits.count,
            source: context.location.url, destination: context.location.url)
        let modifier = archiveModifier
        transferRuntime?.task = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.validateArchiveRevision(context.location.archiveURL, context.revision),
                      self.transfer?.id == sessionID else { throw ArchiveOperationError.changed }
                if let edit, self.nameEdit?.id != edit.id { throw ArchiveOperationError.changed }
                let result = try await modifier.modify(edits, in: context, control: control,
                    onProgress: self.archiveProgressHandler(sessionID))
                guard self.transfer?.id == sessionID else { return }
                if let edit, self.nameEdit?.id == edit.id { self.nameEdit = nil }
                self.operationNotice = result.warning ?? (edit == nil ? "Deleted the selected ZIP contents permanently." : "Renamed the ZIP item.")
                if let receipt = result.recovery {
                    self.appendOperationNotice(receipt.reason + " " + receipt.retainedURLs.map(\.path).joined(separator: ", "))
                }
                self.archiveBroadcaster.publish(result, origin: self,
                    selecting: edit == nil ? [] : result.renamedLocations.map(\.destinationURL))
                self.finishTransferSession(sessionID)
            } catch {
                guard self.transfer?.id == sessionID else { return }
                if let edit, self.nameEdit?.id == edit.id {
                    self.nameEdit?.isSubmitting = false
                    self.nameEdit?.errorMessage = error is CancellationError ? "Rename cancelled before publication." : error.localizedDescription
                    self.nameEdit?.accessIssue = self.accessIssue(for: error, locations: [context.location.archiveURL], action: "Rename in ZIP")
                } else { self.operationNotice = error is CancellationError ? "Deletion cancelled before publication." : error.localizedDescription }
                self.finishTransferSession(sessionID)
            }
        }
    }

    func archiveDidCommit(_ result: ArchiveMutationResult, selecting: [URL]) {
        // Reconciliation below loads archive tabs only. Cloud attempts are
        // admitted only for filesystem entries, so they cannot own those tabs;
        // physical tabs receive history remapping without a read or preview reset.
        if ArchiveLocation(url: activeTab.url)?.archiveURL == result.archiveURL {
            preview.show(nil)
            pointerRename.cancel()
        }
        if archiveDeleteConfirmation?.context.location.archiveURL == result.archiveURL { archiveDeleteConfirmation = nil }
        if let edit = nameEdit, case .archive(let context) = edit.context,
           context.location.archiveURL == result.archiveURL { nameEdit = nil }
        for index in tabs.indices {
            tabs[index].navigationSelections.invalidateArchive(result.archiveURL)
            var history = tabs[index].history
            history.remapLocations { Self.remapArchiveLocation($0, mappings: result.renamedLocations) }
            guard let location = ArchiveLocation(url: tabs[index].url),
                  location.archiveURL == result.archiveURL else {
                tabs[index].history = history
                continue
            }
            let tabID = tabs[index].id
            let token = startLoadWork(tabID: tabID, request: .archiveReconciliation)
            failedLoads.removeValue(forKey: tabID)
            tabs[index].selection.clear()
            tabs[index].navigationSelections = NavigationSelectionMemory()
            tabs[index].archiveRevision = nil
            tabs[index].isLoading = true; tabs[index].isRefreshing = false
            let loader = self.loader
            tabLoads[tabID]?.work?.task = Task { [weak self] in
                var target = history.current
                while let current = ArchiveLocation(url: target) {
                    do { _ = try await loader.snapshot(of: target, showHidden: true); break }
                    catch ZIPListingError.missingFolder where !current.components.isEmpty { target = current.parentURL }
                    catch { break }
                }
                guard !Task.isCancelled, let self, self.isCurrentLoadWork(tabID: tabID, token: token) else { return }
                if target != history.current { history.navigate(to: target) }
                let reveal = result.revision.map { revision in
                    ItemReveal(entries: selecting.map { ItemReveal.Entry(url: $0, identity: nil, archiveRevision: revision) }, missingNotice: nil)
                }
                self.load(tabID: tabID, history: history, preserveSelection: false, reveal: reveal)
            }
        }
    }
    private static func remapArchiveLocation(_ url: URL, mappings: [ArchiveRenameMapping]) -> URL {
        guard let location = ArchiveLocation(url: url) else { return url }
        for mapping in mappings {
            guard let old = ArchiveLocation(url: mapping.sourceURL), let new = ArchiveLocation(url: mapping.destinationURL),
                  location.archiveURL == old.archiveURL, location.components.count >= old.components.count,
                  zip(location.components, old.components).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }),
                  let mapped = try? ArchiveLocation(archiveURL: new.archiveURL,
                    components: new.components + Array(location.components.dropFirst(old.components.count))) else { continue }
            return mapped.url
        }
        return url
    }

    var canCopySelection: Bool {
        if homeResultScope != nil { return canAttemptHomeOperation }
        if activeTab.search != nil { return selectedSearchOperationEntries != nil }
        return isCommandIdle && selectedOperationEntries != nil
    }
    var canCutSelection: Bool { canCopySelection }
    var canDeleteSelection: Bool { canCopySelection }
    var deleteActionTitle: String { ArchiveLocation(url: activeTab.url) == nil ? "Move to Trash" : "Delete" }
    var canPaste: Bool {
        if let origin = homeOperationOrigin {
            guard isCommandIdle, clipboard.hasTransferCandidate, isHomeOperationOriginCurrent(origin) else { return false }
            return origin.selectedUniqueCount == 0 || canAttemptHomeDestination
        }
        guard isCommandIdle, activeTab.search == nil,
              let destination = currentOperationContext, clipboard.hasTransferCandidate else { return false }
        if case .archive = destination {
            if let refusal = clipboard.archivePasteRefusal(isManagedURL: contentRegistry.containsManagedURL) {
                // Like other invalid external candidates, this stays enabled so
                // the action can explain refusal before reserving or starting work.
                return refusal == .unverifiedPrivateToken
            }
            if let payload = clipboard.payload {
                return ItemOperationCapabilities(entries: payload.logicalEntries).canPaste(into: destination)
            }
        }
        return true
    }
    var canMoveHere: Bool { canPaste }

    func copySelection() { captureSelection(kind: .copy) }
    func cutSelection() { captureSelection(kind: .move) }
    private func captureSelection(kind: TransferKind) {
        if homeResultScope != nil {
            let version = clipboard.pasteboard.changeCount
            performVerifiedHomeCommand { store, entries, _ in
                guard store.clipboard.pasteboard.changeCount == version else { return }
                store.clipboard.capture(entries: entries, kind: kind)
            }
            return
        }
        if activeTab.search != nil {
            // Each result keeps its own sampled parent; writers revalidate at Paste.
            guard let entries = selectedSearchOperationEntries else { return }
            clipboard.capture(entries: entries, kind: kind)
            return
        }
        if let entries = selectedOperationEntries, ItemOperationCapabilities(entries: entries).isArchive {
            prepareArchiveClipboard(entries, kind: kind)
            return
        }
        guard canCopySelection, let identity = activeTab.directoryIdentity else { return }
        clipboard.capture(items: sortedItems.filter { activeTab.selection.selectedIDs.contains($0.id) },
                          source: FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity), kind: kind)
    }

    /// NATIVE-P13 / FR-DROP-001/002/004: capture only committed, identity-backed
    /// rows. Drag authority is independent of the general clipboard.
    func fileDragEntries(itemIDs: Set<String>) -> [TransferEntry]? {
        // MAC-065: dragging search results is outside Phase 14.
        guard !itemIDs.isEmpty, itemIDs.count <= 1_024, activeTab.search == nil,
              activeTab.hasLoaded, !activeTab.isLoading, !activeTab.isRefreshing,
              !activeTab.isUnavailable, activeTab.url.isFileURL,
              tabLoads[activeTabID]?.authorizationEpoch != nil,
              let identity = activeTab.directoryIdentity,
              isCommandIdle, !address.isEditing else { return nil }
        let items = sortedItems.filter { itemIDs.contains($0.id) }
        guard items.count == itemIDs.count, Set(items.map(\.id)) == itemIDs,
              items.allSatisfy({ $0.identity != nil && $0.url.isFileURL }) else { return nil }
        let source = FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity)
        return items.map { TransferEntry(source: source, item: $0) }
    }

    func fileDropBinding(destinationURL: URL,
                         expectedDestinationIdentity: LocalFileIdentity? = nil,
                         expectedEntryIdentity: LocalFileIdentity? = nil,
                         tabID: UUID? = nil) -> FileDropBinding? {
        let targetID = tabID ?? activeTabID
        guard let tab = tabs.first(where: { $0.id == targetID }),
              tab.hasLoaded, !tab.isLoading, !tab.isRefreshing, !tab.isUnavailable,
              tab.url.isFileURL, destinationURL.isFileURL,
              destinationURL.host == nil || destinationURL.host == "" || destinationURL.host?.lowercased() == "localhost",
              destinationURL.query == nil, destinationURL.fragment == nil,
              !destinationURL.path(percentEncoded: false).contains("\0"),
              let identity = tab.directoryIdentity, let generation = tabLoads[targetID]?.authorizationEpoch,
              isCommandIdle, !address.isEditing else { return nil }
        let isDisplayedDestination = destinationURL == tab.url
        // A searching tab presents results, not its folder; never accept into it (MAC-065).
        guard !isDisplayedDestination || tab.search == nil else { return nil }
        guard !isDisplayedDestination || expectedDestinationIdentity == nil || expectedDestinationIdentity == identity else { return nil }
        if let expectedEntryIdentity,
           let row = tab.items.first(where: { $0.url == destinationURL }),
           row.identity != expectedEntryIdentity { return nil }
        return FileDropBinding(receiverActiveTabID: activeTabID, tabID: targetID,
            tabURL: tab.url, tabDirectoryIdentity: identity, loadGeneration: generation,
            destinationURL: destinationURL,
            expectedDestinationIdentity: isDisplayedDestination ? identity : expectedDestinationIdentity,
            expectedEntryIdentity: expectedEntryIdentity)
    }

    func reportHomeDropError(_ error: Error, origin: HomeOperationOrigin) {
        if isHomeOperationPageCurrent(origin) { operationNotice = error.localizedDescription }
    }

    func isCurrentFileDropBinding(_ binding: FileDropBinding) -> Bool {
        guard activeTabID == binding.receiverActiveTabID else { return false }
        if let receiver = binding.homeReceiver {
            guard isCommandIdle, !address.isEditing else { return false }
            switch receiver {
            case .selection(let origin):
                return isHomeOperationOriginCurrent(origin)
            case .folder(let scope, let row, let membership):
                return homeResultMembership(row, in: scope) == membership
                    && activeTab.homeResults.target(of: row)?.identity == binding.expectedEntryIdentity
            case .chosen(let origin):
                return isHomeOperationPageCurrent(origin)
            }
        }
        return fileDropBinding(destinationURL: binding.destinationURL,
            expectedDestinationIdentity: binding.expectedDestinationIdentity,
            expectedEntryIdentity: binding.expectedEntryIdentity, tabID: binding.tabID) == binding
    }

    /// Preparation is read-only and asynchronous; acceptance checks the receiving
    /// snapshot synchronously before reserving the existing transfer writer.
    func acceptPreparedFileDrop(_ prepared: PreparedFileDrop, binding: FileDropBinding) -> Bool {
        guard isCurrentFileDropBinding(binding),
              prepared.destination.directoryURL == binding.destinationURL,
              binding.expectedDestinationIdentity == nil
                || prepared.destination.directoryIdentity == binding.expectedDestinationIdentity,
              !prepared.entries.isEmpty, prepared.entries.count <= 1_024,
              Set(prepared.entries.map { $0.item.id }).count == prepared.entries.count,
              prepared.entries.allSatisfy({ $0.item.identity != nil && $0.item.url.isFileURL }) else { return false }
        do {
            try Self.validateTransferBatch(prepared.entries, destination: prepared.destination, kind: prepared.kind)
        } catch { return false }
        let payload = TransferClipboardPayload(id: UUID(), entries: prepared.entries, kind: prepared.kind)
        let session = TransferSession(id: UUID(), kind: prepared.kind,
            sourceURLs: Array(Set(prepared.entries.map { $0.source.directoryURL })).sorted { $0.path < $1.path },
            destinationURL: prepared.destination.directoryURL, totalItems: prepared.entries.count)
        let selectResults = binding.homeReceiver == nil && binding.tabURL == prepared.destination.directoryURL
            && binding.tabDirectoryIdentity == prepared.destination.directoryIdentity
        let control = beginTransferSession(session)
        transferRuntime?.task = Task { [weak self] in
            guard let self else { return }
            await self.runTransfer(payload: payload, destination: prepared.destination,
                session: session, control: control, tabID: binding.tabID, selectResults: selectResults)
        }
        return true
    }

    func pasteSelection() { beginTransfer(moving: false) }
    func canPaste(toHomeRow row: HomeResultRow) -> Bool {
        guard row.isDirectory else { return canPaste }
        guard isCommandIdle, clipboard.hasTransferCandidate, let scope = homeResultScope else { return false }
        return homeResultMembership(row, in: scope) != nil && !activeTab.homeResults.isKnownSymbolicLink(row)
    }
    func pasteSelection(toHomeRow row: HomeResultRow) {
        guard let origin = homeOperationOrigin else { return }
        beginHomePaste(moving: false, origin: origin, row: row.isDirectory ? row : nil)
    }

    private enum HomePasteTarget {
        case selection(HomeOperationOrigin)
        case chosen(HomeOperationOrigin)
        case row(HomeResultScope, HomeResultRow, UUID, LocalFileIdentity)
    }

    private func isCurrentHomePasteTarget(_ target: HomePasteTarget) -> Bool {
        switch target {
        case .selection(let origin): return isHomeOperationOriginCurrent(origin)
        case .chosen(let origin): return isHomeOperationPageCurrent(origin)
        case .row(let scope, let row, let token, let identity):
            return homeResultMembership(row, in: scope) == token
                && activeTab.homeResults.target(of: row)?.identity == identity
        }
    }

    func homeDestination(for row: HomeResultRow?) -> HomeOperationDestination? {
        guard let row, row.isDirectory else { return homeDestination }
        guard let scope = homeResultScope, homeResultMembership(row, in: scope) != nil,
              !activeTab.homeResults.isKnownSymbolicLink(row),
              let identity = activeTab.homeResults.target(of: row)?.identity else { return .unavailable }
        return .folder(FileOperationContext(directoryURL: row.url, directoryIdentity: identity))
    }

    func verifiedHomeFolder(for row: HomeResultRow, in scope: HomeResultScope,
                            membership: UUID) async throws -> FileOperationContext {
        guard row.isDirectory, homeResultMembership(row, in: scope) == membership else {
            throw FileOperationError.staleParent
        }
        let expected = activeTab.homeResults.target(of: row)?.identity
        let entry = try await LocalDirectoryLoader.operationEntry(at: row.url)
        guard entry.item.isDirectory, !entry.item.isSymbolicLink, let identity = entry.item.identity,
              expected == nil || expected == identity,
              homeResultMembership(row, in: scope) == membership,
              activeTab.homeResults.target(of: row)?.identity.map({ $0 == identity }) != false else {
            throw FileOperationError.staleParent
        }
        bindHomeResultIdentity(identity, for: row, in: scope, membership: membership)
        return FileOperationContext(directoryURL: row.url, directoryIdentity: identity)
    }

    @discardableResult
    func chooseHomeDestination(for origin: HomeOperationOrigin,
                               completion: @escaping @MainActor (FileOperationContext?) -> Void) -> Bool {
        guard isCommandIdle, isHomeOperationPageCurrent(origin), let present = onChooseHomeFolder else {
            completion(nil)
            return false
        }
        let reservation = UUID()
        pendingHomeDestination = reservation
        present { [weak self] url in
            guard let self, self.pendingHomeDestination == reservation else { completion(nil); return }
            self.onCancelHomeFolder = nil
            guard let url, self.isHomeOperationPageCurrent(origin) else {
                self.pendingHomeDestination = nil
                completion(nil)
                return
            }
            Task {
                let directory: FileOperationContext?
                do { directory = try await FileOperationContext.verifiedDirectory(at: url) }
                catch { self.operationNotice = error.localizedDescription; directory = nil }
                guard self.pendingHomeDestination == reservation else { completion(nil); return }
                self.pendingHomeDestination = nil
                completion(self.isHomeOperationPageCurrent(origin) && self.isCommandIdle ? directory : nil)
            }
        }
        return pendingHomeDestination == reservation
    }

    private func cancelHomeDestination() {
        pendingHomeDestination = nil
        homePasteRequest = nil
        let dismiss = onCancelHomeFolder
        onCancelHomeFolder = nil
        dismiss?()
    }

    private func beginHomePaste(moving: Bool, origin: HomeOperationOrigin, row: HomeResultRow?) {
        guard row.map(canPaste(toHomeRow:)) ?? canPaste else { return }
        let count = clipboard.pasteboard.changeCount
        let payloadID = clipboard.payload?.id
        let external: ExternalClipboardSnapshot?
        do { external = payloadID == nil ? try clipboard.externalSnapshot() : nil }
        catch { operationNotice = error.localizedDescription; return }
        let request = UUID()
        homePasteRequest = request
        let scope = homeResultScope
        let membership = row.flatMap { row in scope.flatMap { homeResultMembership(row, in: $0) } }
        func accept(_ folder: FileOperationContext, target: HomePasteTarget) {
            guard homePasteRequest == request else { return }
            homePasteRequest = nil
            guard isCommandIdle, isCurrentHomePasteTarget(target) else {
                operationNotice = FileOperationError.staleParent.localizedDescription
                return
            }
            guard clipboard.pasteboard.changeCount == count, clipboard.payload?.id == payloadID,
                  external.map(clipboard.stillMatches) != false else {
                operationNotice = ExternalClipboardError.changed.localizedDescription
                return
            }
            if clipboard.payload?.hasArchiveOrigin == true {
                beginTypedTransfer(to: .filesystem(folder), moving: moving, home: target)
            } else {
                startPhysicalTransfer(to: folder, moving: moving, home: target)
            }
        }
        Task {
            do {
                if let row {
                    guard let scope, let membership else { throw FileOperationError.staleParent }
                    let folder = try await verifiedHomeFolder(for: row, in: scope, membership: membership)
                    accept(folder, target: .row(scope, row, membership, folder.directoryIdentity))
                    return
                }
                let entries = origin.selectedUniqueCount == 0 ? [] : try await verifiedHomeDestinationEntries(for: origin)
                guard homePasteRequest == request, isHomeOperationOriginCurrent(origin), isCommandIdle else {
                    throw FileOperationError.staleParent
                }
                switch Self.homeDestination(for: entries) {
                case .folder(let folder): accept(folder, target: .selection(origin))
                case .chooseFolder:
                    chooseHomeDestination(for: origin) { folder in
                        guard let folder else {
                            if self.homePasteRequest == request { self.homePasteRequest = nil }
                            return
                        }
                        accept(folder, target: .chosen(origin))
                    }
                case .unavailable: throw FileOperationError.staleParent
                }
            } catch {
                guard homePasteRequest == request else { return }
                homePasteRequest = nil
                operationNotice = error.localizedDescription
            }
        }
    }
    func moveHere() { beginTransfer(moving: true) }
    private func beginTransfer(moving: Bool) {
        if let origin = homeOperationOrigin {
            beginHomePaste(moving: moving, origin: origin, row: nil)
            return
        }
        if let destination = currentOperationContext,
           clipboard.payload?.hasArchiveOrigin == true || ArchiveLocation(url: destination.directoryURL) != nil {
            beginTypedTransfer(to: destination, moving: moving)
            return
        }
        guard canCreateFolder, let identity = activeTab.directoryIdentity else { return }
        startPhysicalTransfer(to: FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity),
                              moving: moving)
    }

    private func startPhysicalTransfer(to destination: FileOperationContext, moving: Bool,
                                       home: HomePasteTarget? = nil) {
        let internalPayload = clipboard.payload
        let external: ExternalClipboardSnapshot?
        let kind = moving ? TransferKind.move : internalPayload?.kind ?? .copy
        do {
            external = internalPayload == nil ? try clipboard.externalSnapshot() : nil
            // Reserve an external move before asynchronous preparation. A failed or
            // cancelled attempt cannot be replayed by this or another app window.
            if kind == .move, let external { try clipboard.claimMove(external) }
        } catch {
            operationNotice = error.localizedDescription
            return
        }
        let sources: [URL]
        let itemCount: Int
        if let internalPayload {
            sources = internalPayload.entries.map { $0.source.directoryURL }
            itemCount = internalPayload.entries.count
        } else if let external {
            // A file reference URL can resolve through path access. Leave source
            // locations to the background importer, including progress presentation.
            sources = []
            itemCount = external.urlStrings.count
        } else { return }
        let session = TransferSession(id: UUID(), kind: kind,
                                      sourceURLs: Array(Set(sources)).sorted { $0.path < $1.path },
                                      destinationURL: destination.directoryURL,
                                      totalItems: itemCount,
                                      isPreparing: external != nil)
        if kind == .move, let internalPayload { clipboard.consume(internalPayload.id) }
        let control = beginTransferSession(session)
        let tabID = activeTabID
        let locationGeneration = tabLoads[tabID]?.authorizationEpoch
        transferRuntime?.task = Task { [weak self] in
            guard let self else { return }
            do {
                let payload: TransferClipboardPayload
                if let external {
                    let entries = try await self.transferImporter.capture(urlStrings: external.urlStrings)
                    try Task.checkCancellation()
                    guard self.transfer?.id == session.id else { return }
                    guard self.clipboard.stillMatches(external) else {
                        throw FileOperationError.unsupported("The clipboard changed while preparing the transfer. Paste again to use its current contents.")
                    }
                    let destinationIsCurrent = if let home {
                        self.isCurrentHomePasteTarget(home)
                    } else {
                        self.tabLoads[tabID]?.authorizationEpoch == locationGeneration
                            && self.activeTab.url == destination.directoryURL
                            && self.activeTab.directoryIdentity == destination.directoryIdentity
                            && self.activeTab.hasLoaded && !self.activeTab.isLoading && !self.activeTab.isUnavailable
                    }
                    guard self.activeTabID == tabID, destinationIsCurrent,
                          self.nameEdit == nil, !self.isShowingRecovery else {
                        throw FileOperationError.staleParent
                    }
                    payload = TransferClipboardPayload(id: external.id, entries: entries, kind: kind)
                } else if let internalPayload { payload = internalPayload }
                else { return }
                guard self.transfer?.id == session.id else { return }
                if let home, !self.isCurrentHomePasteTarget(home) { throw FileOperationError.staleParent }
                try Self.validateTransferBatch(payload.entries, destination: destination, kind: kind)
                try Task.checkCancellation()
                if kind == .move, let external, !self.clipboard.consumeExternalMove(external) {
                    throw ExternalClipboardError.changed
                }
                self.transfer?.sourceURLs = Array(Set(payload.entries.map { $0.source.directoryURL }))
                    .sorted { $0.path < $1.path }
                self.transfer?.isPreparing = false
                await self.runTransfer(payload: payload, destination: destination, session: session,
                                       control: control, tabID: tabID, selectResults: home == nil,
                                       stillCurrent: home.map { target in { self.isCurrentHomePasteTarget(target) } })
            } catch {
                self.finishTransferPreparation(sessionID: session.id, error: error)
            }
        }
    }

    /// Predictable batch incompatibilities must be rejected before the first write.
    /// The writer still revalidates every route and entry against later races.
    private static func validateTransferBatch(_ entries: [TransferEntry], destination: FileOperationContext,
                                              kind: TransferKind) throws {
        guard !entries.isEmpty else { throw FileOperationError.unsupported("The clipboard contains no supported files.") }
        // MAC-066: cross-volume moves are supported; the read-only count refuses a
        // read-only source volume before the first write.
    }

    private func finishTransferPreparation(sessionID: UUID, error: any Error) {
        guard transfer?.id == sessionID else { return }
        let locations = (transfer?.sourceURLs ?? []) + (transfer.map { [$0.destinationURL] } ?? [])
        operationNotice = error is CancellationError ? "Transfer cancelled before any files were changed." : error.localizedDescription
        operationAccessIssue = accessIssue(for: error, locations: locations, action: "Prepare transfer")
        finishTransferSession(sessionID)
    }

    private func runTransfer(payload: TransferClipboardPayload, destination: FileOperationContext,
                             session: TransferSession, control: TransferControl, tabID: UUID,
                             selectResults: Bool = true, stillCurrent: (() -> Bool)? = nil) async {
        // MAC-069: read-only count before the first write. Cancellation or a
        // predictable refusal here changes no files.
        transfer?.isCounting = true
        let totals: TransferTotals?
        do {
            totals = try await transferCounter.count(payload.entries, destination: destination, kind: session.kind)
            try Task.checkCancellation()
            if stillCurrent?() == false { throw FileOperationError.staleParent }
        } catch {
            finishTransferPreparation(sessionID: session.id, error: error)
            return
        }
        guard transfer?.id == session.id else { return }
        transfer?.isCounting = false
        transfer?.totals = totals.flatMap { $0.entries.count == payload.entries.count ? $0 : nil }
        var results: [FileOperationResult] = []
        var failure: String?
        var cancelled = false
        func finishEntry(_ index: Int, result: FileOperationResult?) {
            // MAC-069: a completed item contributes its authoritative work and the
            // counted totals are reconciled to it; a skipped item contributes its
            // counted totals to the percent basis but nothing to measured speed.
            let counted = transfer?.totals?.entries[index]
            if let result {
                let entries = result.transferredEntries ?? counted?.items ?? (transfer?.currentEntries ?? 0)
                let bytes = result.transferredBytes ?? counted?.bytes ?? (transfer?.bytesCopied ?? 0)
                transfer?.processedEntries += entries
                transfer?.processedBytes += bytes
                transfer?.measuredBytes += result.transferredBytes ?? (transfer?.bytesCopied ?? 0)
                if let totals = transfer?.totals, let counted,
                   counted != TransferEntryTotals(items: entries, bytes: bytes) {
                    if entries <= counted.items && bytes <= counted.bytes {
                        // Less work than counted: shrink the basis (progress only advances).
                        var reconciled = totals.entries
                        reconciled[index] = TransferEntryTotals(items: entries, bytes: bytes)
                        transfer?.totals = TransferTotals(entries: reconciled)
                    } else {
                        transfer?.totals = nil
                        transfer?.totalsChanged = true
                    }
                }
            } else if let counted {
                transfer?.processedEntries += counted.items
                transfer?.processedBytes += counted.bytes
            }
            transfer?.bytesCopied = 0
            transfer?.currentEntries = 0
        }
        var retainedOriginals: [(original: FileItem, result: FileOperationResult)] = []
        var movedSources: [TransferEntry] = []
        itemLoop: for (entryIndex, entry) in payload.entries.enumerated() {
            let item = entry.item
            transfer?.currentEntryIndex = entryIndex
            let renamesInPlace = session.kind == .move
                && entry.source.directoryIdentity.device == destination.directoryIdentity.device
                && item.identity?.device == destination.directoryIdentity.device
            if renamesInPlace, transfer?.isPaused == true, transfer?.isCancelling == false {
                // Wait here, never inside the single mutation lane (Phase 7 contract).
                await withCheckedContinuation { transferRuntime?.pauseWaiter = $0 }
            }
            transfer?.currentItemPausable = !renamesInPlace
            var naming = TransferConflictNaming(item: item, mode: .physical)
            var replacing: ReplacementTarget?
            while true {
                let name = naming.name
                if transfer?.isCancelling == true { cancelled = true; break itemLoop }
                transfer?.currentName = name
                transfer?.bytesCopied = 0
                transfer?.currentEntries = 0
                transfer?.phase = .copying
                let progressID = UUID()
                transferRuntime?.progressID = progressID
                do {
                    let result = try await transfers.transfer(item, from: entry.source, to: destination,
                        name: name, kind: session.kind, replacing: replacing, control: control, onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard self?.transfer?.id == session.id,
                                      self?.transferRuntime?.progressID == progressID,
                                      self?.transfer?.conflictName == nil,
                                      let currentBytes = self?.transfer?.bytesCopied,
                                      progress.bytesCopied >= currentBytes else { return }
                                // Separate actor hops can arrive out of order. The
                                // byte counter is cumulative within this attempt.
                                guard let self else { return }
                                self.transfer?.currentName = progress.currentName
                                self.transfer?.bytesCopied = progress.bytesCopied
                                self.transfer?.currentEntries = max(self.transfer?.currentEntries ?? 0, progress.itemsCompleted)
                                // Phases only advance within one item (a late callback cannot regress them).
                                if let phase = self.transfer?.phase, Self.order(progress.phase) > Self.order(phase) {
                                    self.transfer?.phase = progress.phase
                                }
                                // An item larger than counted invalidates the totals immediately.
                                if let session = self.transfer, let totals = session.totals,
                                   totals.entries.indices.contains(session.currentEntryIndex) {
                                    let counted = totals.entries[session.currentEntryIndex]
                                    if progress.bytesCopied > counted.bytes || progress.itemsCompleted > counted.items {
                                        self.transfer?.totals = nil
                                        self.transfer?.totalsChanged = true
                                    }
                                }
                                if let measured = self.transfer?.measuredDoneBytes {
                                    self.transfer?.rate.record(bytes: measured, at: ProcessInfo.processInfo.systemUptime)
                                }
                            }
                        })
                    results.append(result)
                    if session.kind == .move, result.sourceRetention == nil { movedSources.append(entry) }
                    if result.sourceRetention != nil { retainedOriginals.append((entry.item, result)) }
                    if let failure = result.accessFailure {
                        // Access Help points where the failure happened (MAC-067).
                        if result.sourceRetentionCause == .originalNotRemovable, let original = result.accessFailureLocation,
                           original == result.retainedOriginalLocation {
                            operationAccessIssue = FileAccessContext(failure: failure, locations: [original],
                                action: "Remove original after move")
                        } else {
                            operationAccessIssue = FileAccessContext(failure: failure,
                                locations: [result.accessFailureLocation ?? result.url.deletingLastPathComponent()],
                                action: "Verify completed transfer")
                        }
                    }
                    transferRuntime?.progressID = nil
                    transfer?.completedItems = results.count
                    transfer?.phase = .copying
                    if replacing != nil {
                        // MAC-071: the replaced item stays recoverable from Recently Trashed.
                        transfer?.replacedItems += 1
                        if let receipt = result.replacedReceipt { recoveryHistory.record(receipt) }
                    }
                    finishEntry(entryIndex, result: result)
                    break
                } catch FileOperationError.collision {
                    transferRuntime?.progressID = nil
                    if transfer?.isCancelling == true { cancelled = true; break itemLoop }
                    if naming.advanceAfterCollision() { continue }
                    let choice = await presentConflict(name: name, item: item, entry: entry, destination: destination,
                                                       changed: false)
                    switch choice.choice {
                    case .replace:
                        replacing = choice.target
                    case .skip: transfer?.skippedItems += 1; finishEntry(entryIndex, result: nil); continue itemLoop
                    case .keepBoth:
                        replacing = nil
                        do { try naming.keepBoth(sameItem: choice.sameItem) }
                        catch { failure = error.localizedDescription; break itemLoop }
                    case .cancel: cancelled = true; break itemLoop
                    }
                } catch let error as TransferReplacementError {
                    // MAC-073: the existing item changed after comparison; ask again
                    // with freshly read details. Nothing was replaced.
                    transferRuntime?.progressID = nil
                    if transfer?.isCancelling == true { cancelled = true; break itemLoop }
                    replacing = nil
                    let refused: Bool
                    if case .notReplaceable = error { refused = true } else { refused = false }
                    let choice = await presentConflict(name: name, item: item, entry: entry, destination: destination,
                                                       changed: !refused, replaceRefused: refused)
                    switch choice.choice {
                    case .replace: replacing = choice.target
                    case .skip: transfer?.skippedItems += 1; finishEntry(entryIndex, result: nil); continue itemLoop
                    case .keepBoth:
                        do { try naming.keepBoth(sameItem: choice.sameItem) }
                        catch { failure = error.localizedDescription; break itemLoop }
                    case .cancel: cancelled = true; break itemLoop
                    }
                } catch let error as ReplacementRecoveryError {
                    // MAC-072: keep the Trash receipt so the existing item can be restored.
                    transferRuntime?.progressID = nil
                    recoveryHistory.record(error.receipt)
                    failure = error.localizedDescription
                    if let access = error.accessFailure {
                        operationAccessIssue = FileAccessContext(failure: access,
                            locations: [error.receipt.originalContext.directoryURL, error.receipt.trashContext.directoryURL],
                            action: "Restore replaced item")
                    }
                    break itemLoop
                } catch is CancellationError {
                    cancelled = true
                    break itemLoop
                } catch {
                    failure = error.localizedDescription
                    operationAccessIssue = accessIssue(for: error,
                        locations: [entry.source.directoryURL, destination.directoryURL], action: session.kind == .copy ? "Copy" : "Move")
                    break itemLoop
                }
            }
        }
        let skipped = transfer?.skippedItems ?? 0
        cancelled = cancelled || transfer?.isCancelling == true
        let verb = session.kind == .copy ? "Copied" : "Moved"
        var summary = "\(verb) \(results.count - retainedOriginals.count) of \(session.totalItems) selected items."
        if !retainedOriginals.isEmpty {
            // Every kept original is named by its original name, with location and reason (MAC-067).
            summary += retainedOriginals.count == 1
                ? " 1 item was copied but not moved:" : " \(retainedOriginals.count) items were copied but not moved:"
            for kept in retainedOriginals {
                summary += " “\(kept.original.name)”: \(kept.result.sourceRetention ?? "")"
            }
        }
        if skipped > 0 { summary += " Skipped \(skipped)." }
        if let replaced = transfer?.replacedItems, replaced > 0 {
            summary += replaced == 1
                ? " Replaced 1 existing item; the previous version is in the Trash (File ▸ Recently Trashed…)."
                : " Replaced \(replaced) existing items; the previous versions are in the Trash (File ▸ Recently Trashed…)."
        }
        if cancelled { summary += " Cancelled; completed items were retained." }
        if let failure { summary += " Stopped. \(failure)" }
        for warning in results.compactMap(\.warning) { summary += " \(warning)" }
        operationNotice = summary
        if !movedSources.isEmpty { homeSourcesDidLeave(movedSources) }
        if let tab = tabs.first(where: { $0.id == tabID }), BrowserPage(url: tab.url) != nil {
            finishTransferSession(session.id)
            return
        }
        operationResult = selectResults ? (tabID, destination, results) : nil
        finishTransferSession(session.id, disposition: .awaitingResultRefresh)
        // Child/sidebar drops refresh the displayed folder without treating its
        // absence of destination results as a verification failure.
        if !selectResults { isPerformingOperation = false }
        // A failed verification read never repeats a completed transfer.
        if let tab = tabs.first(where: { $0.id == tabID }) {
            load(tabID: tabID, history: tab.history, preserveSelection: true)
        } else {
            operationResult = nil
            isPerformingOperation = false
        }
    }

    /// MAC-070: read the existing item, show both versions and wait for a choice.
    private func presentConflict(name: String, item: FileItem, entry: TransferEntry,
                                 destination: FileOperationContext,
                                 changed: Bool, replaceRefused: Bool = false) async
        -> (choice: TransferConflictChoice, target: ReplacementTarget?, sameItem: Bool) {
        guard let sessionID = transfer?.id, transferRuntime?.id == sessionID else { return (.cancel, nil, false) }
        // A rolled-back attempt may have announced a committed phase; this item
        // is uncommitted again and Cancel must stay available (review 55b3f24a #8).
        transfer?.phase = .copying
        var info = TransferConflictInfo(name: name, incoming: item, incomingLocation: entry.source.directoryURL,
                                        destinationLocation: destination.directoryURL, changedSinceCompared: changed,
                                        replaceRefused: replaceRefused)
        let waiter = ConflictInspectionWaiter()
        transferRuntime?.conflictInspection = waiter
        let inspector = conflictInspector
        let outcome = await waiter.run { try await inspector.inspect(name: name, in: destination) }
        if transferRuntime?.conflictInspection === waiter { transferRuntime?.conflictInspection = nil }
        switch outcome {
        case .success(let entry): info.existing = entry
        case .failure(let error): info.inspectionError = error.localizedDescription
        }
        // Cancel pressed while the existing item was being read.
        if transfer?.isCancelling != false { return (.cancel, nil, false) }
        let choice = await awaitTransferConflict(info, sessionID: sessionID)
        let presented = info
        let sameItem = presented.existing.map { $0.target.identity == item.identity } ?? false
        // Replace is honoured only when it was allowed for the compared versions.
        if choice == .replace {
            guard presented.canReplace, let target = presented.existing?.target else { return (.cancel, nil, sameItem) }
            return (.replace, target, sameItem)
        }
        return (choice, nil, sameItem)
    }

    static func order(_ phase: TransferPhase) -> Int {
        switch phase {
        case .copying: return 0
        case .finalizing: return 1
        case .removingOriginals: return 2
        }
    }

    func pauseTransfer() {
        guard transfer?.canPause == true else { return }
        transferRuntime?.control.pause()
        transfer?.isPaused = true
        transfer?.rate.pause(at: ProcessInfo.processInfo.systemUptime)
    }
    func resumeTransfer() {
        transferRuntime?.control.resume()
        transfer?.isPaused = false
        transfer?.rate.resume(at: ProcessInfo.processInfo.systemUptime)
        releasePauseWaiter()
    }
    private func releasePauseWaiter() {
        let waiter = transferRuntime?.pauseWaiter
        transferRuntime?.pauseWaiter = nil
        waiter?.resume()
    }
    func cancelTransfer() {
        guard let session = transfer else { return }
        if session.isPreparing || session.isCounting {
            transferRuntime?.task?.cancel()
            finishTransferPreparation(sessionID: session.id, error: CancellationError())
            return
        }
        // Removal of originals after publication is not cancellable (MAC-068).
        guard session.canCancel else { return }
        transfer?.isCancelling = true
        transfer?.isPaused = false
        transferRuntime?.control.cancel()
        releasePauseWaiter()
        transferRuntime?.conflictInspection?.abandon()
        resolveTransferConflict(.cancel)
    }
    func resolveTransferConflict(_ choice: TransferConflictChoice) {
        guard let reply = transferRuntime?.conflictReply else { return }
        // MAC-071: Replace is ignored unless the compared versions allow it.
        if choice == .replace, transfer?.conflict?.canReplace != true { return }
        transferRuntime?.conflictReply = nil
        if choice == .cancel { transferRuntime?.control.cancel(); transfer?.isCancelling = true }
        reply.resume(returning: choice)
    }
    private func appendOperationNotice(_ text: String) {
        operationNotice = [operationNotice, text].compactMap { $0 }.joined(separator: " ")
    }

    // FR-FILE-005/007/011: typed, session-only recovery; no global Trash scan.
    var canTrashSelection: Bool { homeResultScope != nil ? canAttemptHomeOperation : canCopySelection && hasPhysicalSelection }
    var canShowRecovery: Bool { !activeTab.isLoading && isCommandIdle }
    var canUndoRename: Bool { canShowRecovery && renameRecovery?.isUndone == false }
    var canRedoRename: Bool { canShowRecovery && renameRecovery?.isUndone == true }

    func showRecovery() {
        guard canShowRecovery else { return }
        address.cancel()
        recoveryError = nil
        recoveryAccessIssue = nil
        isShowingRecovery = true
    }

    func dismissRecovery() {
        guard !isPerformingOperation else { return }
        isShowingRecovery = false
        recoveryError = nil
        recoveryAccessIssue = nil
        scheduleObservedRefresh()
    }

    func canRestore(_ id: UUID) -> Bool {
        isShowingRecovery && !activeTab.isLoading && !isPerformingOperation && !recoveryHistory.claimedIDs.contains(id)
            && recoveryHistory.entries.contains { $0.id == id }
    }

    /// MAC-079: Shift+Delete (Windows permanent delete) never deletes; with a
    /// trashable selection it explains the available route instead.
    func notePermanentDeleteUnavailable() {
        if let entries = selectedOperationEntries, ItemOperationCapabilities(entries: entries).isArchive {
            deleteSelection(); return
        }
        guard canTrashSelection else { return }
        operationNotice = "Permanent deletion isn’t available. Press Delete or ⌘⌫ to move the selection to the Trash."
    }

    func trashSelection() {
        guard canTrashSelection else { return }
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, origin in
                store.trashTargets(entries.map { ($0.item, $0.source) }, searchID: nil, homeOrigin: origin)
            }
            return
        }
        let targets: [(item: FileItem, context: FileOperationContext)]
        let searchID = activeTab.search?.id
        if searchID != nil {
            guard let entries = selectedSearchOperationEntries else { return }
            targets = entries.map { ($0.item, $0.source) }
        } else {
            guard let identity = activeTab.directoryIdentity else { return }
            let context = FileOperationContext(directoryURL: activeTab.url, directoryIdentity: identity)
            targets = sortedItems.filter { activeTab.selection.selectedIDs.contains($0.id) }.map { ($0, context) }
        }
        trashTargets(targets, searchID: searchID, homeOrigin: nil)
    }

    private func trashTargets(_ targets: [(item: FileItem, context: FileOperationContext)],
                              searchID: UUID?, homeOrigin: HomeOperationOrigin?) {
        deferBackgroundRefresh()
        let items = targets.map(\.item)
        let tabID = activeTabID
        renameRecovery = nil
        operationNotice = nil
        operationAccessIssue = nil
        trashProgress = TrashProgress(totalItems: items.count)
        address.cancel()
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            var cancelled = false
            var outcomeUncertain = false
            var departed: [TransferEntry] = []
            var messages: [String] = []
            for (item, context) in targets {
                if Task.isCancelled || self.trashProgress?.isCancelling == true { cancelled = true; break }
                self.trashProgress?.currentName = item.name
                do {
                    let result = try await self.recovery.trash(item, in: context)
                    // Native success remains committed even if cancellation arrived
                    // during that call, or its returned receipt could not be verified.
                    completed += 1
                    if homeOrigin != nil { departed.append(TransferEntry(source: context, item: item)) }
                    if let receipt = result.receipt { self.recoveryHistory.record(receipt) }
                    if let warning = result.warning { messages.append(warning) }
                    if let failure = result.accessFailure {
                        self.operationAccessIssue = FileAccessContext(failure: failure,
                            locations: [context.directoryURL], action: "Verify completed Trash operation")
                    }
                    self.trashProgress?.completedItems = completed
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    if case FileRecoveryError.outcomeUncertain = error { outcomeUncertain = true }
                    self.operationAccessIssue = self.accessIssue(for: error,
                        locations: [context.directoryURL], action: "Move to Trash")
                    messages.append("Stopped. \(error.localizedDescription)")
                    break
                }
            }
            cancelled = cancelled || Task.isCancelled || self.trashProgress?.isCancelling == true
            self.operationNotice = outcomeUncertain
                ? "Confirmed \(completed) of \(items.count) selected items moved to Trash."
                : "Moved \(completed) of \(items.count) selected items to Trash."
            if cancelled { self.appendOperationNotice("Cancelled; completed items remain in Trash.") }
            for message in messages { self.appendOperationNotice(message) }
            self.trashProgress = nil
            if homeOrigin != nil {
                self.operationTask = nil
                self.isPerformingOperation = false
                self.homeSourcesDidLeave(departed)
            } else if let searchID {
                self.finishSearchTrash(tabID: tabID, searchID: searchID)
            } else if let context = targets.first?.context {
                self.finishRecoveryWrite(tabID: tabID, context: context, results: [])
            }
        }
    }

    func cancelTrash() {
        guard trashProgress != nil else { return }
        trashProgress?.isCancelling = true
        operationTask?.cancel()
    }

    func restore(_ id: UUID, as name: String) {
        guard canRestore(id), let receipt = recoveryHistory.claim(id) else { return }
        deferBackgroundRefresh()
        let tabID = activeTabID
        renameRecovery = nil
        recoveryError = nil
        recoveryAccessIssue = nil
        operationNotice = nil
        operationAccessIssue = nil
        address.cancel()
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.recovery.restore(receipt, as: name)
                // Never retain a retryable receipt after the move committed.
                self.recoveryHistory.remove(id)
                self.isShowingRecovery = false
                self.operationNotice = "Restored “\(name)”."
                if let warning = result.warning { self.appendOperationNotice(warning) }
                if let failure = result.accessFailure {
                    self.operationAccessIssue = FileAccessContext(failure: failure,
                        locations: [result.url.deletingLastPathComponent()], action: "Verify completed change")
                }
                self.finishRecoveryWrite(tabID: tabID, context: receipt.originalContext, results: [result])
            } catch {
                self.recoveryHistory.release(id)
                self.recoveryError = error.localizedDescription
                self.recoveryAccessIssue = self.accessIssue(for: error,
                    locations: [receipt.originalContext.directoryURL], action: "Restore")
                self.operationTask = nil
                self.isPerformingOperation = false
                self.scheduleObservedRefresh()
            }
        }
    }

    func undoRename() { performRenameRecovery(undo: true) }
    func redoRename() { performRenameRecovery(undo: false) }

    private func performRenameRecovery(undo: Bool) {
        guard undo ? canUndoRename : canRedoRename, var record = renameRecovery else { return }
        deferBackgroundRefresh()
        let tabID = activeTabID
        let name = undo ? record.originalName : record.renamedName
        let action = undo ? "Undo Rename" : "Redo Rename"
        operationNotice = nil
        operationAccessIssue = nil
        address.cancel()
        isPerformingOperation = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.operations.rename(record.currentItem, to: name, in: record.context)
                self.renameRecovery = record.record(result, undone: undo) ? record : nil
                self.operationNotice = "\(action) completed."
                if let warning = result.warning { self.appendOperationNotice(warning) }
                if let failure = result.accessFailure {
                    self.operationAccessIssue = FileAccessContext(failure: failure,
                        locations: [result.url.deletingLastPathComponent()], action: "Verify completed change")
                }
                self.finishRecoveryWrite(tabID: tabID, context: record.context, results: [result])
            } catch {
                self.operationNotice = "\(action) failed. \(error.localizedDescription)"
                self.operationAccessIssue = self.accessIssue(for: error,
                    locations: [record.context.directoryURL], action: action)
                self.operationTask = nil
                self.isPerformingOperation = false
                self.scheduleObservedRefresh()
            }
        }
    }

    private func finishRecoveryWrite(tabID: UUID, context: FileOperationContext, results: [FileOperationResult]) {
        operationTask = nil
        if let tab = tabs.first(where: { $0.id == tabID }), BrowserPage(url: tab.url) != nil {
            operationResult = nil
            isPerformingOperation = false
            return
        }
        operationResult = (tabID, context, results)
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            operationResult = nil
            isPerformingOperation = false
            return
        }
        var history = tab.history
        history.navigate(to: context.directoryURL)
        // A failed refresh leaves a reload-only Retry; it cannot repeat a write.
        load(tabID: tabID, history: history, preserveSelection: true, endsSearch: true)
    }

    private func prepareForNavigation() -> Bool {
        guard finderTagEditor == nil, shortcutDraft == nil, !isPerformingOperation, !isShowingRecovery else { return false }
        if pendingHomeDestination != nil { cancelHomeDestination() }
        cancelRecentOpen()
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        // MAC-076: a navigation request ends a second-click candidate at once,
        // not only when the new location commits (review of the P18A tests).
        pointerRename.cancel()
        // A newer navigation supersedes a result activation still revalidating.
        cancelSearchActivation()
        address.cancel()
        cancelNameEdit()
        return true
    }

    func navigate(to url: URL) { navigate(to: url, reveal: nil) }

    private func isDocumentsFavorite(key: String?, url: URL) -> Bool {
        key == "favorite:Documents"
            && url.standardizedFileURL == homeURL.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
    }

    /// Only the built-in favorite opts into verified redirection. A personal pin
    /// with the same URL and every other navigation entry retain lexical paths.
    func activateSidebarItem(key: String, url: URL, newTab: Bool = false) {
        let favorite = isDocumentsFavorite(key: key, url: url)
        if newTab { openTab(at: url, documentsFavorite: favorite) }
        else {
            navigate(to: url, reveal: nil, documentsFavorite: favorite,
                     clearsDocumentsFavoriteAssociation: !favorite)
        }
    }

    var selectedSidebarFavoriteKey: String? {
        let tab = activeTab
        guard tab.hasLoaded, !tab.isUnavailable, tab.search == nil,
              let association = tab.documentsFavoriteAssociation,
              association.sourceURL.standardizedFileURL == homeURL.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL,
              association.destinationURL == tab.url,
              association.directoryIdentity == tab.directoryIdentity else { return nil }
        return "favorite:Documents"
    }

    /// MAC-082: whether an external open request may navigate this window now. A
    /// window busy with an operation, Recently Trashed or a name draft is left alone
    /// (the request opens in a new window instead), so no draft is discarded.
    var canAcceptOpenRequest: Bool { isCommandIdle }

    /// MAC-083: the tab already showing `folder` (by its path, or the request's
    /// link-resolved path), preferring the active tab. Search tabs show results, not
    /// the folder, and are never reused.
    func tabShowing(_ folder: URL, alternatePaths: [String] = [], folderIdentity: LocalFileIdentity? = nil) -> BrowserTab? {
        guard BrowsingLocation(url: folder)?.physicalURL != nil else { return nil }
        let paths = Set([folder.standardizedFileURL.path] + alternatePaths)
        let candidates = tabs.filter { tab in
            guard tab.search == nil, BrowsingLocation(url: tab.url)?.physicalURL != nil else { return false }
            if paths.contains(tab.url.standardizedFileURL.path) { return true }
            // The same directory reached through another spelling or a link (MAC-083).
            return folderIdentity != nil && tab.directoryIdentity == folderIdentity
        }
        return candidates.first { $0.id == activeTabID } ?? candidates.first
    }

    /// MAC-083: shows a request in a tab that already shows its folder instead of
    /// adding a tab: activates it and selects `items` (re-spelled in the tab's own
    /// path so they match its listing). Returns false, changing nothing, when no tab
    /// shows the folder or this window is busy.
    @discardableResult
    func showInExistingTab(_ folder: URL, revealing items: [URL], identities: [String: LocalFileIdentity] = [:],
                           alternatePaths: [String] = [], folderIdentity: LocalFileIdentity? = nil) -> Bool {
        guard canAcceptOpenRequest,
              let tab = tabShowing(folder, alternatePaths: alternatePaths, folderIdentity: folderIdentity) else { return false }
        if tab.id != activeTabID { activateTab(tab.id) }
        guard activeTabID == tab.id else { return false }
        // A tab matched by one of the request's own spellings keeps its spelling. A tab
        // matched only by its cached folder identity navigates to the requested
        // spelling instead: if the tab's link was retargeted since it loaded, its own
        // path could now name another folder (review dfdb1ba9 finding 4).
        let paths = Set([folder.standardizedFileURL.path] + alternatePaths)
        let base = paths.contains(tab.url.standardizedFileURL.path) ? tab.url : folder.standardizedFileURL
        // Always issue this tab's own navigation, so the request supersedes any
        // navigation still pending in the reused tab (review e73b0f67 finding 1).
        guard !items.isEmpty else { navigate(to: base); return true }
        var respelled: [URL] = [], keyed: [String: LocalFileIdentity] = [:]
        for item in items {
            let url = base.appendingPathComponent(item.lastPathComponent)
            respelled.append(url)
            if let identity = identities[item.standardizedFileURL.path] { keyed[url.path] = identity }
        }
        reveal(respelled, in: base, identities: keyed)
        return true
    }

    /// MAC-082: show `items` (which share `folder`) selected in the active tab.
    func reveal(_ items: [URL], in folder: URL, identities: [String: LocalFileIdentity] = [:]) {
        navigate(to: folder, reveal: items.isEmpty ? nil : .requested(items, identities: identities))
    }

    /// Views may consume only a verified request belonging to their active tab.
    var pendingRevealVisibility: RevealVisibilityRequest? {
        guard isCommandIdle, let request = activeTab.revealVisibilityRequest,
              request.matches(activeTab) else { return nil }
        return request
    }

    @discardableResult
    func acknowledgeRevealVisibility(_ request: RevealVisibilityRequest) -> Bool {
        guard let index = activeIndex, pendingRevealVisibility == request else { return false }
        tabs[index].revealVisibilityRequest = nil
        return true
    }

    private func cancelRevealVisibility() {
        guard let index = activeIndex, tabs[index].revealVisibilityRequest != nil else { return }
        tabs[index].revealVisibilityRequest = nil
    }

    private func invalidateRevealVisibility(at index: Int) {
        guard let request = tabs[index].revealVisibilityRequest, !request.matches(tabs[index]) else { return }
        tabs[index].revealVisibilityRequest = nil
    }

    /// MAC-082: a new tab at `folder`, selecting `items` once its read commits.
    /// Returns false (nothing changed) when navigation is not possible now.
    @discardableResult
    func openTab(at folder: URL, revealing items: [URL], identities: [String: LocalFileIdentity] = [:]) -> Bool {
        guard canAcceptOpenRequest, folder.isFileURL, prepareForNavigation() else { return false }
        let tab = BrowserTab(url: folder.standardizedFileURL)
        prepareViewReplacement(to: tab.viewMode)
        tabs.append(tab)
        stopObservation()
        activeTabID = tab.id
        load(tabID: tab.id, history: tab.history, preserveSelection: false,
             reveal: items.isEmpty ? nil : .requested(items, identities: identities), grantsSidebarAccess: true)
        return true
    }

    /// MAC-062: navigation ends search only when its folder read commits.
    func navigateBreadcrumb(to url: URL) { navigate(to: url, reveal: nil, selectionIntent: .ancestor) }

    private func navigate(to url: URL, reveal: ItemReveal?, selectionIntent: NavigationSelectionIntent = .ordinary,
                          documentsFavorite: Bool = false, clearsDocumentsFavoriteAssociation: Bool = false) {
        guard prepareForNavigation() else { return }
        guard let location = BrowsingLocation(url: url) else { setError("Enter a local folder or a supported ZIP location."); return }
        cancelRevealVisibility()
        var history = activeTab.history
        history.navigate(to: location.url)
        load(tabID: activeTabID, history: history, preserveSelection: false, endsSearch: true, reveal: reveal,
             selectionIntent: selectionIntent, grantsSidebarAccess: true, documentsFavorite: documentsFavorite,
             clearsDocumentsFavoriteAssociation: clearsDocumentsFavoriteAssociation)
    }

    /// While searching, Back returns to the original folder (MAC-062).
    var canGoBack: Bool { activeTab.search != nil || activeTab.history.canGoBack }

    // FR-NAV-002/003/004, EV-0290: commit the history only once the target can be read.
    func back() {
        guard prepareForNavigation() else { return }
        if activeTab.search != nil { closeSearch(); return }
        var history = activeTab.history
        guard history.goBack() != nil else { return }
        cancelRevealVisibility()
        load(tabID: activeTabID, history: history, preserveSelection: false, endsSearch: true,
             selectionIntent: .history, grantsSidebarAccess: true)
    }
    func forward() {
        guard prepareForNavigation() else { return }
        var history = activeTab.history
        guard history.goForward() != nil else { return }
        cancelRevealVisibility()
        load(tabID: activeTabID, history: history, preserveSelection: false, endsSearch: true,
             selectionIntent: .history, grantsSidebarAccess: true)
    }
    func up() { if let parent = activeTab.history.parent { navigate(to: parent, reveal: nil, selectionIntent: .ancestor) } }
    /// In search, Refresh re-runs the search; results are not live (MAC-064).
    func refresh() { refresh(grantingSidebarAccess: true) }

    private func refresh(grantingSidebarAccess: Bool) {
        guard shortcutDraft == nil, nameEdit == nil, !isPerformingOperation else { return }
        if grantingSidebarAccess {
            if activeTab.search != nil { OneDriveBadgeCache.shared.hintVisibleSearch(in: cloudStatusOwner) }
            else if activePage == nil { OneDriveBadgeCache.shared.hint(folder: activeTab.url, reason: .explicitRefresh) }
        }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        if grantingSidebarAccess { ownedSidebarModel?.invalidateVisiblePresence() }
        preview.show(nil)
        deferredPreviewLoads.removeValue(forKey: activeTabID)
        let pending = pendingLoad(for: activeTabID)
        // A pending folder-maintenance read (observation, activation, abandoned
        // exit) does not outrank search: Refresh restarts the search run, which
        // also invalidates a revalidating activation. Only a genuine pending
        // navigation is restarted instead (MAC-064/065).
        let isPendingNavigation = pending.map { $0.endsSearch && !$0.automatic } ?? false
        if activeTab.search != nil, !isPendingNavigation {
            guard !isShowingRecovery else { return }
            runSearch(tabID: activeTabID)
            return
        }
        if var request = pending ?? uncommittedFavoriteFailure(for: activeTabID) {
            request.automatic = false
            request.grantsSidebarAccess = request.grantsSidebarAccess || grantingSidebarAccess
            load(tabID: activeTabID, request: request)
        } else {
            load(tabID: activeTabID, history: activeTab.history, preserveSelection: true,
                 grantsSidebarAccess: grantingSidebarAccess)
        }
    }
    /// Page collections already receive live updates from their data sources.
    /// Returning to the window must not restart a tag query or cancel a row action.
    func refreshAfterActivation() {
        guard activePage == nil, shortcutDraft == nil, nameEdit == nil,
              !isPerformingOperation, pendingLoad(for: activeTabID) == nil else { return }
        OneDriveBadgeCache.shared.hint(folder: activeTab.url, reason: .activation)
        load(tabID: activeTabID, history: activeTab.history, preserveSelection: true, automatic: true)
    }
    private func reloadPreservingIntent(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if let pending = pendingLoad(for: tabID) {
            load(tabID: tabID, request: pending)
        } else {
            load(tabID: tabID, history: tab.history, preserveSelection: true, automatic: true)
        }
    }
    /// Until a favorite's first successful commit, its alias is only an intent,
    /// not a location that folder maintenance may list. Explicit Refresh retries
    /// that intent; passive loads leave the existing failure and Retry intact.
    private func uncommittedFavoriteFailure(for tabID: UUID) -> PendingLoad? {
        guard let tab = tabs.first(where: { $0.id == tabID }), !tab.hasLoaded,
              let failed = failedLoads[tabID], failed.documentsFavorite else { return nil }
        return failed
    }
    func retry() {
        guard prepareForNavigation() else { return }
        guard var failed = failedLoads[activeTabID] else { refresh(); return }
        cancelRevealVisibility()
        failed.grantsSidebarAccess = true
        load(tabID: activeTabID, request: failed)
    }
    func toggleHidden() {
        guard prepareForNavigation() else { return }
        showHidden.toggle()
        ownedSidebarModel?.setShowHidden(showHidden)
        // Every tab must use the same visibility setting, including background tabs.
        for id in tabs.map(\.id) {
            reloadPreservingIntent(id)
            if tabs.first(where: { $0.id == id })?.search != nil { runSearch(tabID: id) }
        }
    }

    func addTab() { openTab(at: BrowserPage.home.url) }
    func openTab(at url: URL) {
        openTab(at: url, documentsFavorite: false)
    }
    private func openTab(at url: URL, documentsFavorite: Bool) {
        guard prepareForNavigation() else { return }
        guard let location = BrowsingLocation(url: url) else { return }
        let tab = BrowserTab(url: location.url)
        prepareViewReplacement(to: tab.viewMode)
        tabs.append(tab)
        stopObservation()
        activeTabID = tab.id
        if documentsFavorite {
            load(tabID: tab.id, history: tab.history, preserveSelection: false,
                 grantsSidebarAccess: true, documentsFavorite: true)
        } else { refresh() }
    }

    /// FR-TAB-007 / EV-0379 / AT-TAB-007 proves the location only.
    /// Native policy: duplicate starts fresh history/selection with the source sort/layout.
    func duplicateTab(_ id: UUID) {
        guard prepareForNavigation() else { return }
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        var duplicate = BrowserTab(url: source.url)
        duplicate.homeSection = source.homeSection
        duplicate.homeTag = source.homeTag
        duplicate.pageFilter = source.pageFilter
        duplicate.sort = source.sort
        duplicate.viewMode = source.viewMode
        prepareViewReplacement(to: duplicate.viewMode)
        let index = tabs.firstIndex(where: { $0.id == id })! + 1
        tabs.insert(duplicate, at: index)
        stopObservation()
        activeTabID = duplicate.id
        refresh(grantingSidebarAccess: false)
    }
    func closeOtherTabs(_ id: UUID) {
        guard prepareForNavigation() else { return }
        guard tabs.contains(where: { $0.id == id }) else { return }
        for other in tabs.map(\.id) where other != id { closeTab(other) }
        activateTab(id)
    }
    func closeTabsToRight(_ id: UUID) {
        guard prepareForNavigation() else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for other in tabs.dropFirst(index + 1).map(\.id) { closeTab(other) }
    }
    func canDetachTab(_ id: UUID) -> Bool { !isPerformingOperation && tabs.count > 1 && tabs.contains(where: { $0.id == id }) }
    /// FR-TAB-008 / EV-0386 / AT-TAB-008: move the committed tab state to its own window.
    /// Pending reads are invalidated; the receiving store re-reads the committed location.
    func detachTab(_ id: UUID, at point: NSPoint? = nil) {
        guard prepareForNavigation() else { return }
        guard canDetachTab(id), let onDetachTab, var tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isLoading = false
        tab.isRefreshing = false
        tab.revealVisibilityRequest = nil
        // MAC-062: search state and its running traversal stay with this window.
        tab.search = nil
        closeTab(id)
        onDetachTab(tab, point)
    }
    func closeTab(_ id: UUID) {
        guard prepareForNavigation() else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { onLastTabClosed?(); return }
        contentBarriers.removeValue(forKey: id)
        retentionPreviewBarriers.removeValue(forKey: id)
        contentIntentIDs.removeValue(forKey: id)
        tabLoads.removeValue(forKey: id)?.work?.task?.cancel()
        deferredPreviewLoads.removeValue(forKey: id)
        previewMetadataTasks.removeValue(forKey: id)?.cancel()
        previewMetadataTokens.removeValue(forKey: id)
        searchTasks.removeValue(forKey: id)?.cancel()
        failedLoads.removeValue(forKey: id)
        if activeTabID == id {
            let replacement = tabs[index + 1 < tabs.count ? index + 1 : index - 1]
            prepareViewReplacement(to: replacement.viewMode)
            stopObservation()
        }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
            if observer != nil { reloadPreservingIntent(activeTabID) }
        }
    }
    func activateTab(_ id: UUID) {
        guard prepareForNavigation() else { return }
        guard let target = tabs.first(where: { $0.id == id }), activeTabID != id else { return }
        prepareViewReplacement(to: target.viewMode)
        stopObservation()
        activeTabID = id
        if observer != nil { reloadPreservingIntent(id) }
    }
    func cycleTab(backwards: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activateTab(tabs[(index + (backwards ? tabs.count - 1 : 1)) % tabs.count].id)
    }
    func setSelection(_ ids: Set<String>, focusedID: String?, anchorID: String? = nil) {
        guard shortcutDraft == nil, nameEdit == nil, !isPerformingOperation, let index = activeIndex else { return }
        let validIDs = Set((tabs[index].search?.displayedItems ?? tabs[index].items).map(\.id))
        var proposed = currentSelection
        proposed.selectedIDs = ids.intersection(validIDs)
        proposed.focusedID = focusedID.flatMap { validIDs.contains($0) ? $0 : nil }
        if ids.isEmpty && focusedID == nil { proposed.anchorID = nil }
        else if let anchorID, validIDs.contains(anchorID) { proposed.anchorID = anchorID }
        else if proposed.anchorID == nil { proposed.anchorID = focusedID }
        if proposed != currentSelection { invalidateCloudCommandForNewIntent(clearBarrier: true, selectionChanged: true) }
        if var search = tabs[index].search {
            let valid = Set(search.displayedItems.map(\.id))
            search.selection.selectedIDs = ids.intersection(valid)
            search.selection.focusedID = focusedID.flatMap { valid.contains($0) ? $0 : nil }
            if ids.isEmpty && focusedID == nil { search.selection.anchorID = nil }
            else if let anchorID, valid.contains(anchorID) { search.selection.anchorID = anchorID }
            else if search.selection.anchorID == nil { search.selection.anchorID = focusedID }
            tabs[index].search = search
            return
        }
        guard !tabs[index].isUnavailable else { return }
        let valid = Set(tabs[index].items.map(\.id))
        tabs[index].selection.selectedIDs = ids.intersection(valid)
        tabs[index].selection.focusedID = focusedID.flatMap { valid.contains($0) ? $0 : nil }
        if ids.isEmpty && focusedID == nil { tabs[index].selection.anchorID = nil }
        else if let anchorID, valid.contains(anchorID) { tabs[index].selection.anchorID = anchorID }
        else if tabs[index].selection.anchorID == nil { tabs[index].selection.anchorID = focusedID }
        invalidateRevealVisibility(at: index)
    }
    func sort(by key: SortKey) {
        guard canSortItems, let index = activeIndex else { return }
        let old = tabs[index].sort
        tabs[index].sort = FileSort(key: key, ascending: old.key == key ? !old.ascending : true)
        tabs[index].search?.resort(tabs[index].sort)
    }
    func setSortAscending(_ ascending: Bool) {
        guard canSortItems, let index = activeIndex else { return }
        tabs[index].sort = FileSort(key: tabs[index].sort.key, ascending: ascending)
        tabs[index].search?.resort(tabs[index].sort)
    }
    func dismissError() {
        if let index = activeIndex {
            tabs[index].errorMessage = nil
            tabs[index].accessIssue = nil
        }
    }
    func activate(_ item: FileItem) {
        guard activePage == nil, shortcutDraft == nil, nameEdit == nil, !isPerformingOperation else { return }
        if let search = activeTab.search {
            if let result = search.result(id: item.id) { openSearchResult(result, revealingParent: false) }
            return
        }
        guard !activeTab.isUnavailable else { return }
        if ArchiveLocation(url: item.url) != nil, !listsEntry(item) {
            operationNotice = Self.changedNotice([item.name]); return
        }
        let target = FileActivationTarget(item)
        if let url = target.browsingURL { navigate(to: url) }
        else if case .virtualFile = target { openArchiveSelection([item]) }
        else if case .ordinaryFile(let url) = target {
            address.cancelPendingSubmission()
            guard item.identity != nil, item.isRegularFile != nil || item.isSymbolicLink else {
                openPhysicalFile(url, captured: nil)
                return
            }
            let origin = routingOrigin, epoch = contextMenuLoadGeneration
            address.resolveSubmission(url, using: { await RecentDocument.sample($0) }) { [weak self] result in
                guard let self, self.routingOrigin == origin, self.contextMenuLoadGeneration == epoch,
                      self.isCommandIdle, self.listsEntry(item), case .success(let captured) = result else { return }
                if !item.isSymbolicLink, let captured, captured.identity != item.identity {
                    self.operationNotice = Self.changedNotice([item.name])
                    return
                }
                self.openPhysicalFile(url, captured: captured)
            }
        } else { operationNotice = "Opening files inside ZIP archives isn’t available." }
    }
    func chooseFolder() {
        guard prepareForNavigation() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = physicalFolderURL ?? ArchiveLocation(url: activeTab.url)?.archiveURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { navigate(to: url) }
    }
    func cancelLoads() {
        homeFileOperations.preparation?.cancel()
        homeFileOperations.command?.cancel()
        cancelHomeDestination()
        cancelFinderTagEditing()
        cancelRecentOpen()
        invalidateCloudCommandForNewIntent()
        contentBarriers.removeAll(); retentionPreviewBarriers.removeAll(); contentIntentIDs.removeAll()
        if shortcutDraft != nil {
            shortcutValidation?.cancel()
            shortcutValidation = nil
            if isPerformingOperation {
                operationTask?.cancel()
                operationTask = nil
                isPerformingOperation = false
            }
            shortcutDraft = nil
        }
        setPreviewSurfaceVisible(false)
        deferredPreviewLoads.removeAll()
        previewMetadataTasks.values.forEach { $0.cancel() }
        previewMetadataTasks.removeAll()
        previewMetadataTokens.removeAll()
        sidebarSettingsSubscription?.cancel()
        sidebarSettingsSubscription = nil
        tagShortcutChanges?.cancel()
        tagShortcutChanges = nil
        ownedSidebarModel?.cancelLoads()
        if transfer?.isPreparing == true { cancelTransfer() }
        address.cancel()
        cancelNameEdit()
        stopObservation()
        tabLoads.values.forEach { $0.work?.task?.cancel() }
        tabLoads.removeAll()
        searchTasks.values.forEach { $0.cancel() }
        searchTasks.removeAll()
        cancelSearchActivation()
        for index in tabs.indices where tabs[index].search?.isRunning == true {
            tabs[index].search?.generation = UUID()
            tabs[index].search?.phase = .cancelled
        }
        failedLoads.removeAll()
        for index in tabs.indices {
            tabs[index].isLoading = false; tabs[index].isRefreshing = false
            tabs[index].revealVisibilityRequest = nil
        }
    }

    /// A draft or mutation takes ownership of the current snapshot. A late background
    /// result must not change its rows or consume its postcommit reconciliation.
    private func deferBackgroundRefresh() {
        guard let index = activeIndex, tabs[index].isRefreshing else { return }
        tabLoads[activeTabID]?.work?.task?.cancel()
        tabLoads[activeTabID]?.work = nil
        tabs[index].isRefreshing = false
        observationDirty = true
    }

    private func pendingLoad(for tabID: UUID) -> PendingLoad? {
        guard let work = tabLoads[tabID]?.work, case .directory(let request) = work.request else { return nil }
        return request
    }

    private func startLoadWork(tabID: UUID, request: ActiveLoad.Request) -> UUID {
        if let oldWork = tabLoads[tabID]?.work, case .directory(let pending) = oldWork.request,
           let handoff = pending.cloudHandoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
        tabLoads[tabID]?.work?.task?.cancel()
        let work = ActiveLoad(request: request)
        tabLoads[tabID] = TabLoadState(work: work)
        return work.token
    }

    private func isCurrentLoadWork(tabID: UUID, token: UUID) -> Bool {
        tabLoads[tabID]?.work?.token == token
    }

    private func finishLoadWork(tabID: UUID, token: UUID) {
        guard isCurrentLoadWork(tabID: tabID, token: token) else { return }
        tabLoads[tabID]?.work = nil
    }

    private var activeIndex: Int? { tabs.firstIndex(where: { $0.id == activeTabID }) }
    private func setError(_ message: String) {
        if let index = activeIndex {
            tabs[index].errorMessage = message
            tabs[index].accessIssue = nil
        }
    }
    private func load(tabID: UUID, history: NavigationHistory, preserveSelection: Bool,
                      automatic: Bool = false, addressEntry: URL? = nil,
                      endsSearch: Bool = false, reveal: ItemReveal? = nil,
                      selectionIntent: NavigationSelectionIntent = .ordinary,
                      grantsSidebarAccess: Bool = false, documentsFavorite: Bool = false,
                      clearsDocumentsFavoriteAssociation: Bool = false) {
        load(tabID: tabID, request: PendingLoad(history: history, preserveSelection: preserveSelection,
            automatic: automatic, addressEntry: addressEntry, endsSearch: endsSearch,
            reveal: reveal, selectionIntent: selectionIntent, grantsSidebarAccess: grantsSidebarAccess,
            documentsFavorite: documentsFavorite, clearsDocumentsFavoriteAssociation: clearsDocumentsFavoriteAssociation))
    }

    private func load(tabID: UUID, request: PendingLoad) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            if let handoff = request.cloudHandoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            return
        }
        if let page = BrowserPage(url: request.history.current) {
            loadPage(page, at: index, request: request)
            return
        }
        if request.automatic, uncommittedFavoriteFailure(for: tabID) != nil {
            if let handoff = request.cloudHandoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
            return
        }
        if request.automatic, blocksAutomaticContentRefresh(tabID: tabID, allowing: request.cloudHandoff) {
            // Watcher coalescing cannot replace the owning one-use handoff.
            if deferredPreviewLoads[tabID]?.cloudHandoff == nil { deferredPreviewLoads[tabID] = request }
            else if let handoff = request.cloudHandoff, deferredPreviewLoads[tabID]?.cloudHandoff !== handoff {
                finishCloudHandoff(handoff, snapshot: nil, transition: nil)
            }
            return
        }
        if !request.automatic, tabID == activeTabID {
            deferredPreviewLoads.removeValue(forKey: tabID)
            preview.show(nil)
        }
        let requestedHistory = request.history, preserveSelection = request.preserveSelection
        let committedHistory = tabs[index].history
        let automatic = request.automatic, addressEntry = request.addressEntry
        let endsSearch = request.endsSearch, reveal = request.reveal, selectionIntent = request.selectionIntent
        if tabID == activeTabID && !automatic { address.cancel() }
        let token = startLoadWork(tabID: tabID, request: .directory(request))
        let background = automatic && tabs[index].hasLoaded && !tabs[index].isUnavailable
            && requestedHistory.current == tabs[index].url
        tabs[index].isLoading = !background
        tabs[index].isRefreshing = background
        if !automatic {
            tabs[index].errorMessage = nil
            tabs[index].accessIssue = nil
            failedLoads.removeValue(forKey: tabID)
        }
        let hidden = showHidden
        let loader = self.loader
        let home = homeURL
        tabLoads[tabID]?.work?.task = Task { [weak self] in
            var history = requestedHistory
            do {
                let redirect = request.documentsFavorite ? try await DocumentsFavoriteRedirect.resolve(homeURL: home) : nil
                if let redirect {
                    if BrowsingLocation(url: committedHistory.current) == BrowsingLocation(url: redirect.destinationURL) { history = committedHistory }
                    else { history.replaceCurrent(with: redirect.destinationURL) }
                }
                try Task.checkCancellation()
                await self?.prepareObservation(tabID: tabID, url: history.current)
                try Task.checkCancellation()
                let badgeCache = OneDriveBadgeCache.shared
                let statusSequence = badgeCache.beginListingSnapshot(for: history.current)
                if let store = self?.cloudStatusOwner {
                    badgeCache.beginDirectoryRecovery(store: store, folder: history.current, load: token, startedAt: statusSequence)
                }
                defer { badgeCache.endDirectoryRecovery(token) }
                let snapshot = try await loader.snapshot(of: history.current, showHidden: hidden)
                if let redirect { try await redirect.validate(snapshot) }
                var transition: VerifiedHydrationTransition?
                var handoffRefused = false
                if let handoff = request.cloudHandoff {
                    if self?.isContentOriginCurrent(handoff.origin) == true, !handoff.invalidated {
                        do { transition = try await handoff.claim(snapshot: snapshot) }
                        catch { handoffRefused = true; handoff.invalidate() }
                    } else { handoffRefused = true; handoff.invalidate() }
                }
                guard !Task.isCancelled, let self,
                      self.isCurrentLoadWork(tabID: tabID, token: token),
                      let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { request.cloudHandoff?.invalidate(); return }
                if let handoff = request.cloudHandoff, !self.isContentOriginCurrent(handoff.origin) {
                    handoffRefused = true; transition = nil; handoff.invalidate()
                }
                let defersPreview = request.cloudHandoff != nil
                if defersPreview { self.previewUpdateDepth += 1 }
                defer { if defersPreview { self.finishDeferredPreviewUpdate() } }
                var previous = DirectorySnapshot(items: self.tabs[index].items,
                                                 directoryIdentity: self.tabs[index].directoryIdentity,
                                                 archiveRevision: self.tabs[index].archiveRevision)
                if let transition, !handoffRefused {
                    let matches = previous.items.filter { $0.url.absoluteString == transition.originalEntry.item.url.absoluteString }
                    if matches.count == 1, matches[0].identity == transition.originalEntry.item.identity {
                        previous = DirectorySnapshot(items: previous.items.map {
                            $0.url.absoluteString == transition.originalEntry.item.url.absoluteString ? transition.refreshedItem : $0
                        }, directoryIdentity: previous.directoryIdentity, archiveRevision: previous.archiveRevision)
                    } else { handoffRefused = true }
                }
                let outgoingURL = self.tabs[index].url
                if BrowsingLocation(url: outgoingURL) != BrowsingLocation(url: history.current),
                   self.tabs[index].hasLoaded, !self.tabs[index].isUnavailable {
                    // Capture the latest committed selection, including changes
                    // made while this read was pending; failed reads never save it.
                    self.tabs[index].navigationSelections.remember(location: outgoingURL,
                        selection: self.tabs[index].selection, snapshot: previous)
                }
                // A user can reopen the address editor while a blocking read is
                // pending. Its results belong to the old committed location.
                if tabID == self.activeTabID, self.tabs[index].url != history.current {
                    self.address.cancel()
                }
                if preserveSelection { self.tabs[index].selection.reconcile(previous: previous, current: snapshot) }
                else if selectionIntent == .history {
                    self.tabs[index].selection = self.tabs[index].navigationSelections.restoredSelection(
                        location: history.current, snapshot: snapshot)
                } else { self.tabs[index].selection.clear() }
                // Results belong to their root: any committed location change ends
                // search, as does an explicit search-exit navigation (MAC-062).
                if let search = self.tabs[index].search,
                   endsSearch || BrowsingLocation(url: search.rootURL) != BrowsingLocation(url: history.current) {
                    self.endSearch(at: index)
                }
                let selectedReveal = reveal ?? (selectionIntent == .ancestor
                    ? BrowsingLocation.childOnPath(from: outgoingURL, to: history.current).map(ItemReveal.navigationChild) : nil)
                var visibilityTarget: FileItem?
                if let reveal = selectedReveal, reveal.entries.allSatisfy({ entry in
                    guard let parent = BrowsingLocation(url: entry.url)?.parentURL else { return false }
                    return BrowsingLocation(url: history.current) == BrowsingLocation(url: parent)
                }) {
                    // Select only the requested entries (the sampled one for search, MAC-065/082).
                    let rows = reveal.entries.compactMap { entry in
                        snapshot.items.first { $0.url.path == entry.url.path && entry.matches($0) }
                            ?? snapshot.items.first { entry.matches($0) }
                    }
                    if let first = rows.first {
                        self.tabs[index].selection.selectedIDs = Set(rows.map(\.id))
                        self.tabs[index].selection.focusedID = first.id
                        self.tabs[index].selection.anchorID = first.id
                        if reveal.requestsVisibility { visibilityTarget = first }
                    }
                    if rows.count < reveal.entries.count, let notice = reveal.missingNotice { self.operationNotice = notice }
                }
                self.tabs[index].history = history
                self.tabs[index].pageFilter = ""
                let sameScope = outgoingURL == history.current && previous.directoryIdentity == snapshot.directoryIdentity
                self.tabs[index].hasObservedCloudItems = (sameScope && self.tabs[index].hasObservedCloudItems)
                    || snapshot.items.contains { $0.availability != .unknown }
                    || (OneDriveRetentionService.isBadgeLocation(history.current)
                        && snapshot.items.contains { OneDriveRetentionService.isBadgeCandidate($0) })
                if let addressEntry { self.address.recordSuccessfulSubmission(addressEntry) }
                if let transition, !handoffRefused {
                    self.tabs[index].items = snapshot.items.map {
                        $0.id == transition.refreshedItem.id ? transition.refreshedItem : $0
                    }
                } else { self.tabs[index].items = snapshot.items }
                self.tabs[index].directoryIdentity = snapshot.directoryIdentity
                if let redirect {
                    self.tabs[index].documentsFavoriteAssociation = DocumentsFavoriteAssociation(
                        sourceURL: home.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL,
                        destinationURL: history.current, directoryIdentity: redirect.directoryIdentity)
                } else if let association = self.tabs[index].documentsFavoriteAssociation,
                          request.clearsDocumentsFavoriteAssociation || request.documentsFavorite
                            || (BrowsingLocation(url: association.destinationURL) == BrowsingLocation(url: history.current)
                            && association.directoryIdentity != snapshot.directoryIdentity) {
                    self.tabs[index].documentsFavoriteAssociation = nil
                }
                self.tabs[index].archiveRevision = snapshot.archiveRevision
                self.tabs[index].hasLoaded = true
                self.tabs[index].isUnavailable = false
                // An automatic refresh must not consume a failed navigation's Retry target.
                if self.failedLoads[tabID]?.history.current == history.current || !automatic {
                    self.failedLoads.removeValue(forKey: tabID)
                    self.tabs[index].errorMessage = nil
                    self.tabs[index].accessIssue = nil
                }
                self.tabs[index].isLoading = false
                self.tabs[index].isRefreshing = false
                self.invalidateRevealVisibility(at: index)
                if let visibilityTarget {
                    let request = RevealVisibilityRequest(tab: self.tabs[index], item: visibilityTarget)
                    self.tabs[index].revealVisibilityGeneration = request.id
                    self.tabs[index].revealVisibilityRequest = request
                }
                if BrowsingLocation(url: history.current)?.physicalURL != nil,
                   snapshot.archiveRevision == nil, hidden == self.showHidden {
                    self.ownedSidebarModel?.observePhysicalSnapshot(at: history.current, snapshot: snapshot,
                        showHidden: hidden, explicitlyOpened: !automatic && request.grantsSidebarAccess)
                }
                self.finishLoadWork(tabID: tabID, token: token)
                if history.current.isFileURL, snapshot.archiveRevision == nil, let identity = snapshot.directoryIdentity {
                    let parent = FileOperationContext(directoryURL: history.current, directoryIdentity: identity)
                    let entries = self.tabs[index].items.filter { OneDriveRetentionService.isBadgeCandidate($0) }
                        .map { TransferEntry(source: parent, item: $0) }
                    OneDriveBadgeCache.shared.mergeDirectoryListing(entries, roster: snapshot.items, parent: parent, startedAt: statusSequence)
                }
                if let handoff = request.cloudHandoff {
                    self.finishCloudHandoff(handoff, snapshot: handoffRefused ? nil : snapshot,
                                            transition: handoffRefused ? nil : transition)
                }
                if let operation = self.operationResult, operation.tabID == tabID {
                    self.tabs[index].selection.clear()
                    let verified = operation.results.compactMap { result -> FileItem? in
                        guard snapshot.directoryIdentity == operation.context.directoryIdentity,
                              let identity = result.identity else { return nil }
                        return snapshot.items.first { $0.url == result.url && $0.identity == identity }
                    }
                    self.tabs[index].selection.selectedIDs = Set(verified.map(\.id))
                    self.tabs[index].selection.focusedID = verified.first?.id
                    self.tabs[index].selection.anchorID = verified.first?.id
                    if verified.count != operation.results.count {
                        self.appendOperationNotice("The change completed, but its result is not visible or could not be verified. Refresh to check the folder.")
                    }
                    self.operationResult = nil
                    self.isPerformingOperation = false
                }
                self.scheduleObservedRefresh()
            } catch {
                if let handoff = request.cloudHandoff { self?.finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
                guard !Task.isCancelled, let self,
                      self.isCurrentLoadWork(tabID: tabID, token: token),
                      let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.tabs[index].isLoading = false
                self.tabs[index].isRefreshing = false
                let preserveFailure = automatic && self.failedLoads[tabID] != nil
                    && self.failedLoads[tabID]?.history.current != history.current
                if !preserveFailure {
                    let archive = ArchiveLocation(url: history.current)
                    self.tabs[index].errorMessage = "Couldn’t open \(BrowsingPresentation.path(history.current)). \(error.localizedDescription)"
                    if archive == nil, history.current.pathComponents.contains(where: { $0.lowercased().hasSuffix(".zip") }) {
                        self.tabs[index].errorMessage? += " If this path is inside another ZIP, open that ZIP from its containing folder first."
                    }
                    self.tabs[index].accessIssue = self.accessIssue(for: error,
                        locations: [archive?.archiveURL ?? history.current], action: "Open folder")
                    self.failedLoads[tabID] = PendingLoad(history: request.documentsFavorite ? requestedHistory : history, preserveSelection: preserveSelection,
                                                          automatic: false, addressEntry: nil,
                                                          endsSearch: endsSearch, reveal: reveal, selectionIntent: selectionIntent,
                                                          documentsFavorite: request.documentsFavorite,
                                                          clearsDocumentsFavoriteAssociation: request.clearsDocumentsFavoriteAssociation)
                }
                let uncommittedFavorite = request.documentsFavorite && !self.tabs[index].hasLoaded
                if history.current == self.tabs[index].url || uncommittedFavorite {
                    self.tabs[index].isUnavailable = true
                    self.tabs[index].selection.clear()
                    self.tabs[index].revealVisibilityRequest = nil
                }
                if self.operationResult?.tabID == tabID {
                    self.appendOperationNotice(self.operationResult?.results.isEmpty == false
                        ? "The change completed, but the folder could not be refreshed. Retry only reloads the folder."
                        : "The folder could not be refreshed. Retry only reloads the folder.")
                    self.operationResult = nil
                    self.isPerformingOperation = false
                }
                if tabID == self.activeTabID && uncommittedFavorite {
                    // Neither the alias nor the refused target is a committed
                    // location. A watch must not turn the failed intent into an
                    // ordinary alias refresh and consume its Retry request.
                    self.stopObservation()
                } else if tabID == self.activeTabID && self.tabs[index].hasLoaded
                            && history.current != self.tabs[index].url {
                    // Resume observing the committed location after a refused navigation.
                    // A post-attach snapshot covers changes made while its watch was absent.
                    await self.prepareObservation(tabID: tabID, url: self.tabs[index].url)
                    guard !Task.isCancelled, self.isCurrentLoadWork(tabID: tabID, token: token) else { return }
                    self.observationDirty = true
                }
                self.finishLoadWork(tabID: tabID, token: token)
                self.scheduleObservedRefresh()
            }
        }
    }

    private func loadPage(_ page: BrowserPage, at index: Int, request: PendingLoad) {
        let previous = tabs[index]
        let id = previous.id
        let changed = previous.url != request.history.current
        let token = startLoadWork(tabID: id, request: .directory(request))
        if let handoff = deferredPreviewLoads.removeValue(forKey: id)?.cloudHandoff {
            finishCloudHandoff(handoff, snapshot: nil, transition: nil)
        }
        if let handoff = request.cloudHandoff { finishCloudHandoff(handoff, snapshot: nil, transition: nil) }
        for handoff in contentHandoffs.values.filter({ $0.origin.tabID == id }) {
            finishCloudHandoff(handoff, snapshot: nil, transition: nil)
        }
        previewMetadataTasks.removeValue(forKey: id)?.cancel()
        previewMetadataTokens.removeValue(forKey: id)
        searchTasks.removeValue(forKey: id)?.cancel()
        for owner in OneDriveBadgeCache.shared.viewportOwners(store: cloudStatusOwner, tab: id) {
            removeOneDriveBadgeViewport(owner)
        }
        if id == activeTabID {
            stopObservation()
            cancelSearchActivation()
            if changed || !request.automatic { address.cancel() }
            preview.show(nil)
            OneDriveBadgeCache.shared.cancelFollowUp(owner: cloudStatusOwner)
        }
        var tab = previous
        if changed, previous.hasLoaded, !previous.isUnavailable {
            let snapshot = DirectorySnapshot(items: previous.items, directoryIdentity: previous.directoryIdentity,
                                             archiveRevision: previous.archiveRevision)
            tab.navigationSelections.remember(location: previous.url, selection: previous.selection, snapshot: snapshot)
        }
        tab.history = request.history
        if changed {
            tab.pageFilter = ""
            tab.homeResults = HomeResultSelection()
        }
        if case .tag(let name) = page {
            // Existing saved tag URLs enter the same inline Home filter.
            if previous.url == BrowserPage.home.url {
                tab.history = previous.history
            } else {
                tab.history.replaceCurrent(with: BrowserPage.home.url)
            }
            tab.homeSection = .tags
            tab.homeTag = name.precomposedStringWithCanonicalMapping
            tab.homeTagGeneration = UUID()
        }
        tab.items = []
        tab.selection.clear()
        tab.directoryIdentity = nil
        tab.documentsFavoriteAssociation = nil
        tab.archiveRevision = nil
        tab.hasObservedCloudItems = false
        tab.revealVisibilityRequest = nil
        tab.revealVisibilityGeneration = nil
        tab.search = nil
        tab.isLoading = false
        tab.isRefreshing = false
        tab.hasLoaded = true
        tab.isUnavailable = false
        if !request.automatic || failedLoads[id] == nil {
            failedLoads.removeValue(forKey: id)
            tab.errorMessage = nil
            tab.accessIssue = nil
        }
        finishLoadWork(tabID: id, token: token)
        tabs[index] = tab
    }

    // MARK: - NATIVE-P14 filename search (MAC-062–065)

    private func cancelSearchActivation() {
        searchActivation?.cancel()
        searchActivation = nil
        searchActivationToken = nil
    }

    var canSearch: Bool { (physicalFolderURL != nil || activePage != nil) && shortcutDraft == nil && !isPerformingOperation && !isShowingRecovery }
    var activeSearch: SearchSession? { activeTab.search }

    func requestSearchFocus() {
        guard canSearch else { return }
        searchFocusRequest &+= 1
    }

    /// Return in the search field. Empty text closes search; otherwise a new run
    /// replaces any previous one, keeping the current scope/filters while searching.
    func submitSearch(_ text: String) {
        guard canSearch, let index = activeIndex else { return }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        address.cancel()
        cancelNameEdit()
        if activePage != nil {
            abandonPendingSearchExit(tabID: activeTabID)
            tabs[index].pageFilter = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        let scope = tabs[index].search?.query.scope ?? .allSubfolders
        let filters = tabs[index].search?.query.filters ?? SearchFilters()
        guard let query = FilenameSearchQuery(text: text, scope: scope, filters: filters) else {
            closeSearch()
            return
        }
        if tabs[index].search == nil { prepareViewReplacement(to: tabs[index].viewMode) }
        cancelRevealVisibility()
        tabs[index].search = SearchSession(query: query, rootURL: tabs[index].url, rootTitle: tabs[index].folderTitle)
        // A new search is the newest intent; an older search exit must not end it.
        abandonPendingSearchExit(tabID: activeTabID)
        runSearch(tabID: activeTabID)
    }

    func setSearchScope(_ scope: SearchScope) {
        updateSearchQuery { $0.scope = scope }
    }
    func setSearchKind(_ kind: SearchKindFilter?) {
        updateSearchQuery { $0.filters.kind = kind }
    }
    func setSearchDate(_ date: SearchDateFilter?) {
        updateSearchQuery { $0.filters.dateModified = date }
    }
    func setSearchSize(_ size: SearchSizeFilter?) {
        updateSearchQuery { $0.filters.size = size }
    }

    private func updateSearchQuery(_ change: (inout FilenameSearchQuery) -> Void) {
        guard canSearch, let index = activeIndex, var search = tabs[index].search else { return }
        var query = search.query
        change(&query)
        guard query != search.query else { return }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        search.query = query
        tabs[index].search = search
        abandonPendingSearchExit(tabID: activeTabID)
        runSearch(tabID: activeTabID)
    }

    /// Stop keeps the results found so far, presented as cancelled.
    func stopSearch() {
        guard let index = activeIndex, tabs[index].search?.isRunning == true else { return }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        searchTasks.removeValue(forKey: activeTabID)?.cancel()
        cancelSearchActivation()
        address.cancelPendingSubmission()
        tabs[index].search?.generation = UUID()
        tabs[index].search?.phase = .cancelled
    }

    /// Close search, Escape, an empty submission or Back return to the original
    /// folder without a read or history change (MAC-062).
    func closeSearch() {
        // An operation (e.g. Restore's post-write read) owns navigation until it finishes.
        guard canSearch, let index = activeIndex else { return }
        if activePage != nil { tabs[index].pageFilter = ""; return }
        guard tabs[index].search != nil else { return }
        invalidateCloudCommandForNewIntent(clearBarrier: true)
        cancelSearchActivation()
        prepareViewReplacement(to: tabs[index].viewMode)
        endSearch(at: index)
        if !abandonPendingSearchExit(tabID: activeTabID) { scheduleObservedRefresh() }
    }

    /// A newer intent can abandon a still-loading navigation. A passive reload
    /// of the committed folder replaces it and also rebinds observation.
    @discardableResult
    private func abandonPendingSearchExit(tabID: UUID) -> Bool {
        guard let pending = pendingLoad(for: tabID), pending.endsSearch, !pending.automatic,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let history = tabs[index].history
        if blocksAutomaticContentRefresh(tabID: tabID) {
            // Deferring the maintenance read must still revoke the old
            // navigation's permission to publish.
            tabLoads[tabID]?.work?.task?.cancel()
            tabLoads[tabID]?.work = nil
            tabs[index].isLoading = false
            tabs[index].isRefreshing = false
        }
        load(tabID: tabID, history: history, preserveSelection: true, automatic: true)
        return true
    }

    private func endSearch(at index: Int) {
        let tabID = tabs[index].id
        searchTasks.removeValue(forKey: tabID)?.cancel()
        if tabID == activeTabID {
            cancelSearchActivation()
            address.cancelPendingSubmission()
        }
        tabs[index].search = nil
    }

    /// Starts a new generation for the tab's current query. Only that generation
    /// can apply results or completion (MAC-064).
    private func runSearch(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), var search = tabs[index].search else { return }
        searchTasks.removeValue(forKey: tabID)?.cancel()
        if tabID == activeTabID {
            cancelSearchActivation()
            address.cancelPendingSubmission()
        }
        let generation = UUID()
        search.generation = generation
        search.reset()
        let tab = tabs[index]
        guard tab.hasLoaded, !tab.isUnavailable, tab.url == search.rootURL,
              let identity = tab.directoryIdentity else {
            search.phase = .unavailable(tab.directoryIdentity == nil && tab.hasLoaded && !tab.isUnavailable
                ? "Search is available only for local folders."
                : "Search needs the folder to be available. Refresh the folder, then search again.")
            tabs[index].search = search
            return
        }
        search.phase = .searching
        tabs[index].search = search
        let request = FilenameSearchRequest(root: tab.url, rootIdentity: identity, query: search.query,
                                            showHidden: showHidden)
        let statusSequence = OneDriveBadgeCache.shared.beginListingSnapshot(for: tab.url)
        let stream = searcher.search(request)
        searchTasks[tabID] = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.applySearchEvent(event, tabID: tabID, generation: generation, statusSequence: statusSequence)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failSearch(error, tabID: tabID, generation: generation)
            }
        }
    }

    private func currentSearchIndex(tabID: UUID, generation: UUID) -> Int? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let search = tabs[index].search, search.generation == generation, search.isRunning else { return nil }
        return index
    }

    private func applySearchEvent(_ event: FilenameSearchEvent, tabID: UUID, generation: UUID, statusSequence: UInt64) {
        guard let index = currentSearchIndex(tabID: tabID, generation: generation) else { return }
        let sort = tabs[index].sort
        switch event {
        case .progress(let results, let coverage):
            tabs[index].search?.append(results, sort: sort)
            tabs[index].search?.coverage = coverage
            let entries = results.compactMap { result -> TransferEntry? in
                guard tabs[index].search?.result(id: result.id) == result, let parent = result.parent,
                      OneDriveRetentionService.isBadgeCandidate(result.item) else { return nil }
                return TransferEntry(source: parent, item: result.item)
            }
            OneDriveBadgeCache.shared.mergeListing(entries, startedAt: statusSequence)
        case .finished(let coverage):
            tabs[index].search?.coverage = coverage
            tabs[index].search?.phase = coverage.isComplete ? .complete : .partial
            if let failure = coverage.accessFailure {
                tabs[index].search?.accessIssue = FileAccessContext(failure: failure,
                    locations: coverage.unreadableSamples, action: "Search")
            }
            searchTasks.removeValue(forKey: tabID)
        }
    }

    private func failSearch(_ error: Error, tabID: UUID, generation: UUID) {
        guard !(error is CancellationError),
              let index = currentSearchIndex(tabID: tabID, generation: generation),
              let root = tabs[index].search?.rootURL else { return }
        let message = (error as? FilenameSearchError)?.errorDescription
            ?? "Couldn’t search \(root.path). \(error.localizedDescription)"
        tabs[index].search?.phase = .unavailable(message)
        tabs[index].search?.accessIssue = accessIssue(for: error, locations: [root], action: "Search")
        searchTasks.removeValue(forKey: tabID)
    }

    /// Selected identity-backed results with their own sampled parents, in display order.
    private var selectedSearchOperationEntries: [TransferEntry]? {
        // As in folder mode, writes wait while a navigation read is pending:
        // Trash must not race an Open file location or other search exit.
        guard let search = activeTab.search, isCommandIdle,
              !activeTab.isLoading,
              !search.selection.selectedIDs.isEmpty, search.selection.selectedIDs.count <= 1_024 else { return nil }
        let results = search.selectedResults
        guard results.count == search.selection.selectedIDs.count else { return nil }
        var entries: [TransferEntry] = []
        for result in results {
            guard result.supportsOperations, let parent = result.parent else { return nil }
            entries.append(TransferEntry(source: parent, item: result.item))
        }
        return entries
    }

    /// The single focused/selected result for Open file location.
    var selectedSearchResult: FilenameSearchResult? {
        guard let search = activeTab.search, search.selection.selectedIDs.count == 1,
              let id = search.selection.selectedIDs.first else { return nil }
        return search.result(id: id)
    }
    var canOpenSearchResultLocation: Bool {
        selectedSearchResult?.supportsOperations == true && isCommandIdle
    }

    func openSelectedSearchResultLocation() {
        guard canOpenSearchResultLocation, let result = selectedSearchResult else { return }
        openSearchResult(result, revealingParent: true)
    }

    /// MAC-065: revalidate the result's entry and parent before opening it or
    /// navigating to its location. A later activation replaces an earlier one.
    private func openSearchResult(_ result: FilenameSearchResult, revealingParent: Bool) {
        guard let search = activeTab.search, result.supportsOperations,
              let parent = result.parent, let identity = result.item.identity else {
            operationNotice = "“\(result.item.name)” can’t be opened from search because its location couldn’t be verified."
            return
        }
        let target = FileActivationTarget(result.item)
        if revealingParent || target.canOpen { address.cancelPendingSubmission() }
        cancelSearchActivation()
        let tabID = activeTabID
        // The newest intent wins: an earlier result's (or other) still-loading
        // search-exit navigation must not commit while this one revalidates.
        abandonPendingSearchExit(tabID: tabID)
        let sessionID = search.id
        let generation = search.generation
        let validate = validateSearchResult
        let token = UUID()
        searchActivationToken = token
        searchActivation = Task { [weak self] in
            let current: Bool
            do { current = try await validate(result) }
            catch { current = false }
            let document: RecentDocument?
            if current, !revealingParent, case .ordinaryFile = target { document = await RecentDocument.validated(result.item) }
            else { document = nil }
            // Bound to the exact presented run: a Refresh, option change, Stop,
            // close or tab switch invalidates it, and any navigation started
            // afterwards cancels it in prepareForNavigation. As the newest intent,
            // it supersedes an earlier result's still-loading navigation (MAC-064/065).
            guard !Task.isCancelled, let self, self.searchActivationToken == token,
                  self.activeTabID == tabID,
                  self.activeTab.search?.id == sessionID, self.activeTab.search?.generation == generation,
                  self.activeTab.search?.result(id: result.id) != nil,
                  self.isCommandIdle else { return }
            self.searchActivation = nil
            self.searchActivationToken = nil
            guard current else {
                self.operationNotice = "“\(result.item.name)” changed or moved since the search. Refresh to search again."
                return
            }
            if revealingParent {
                self.navigate(to: parent.directoryURL, reveal: .searchResult(url: result.item.url, identity: identity))
            } else if let url = target.browsingURL {
                self.navigate(to: url)
            } else if case .ordinaryFile(let url) = target {
                self.openPhysicalFile(url, captured: document)
            }
        }
    }

    /// Trash from results keeps the user in search and re-runs it, while the
    /// folder snapshot underneath refreshes passively.
    private func finishSearchTrash(tabID: UUID, searchID: UUID) {
        operationTask = nil
        isPerformingOperation = false
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        load(tabID: tabID, history: tab.history, preserveSelection: true, automatic: true)
        if tab.search?.id == searchID { runSearch(tabID: tabID) }
    }

    /// One subscription per window. Native events are hints, never row mutations.
    /// Epoch checks reject queued callbacks even when cancellation is ignored.
    private func prepareObservation(tabID: UUID, url: URL) async {
        guard !Task.isCancelled, activeTabID == tabID,
              tabs.contains(where: { $0.id == tabID }) else { return }
        guard BrowsingLocation(url: url)?.physicalURL != nil else { stopObservation(); return }
        guard let observer else { return }
        if observationTarget?.tabID == tabID, observationTarget?.url == url,
           observationTask != nil, !observationNeedsRebind { return }
        stopObservation()
        let epoch = observationEpoch
        observationTarget = (tabID, url)
        do {
            // FSEvents attachment and route resolution never block the main thread.
            // events() returns only after the native subscription has started.
            let stream = try await BlockingIO.run(on: .watchAttach) { cancellation in
                try cancellation.checkCancellation()
                return try observer.events(for: url)
            }
            guard !Task.isCancelled, observationEpoch == epoch, activeTabID == tabID else { return }
            observationTask = Task { [weak self] in
                do {
                    for try await change in stream {
                        guard !Task.isCancelled else { return }
                        self?.observed(change, epoch: epoch, tabID: tabID)
                    }
                    if !Task.isCancelled { self?.observationEnded(epoch: epoch, message: "Automatic updates stopped. Use Refresh to reload.") }
                } catch {
                    if !Task.isCancelled { self?.observationEnded(epoch: epoch, message: "Automatic updates unavailable. Use Refresh. \(error.localizedDescription)") }
                }
            }
        } catch {
            guard !Task.isCancelled, observationEpoch == epoch else { return }
            observationWarning = "Automatic updates unavailable. Use Refresh. \(error.localizedDescription)"
        }
    }

    func isRetiredSearchBadge(_ item: FileItem) -> Bool {
        guard let search = activeTab.search, search.generation == retiredBadgeSearch,
              let parent = search.result(id: item.id)?.parent,
              let key = OneDriveStatusKey(.init(source: parent, item: item)) else { return false }
        return retiredBadgeHits.contains(key)
    }

    func recoverOneDriveBadge(_ entry: TransferEntry, owner: UUID, scope: OneDriveBadgeCache.Scope) {
        guard scope.tab == activeTabID, scope.folder == activeTab.url,
              activeTab.search?.generation == scope.searchGeneration,
              OneDriveBadgeCache.shared.isVisible(entry, owner: owner) else { return }
        // Directory observations coalesce one post-refusal authoritative listing.
        guard scope.searchGeneration == nil else { return }
        observationDirty = true
        scheduleObservedRefresh()
    }

    func searchBadgeParentReader(_ entry: TransferEntry, owner: UUID, scope: OneDriveBadgeCache.Scope) -> OneDriveBadgeCache.ParentRead? {
        guard scope.tab == activeTabID, let search = scope.searchGeneration, activeTab.search?.generation == search,
              let current = activeTab.search?.result(id: entry.item.id), current.item == entry.item,
              current.parent == entry.source, !blocksAutomaticContentRefresh(tabID: scope.tab),
              OneDriveBadgeCache.shared.isVisible(entry, owner: owner) else { return nil }
        let loader = self.loader, hidden = showHidden
        return { try await loader.snapshot(of: entry.source.directoryURL, showHidden: hidden) }
    }

    func acceptRecoveredSearchBadge(_ original: TransferEntry, item: FileItem?, owner: UUID, scope: OneDriveBadgeCache.Scope) -> Bool {
        guard let search = scope.searchGeneration, scope.tab == activeTabID, activeTab.search?.generation == search,
              let index = activeIndex, let current = activeTab.search?.result(id: original.item.id),
              current.item == original.item, current.parent == original.source,
              !blocksAutomaticContentRefresh(tabID: scope.tab),
              OneDriveBadgeCache.shared.isVisible(original, owner: owner) else { return false }
        if let item, item.identity == original.item.identity {
            let sort = tabs[index].sort
            tabs[index].search?.refreshMetadata(item, parent: original.source, sort: sort)
        } else {
            if search != retiredBadgeSearch { retiredBadgeSearch = search; retiredBadgeHits.removeAll() }
            if let key = OneDriveStatusKey(original) { retiredBadgeHits.insert(key) }
            objectWillChange.send()
        }
        return true
    }

    private func observed(_ change: DirectoryChange, epoch: UUID, tabID: UUID) {
        guard observationEpoch == epoch, activeTabID == tabID else { return }
        if case .children(let names) = change {
            OneDriveBadgeCache.shared.hint(folder: activeTab.url, reason: .directory, childNames: names)
        } else {
            OneDriveBadgeCache.shared.hint(folder: activeTab.url, reason: .directory)
        }
        observationDirty = true
        if case .rootChanged = change {
            observationNeedsRebind = true
            OneDriveBadgeCache.shared.revalidateRoot(for: activeTab.url)
        }
        scheduleObservedRefresh()
    }

    private func observationEnded(epoch: UUID, message: String) {
        guard observationEpoch == epoch else { return }
        observationTask = nil
        observationWarning = message
    }

    private func scheduleObservedRefresh() {
        if drainDeferredPreviewLoad(tabID: activeTabID) { return }
        guard shortcutDraft == nil, nameEdit == nil, !isPerformingOperation, observer != nil, observationDirty, observationDebounce == nil,
              !blocksAutomaticContentRefresh(tabID: activeTabID),
              observationTarget?.tabID == activeTabID, tabLoads[activeTabID]?.work == nil else { return }
        let epoch = observationEpoch
        let tabID = activeTabID
        observationDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.observationEpoch == epoch, self.activeTabID == tabID else { return }
            self.observationDebounce = nil
            guard self.shortcutDraft == nil, self.nameEdit == nil, !self.isPerformingOperation, self.tabLoads[tabID]?.work == nil,
                  !self.blocksAutomaticContentRefresh(tabID: tabID) else { return } // Completion drains the dirty flag.
            self.observationDirty = false
            self.load(tabID: tabID, history: self.activeTab.history, preserveSelection: true, automatic: true)
        }
    }

    private func stopObservation() {
        observationEpoch = UUID()
        observationTask?.cancel()
        observationTask = nil
        observationDebounce?.cancel()
        observationDebounce = nil
        observationTarget = nil
        observationDirty = false
        observationNeedsRebind = false
        observationWarning = nil
    }
}
