import ExplorerCore
import Foundation

extension ExplorerStore {
    var homeOperationOrigin: HomeOperationOrigin? {
        guard let scope = homeResultScope else { return nil }
        let results = activeTab.homeResults, selected = results.selection.selectedIDs
        var witnesses: [HomeOperationOrigin.Occurrence] = []
        var paths = Set<Data>()
        if results.scope == scope && !selected.isEmpty {
            for row in results.rows where selected.contains(row.id) {
                paths.insert(HomeFileLocations.pathKey(row.url))
                if let token = results.membership(of: row), let target = results.target(of: row) {
                    witnesses.append(.init(row: row, membership: token, identity: target.identity))
                }
            }
        }
        return HomeOperationOrigin(scope: scope, visit: results.visitID, activation: homeFileOperations.activation,
                                   generation: results.operationGeneration,
                                   occurrences: witnesses, selectedUniqueCount: paths.count,
                                   complete: witnesses.count == selected.count)
    }

    func isHomeOperationPageCurrent(_ origin: HomeOperationOrigin) -> Bool {
        !tabs.isEmpty && activeTabID == origin.scope.tabID && activePage == origin.scope.page
            && homeFileOperations.activation == origin.activation
            && activeTab.homeResults.visitID == origin.visit
    }

    func isHomeOperationOriginCurrent(_ origin: HomeOperationOrigin) -> Bool {
        guard isHomeOperationPageCurrent(origin), homeResultScope == origin.scope, origin.complete,
              activeTab.homeResults.operationGeneration == origin.generation,
              activeTab.homeResults.selection.selectedIDs.count == origin.occurrences.count else { return false }
        if origin.occurrences.isEmpty { return true }
        guard activeTab.homeResults.scope == origin.scope else { return false }
        let results = activeTab.homeResults
        for member in origin.occurrences {
            guard results.selection.selectedIDs.contains(member.row.id),
                  results.membership(of: member.row) == member.membership,
                  let target = results.target(of: member.row),
                  member.identity == nil || member.identity == target.identity,
                  member.row.recent.map(recentDocuments.contains) != false else { return false }
        }
        return true
    }

    var canAttemptHomeOperation: Bool {
        canAttemptHomeDestination && homeFileOperations.prepared?.sourceError == nil
    }

    var canAttemptHomeDestination: Bool {
        guard isCommandIdle, let origin = homeFileOperations.origin, !homeFileOperations.unavailable,
              (1...1_024).contains(origin.selectedUniqueCount) else { return false }
        guard isHomeOperationOriginCurrent(origin) else { return false }
        return homeFileOperations.prepared.map { agreesWithVisibleProofs($0.byPath, origin: origin) } ?? true
    }

    private func agreesWithVisibleProofs(_ byPath: [Data: TransferEntry], origin: HomeOperationOrigin) -> Bool {
        byPath.count == origin.selectedUniqueCount && origin.occurrences.allSatisfy { member in
            guard let entry = byPath[HomeFileLocations.pathKey(member.row.url)] else { return false }
            if member.row.recent != nil { return true }
            let now = activeTab.homeResults.target(of: member.row)?.identity
            return now == nil || now == entry.item.identity
        }
    }

    var homeOperationEntries: [TransferEntry]? {
        guard homeFileOperations.prepared?.sourceError == nil else { return nil }
        return homeDestinationEntries
    }

    private var homeDestinationEntries: [TransferEntry]? {
        guard let origin = homeFileOperations.origin, isHomeOperationOriginCurrent(origin),
              let prepared = homeFileOperations.prepared, agreesWithVisibleProofs(prepared.byPath, origin: origin) else { return nil }
        return prepared.entries
    }

