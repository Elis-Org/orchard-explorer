import ExplorerCore
import Foundation

extension ExplorerStore {
    // The visible rows belong to the committed tab snapshot until its replacement
    // arrives. A pending folder read disables commands, but does not change those
    // rows' physical origins. Action dispatch uses the selection-bound operationEntry.
    func pinBadgeEntry(_ item: FileItem) -> TransferEntry? {
        guard activeTab.hasLoaded, !activeTab.isUnavailable,
              OneDriveRetentionService.isBadgeCandidate(item) else { return nil }
        if let search = activeTab.search {
            guard !isRetiredSearchBadge(item), let hit = search.result(id: item.id), hit.item == item, let parent = hit.parent else { return nil }
            return TransferEntry(source: parent, item: item)
        }
        let folder = activeTab.url
        guard folder.isFileURL, let identity = activeTab.directoryIdentity,
              item.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return nil }
        return TransferEntry(source: FileOperationContext(directoryURL: folder, directoryIdentity: identity), item: item)
    }

    func cloudStatusDisplay(for item: FileItem) -> (presentation: CloudStatusPresentation?, checkedAt: Date?) {
        guard !isRetiredSearchBadge(item) else { return (nil, nil) }
        let entry = pinBadgeEntry(item)
        var snapshot = entry.flatMap { OneDriveBadgeCache.shared.snapshot(for: $0) }
        if let entry, let key = visibleSearchResidencyKey(entry),
           let available = searchBadgeResidency.availability(for: key), available != .unknown,
           snapshot?.source != .query, snapshot?.source != .operation, snapshot?.availability ?? .unknown == .unknown {
            if snapshot == nil { snapshot = OneDriveStatusSnapshot(availability: available, generation: 0) }
            else { snapshot?.availability = available }
        }
        let presentation = CloudStatusPresentation.forItem(item, isDownloading: downloadingItemID == item.id, snapshot: snapshot)
        return (presentation, snapshot?.policy == nil ? nil : snapshot?.confirmedAt)
    }

    private func visibleSearchResidencyKey(_ entry: TransferEntry) -> VisibleSearchResidency.Key? {
        guard let generation = activeTab.search?.generation, entry.item.availability == .unknown,
              let key = OneDriveStatusKey(entry) else { return nil }
        return .init(entry: key, generation: generation,
                     namespaceEpoch: OneDriveBadgeCache.shared.namespaceEpoch(for: entry))
    }

    func reportOneDriveBadgeViewport(_ owner: UUID, items: [FileItem], onChange: @escaping @MainActor (Set<String>) -> Void) {
        let scope = OneDriveBadgeCache.Scope(tab: activeTabID, folder: activeTab.url,
            load: contextMenuLoadGeneration, searchGeneration: activeTab.search?.generation)
        let entries = items.compactMap(pinBadgeEntry)
        var pendingMembership = [VisibleSearchResidency.Key: TransferEntry]()
        for entry in entries {
            guard let key = visibleSearchResidencyKey(entry) else { continue }
            let snapshot = OneDriveBadgeCache.shared.snapshot(for: entry)
            if snapshot?.availability ?? .unknown == .unknown { pendingMembership[key] = entry }
        }
        searchBadgeResidency.update(owner, entries: pendingMembership, changed: onChange)
        OneDriveBadgeCache.shared.update(owner, scope: scope, entries: entries,
            selectedIDs: currentSelection.selectedIDs, storeID: cloudStatusOwner, mergeEntries: false,
            recover: { [weak self] entry in self?.recoverOneDriveBadge(entry, owner: owner, scope: scope) },
            searchReader: { [weak self] entry in self?.searchBadgeParentReader(entry, owner: owner, scope: scope) },
            recoveredSearchHit: { [weak self] entry, item in
                self?.acceptRecoveredSearchBadge(entry, item: item, owner: owner, scope: scope) ?? false
            }, changedIDs: onChange,
            observed: { [weak self] entry, observation in
                self?.receivedOneDriveBadgeObservation(observation, for: entry, scope: scope)
            })
    }

    func removeOneDriveBadgeViewport(_ owner: UUID) {
        searchBadgeResidency.remove(owner)
        OneDriveBadgeCache.shared.remove(owner)
    }
}
