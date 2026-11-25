import Darwin
import Foundation
import UniformTypeIdentifiers

// NATIVE-P14 / FR-SEARCH-001–004, UI-SEARCH-001; EV-0343–0351, EV-9001/9004;
// AT-SEARCH-001–004, AT-UISEARCH-001. MAC-062–065 define the native policy:
// bounded, read-only filename matching over listing metadata. No content,
// index, wildcard or provider hydration is involved.

public enum SearchScope: String, CaseIterable, Sendable {
    case allSubfolders, currentFolder

    public var title: String {
        switch self {
        case .allSubfolders: return "All subfolders"
        case .currentFolder: return "Current folder"
        }
    }
}

/// Kind categories derive from the filename extension only (MAC-063).
public enum SearchKindFilter: String, CaseIterable, Sendable {
    case folder, document, picture, video, music, archive, application, link, other

    public var title: String {
        switch self {
        case .folder: return "Folder"
        case .document: return "Document"
        case .picture: return "Picture"
        case .video: return "Video"
        case .music: return "Music"
        case .archive: return "Archive"
        case .application: return "Application"
        case .link: return "Link"
        case .other: return "Other"
        }
    }

    public static func category(of item: FileItem) -> SearchKindFilter {
        if item.isSymbolicLink || item.kind == "Alias" { return .link }
        if item.isDirectory { return .folder }
        let pathExtension = item.url.pathExtension
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle)
            || type.conforms(to: .unixExecutable) { return .application }
        if type.conforms(to: .image) { return .picture }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent)
            || type.conforms(to: .rtf) { return .document }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        return .other
    }
}

public enum SearchDateFilter: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisYear: return "This year"
        case .lastYear: return "Last year"
        }
    }

    /// Half-open calendar interval containing matching modification dates.
    public func interval(relativeTo reference: Date, calendar: Calendar) -> DateInterval? {
        func period(_ component: Calendar.Component, offset: Int) -> DateInterval? {
            guard let current = calendar.dateInterval(of: component, for: reference) else { return nil }
            guard offset != 0 else { return current }
            // The instant before the current period starts lies in the previous period.
            return calendar.dateInterval(of: component, for: current.start.addingTimeInterval(-1))
        }
        switch self {
        case .today: return period(.day, offset: 0)
        case .yesterday: return period(.day, offset: -1)
        case .thisWeek: return period(.weekOfYear, offset: 0)
        case .lastWeek: return period(.weekOfYear, offset: -1)
        case .thisMonth: return period(.month, offset: 0)
        case .lastMonth: return period(.month, offset: -1)
        case .thisYear: return period(.year, offset: 0)
        case .lastYear: return period(.year, offset: -1)
        }
    }
}

/// Native size buckets over regular-file byte counts, 1 KB = 1,024 bytes.
public enum SearchSizeFilter: String, CaseIterable, Sendable {
    case empty, tiny, small, medium, large, huge, gigantic

    public var title: String {
        switch self {
        case .empty: return "Empty (0 KB)"
        case .tiny: return "Tiny (0 – 16 KB)"
        case .small: return "Small (16 KB – 1 MB)"
        case .medium: return "Medium (1 – 128 MB)"
        case .large: return "Large (128 MB – 1 GB)"
        case .huge: return "Huge (1 – 4 GB)"
        case .gigantic: return "Gigantic (> 4 GB)"
        }
    }

    public func contains(_ bytes: Int64) -> Bool {
        let kilobyte: Int64 = 1_024
        let megabyte = kilobyte * 1_024
        let gigabyte = megabyte * 1_024
        switch self {
        case .empty: return bytes == 0
        case .tiny: return bytes > 0 && bytes <= 16 * kilobyte
        case .small: return bytes > 16 * kilobyte && bytes <= megabyte
        case .medium: return bytes > megabyte && bytes <= 128 * megabyte
        case .large: return bytes > 128 * megabyte && bytes <= gigabyte
        case .huge: return bytes > gigabyte && bytes <= 4 * gigabyte
        case .gigantic: return bytes > 4 * gigabyte
        }
    }
}

