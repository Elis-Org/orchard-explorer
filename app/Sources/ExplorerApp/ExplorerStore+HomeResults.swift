import ExplorerCore
import Foundation

extension ExplorerStore {
    var homeResultScope: HomeResultScope? {
        guard !tabs.isEmpty, let page = activePage, page != .thisMac else { return nil }
        let tab = activeTab
        return HomeResultScope(tabID: tab.id, page: page, section: tab.homeSection,
            epoch: contextMenuLoadGeneration, tagGeneration: tab.homeTagGeneration,
            tagScope: tab.homeSection == .tags ? tagShortcuts.scope(for: tab.homeTag) : nil,
            filter: tab.pageFilter)
    }

    var homeTagSnapshot: FinderTagsSnapshot? {
        guard let scope = homeResultScope, scope.section == .tags,
              activeTab.homeResults.scope?.hasSameCollection(as: scope) == true else { return nil }
        return activeTab.homeResults.tagSnapshot
    }

    func replaceHomeTagSnapshot(_ snapshot: FinderTagsSnapshot, in scope: HomeResultScope) {
        guard let index = homeIndex(in: scope), let query = scope.tagScope else { return }
        var results = tabs[index].homeResults
        guard results.scope != scope || results.tagSnapshot != snapshot else { return }
        let groups = snapshot.groups(for: query, matching: matchesPageFilter)
        results.replace(groups.flatMap { group in group.items.map { HomeResultRow(item: $0, group: group.id) } },
                        scope: scope)
        results.tagSnapshot = snapshot
        tabs[index].homeResults = results
    }

    func replaceHomeResults(_ rows: [HomeResultRow], in scope: HomeResultScope) {
        guard let index = homeIndex(in: scope) else { return }
        var results = tabs[index].homeResults
        guard results.scope != scope || results.rows != rows else { return }
        results.replace(rows, scope: scope)
        tabs[index].homeResults = results
    }

    func bindHomeResultIdentity(_ identity: LocalFileIdentity?, for row: HomeResultRow,
                                in scope: HomeResultScope, membership: UUID? = nil, isSymbolicLink: Bool? = nil) {
        guard let index = homeIndex(in: scope), tabs[index].homeResults.scope == scope else { return }
        var results = tabs[index].homeResults
        if let membership, results.membership(of: row) != membership { return }
        if results.bind(identity, for: row, isSymbolicLink: isSymbolicLink) { tabs[index].homeResults = results }
    }

    func homeResultMembership(_ row: HomeResultRow, in scope: HomeResultScope) -> UUID? {
        guard homeResultScope == scope, activeTab.homeResults.scope == scope,
              row.recent.map(recentDocuments.contains) != false else { return nil }
        return activeTab.homeResults.membership(of: row)
    }

    func selectHomeResult(_ row: HomeResultRow, in scope: HomeResultScope,
                          extending: Bool = false, toggling: Bool = false) {
        guard isCommandIdle, let index = homeIndex(in: scope), homeResultMembership(row, in: scope) != nil else { return }
        var results = tabs[index].homeResults
        let generation = results.generation
        guard results.select(row, extending: extending, toggling: toggling) else { return }
        if results.generation != generation {
            invalidateCloudCommandForNewIntent(clearBarrier: true, selectionChanged: true)
        }
        tabs[index].homeResults = results
    }

    func moveHomeResultFocus(from row: HomeResultRow, in scope: HomeResultScope, by offset: Int,
                             extending: Bool) -> HomeResultRow? {
        guard isCommandIdle, homeResultMembership(row, in: scope) != nil else { return nil }
        let rows = activeTab.homeResults.rows
        guard let origin = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        let destination = rows[min(max(origin + offset, 0), rows.count - 1)]
        selectHomeResult(destination, in: scope, extending: extending)
        return destination
    }

    func performHomeResultAction(_ action: PageItemAction, row: HomeResultRow, in scope: HomeResultScope,
                                 identity: LocalFileIdentity?, whileCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard let token = homeResultMembership(row, in: scope),
              activeTab.homeResults.target(of: row)?.identity == identity, whileCurrent() else { return }
        performPageAction(action, url: row.url, folder: row.isDirectory, recent: row.recent,
                          representedIdentity: identity) { [weak self] in
            guard let self else { return false }
            return whileCurrent() && self.homeResultMembership(row, in: scope) == token
                && self.activeTab.homeResults.target(of: row)?.identity == identity
        }
    }

    func removeHomeRecent(_ row: HomeResultRow, in scope: HomeResultScope) {
        guard isCommandIdle, homeResultMembership(row, in: scope) != nil, let recent = row.recent else { return }
        recentDocuments.remove(recent)
    }

    var homeInspectorTargets: [HomeResultTarget]? {
        guard let scope = homeResultScope else { return nil }
        guard activeTab.homeResults.scope == scope else { return [] }
        return activeTab.homeResults.selectedTargets.filter { $0.recent.map(recentDocuments.contains) != false }
    }

    var homeInspectorGeneration: UUID? {
        guard let scope = homeResultScope, activeTab.homeResults.scope == scope else { return nil }
        return activeTab.homeResults.generation
    }

    private func homeIndex(in scope: HomeResultScope) -> Int? {
        guard homeResultScope == scope else { return nil }
        return tabs.firstIndex { $0.id == scope.tabID }
    }
}