    func updateHomeOperationSelection() {
        let state = homeFileOperations
        if state.activeTab != activeTabID {
            state.activeTab = activeTabID
            state.activation = UUID()
        }
        if let before = state.origin, homeResultScope == before.scope,
           state.activation == before.activation, activeTab.homeResults.operationGeneration == before.generation,
           activeTab.homeResults.visitID == before.visit { return }
        let next = homeOperationOrigin
        if next == nil && state.origin == nil { return }
        state.preparation?.cancel(); state.command?.cancel()
        state.origin = next; state.prepared = nil; state.unavailable = false
        state.command = nil; state.commandID = nil; state.preparation = nil
        guard let next, !next.occurrences.isEmpty, isHomeOperationOriginCurrent(next) else { return }
        guard let targets = try? HomeFileOperationSampler.targets(in: next) else { state.unavailable = true; return }
        let read = readHomeOperationEntry
        let task = Task { try await HomePreparedSelection(targets: targets, reading: read) }
        state.preparation = task
        Task { [weak self] in
            await self?.finishHomeSelectionPreparation(for: next)
        }
    }

    /// A first context click and the selection observer consume the same sample.
    func finishHomeSelectionPreparation(for origin: HomeOperationOrigin) async {
        let state = homeFileOperations
        guard isHomeOperationOriginCurrent(origin), state.prepared == nil, !state.unavailable,
              let task = state.preparation else { return }
        let prepared = try? await task.value
        guard !Task.isCancelled, !task.isCancelled, isHomeOperationOriginCurrent(origin),
              state.prepared == nil, !state.unavailable else { return }
        objectWillChange.send()
        if let prepared, agreesWithVisibleProofs(prepared.byPath, origin: origin) {
            state.prepared = prepared
            adoptHomeOperationProofs(prepared, origin: origin)
        } else { state.unavailable = true }
    }

    private func adoptHomeOperationProofs(_ prepared: HomePreparedSelection, origin: HomeOperationOrigin) {
        var documents: [Data: RecentDocument] = [:]
        guard let index = tabs.firstIndex(where: { $0.id == origin.scope.tabID }) else { return }
        var results = tabs[index].homeResults, changed = false
        for member in origin.occurrences {
            let key = HomeFileLocations.pathKey(member.row.url)
            if let recent = member.row.recent { documents[key] = recent; continue }
            guard let item = prepared.byPath[key]?.item, let identity = item.identity,
                  let target = results.target(of: member.row), target.identity == nil || target.identity == identity else { continue }
            if results.bind(identity, for: member.row, isSymbolicLink: item.isSymbolicLink) { changed = true }
        }
        recentDocuments.rememberSourceEntries(prepared.entries, represented: documents)
        if changed { tabs[index].homeResults = results }
    }

    func verifiedHomeOperationEntries(for origin: HomeOperationOrigin) async throws -> [TransferEntry] {
        guard isHomeOperationOriginCurrent(origin), let pending = homeFileOperations.preparation else { throw ItemContentError.staleSource }
        let prepared = try await pending.value
        if let error = prepared.sourceError { throw error }
        let entries: [TransferEntry]
        do { entries = try await verifiedHomeDestinationEntries(for: origin) }
        catch {
            if !Task.isCancelled, !(error is CancellationError), isHomeOperationOriginCurrent(origin) {
                objectWillChange.send()
                homeFileOperations.unavailable = true
                homeFileOperations.prepared = nil
            }
            throw error
        }
        try await LocalFileTransferImporter.validateSelectionRelationships(entries)
        try Task.checkCancellation()
        guard isHomeOperationOriginCurrent(origin), agreesWithVisibleProofs(prepared.byPath, origin: origin) else { throw ItemContentError.staleSource }
        return entries
    }