public struct SearchFilters: Equatable, Sendable {
    public var kind: SearchKindFilter?
    public var dateModified: SearchDateFilter?
    public var size: SearchSizeFilter?

    public init(kind: SearchKindFilter? = nil, dateModified: SearchDateFilter? = nil, size: SearchSizeFilter? = nil) {
        self.kind = kind
        self.dateModified = dateModified
        self.size = size
    }

    public var isEmpty: Bool { kind == nil && dateModified == nil && size == nil }
}

public struct FilenameSearchQuery: Equatable, Sendable {
    public let text: String
    public let terms: [String]
    public var scope: SearchScope
    public var filters: SearchFilters

    /// Returns nil for text without a searchable term.
    public init?(text: String, scope: SearchScope = .allSubfolders, filters: SearchFilters = SearchFilters()) {
        let terms = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !terms.isEmpty, !text.contains("\0") else { return nil }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.terms = terms
        self.scope = scope
        self.filters = filters
    }

    public func matchesName(_ name: String) -> Bool {
        terms.allSatisfy { term in
            name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }
}

/// Precomputes the date interval once per run so every entry uses one reference time.
public struct FilenameSearchMatcher: Sendable {
    public let query: FilenameSearchQuery
    private let dateInterval: DateInterval?

    public init(query: FilenameSearchQuery, referenceDate: Date, calendar: Calendar) {
        self.query = query
        dateInterval = query.filters.dateModified?.interval(relativeTo: referenceDate, calendar: calendar)
    }

    public func matches(_ item: FileItem) -> Bool {
        guard query.matchesName(item.name) else { return false }
        let filters = query.filters
        if let kind = filters.kind, SearchKindFilter.category(of: item) != kind { return false }
        if filters.dateModified != nil {
            guard let interval = dateInterval, let modified = item.modifiedAt,
                  modified >= interval.start, modified < interval.end else { return false }
        }
        if let size = filters.size {
            guard !item.isDirectory, !item.isSymbolicLink, let bytes = item.size, size.contains(bytes) else { return false }
        }
        return true
    }
}

/// A result is display-only unless both its own identity and the identity of
/// the enumerated parent were sampled (MAC-062/065).
public struct FilenameSearchResult: Identifiable, Equatable, Sendable {
    public let item: FileItem
    public let parent: FileOperationContext?
    public var id: String { item.id }

    public init(item: FileItem, parent: FileOperationContext?) {
        self.item = item
        self.parent = parent
    }

    public var supportsOperations: Bool { item.identity != nil && parent != nil }
}

/// Every nonzero exclusion makes a finished run partial rather than complete.
public struct SearchCoverage: Equatable, Sendable {
    public static let sampleLimit = 5
    public var foldersSearched = 0
    public var unreadableFolders = 0
    public var changedFolders = 0
    public var otherVolumeFolders = 0
    public var unavailableFolders = 0
    public var depthLimitedFolders = 0
    public var reachedResultLimit = false
    public var unreadableSamples: [URL] = []
    public var accessFailure: FileAccessFailure?

    public init() {}

    public var isComplete: Bool {
        unreadableFolders == 0 && changedFolders == 0 && otherVolumeFolders == 0
            && unavailableFolders == 0 && depthLimitedFolders == 0 && !reachedResultLimit
    }
}

public enum FilenameSearchEvent: Sendable {
    /// Newly found results since the previous event plus cumulative coverage.
    case progress(results: [FilenameSearchResult], coverage: SearchCoverage)
    case finished(SearchCoverage)
}

public enum FilenameSearchError: LocalizedError, Equatable, Sendable {
    case unsupportedLocation
    case notFolder
    case notLocal
    case rootChanged

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation: return "Search is available only for local folder URLs."
        case .notFolder: return "This location is not a folder."
        case .notLocal: return "Search is available only on local volumes."
        case .rootChanged: return "The folder changed since it was displayed. Close search, refresh the folder and search again."
        }
    }
}

