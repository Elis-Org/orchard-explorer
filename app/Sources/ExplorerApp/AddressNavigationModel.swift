import Combine
import ExplorerCore
import Foundation

@MainActor
final class RecentAddressHistory: ObservableObject {
    @Published private(set) var entries: [URL] = []

    func record(_ url: URL) {
        guard let location = BrowsingLocation(url: url), BrowserPage(url: url) == nil else { return }
        let remaining = entries.filter { BrowsingLocation(url: $0) != location }
        let candidate = [location.url] + remaining.prefix(19)
        if candidate != entries { entries = candidate }
    }

    func clear() { entries = [] }
}

/// NATIVE-P11 / MAC-052–055. Completion and recent-address semantics are native
/// choices; UI-NAV-002 / EV-0404–0406 establishes only context-menu presence.
@MainActor
final class AddressNavigationModel: ObservableObject {
    enum Presentation: Equatable {
        case completion
        case children(URL)
        case history
    }

    @Published private(set) var isEditing = false
    @Published private(set) var text = ""
    @Published private(set) var presentation: Presentation?
    @Published private(set) var suggestions: [URL] = []
    @Published private(set) var highlightedIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTruncated = false
    var recentAddresses: [URL] { recentHistory.entries }
    private(set) var requestID = UUID()
    private let suggester: any FolderSuggesting
    private let debounce: Duration
    private let recentHistory: RecentAddressHistory
    private var recentHistorySubscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var submissionTask: Task<Void, Never>?
    private var editingLocation: URL?

    init(suggester: any FolderSuggesting = LocalFolderSuggester(),
         debounce: Duration = .milliseconds(120), recentHistory: RecentAddressHistory? = nil) {
        self.suggester = suggester
        self.debounce = debounce
        self.recentHistory = recentHistory ?? RecentAddressHistory()
        recentHistorySubscription = self.recentHistory.$entries.dropFirst().sink { [weak self] _ in
            guard let self, self.presentation == .history else { return }
            self.dismissPopup()
        }
    }

    deinit {
        task?.cancel()
        submissionTask?.cancel()
    }

    func beginEditing(at url: URL) {
        cancel()
        editingLocation = url
        text = BrowsingPresentation.path(url)
        isEditing = true
    }

    func updateText(_ value: String, showHidden: Bool) {
        guard isEditing else { return }
        text = value
        let query = Self.completionQuery(value, relativeTo: editingLocation ?? URL(fileURLWithPath: "/"))
        guard let query else {
            dismissPopup()
            return
        }
        request(.completion, directory: query.directory, prefix: query.prefix,
                showHidden: showHidden, delay: debounce)
    }

    func showChildren(of url: URL, showHidden: Bool) {
        guard BrowserPage(url: url) == nil else { return }
        isEditing = false
        request(.children(url), directory: url, prefix: "", showHidden: showHidden, delay: .zero)
    }

    func showHistory() {
        dismissPopup()
        isEditing = false
        presentation = .history
        suggestions = recentAddresses
    }

    func dismissPopup() {
        requestID = UUID()
        task?.cancel()
        task = nil
        presentation = nil
        suggestions = []
        highlightedIndex = nil
        isLoading = false
        errorMessage = nil
        isTruncated = false
    }

    func cancel() {
        cancelPendingSubmission()
        dismissPopup()
        isEditing = false
        editingLocation = nil
    }