    /// A failed destination probe refuses this offer. Each subsequent command
    /// independently compares freshly sampled entries to the original proofs.
    func verifiedHomeDestinationEntries(for origin: HomeOperationOrigin) async throws -> [TransferEntry] {
        guard isHomeOperationOriginCurrent(origin), let cached = homeFileOperations.origin,
              !homeFileOperations.unavailable, cached.hasSameSelection(as: origin),
              let pending = homeFileOperations.preparation else { throw ItemContentError.staleSource }
        let original = try await pending.value.byPath
        try Task.checkCancellation()
        guard isHomeOperationOriginCurrent(origin), agreesWithVisibleProofs(original, origin: origin) else { throw ItemContentError.staleSource }
        let targets = try HomeFileOperationSampler.targets(in: origin)
        let current = try await HomeFileOperationSampler.sample(targets, reading: readHomeOperationEntry)
        try Task.checkCancellation()
        guard let fresh = HomeFileOperationSampler.indexedEntries(current), fresh.count == original.count,
              fresh.allSatisfy({ key, entry in original[key].map { HomeFileOperationSampler.agrees($0, entry) } == true }),
              isHomeOperationOriginCurrent(origin), agreesWithVisibleProofs(fresh, origin: origin) else { throw ItemContentError.staleSource }
        return current
    }

    func performVerifiedHomeCommand(_ action: @escaping @MainActor (ExplorerStore, [TransferEntry], HomeOperationOrigin) -> Void) {
        guard canAttemptHomeOperation, let origin = homeOperationOrigin else { return }
        let state = homeFileOperations, id = UUID()
        state.command?.cancel(); state.commandID = id
        state.command = Task { [weak self] in
            guard let self else { return }
            defer { if self.homeFileOperations.commandID == id { self.homeFileOperations.command = nil } }
            do {
                let entries = try await self.verifiedHomeOperationEntries(for: origin)
                guard !Task.isCancelled, self.isCommandIdle, self.homeFileOperations.commandID == id else { return }
                action(self, entries, origin)
            } catch {
                if !Task.isCancelled, self.isHomeOperationOriginCurrent(origin), self.homeFileOperations.commandID == id {
                    self.reportHomeOperationFailure(error)
                }
            }
        }
    }

    static func homeDestination(for entries: [TransferEntry]) -> HomeOperationDestination {
        var result: FileOperationContext?
        for entry in entries {
            let candidate: FileOperationContext
            if entry.item.isDirectory && !entry.item.isSymbolicLink {
                guard let identity = entry.item.identity else { return .unavailable }
                candidate = FileOperationContext(directoryURL: entry.item.url, directoryIdentity: identity)
            } else { candidate = entry.source }
            if let result, result.directoryIdentity != candidate.directoryIdentity { return .chooseFolder }
            if result == nil { result = candidate }
        }
        return result.map(HomeOperationDestination.folder) ?? .chooseFolder
    }

    var homeDestination: HomeOperationDestination? {
        guard let origin = homeOperationOrigin else { return nil }
        guard isHomeOperationOriginCurrent(origin) else { return .unavailable }
        if origin.selectedUniqueCount == 0 { return .chooseFolder }
        return homeDestinationEntries.map(Self.homeDestination(for:)) ?? .unavailable
    }

    func homeSourcesDidLeave(_ entries: [TransferEntry]) {
        var represented: [Data: RecentDocument] = [:]
        if let origin = homeFileOperations.origin, let before = homeFileOperations.prepared?.byPath {
            let docs = origin.occurrences.compactMap(\.row.recent)
            for entry in entries {
                let key = HomeFileLocations.pathKey(entry.item.url)
                guard before[key].map({ HomeFileOperationSampler.agrees($0, entry) }) == true else { continue }
                represented[key] = docs.first { HomeFileLocations.pathKey($0.url) == key }
            }
        }
        recentDocuments.retireDeparted(entries, represented: represented)
    }

    func retireDepartedHomeRows(_ entries: [TransferEntry]) {
        guard let departed = HomeFileOperationSampler.indexedEntries(entries) else { return }
        var updated = tabs
        var changed = false
        for index in updated.indices {
            var results = updated[index].homeResults
            guard let scope = results.scope else { continue }
            let kept = results.rows.filter { row in
                guard let identity = departed[HomeFileLocations.pathKey(row.url)]?.item.identity else { return true }
                if let recent = row.recent { return recentDocuments.contains(recent) }
                return results.target(of: row)?.identity != identity
            }
            guard kept.count != results.rows.count else { continue }
            results.replace(kept, scope: scope)
            updated[index].homeResults = results
            changed = true
        }
        if changed { tabs = updated }
    }
}
