import ExplorerCore
import Foundation

/// WPHY10–15 / WZIP10: Back/Forward restore a location's selection; they do
/// not infer a departed child. Bookmarks hold exact entries, never rename authority.
struct NavigationSelectionMemory {
    private struct Bookmark {
        let selection: SelectionState
        let entries: [FileItem]
        let directoryIdentity: LocalFileIdentity?
        let archiveRevision: ArchiveRevision?
    }
    private var bookmarks: [BrowsingLocation: Bookmark] = [:]
    private var recency: [BrowsingLocation] = []
    private let locationLimit = 32
    private let entryLimit = 10_000

    mutating func invalidateArchive(_ archiveURL: URL) {
        let affected = bookmarks.keys.filter {
            if case .archive(let location) = $0 { return location.archiveURL == archiveURL }
            return false
        }
        for location in affected { remove(location) }
    }

    mutating func remember(location url: URL, selection: SelectionState, snapshot: DirectorySnapshot) {
        guard let location = BrowsingLocation(url: url) else { return }
        remove(location)
        switch location {
        case .page: return
        case .filesystem: guard snapshot.directoryIdentity != nil, snapshot.archiveRevision == nil else { return }
        case .archive: guard snapshot.archiveRevision != nil, snapshot.directoryIdentity == nil else { return }
        }
        var ids = selection.selectedIDs
        if let id = selection.focusedID { ids.insert(id) }
        if let id = selection.anchorID { ids.insert(id) }
        guard ids.count <= entryLimit else { return }
        let entries = snapshot.items.filter { ids.contains($0.id) }
        guard entries.count == ids.count, Set(entries.map(\.id)).count == entries.count else { return }
        switch location {
        case .page: return
        case .filesystem: guard entries.allSatisfy({ $0.identity != nil && BrowsingPresentation.isPhysical($0) }) else { return }
        case .archive: guard entries.allSatisfy({ $0.identity == nil && $0.archiveRevision == snapshot.archiveRevision }) else { return }
        }
        bookmarks[location] = Bookmark(selection: selection, entries: entries,
            directoryIdentity: snapshot.directoryIdentity, archiveRevision: snapshot.archiveRevision)
        recency.append(location)
        while recency.count > locationLimit || bookmarks.values.reduce(0, { $0 + $1.entries.count }) > entryLimit {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
    }

    mutating func restoredSelection(location url: URL, snapshot: DirectorySnapshot) -> SelectionState {
        guard let location = BrowsingLocation(url: url), let bookmark = bookmarks[location] else { return SelectionState() }
        guard bookmark.directoryIdentity == snapshot.directoryIdentity,
              bookmark.archiveRevision == snapshot.archiveRevision else {
            remove(location); return SelectionState()
        }
        let current = Dictionary(grouping: snapshot.items, by: \.id)
        let valid = Set(bookmark.entries.compactMap { old -> String? in
            guard let candidates = current[old.id], candidates.count == 1, let candidate = candidates.first,
                  old.identity == candidate.identity, old.archiveRevision == candidate.archiveRevision else { return nil }
            return candidate.id
        })
        var selection = bookmark.selection
        selection.reconcile(validIDs: valid)
        recency.removeAll { $0 == location }
        recency.append(location)
        return selection
    }

    private mutating func remove(_ location: BrowsingLocation) {
        bookmarks.removeValue(forKey: location)
        recency.removeAll { $0 == location }
    }
}