public struct FilenameSearchRequest: Sendable {
    public let root: URL
    public let rootIdentity: LocalFileIdentity
    public let query: FilenameSearchQuery
    public let showHidden: Bool
    public let referenceDate: Date
    public let calendar: Calendar
    public let resultLimit: Int

    public init(root: URL, rootIdentity: LocalFileIdentity, query: FilenameSearchQuery, showHidden: Bool,
                referenceDate: Date = Date(), calendar: Calendar = .current, resultLimit: Int = 10_000) {
        self.root = root
        self.rootIdentity = rootIdentity
        self.query = query
        self.showHidden = showHidden
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.resultLimit = max(1, resultLimit)
    }
}

public protocol FilenameSearching: Sendable {
    /// Terminating the stream cancels the traversal. Errors describe an
    /// unavailable root; subtree failures are reported in coverage instead.
    func search(_ request: FilenameSearchRequest) -> AsyncThrowingStream<FilenameSearchEvent, Error>
}

/// MAC-063: breadth-first, no-follow traversal on the BlockingIO read lane.
public struct LocalFilenameSearcher: FilenameSearching {
    public static let maximumDepth = 64
    private let batchInterval: TimeInterval
    private let maximumDepth: Int

    public init() {
        batchInterval = 0.1
        maximumDepth = Self.maximumDepth
    }

    /// Test seam: deterministic emission and a small depth bound.
    init(batchInterval: TimeInterval, maximumDepth: Int = LocalFilenameSearcher.maximumDepth) {
        self.batchInterval = batchInterval
        self.maximumDepth = maximumDepth
    }

