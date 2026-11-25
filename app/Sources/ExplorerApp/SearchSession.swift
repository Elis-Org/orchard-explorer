import ExplorerCore
import Foundation

/// NATIVE-P14 / MAC-062–064. One transient search presentation over a tab's
/// committed folder. The folder snapshot and its selection stay authoritative
/// underneath; results carry their own sampled parent contexts.
enum SearchPhase: Equatable {
    case searching
    case complete
    case partial
    case cancelled
    case unavailable(String)
}

struct SearchSession {
    let id: UUID
    var query: FilenameSearchQuery
    let rootURL: URL
    let rootTitle: String
    var generation = UUID()
    var phase = SearchPhase.searching
    var coverage = SearchCoverage()
    var selection = SelectionState()
    var accessIssue: FileAccessContext?
    private(set) var hasObservedCloudItems = false
    private(set) var results: [FilenameSearchResult] = []
    private(set) var displayedItems: [FileItem] = []
    private var resultsByID: [String: FilenameSearchResult] = [:]

    init(id: UUID = UUID(), query: FilenameSearchQuery, rootURL: URL, rootTitle: String) {
        self.id = id
        self.query = query
        self.rootURL = rootURL
        self.rootTitle = rootTitle
    }

    var title: String { "\(query.text) - Search Results" }
    var locationTitle: String { "Search Results in \(rootTitle)" }
    var isRunning: Bool { phase == .searching }

    func result(id: String) -> FilenameSearchResult? { resultsByID[id] }

    /// Selected results in presentation order.
    var selectedResults: [FilenameSearchResult] {
        displayedItems.compactMap { selection.selectedIDs.contains($0.id) ? resultsByID[$0.id] : nil }
    }

    mutating func reset() {
        results = []
        displayedItems = []
        resultsByID = [:]
        coverage = SearchCoverage()
        selection.clear()
        accessIssue = nil
        hasObservedCloudItems = false
    }

    /// Duplicate identifiers from a misbehaving provider are ignored rather than
    /// creating ambiguous rows.
    mutating func append(_ batch: [FilenameSearchResult], sort: FileSort) {
        var added = false
        for result in batch where resultsByID[result.id] == nil {
            resultsByID[result.id] = result
            results.append(result)
            hasObservedCloudItems = hasObservedCloudItems || result.item.availability != .unknown || OneDriveRetentionService.isBadgeCandidate(result.item)
            added = true
        }
        if added { resort(sort) }
    }

    mutating func resort(_ sort: FileSort) {
        displayedItems = sort.sorted(results.map(\.item))
    }

    /// Metadata-only refresh of a captured result; never substitute a new item
    /// or parent identity into the result's operation context.
    mutating func refreshMetadata(_ item: FileItem, parent: FileOperationContext, sort: FileSort) {
        guard let old = resultsByID[item.id], old.item.identity == item.identity,
              old.parent == parent, let index = results.firstIndex(where: { $0.id == item.id }) else { return }
        let result = FilenameSearchResult(item: item, parent: parent)
        resultsByID[item.id] = result; results[index] = result
        hasObservedCloudItems = hasObservedCloudItems || item.availability != .unknown || OneDriveRetentionService.isBadgeCandidate(item)
        resort(sort)
    }

    /// Only Core's claimed proof may replace a captured search identity.
    mutating func applyHydrationTransition(_ transition: VerifiedHydrationTransition, sort: FileSort) {
        let original = transition.originalEntry, item = transition.refreshedItem
        guard let old = resultsByID[original.item.id], old.parent == original.source,
              old.item.identity == original.item.identity,
              old.item.url.absoluteString == original.item.url.absoluteString,
              let index = results.firstIndex(where: { $0.id == original.item.id }) else { return }
        let replacement = FilenameSearchResult(item: item, parent: transition.acceptedEntry.source)
        resultsByID[original.item.id] = replacement
        results[index] = replacement
        hasObservedCloudItems = hasObservedCloudItems || item.availability != .unknown || OneDriveRetentionService.isBadgeCandidate(item)
        resort(sort)
    }
}
