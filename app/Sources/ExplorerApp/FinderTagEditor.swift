import Combine
import ExplorerCore
import Foundation

@MainActor
final class FinderTagEditor: ObservableObject {
    struct Target: Sendable {
        let url: URL
        let identity: LocalFileIdentity
    }

    enum State: String { case none = "None", some = "Some", all = "All" }

    let targets: [Target]
    private let originIsCurrent: () -> Bool
    private var files: [URL: FinderTagFile] = [:]
    private var remaining: [Target]
    private var work: Task<Void, Never>?
    @Published var query = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isApplying = false
    @Published private(set) var submitted = false
    @Published private(set) var completed = 0
    @Published private(set) var failures: [URL: String] = [:]
    @Published private(set) var warnings: [URL: String] = [:]
    @Published private(set) var originChanged = false
    @Published private var choices: [String: Bool] = [:]

    init(targets: [Target], originIsCurrent: @escaping () -> Bool) {
        self.targets = targets
        remaining = targets
        self.originIsCurrent = originIsCurrent
        work = Task { [weak self] in await self?.loadAssignments() }
    }

    var canApply: Bool {
        !isLoading && !isApplying && !originChanged && !remaining.isEmpty && !choices.isEmpty
    }

    func names(including suggestions: [String]) -> [String] {
        FinderTagsSnapshot.tagNames(from: suggestions + files.values.flatMap(\.names) + Array(choices.keys))
    }

    private func initialState(for name: String) -> State {
        let count = files.values.filter { $0.names.contains(name) }.count
        if count == 0 { return .none }
        return count == files.count ? .all : .some
    }

    func state(for name: String) -> State {
        if let selected = choices[name] { return selected ? .all : .none }
        return initialState(for: name)
    }

    func toggle(_ name: String) {
        guard !isLoading, !submitted, !originChanged, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let initial = initialState(for: name)
        if initial == .some, choices[name] == false { choices.removeValue(forKey: name); return }
        let selected = state(for: name) != .all
        if initial != .some, (initial == .all) == selected { choices.removeValue(forKey: name) }
        else { choices[name] = selected }
    }

    private func loadAssignments() async {
        for target in targets {
            guard !Task.isCancelled else { return }
            do { files[target.url] = try await FinderTagFile.read(at: target.url, expecting: target.identity) }
            catch { failures[target.url] = error.localizedDescription }
        }
        isLoading = false
    }

    func apply(finished: @escaping () -> Void) {
        guard canApply else { return }
        guard originIsCurrent() else { originChanged = true; return }
        submitted = true
        isApplying = true
        let adding = choices.filter(\.value).map(\.key).sorted()
        let removing = Set(choices.filter { !$0.value }.map(\.key))
        work = Task { [weak self] in
            guard let self else { return }
            var retry: [Target] = []
            for target in remaining {
                guard !Task.isCancelled else { return }
                do {
                    let file: FinderTagFile
                    if let loaded = files[target.url] { file = loaded }
                    else { file = try await FinderTagFile.read(at: target.url, expecting: target.identity) }
                    let result = try await file.apply(adding: adding, removing: removing)
                    if result.otherNamesChanged {
                        warnings[target.url] = "The requested tags were saved. Other tag assignments also changed."
                    }
                    failures.removeValue(forKey: target.url)
                    completed += 1
                } catch {
                    failures[target.url] = error.localizedDescription
                    retry.append(target)
                }
            }
            remaining = retry
            isApplying = false
            if retry.isEmpty && warnings.isEmpty { finished() }
        }
    }

    func cancel() { work?.cancel() }
}

extension ExplorerStore {
    var canEditSelectionTags: Bool {
        if homeResultScope != nil {
            return canAttemptHomeOperation
                && homeFileOperations.origin?.occurrences.contains(where: { activeTab.homeResults.isKnownSymbolicLink($0.row) }) != true
                && homeOperationEntries?.contains(where: { $0.item.isSymbolicLink }) != true
        }
        let items = presentationSelection
        return !activeTab.isLoading && !items.isEmpty && items.allSatisfy {
            BrowsingPresentation.isPhysical($0) && !$0.isSymbolicLink && $0.identity != nil
        }
    }

    func beginSelectionTagEditing() {
        guard canEditSelectionTags else { return }
        if homeResultScope != nil {
            performVerifiedHomeCommand { store, entries, origin in
                let targets = entries.compactMap { entry -> FinderTagEditor.Target? in
                    guard !entry.item.isSymbolicLink, let identity = entry.item.identity else { return nil }
                    return .init(url: entry.item.url, identity: identity)
                }
                guard targets.count == entries.count else { return }
                store.finderTagEditor = FinderTagEditor(targets: targets) { [weak store] in
                    store?.isHomeOperationOriginCurrent(origin) == true
                }
            }
            return
        }
        let items = selectedItemsInOrder
        let targets = items.compactMap { item in
            item.identity.map { FinderTagEditor.Target(url: item.url, identity: $0) }
        }
        guard targets.count == items.count, let first = items.first else { return }
        let origin = ContextMenuSnapshot(store: self, item: first)
        finderTagEditor = FinderTagEditor(targets: targets) { [weak self] in
            self.map(origin.matches) == true
        }
    }

    func cancelFinderTagEditing() {
        finderTagEditor?.cancel()
        finderTagEditor = nil
    }

    func applyFinderTagEdits() {
        guard let editor = finderTagEditor else { return }
        editor.apply { [weak self, weak editor] in
            guard let self, let editor, self.finderTagEditor === editor else { return }
            self.finderTagEditor = nil
        }
    }
}