    public func search(_ request: FilenameSearchRequest) -> AsyncThrowingStream<FilenameSearchEvent, Error> {
        let batchInterval = self.batchInterval
        let maximumDepth = self.maximumDepth
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let coverage = try await BlockingIO.run(on: .read) { cancellation in
                        try Self.traverse(request, batchInterval: batchInterval, maximumDepth: maximumDepth,
                                          cancellation: cancellation) { results, coverage in
                            guard !cancellation.isCancelled else { return }
                            continuation.yield(.progress(results: results, coverage: coverage))
                        }
                    }
                    try Task.checkCancellation()
                    continuation.yield(.finished(coverage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct PendingDirectory {
        let displayURL: URL
        let realURL: URL
        let identity: LocalFileIdentity
        let depth: Int
    }

    static func traverse(_ request: FilenameSearchRequest, batchInterval: TimeInterval, maximumDepth: Int,
                         cancellation: BlockingIOCancellation,
                         emit: ([FilenameSearchResult], SearchCoverage) -> Void) throws -> SearchCoverage {
        // Provider placeholders must not download while being searched (MAC-063).
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previousPolicy >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
        }
        try cancellation.checkCancellation()
        let root = request.root
        guard root.isFileURL, root.host == nil || root.host == "" || root.host?.lowercased() == "localhost",
              !root.path.contains("\0") else { throw FilenameSearchError.unsupportedLocation }
        let lexicalRoot = root.standardizedFileURL
        let resolvedRoot = try FileSystemPath.resolvingExisting(lexicalRoot)
        let rootValues = try resolvedRoot.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard rootValues.isDirectory == true else { throw FilenameSearchError.notFolder }
        guard rootValues.volumeIsLocal == true else { throw FilenameSearchError.notLocal }
        guard let rootIdentity = try LocalFileIdentity.read(at: resolvedRoot, ifLocal: true),
              rootIdentity == request.rootIdentity else { throw FilenameSearchError.rootChanged }

        let matcher = FilenameSearchMatcher(query: request.query, referenceDate: request.referenceDate,
                                            calendar: request.calendar)
        let recursive = request.query.scope == .allSubfolders
        let options: FileManager.DirectoryEnumerationOptions = request.showHidden ? [] : [.skipsHiddenFiles]
        let manager = FileManager()
        var coverage = SearchCoverage()
        var visited: Set<LocalFileIdentity> = [rootIdentity]
        var queue = [PendingDirectory(displayURL: lexicalRoot, realURL: resolvedRoot, identity: rootIdentity, depth: 0)]
        var head = 0
        var pending: [FilenameSearchResult] = []
        var emittedCount = 0
        var lastEmission = Date()
        var lastEmittedFolders = 0

        func flush(force: Bool) {
            let due = Date().timeIntervalSince(lastEmission) >= batchInterval
            guard force || due, !pending.isEmpty || coverage.foldersSearched != lastEmittedFolders else { return }
            emit(pending, coverage)
            emittedCount += pending.count
            pending.removeAll(keepingCapacity: true)
            lastEmission = Date()
            lastEmittedFolders = coverage.foldersSearched
        }

        func recordUnreadable(_ url: URL, _ error: Error) {
            coverage.unreadableFolders += 1
            if coverage.unreadableSamples.count < SearchCoverage.sampleLimit { coverage.unreadableSamples.append(url) }
            if coverage.accessFailure == nil { coverage.accessFailure = FileAccessFailure.classify(error) }
        }

        while head < queue.count {
            try cancellation.checkCancellation()
            let directory = queue[head]
            head += 1
            if head >= 4_096 {
                queue.removeFirst(head)
                head = 0
            }
            let isRoot = directory.depth == 0
            if !isRoot {
                // The directory must still be the exact no-follow entry that was queued.
                guard let sample = Self.lstatSample(directory.realURL), sample.isDirectory,
                      sample.identity == directory.identity else {
                    coverage.changedFolders += 1
                    continue
                }
            }
            let urls: [URL]
            do {
                urls = try manager.contentsOfDirectory(at: directory.realURL,
                    includingPropertiesForKeys: Array(LocalDirectoryLoader.entryKeys.union(LocalDirectoryLoader.presentationKeys)),
                    options: options)
            } catch {
                if isRoot { throw error }
                if FileAccessFailure.isMissingLocation(error) { coverage.changedFolders += 1 }
                else { recordUnreadable(directory.displayURL, error) }
                continue
            }
            let parent = FileOperationContext(directoryURL: directory.displayURL, directoryIdentity: directory.identity)
            var found: [FilenameSearchResult] = []
            var children: [(item: FileItem, realURL: URL)] = []
            var unclassified: [URL] = []
            // Deterministic order makes first-visit wins (for firmlinks and other
            // aliases of one directory) and batch contents reproducible.
            for entryURL in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try cancellation.checkCancellation()
                let sample = LocalDirectoryLoader.sample(for: entryURL, displayedIn: directory.displayURL,
                                                         supportsLocalIdentity: true, readCloudMetadata: false)
                let item = sample.item
                if matcher.matches(item) {
                    found.append(FilenameSearchResult(item: item, parent: item.identity == nil ? nil : parent))
                }
                if recursive, item.isDirectory, !item.isSymbolicLink { children.append((item, entryURL)) }
                else if recursive, !sample.structureKnown, !item.isSymbolicLink,
                        Self.lstatSample(entryURL)?.isDirectory != false {
                    // A possible folder whose structure could not be read is not
                    // silently treated as searched (MAC-063).
                    unclassified.append(item.url)
                }
            }
            try cancellation.checkCancellation()
            // Discard a directory that changed while it was being enumerated.
            let unchanged: Bool
            if isRoot {
                if let resolvedAfter = try? FileSystemPath.resolvingExisting(lexicalRoot) {
                    unchanged = resolvedAfter.path == resolvedRoot.path
                        && (try? LocalFileIdentity.read(at: resolvedAfter, ifLocal: true)) == rootIdentity
                } else { unchanged = false }
                guard unchanged else { throw FilenameSearchError.rootChanged }
            } else {
                unchanged = Self.lstatSample(directory.realURL).map { $0.isDirectory && $0.identity == directory.identity } ?? false
                guard unchanged else { coverage.changedFolders += 1; continue }
            }
            coverage.foldersSearched += 1
            for url in unclassified {
                coverage.unreadableFolders += 1
                if coverage.unreadableSamples.count < SearchCoverage.sampleLimit { coverage.unreadableSamples.append(url) }
            }
            for result in found {
                guard emittedCount + pending.count < request.resultLimit else {
                    coverage.reachedResultLimit = true
                    break
                }
                pending.append(result)
            }
            if coverage.reachedResultLimit {
                flush(force: true)
                return coverage
            }
            for child in children {
                guard let identity = child.item.identity else { coverage.unavailableFolders += 1; continue }
                guard identity.device == rootIdentity.device else { coverage.otherVolumeFolders += 1; continue }
                guard !visited.contains(identity) else { continue }
                guard directory.depth + 1 <= maximumDepth else { coverage.depthLimitedFolders += 1; continue }
                guard let sample = Self.lstatSample(child.realURL), sample.isDirectory,
                      sample.identity == identity else { coverage.changedFolders += 1; continue }
                guard !sample.isDataless else { coverage.unavailableFolders += 1; continue }
                visited.insert(identity)
                queue.append(PendingDirectory(displayURL: child.item.url, realURL: child.realURL,
                                              identity: identity, depth: directory.depth + 1))
            }
            flush(force: false)
        }
        try cancellation.checkCancellation()
        // Results remain under the displayed spelling only while it still names the root.
        guard let resolvedAfter = try? FileSystemPath.resolvingExisting(lexicalRoot),
              resolvedAfter.path == resolvedRoot.path,
              (try? LocalFileIdentity.read(at: resolvedAfter, ifLocal: true)) == rootIdentity else {
            throw FilenameSearchError.rootChanged
        }
        flush(force: true)
        return coverage
    }

    private struct EntrySample {
        let identity: LocalFileIdentity?
        let isDirectory: Bool
        let isDataless: Bool
    }

    private static func lstatSample(_ url: URL) -> EntrySample? {
        var value = stat()
        var path = url.path
        // A trailing slash would make lstat follow a final-component symlink.
        while path.count > 1 && path.last == "/" { path.removeLast() }
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        return EntrySample(identity: LocalFileIdentity.fromStat(value),
                           isDirectory: value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                           isDataless: value.st_flags & UInt32(SF_DATALESS) != 0)
    }
}

/// MAC-065: before opening a result or its location, confirm on the read lane
/// that the lexical parent still resolves to the sampled parent identity and
/// that the named no-follow entry still has the sampled entry identity. This
/// narrows, but cannot remove, a race with later external changes.
public enum FilenameSearchValidation {
    public static func isCurrent(_ result: FilenameSearchResult) async throws -> Bool {
        let value = try await BlockingIO.run(on: .read) { cancellation -> Bool in
            try cancellation.checkCancellation()
            guard let parent = result.parent, let expected = result.item.identity,
                  result.item.name == result.item.url.lastPathComponent,
                  result.item.url.deletingLastPathComponent().standardizedFileURL.path
                    == parent.directoryURL.standardizedFileURL.path else { return false }
            guard let resolvedParent = try? FileSystemPath.resolvingExisting(parent.directoryURL),
                  (try? LocalFileIdentity.read(at: resolvedParent, ifLocal: true)) == parent.directoryIdentity else {
                return false
            }
            var sample = stat()
            let entryPath = resolvedParent.appendingPathComponent(result.item.name).path
            guard entryPath.withCString({ Darwin.lstat($0, &sample) }) == 0 else { return false }
            return LocalFileIdentity.fromStat(sample) == expected
        }
        try Task.checkCancellation()
        return value
    }
}