    func highlight(_ index: Int?) {
        highlightedIndex = index.flatMap { suggestions.indices.contains($0) ? $0 : nil }
    }

    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let initial = delta < 0 ? suggestions.count : -1
        highlight(min(suggestions.count - 1, max(0, (highlightedIndex ?? initial) + delta)))
    }

    /// A popup action must retain the generation it displayed, not read a newer
    /// result's index. This also rejects delayed clicks after cancellation.
    func suggestion(at index: Int, requestID: UUID) -> URL? {
        guard self.requestID == requestID, presentation != nil, !isLoading,
              suggestions.indices.contains(index) else { return nil }
        return suggestions[index]
    }

    @discardableResult
    func completeHighlighted(showHidden: Bool) -> Bool {
        guard isEditing, presentation == .completion, let index = highlightedIndex,
              let url = suggestion(at: index, requestID: requestID) else { return false }
        let path = BrowsingPresentation.path(url)
        updateText(path == "/" ? "/" : path + "/", showHidden: showHidden)
        return true
    }

    func submissionURL(relativeTo directory: URL) -> URL? {
        guard isEditing else { return nil }
        do {
            return try AddressPath.resolve(text, relativeTo: directory)
        } catch {
            // Keep the editor and its text so an invalid Enter is visible and
            // correctable. Cancel pending completion callbacks before publishing.
            dismissPopup()
            presentation = .completion
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resolveSubmission<Value: Sendable>(_ url: URL,
                           using resolve: @escaping @Sendable (URL) async throws -> Value,
                           receive: @escaping @MainActor (Result<Value, Error>) -> Void) {
        cancelPendingSubmission()
        submissionTask = Task { [weak self] in
            let result: Result<Value, Error>
            do { result = .success(try await resolve(url)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            self.submissionTask = nil
            receive(result)
        }
    }

    func cancelPendingSubmission() {
        submissionTask?.cancel()
        submissionTask = nil
    }

    func recordSuccessfulSubmission(_ url: URL) {
        recentHistory.record(url)
    }

    func clearHistory() {
        recentHistory.clear()
        if presentation == .history { dismissPopup() }
    }

    static func completionQuery(_ text: String) -> (directory: URL, prefix: String)? {
        completionQuery(text, relativeTo: URL(fileURLWithPath: "/"))
    }

    private static func completionQuery(_ text: String, relativeTo location: URL) -> (directory: URL, prefix: String)? {
        guard !text.isEmpty, !text.contains("\0") else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), let resolved = try? AddressPath.resolve(text, relativeTo: location),
              let destination = BrowsingLocation(url: resolved) else { return nil }
        // NSString expansion removes a trailing slash even without a tilde.
        // Retain the user's directory delimiter and dot segment before expansion.
        let last = text.split(separator: "/").last
        if text.hasSuffix("/") || last == "." || last == ".." || destination.parentURL == nil
            || ArchiveLocation(url: resolved)?.components.isEmpty == true {
            return (resolved, "")
        }
        guard let parent = destination.parentURL else { return nil }
        return (parent, destination.name)
    }

    private func request(_ presentation: Presentation, directory: URL, prefix: String,
                         showHidden: Bool, delay: Duration) {
        dismissPopup()
        self.presentation = presentation
        isLoading = true
        let generation = requestID
        let suggester = suggester
        task = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                let result = try await suggester.folders(in: directory, prefix: prefix, showHidden: showHidden)
                guard !Task.isCancelled, let self, self.requestID == generation else { return }
                self.suggestions = result.urls.filter { BrowserPage(url: $0) == nil }
                self.isTruncated = result.isTruncated
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.requestID == generation else { return }
                self.errorMessage = "Couldn’t list folders. \(error.localizedDescription)"
                self.isLoading = false
                self.task = nil
            }
        }
    }
}

/// Address text is a user-editable lexical path. ZIP directory records and the
/// canonical virtual URL decoder deliberately do not use this normalization.
private enum AddressPath {
    enum Failure: LocalizedError {
        case unsupportedArchivePath
        var errorDescription: String? {
            switch self {
            case .unsupportedArchivePath: return "This ZIP folder address is not supported. Check the folder names and remove any backslashes."
            }
        }
    }

    static func resolve(_ text: String, relativeTo directory: URL) throws -> URL {
        guard let current = BrowsingLocation(url: directory) else { throw LocalPathInput.Failure.invalid }
        let parsed = try LocalPathInput.parse(text, relativeToPath: BrowserPage(url: directory) == nil ? current.displayPath : nil)
        let parts = parsed.components
        // Only the known current container supplies an archive boundary. Exact
        // component bytes distinguish similarly prefixed and Unicode names.
        if !parsed.isExplicitFileURL, case .archive(let archive) = current {
            let boundary = archive.archiveURL.path.split(separator: "/").map(String.init)
            if parts.count >= boundary.count,
               zip(parts, boundary).allSatisfy({ Data($0.utf8) == Data($1.utf8) }) {
                do {
                    return try ArchiveLocation(archiveURL: archive.archiveURL,
                        components: Array(parts.dropFirst(boundary.count))).url
                } catch { throw Failure.unsupportedArchivePath }
            }
        }
        return parsed.url
    }
}
