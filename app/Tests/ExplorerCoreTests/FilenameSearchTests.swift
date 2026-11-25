import Foundation
import Testing
@testable import ExplorerCore

/// NATIVE-P14 / FR-SEARCH-002/003/004; EV-0345–0351, EV-9004;
/// AT-SEARCH-002/003/004 (core filesystem analogues only), MAC-062/063/065.
/// No UI, visual, Windows-fidelity or full acceptance verdict is implied.
/// Disabled regressions were executed on macOS 26.7.1 / 25G241, arm64 / CLT:
/// localized type descriptions throw NSOSStatusErrorDomain -10813 while the
/// individual directory, size and mtime reads succeed. The bundled row read
/// discards those fields, preventing descent while claiming complete coverage.
/// Standard extension UTTypes also resolve dynamically in this environment.
final class FilenameSearchTests {
    private let root: URL
    private var permissionRestorations: [(URL, Int)] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        for (url, mode) in permissionRestorations.reversed() {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static var referenceDate: Date { date(2026, 11, 6, 12) }

    private static var sizeBoundaries: [(Int64, SearchSizeFilter)] {
        [(0, .empty), (1, .tiny), (16_384, .tiny), (16_385, .small),
         (1_048_576, .small), (1_048_577, .medium),
         (134_217_728, .medium), (134_217_729, .large),
         (1_073_741_824, .large), (1_073_741_825, .huge),
         (4_294_967_296, .huge), (4_294_967_297, .gigantic)]
    }

    private static var datePeriods: [(SearchDateFilter, Date, Date)] {
        [(.today, date(2026, 11, 6), date(2026, 11, 7)),
         (.yesterday, date(2026, 11, 5), date(2026, 11, 6)),
         (.thisWeek, date(2026, 11, 2), date(2026, 11, 9)),
         (.lastWeek, date(2026, 10, 26), date(2026, 11, 2)),
         (.thisMonth, date(2026, 11, 1), date(2026, 12, 1)),
         (.lastMonth, date(2026, 10, 1), date(2026, 11, 1)),
         (.thisYear, date(2026, 1, 1), date(2027, 1, 1)),
         (.lastYear, date(2025, 1, 1), date(2026, 1, 1))]
    }

    @discardableResult
    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Truncation creates sparse files, including GiB boundaries, without writing GiB payloads.
    @discardableResult
    private func file(_ path: String, bytes: Int64 = 1, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func denyPermissions(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        // Register restoration before changing the mode, including failed assertions/errors.
        permissionRestorations.append((url, mode))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    private static func identity(_ url: URL) throws -> LocalFileIdentity {
        try #require(try LocalFileIdentity.read(at: url, ifLocal: true))
    }

    private func request(_ text: String, scope: SearchScope = .allSubfolders,
                         filters: SearchFilters = SearchFilters(), showHidden: Bool = false,
                         searchRoot: URL? = nil, resultLimit: Int = 10_000) throws -> FilenameSearchRequest {
        let url = searchRoot ?? root
        return FilenameSearchRequest(root: url,
            rootIdentity: try Self.identity(url.resolvingSymlinksInPath()),
            query: try #require(FilenameSearchQuery(text: text, scope: scope, filters: filters)),
            showHidden: showHidden, referenceDate: Self.referenceDate,
            calendar: Self.calendar, resultLimit: resultLimit)
    }

    private struct Run: Sendable {
        var results: [FilenameSearchResult] = []
        var batches: [[FilenameSearchResult]] = []
        var progressCoverage: [SearchCoverage] = []
        var coverage = SearchCoverage()
    }

    /// Progress contains deltas; only the finished event supplies final coverage.
    private static func collect(_ request: FilenameSearchRequest,
                                searcher: LocalFilenameSearcher = LocalFilenameSearcher()) async throws -> Run {
        var run = Run()
        var finished = false
        for try await event in searcher.search(request) {
            #expect(!finished, "No events may follow the terminal coverage event")
            switch event {
            case .progress(let results, let coverage):
                run.results.append(contentsOf: results)
                run.batches.append(results)
                run.progressCoverage.append(coverage)
            case .finished(let coverage):
                finished = true
                run.coverage = coverage
            }
        }
        #expect(finished, "An uncancelled search must publish final coverage")
        return run
    }

    private enum Timeout: Error { case exceeded }

    /// Cancel the losing child so a nonterminating traversal cannot hang the test.
    private static func withinTenSeconds<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw Timeout.exceeded
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
    }

    private static func row(_ name: String = "needle.txt", directory: Bool = false,
                            link: Bool = false, size: Int64? = 1, modified: Date? = nil,
                            kind: String = "File") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/synthetic/\(name)"), name: name,
                 isDirectory: directory, isSymbolicLink: link, size: size,
                 modifiedAt: modified, kind: kind)
    }

    private static func matcher(_ text: String = "needle", filters: SearchFilters = SearchFilters()) throws
        -> FilenameSearchMatcher {
        FilenameSearchMatcher(query: try #require(FilenameSearchQuery(text: text, filters: filters)),
                              referenceDate: referenceDate, calendar: calendar)
    }

    private func expectResults(_ run: Run, _ paths: [String], under searchRoot: URL? = nil) {
        let base = searchRoot ?? root
        #expect(Set(run.results.map { $0.item.url.path }) == Set(paths.map { base.appendingPathComponent($0).path }))
        #expect(Set(run.results.map { $0.item.name }) == Set(paths.map { base.appendingPathComponent($0).lastPathComponent }))
        #expect(run.results.count == paths.count, "Exact sets must not conceal duplicate results")
    }

    /// NATIVE-P14 / FR-SEARCH-002/003/004; EV-0351; AT-SEARCH-002/003/004 core analogue.
    @Test
    func windowsEquivalentDescendantAndCurrentFolderScopesHaveExactResultsAndParentIdentity() async throws {
        let fixture = try directory("fixture")
        let hit = try file("fixture/Nested/Level 2/Level 3/needle-name.txt")
        try file("fixture/unrelated.txt")
        try file("fixture/Nested/needless.txt")
        try file("fixture/Nested/Level 2/name-only.txt")
        let recursive = try await Self.collect(request("needle-name", searchRoot: fixture))
        expectResults(recursive, ["Nested/Level 2/Level 3/needle-name.txt"], under: fixture)
        let result = try #require(recursive.results.first)
        #expect(result.item.url == hit)
        #expect(result.parent == FileOperationContext(directoryURL: hit.deletingLastPathComponent(),
            directoryIdentity: try Self.identity(hit.deletingLastPathComponent())))
        #expect(result.item.identity == (try Self.identity(hit)))
        #expect(result.supportsOperations)
        var expected = SearchCoverage()
        expected.foldersSearched = 4
        #expect(recursive.coverage == expected)
        #expect(recursive.coverage.isComplete)

        let current = try await Self.collect(request("needle-name", scope: .currentFolder, searchRoot: fixture))
        expectResults(current, [], under: fixture)
        expected.foldersSearched = 1
        #expect(current.coverage == expected)
        #expect(current.coverage.isComplete)
    }

    /// NATIVE-P14 / FR-SEARCH-003/004; EV-0351; AT-SEARCH-003/004 core empty-result subset.
    @Test
    func currentFolderScopeCompletesWithNoDescendantResults() async throws {
        let fixture = try directory("fixture")
        try file("fixture/Nested/Level 2/Level 3/needle-name.txt")
        try file("fixture/decoy.txt")
        let run = try await Self.collect(request("needle-name", scope: .currentFolder, searchRoot: fixture))
        expectResults(run, [], under: fixture)
        var expected = SearchCoverage()
        expected.foldersSearched = 1
        #expect(run.coverage == expected)
        #expect(run.coverage.isComplete)
    }

    /// NATIVE-P14 / FR-SEARCH-002/003: exact scope/filter intersections, MAC-063 native policy.
    @Test
    func richNestedFixtureProducesExactScopeAndCombinedFilterSets() async throws {
        let today = Self.date(2026, 11, 6, 1)
        let yesterday = Self.date(2026, 11, 5, 1)
        try file("needle-root.txt", bytes: 0, modified: today)
        try file("needle-root.jpg", bytes: 16_384, modified: today)
        try file("A/needle-note.txt", bytes: 16_385, modified: yesterday)
        try file("A/needle-picture.png", bytes: 1_048_577, modified: today)
        try file("A/Deep/needle-note.pdf", bytes: 1_048_576, modified: today)
        try file("B/needle-movie.mp4", bytes: 1, modified: today)
        try file("B/needle-song.mp3", bytes: 1, modified: yesterday)
        try file("B/needle-archive.zip", bytes: 1, modified: today)
        let folder = try directory("B/needle-folder")
        try FileManager.default.setAttributes([.modificationDate: today], ofItemAtPath: folder.path)
        try file("A/decoy.txt", bytes: 16_385, modified: today)

        let cases: [(SearchScope, SearchFilters, [String])] = [
            (.allSubfolders, SearchFilters(), ["needle-root.txt", "needle-root.jpg", "A/needle-note.txt",
                "A/needle-picture.png", "A/Deep/needle-note.pdf", "B/needle-movie.mp4", "B/needle-song.mp3",
                "B/needle-archive.zip", "B/needle-folder"]),
            (.currentFolder, SearchFilters(), ["needle-root.txt", "needle-root.jpg"]),
            (.allSubfolders, SearchFilters(kind: .document),
                ["needle-root.txt", "A/needle-note.txt", "A/Deep/needle-note.pdf"]),
            (.allSubfolders, SearchFilters(kind: .document, dateModified: .today, size: .small),
                ["A/Deep/needle-note.pdf"]),
            (.allSubfolders, SearchFilters(kind: .document, dateModified: .yesterday, size: .small),
                ["A/needle-note.txt"]),
            (.currentFolder, SearchFilters(kind: .picture, dateModified: .today, size: .tiny), ["needle-root.jpg"]),
            (.allSubfolders, SearchFilters(kind: .picture, size: .medium), ["A/needle-picture.png"]),
            (.allSubfolders, SearchFilters(kind: .folder), ["B/needle-folder"]),
            (.allSubfolders, SearchFilters(kind: .folder, size: .empty), []),
            (.allSubfolders, SearchFilters(size: .empty), ["needle-root.txt"]),
            (.currentFolder, SearchFilters(dateModified: .yesterday), [])
        ]
        for (scope, filters, paths) in cases {
            let run = try await Self.collect(request("needle", scope: scope, filters: filters))
            expectResults(run, paths)
            #expect(run.coverage.isComplete)
            #expect(run.coverage.foldersSearched == (scope == .currentFolder ? 1 : 5))
            #expect(run.results.allSatisfy { $0.supportsOperations })
        }
    }

    /// NATIVE-P14 / FR-SEARCH-002; MAC-063 matching is AND, folded, and literal.
    @Test
    func matcherUsesAllTermsAndCaseDiacriticWidthFoldingWithoutWildcards() throws {
        let matcher = try Self.matcher("  CAFÉ\tREPORT\n")
        #expect(matcher.query.terms == ["CAFÉ", "REPORT"])
        #expect(matcher.matches(Self.row("report-cafe.txt")))
        #expect(matcher.matches(Self.row("ＣＡＦＥ-report.txt")))
        #expect(!matcher.matches(Self.row("cafe.txt")))
        #expect(!matcher.matches(Self.row("report.txt")))
        #expect(!matcher.matches(Self.row("unrelated.txt")))
        let literal = try Self.matcher("*")
        #expect(literal.matches(Self.row("literal*star.txt")))
        #expect(!literal.matches(Self.row("literal-star.txt")))
    }

    /// NATIVE-P14 / FR-SEARCH-002; MAC-063 canonical equivalence on actual filenames.
    @Test
    func nfcAndNfdFilenamesAndQueriesMatchInBothDirections() async throws {
        let nfc = "Caf\u{00E9}"
        let nfd = "Cafe\u{0301}"
        // Separate parents avoid APFS treating equivalent names as a collision.
        try file("NFC/\(nfc)-report.txt")
        try file("NFD/\(nfd)-report.txt")
        try file("NFD/coffee-report.txt")
        for query in [nfc, nfd, "CAFE"] {
            let run = try await Self.collect(request("\(query) report"))
            expectResults(run, ["NFC/\(nfc)-report.txt", "NFD/\(nfd)-report.txt"])
            #expect(run.coverage.isComplete)
            let matcher = try Self.matcher(query)
            #expect(matcher.matches(Self.row("\(nfc).txt")))
            #expect(matcher.matches(Self.row("\(nfd).txt")))
        }
        try file("literal*star.txt")
        try file("literal-star.txt")
        expectResults(try await Self.collect(request("*")), ["literal*star.txt"])
    }

    /// NATIVE-P14 / FR-SEARCH-002; MAC-063 canonical equivalence with actual NFC/NFD entries.
    @Test
    func matcherRecognizesCanonicalEquivalentNamesInBothDirections() async throws {
        let nfc = try directory("NFC")
        let nfd = try directory("NFD")
        try file("NFC/Caf\u{00E9}-report.txt")
        try file("NFD/Cafe\u{0301}-report.txt")
        try file("NFD/coffee-report.txt")
        for text in ["Caf\u{00E9}", "Cafe\u{0301}", "CAFE"] {
            let matcher = try Self.matcher(text)
            #expect(matcher.matches(Self.row("Caf\u{00E9}-report.txt")))
            #expect(matcher.matches(Self.row("Cafe\u{0301}-report.txt")))
            #expect(!matcher.matches(Self.row("coffee-report.txt")))
            for (folder, name) in [(nfc, "Caf\u{00E9}-report.txt"), (nfd, "Cafe\u{0301}-report.txt")] {
                let run = try await Self.collect(request(text, scope: .currentFolder, searchRoot: folder))
                expectResults(run, [name], under: folder)
                #expect(run.coverage.isComplete)
            }
        }
        try file("literal*star.txt")
        try file("literal-star.txt")
        expectResults(try await Self.collect(request("*", scope: .currentFolder)), ["literal*star.txt"])
    }

    /// NATIVE-P14 / FR-SEARCH-004: query validation alone does not prove the empty-state UI.
    @Test
    func whitespaceOnlyAndNulQueriesAreRejected() {
        for text in ["", " ", "\t\n\r", "\u{2003}\u{00A0}", "needle\0name"] {
            #expect(FilenameSearchQuery(text: text) == nil)
        }
        #expect(FilenameSearchQuery(text: "  needle  ")?.text == "needle")
    }

    /// NATIVE-P14 / MAC-063: kind derives from extension and entry flags, never descriptive strings.
    @Test
    func kindCategoriesUseExtensionsWithFolderLinkAndAliasPrecedence() throws {
        let cases: [(FileItem, SearchKindFilter)] = [
            (Self.row("needle.pdf", directory: true), .folder),
            (Self.row("needle.TXT", kind: "JPEG image"), .document),
            (Self.row("needle.jpg", kind: "Text document"), .picture),
            (Self.row("needle.mp4"), .video), (Self.row("needle.mp3"), .music),
            (Self.row("needle.zip"), .archive), (Self.row("needle.app"), .application),
            (Self.row("needle.jpg", directory: true, link: true), .link),
            (Self.row("needle.txt", kind: "Alias"), .link),
            (Self.row("needle"), .other), (Self.row("needle.unrecognizedexplorertestextension"), .other)
        ]
        for (item, expected) in cases {
            #expect(SearchKindFilter.category(of: item) == expected)
            for filter in SearchKindFilter.allCases {
                #expect(try Self.matcher(filters: SearchFilters(kind: filter)).matches(item) == (filter == expected))
            }
        }
    }

    /// NATIVE-P14 / MAC-063: folder/link/alias precedence does not require an extension registry.
    @Test
    func kindFlagsOverrideExtensionsAndExtensionlessNamesAreOther() throws {
        let cases: [(FileItem, SearchKindFilter)] = [
            (Self.row("needle.pdf", directory: true), .folder),
            (Self.row("needle.jpg", directory: true, link: true), .link),
            (Self.row("needle.txt", kind: "Alias"), .link),
            (Self.row("needle", kind: "JPEG image"), .other)
        ]
        for (item, expected) in cases {
            #expect(SearchKindFilter.category(of: item) == expected)
            for filter in SearchKindFilter.allCases {
                #expect(try Self.matcher(filters: SearchFilters(kind: filter)).matches(item) == (filter == expected))
            }
        }
    }

    /// NATIVE-P14 / MAC-063: independently specified inclusive byte boundaries, with sparse I/O.
    @Test
    func everySizeBucketMatchesExactSparseFileBoundaryValues() async throws {
        let boundaries = Self.sizeBoundaries
        for (bytes, expected) in boundaries {
            let url = try file("needle-\(bytes).bin", bytes: bytes)
            let item = LocalDirectoryLoader.item(for: url, displayedIn: root, supportsLocalIdentity: true)
            #expect(item.size == bytes)
            for filter in SearchSizeFilter.allCases {
                #expect(filter.contains(bytes) == (filter == expected))
                #expect(try Self.matcher(filters: SearchFilters(size: filter)).matches(item) == (filter == expected))
            }
        }
        for filter in SearchSizeFilter.allCases {
            #expect(!filter.contains(-1))
            let run = try await Self.collect(request("needle", filters: SearchFilters(size: filter)))
            expectResults(run, boundaries.filter { $0.1 == filter }.map { "needle-\($0.0).bin" })
            #expect(run.coverage.isComplete)
        }
    }

    /// NATIVE-P14 / MAC-063: sparse-file bytes, contains and matcher isolated from the shared row builder.
    @Test
    func sizeContainsAndMatcherAssignEveryBoundaryToExactlyOneBucket() throws {
        for (bytes, expected) in Self.sizeBoundaries {
            let url = try file("needle-\(bytes).bin", bytes: bytes)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let actualBytes = Int64(try #require(values.fileSize))
            #expect(actualBytes == bytes)
            let item = Self.row(size: actualBytes)
            for filter in SearchSizeFilter.allCases {
                #expect(filter.contains(bytes) == (filter == expected))
                #expect(try Self.matcher(filters: SearchFilters(size: filter)).matches(item) == (filter == expected))
            }
        }
        for filter in SearchSizeFilter.allCases { #expect(!filter.contains(-1)) }
    }

    /// NATIVE-P14 / MAC-063: unknown bytes, directories and links fail every active size filter.
    @Test
    func sizeFiltersRejectDirectoriesLinksAndUnknownSizesButNoneAllowsThem() throws {
        let items = [Self.row(directory: true, size: 0), Self.row(link: true, size: 0), Self.row(size: nil)]
        for item in items {
            #expect(try Self.matcher().matches(item))
            for filter in SearchSizeFilter.allCases {
                #expect(try !Self.matcher(filters: SearchFilters(size: filter)).matches(item))
            }
        }
        #expect(SearchSizeFilter.gigantic.contains(Int64.max))
    }

    /// NATIVE-P14 / MAC-063: fixed Gregorian UTC periods and half-open mtime boundaries.
    @Test
    func allDateFiltersUseExactCalendarIntervalsAndHalfOpenFilesystemMtimes() async throws {
        for (filter, start, end) in Self.datePeriods {
            let interval = try #require(filter.interval(relativeTo: Self.referenceDate, calendar: Self.calendar))
            #expect(interval.start == start)
            #expect(interval.end == end)
            let folder = try directory(filter.rawValue)
            let instants: [(String, Date, Bool)] = [
                ("needle-before.txt", start.addingTimeInterval(-1), false),
                ("needle-start.txt", start, true),
                ("needle-inside.txt", end.addingTimeInterval(-1), true),
                ("needle-end.txt", end, false)
            ]
            let matcher = try Self.matcher(filters: SearchFilters(dateModified: filter))
            for (name, instant, matches) in instants {
                let url = try file("\(filter.rawValue)/\(name)", modified: instant)
                let item = LocalDirectoryLoader.item(for: url, displayedIn: folder, supportsLocalIdentity: true)
                #expect(item.modifiedAt == instant)
                #expect(matcher.matches(item) == matches)
            }
            let run = try await Self.collect(request("needle", filters: SearchFilters(dateModified: filter), searchRoot: folder))
            expectResults(run, ["needle-start.txt", "needle-inside.txt"], under: folder)
            #expect(run.coverage.isComplete)
        }
    }

    /// NATIVE-P14 / MAC-063: real mtimes and half-open matching isolated from the shared row builder.
    @Test
    func dateIntervalsAndMatcherIncludeStartButExcludeEndForAllEightPeriods() throws {
        for (filter, start, end) in Self.datePeriods {
            let interval = try #require(filter.interval(relativeTo: Self.referenceDate, calendar: Self.calendar))
            #expect(interval.start == start)
            #expect(interval.end == end)
            let matcher = try Self.matcher(filters: SearchFilters(dateModified: filter))
            let instants: [(String, Date, Bool)] = [
                ("before", start.addingTimeInterval(-1), false), ("start", start, true),
                ("inside", end.addingTimeInterval(-1), true), ("end", end, false)
            ]
            for (name, instant, matches) in instants {
                let url = try file("\(filter.rawValue)/needle-\(name).txt", modified: instant)
                let actualDate = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)
                #expect(actualDate == instant)
                #expect(matcher.matches(Self.row(modified: actualDate)) == matches)
            }
        }
    }

    /// NATIVE-P14 / MAC-063: unknown modification dates fail active filters and pass with none.
    @Test
    func dateFiltersRejectUnknownDatesAndNoneAllowsUnknownOrOldDates() throws {
        let unknown = Self.row(modified: nil)
        #expect(try Self.matcher().matches(unknown))
        #expect(try Self.matcher().matches(Self.row(modified: Self.date(1990, 1, 1))))
        for filter in SearchDateFilter.allCases {
            #expect(try !Self.matcher(filters: SearchFilters(dateModified: filter)).matches(unknown))
        }
    }

    /// NATIVE-P14 / FR-SEARCH-002; MAC-063 hidden directories are skipped before descent.
    @Test
    func hiddenVisibilityControlsFilesDirectoryEntriesAndEntireHiddenSubtrees() async throws {
        try file("needle-visible.txt")
        try file(".needle-hidden.txt")
        try file(".needle-directory/needle-inside.txt")
        try file("Visible/needle-child.txt")
        let hidden = try await Self.collect(request("needle"))
        expectResults(hidden, ["needle-visible.txt", "Visible/needle-child.txt"])
        #expect(hidden.coverage.foldersSearched == 2)
        #expect(hidden.coverage.isComplete)
        let shown = try await Self.collect(request("needle", showHidden: true))
        expectResults(shown, ["needle-visible.txt", ".needle-hidden.txt", ".needle-directory",
                              ".needle-directory/needle-inside.txt", "Visible/needle-child.txt"])
        #expect(shown.coverage.foldersSearched == 3)
        #expect(shown.coverage.isComplete)
        let current = try await Self.collect(request("needle", scope: .currentFolder, showHidden: true))
        expectResults(current, ["needle-visible.txt", ".needle-hidden.txt", ".needle-directory"])
    }

    /// NATIVE-P14 / MAC-063: links match as entries, cycles terminate, targets are never entered.
    @Test
    func rootAndParentSymlinkCyclesMatchOnlyLinkEntriesAndTerminatePromptly() async throws {
        try file("needle-root.txt")
        let nested = try directory("Nested/Child")
        try file("Nested/Child/needle-child.txt")
        let rootLink = nested.appendingPathComponent("needle-root-link")
        let parentLink = nested.appendingPathComponent("needle-parent-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: nested.deletingLastPathComponent())
        let request = try request("needle")
        let run = try await Self.withinTenSeconds { try await Self.collect(request) }
        expectResults(run, ["needle-root.txt", "Nested/Child/needle-child.txt",
                            "Nested/Child/needle-root-link", "Nested/Child/needle-parent-link"])
        #expect(run.coverage.foldersSearched == 3)
        #expect(run.coverage.isComplete)
        let links = run.results.filter { $0.item.isSymbolicLink }
        #expect(links.count == 2)
        for link in links {
            #expect(SearchKindFilter.category(of: link.item) == .link)
            #expect(link.item.size == nil)
            #expect(link.item.identity == (try Self.identity(link.item.url)))
            #expect(link.item.identity != (try Self.identity(link.item.url.resolvingSymlinksInPath())))
            #expect(link.supportsOperations)
        }
    }

    /// NATIVE-P14 / MAC-063: packages are file-like results and never recursive roots.
    @Test
    func packageEntryIsMatchableWithoutEnteringItsContents() async throws {
        let package = try directory("Bundle.app")
        try file("Bundle.app/Contents/needle.txt")
        try file("ordinary/needle.txt")
        let contents = try await Self.collect(request("needle"))
        expectResults(contents, ["ordinary/needle.txt"])
        #expect(contents.coverage.foldersSearched == 2)
        #expect(contents.coverage.isComplete)
        let bundles = try await Self.collect(request("Bundle.app", filters: SearchFilters(kind: .application)))
        expectResults(bundles, ["Bundle.app"])
        let item = try #require(bundles.results.first?.item)
        #expect(!item.isDirectory)
        #expect(item.size == nil)
        #expect(item.url.path == package.path)
    }

    /// NATIVE-P14 / MAC-063: unreadable lexical subtree is partial, siblings remain searchable.
    @Test
    func unreadableSubtreeReportsExactPermissionFailureCoverageAndKeepsSiblingMatches() async throws {
        try file("Denied/needle-denied.txt")
        try file("Readable/needle-ok.txt")
        try file("needle-root.txt")
        let denied = root.appendingPathComponent("Denied", isDirectory: true)
        try denyPermissions(denied)
        let run = try await Self.collect(request("needle"))
        expectResults(run, ["Readable/needle-ok.txt", "needle-root.txt"])
        var expected = SearchCoverage()
        expected.foldersSearched = 2
        expected.unreadableFolders = 1
        expected.unreadableSamples = [denied]
        expected.accessFailure = .permissionDenied
        #expect(run.coverage == expected)
        #expect(!run.coverage.isComplete)
    }

    /// NATIVE-P14 / MAC-063: unreadable counts are cumulative while lexical samples cap at five.
    @Test
    func unreadableSamplesStopAtFiveWithoutTruncatingFailureCounts() async throws {
        var denied: [URL] = []
        for index in 0..<7 {
            try file("Denied-\(index)/needle.txt")
            let url = root.appendingPathComponent("Denied-\(index)", isDirectory: true)
            denied.append(url)
            try denyPermissions(url)
        }
        try file("needle-ok.txt")
        let run = try await Self.collect(request("needle"))
        expectResults(run, ["needle-ok.txt"])
        var expected = SearchCoverage()
        expected.foldersSearched = 1
        expected.unreadableFolders = 7
        expected.unreadableSamples = Array(denied.prefix(5))
        expected.accessFailure = .permissionDenied
        #expect(SearchCoverage.sampleLimit == 5)
        #expect(run.coverage == expected)
        #expect(!run.coverage.isComplete)
    }

    /// NATIVE-P14 / MAC-063: depth two is entered, depth three is excluded and reported.
    @Test
    func depthLimitIncludesBoundaryFolderButExcludesDeeperMatchAndMarksPartial() async throws {
        try file("One/Two/needle-boundary.txt")
        try file("One/Two/Three/needle-too-deep.txt")
        let run = try await Self.collect(request("needle"),
            searcher: LocalFilenameSearcher(batchInterval: 0, maximumDepth: 2))
        expectResults(run, ["One/Two/needle-boundary.txt"])
        var expected = SearchCoverage()
        expected.foldersSearched = 3
        expected.depthLimitedFolders = 1
        #expect(run.coverage == expected)
        #expect(!run.coverage.isComplete)
        #expect(LocalFilenameSearcher.maximumDepth == 64)
    }

    /// NATIVE-P14 / MAC-063: a result cap preserves deterministic first results and marks partial.
    @Test
    func resultLimitReturnsExactlyThreeOfFiveMatchesAndMarksPartial() async throws {
        for index in 0..<5 { try file("needle-\(index).txt") }
        let run = try await Self.collect(request("needle", resultLimit: 3),
                                         searcher: LocalFilenameSearcher(batchInterval: 0))
        expectResults(run, ["needle-0.txt", "needle-1.txt", "needle-2.txt"])
        var expected = SearchCoverage()
        expected.foldersSearched = 1
        expected.reachedResultLimit = true
        #expect(run.coverage == expected)
        #expect(!run.coverage.isComplete)
    }

    private static func expectRootError(_ request: FilenameSearchRequest, _ expected: FilenameSearchError) async {
        var events = 0
        do {
            for try await _ in LocalFilenameSearcher().search(request) { events += 1 }
            Issue.record("Expected root error \(expected)")
        } catch {
            #expect(error as? FilenameSearchError == expected)
        }
        #expect(events == 0, "Root validation failures must not publish progress or success")
    }

    /// NATIVE-P14 / MAC-062/063: a different existing directory identity is rejected.
    @Test
    func wrongRootIdentityThrowsRootChangedBeforeAnyEvent() async throws {
        let other = try directory("Other")
        let original = try request("needle")
        let wrong = FilenameSearchRequest(root: root, rootIdentity: try Self.identity(other),
            query: original.query, showHidden: false)
        await Self.expectRootError(wrong, .rootChanged)
    }

    /// NATIVE-P14 / MAC-063: a regular-file root is rejected rather than reported empty.
    @Test
    func regularFileRootThrowsNotFolderBeforeAnyEvent() async throws {
        let file = try file("needle.txt")
        await Self.expectRootError(try request("needle", searchRoot: file), .notFolder)
    }

    /// NATIVE-P14 / MAC-063: remote schemes cannot start a local traversal.
    @Test
    func nonFileURLThrowsUnsupportedLocationBeforeAnyEvent() async throws {
        let original = try request("needle")
        let unsupported = FilenameSearchRequest(root: try #require(URL(string: "https://example.invalid/fixture")),
            rootIdentity: original.rootIdentity, query: original.query, showHidden: false)
        await Self.expectRootError(unsupported, .unsupportedLocation)
    }

    /// NATIVE-P14 / MAC-062/065: lexical result paths retain a root link; parent identities are real.
    @Test
    func symlinkRootRetainsLexicalResultAndParentURLsWithResolvedParentIdentities() async throws {
        let real = try directory("Real")
        try file("Real/needle-root.txt")
        try file("Real/Nested/needle-child.txt")
        let lexical = root.appendingPathComponent("Lexical")
        try FileManager.default.createSymbolicLink(at: lexical, withDestinationURL: real)
        #expect(try Self.identity(lexical) != Self.identity(real))
        let run = try await Self.collect(request("needle", searchRoot: lexical))
        expectResults(run, ["needle-root.txt", "Nested/needle-child.txt"], under: lexical)
        #expect(run.coverage.isComplete)
        #expect(run.coverage.foldersSearched == 2)
        for result in run.results {
            let parent = try #require(result.parent)
            #expect(parent.directoryURL == result.item.url.deletingLastPathComponent())
            #expect(parent.directoryURL.path.hasPrefix(lexical.path))
            #expect(parent.directoryIdentity == (try Self.identity(parent.directoryURL.resolvingSymlinksInPath())))
            #expect(result.item.identity == (try Self.identity(result.item.url.resolvingSymlinksInPath())))
            #expect(result.supportsOperations)
        }
    }

    /// NATIVE-P14 / MAC-062/065: immediate results retain the root link spelling and resolved identity.
    @Test
    func currentFolderSymlinkRootKeepsLexicalPathsAndRealParentIdentity() async throws {
        let real = try directory("Real")
        let file = try file("Real/needle.txt")
        let lexical = root.appendingPathComponent("Lexical")
        try FileManager.default.createSymbolicLink(at: lexical, withDestinationURL: real)
        let run = try await Self.collect(request("needle", scope: .currentFolder, searchRoot: lexical))
        expectResults(run, ["needle.txt"], under: lexical)
        let result = try #require(run.results.first)
        #expect(result.parent == FileOperationContext(directoryURL: lexical.standardizedFileURL,
            directoryIdentity: try Self.identity(real)))
        #expect(result.item.identity == (try Self.identity(file)))
        #expect(result.supportsOperations)
        #expect(run.coverage.isComplete)
        #expect(run.coverage.foldersSearched == 1)
    }

    private struct CancellationObservation: Sendable {
        var progressEvents = 0
        var finishedEvents = 0
        var unexpectedError = false
    }

    /// NATIVE-P14 / MAC-063: cancel the consumer after acknowledged progress; fresh runs still work.
    @Test
    func cancellationAfterFirstProgressEndsPromptlyWithoutFinishedAndFreshSearchCompletes() async throws {
        try file("needle-root.txt")
        var expected = ["needle-root.txt"]
        for index in 0..<300 {
            let path = "Folder-\(index)/Nested/needle-\(index).txt"
            try file(path)
            expected.append(path)
        }
        let request = try request("needle")
        let firstEvent = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let completion = AsyncStream<CancellationObservation>.makeStream()
        // Holding the consumer at the gate ensures the parent cancels after exactly one event.
        let consumer = Task { () -> CancellationObservation in
            var observation = CancellationObservation()
            do {
                for try await event in LocalFilenameSearcher(batchInterval: 0).search(request) {
                    // AsyncThrowingStream can still hand already-buffered elements to a
                    // cancelled consumer; like ExplorerStore, stop applying them.
                    if Task.isCancelled { break }
                    switch event {
                    case .progress:
                        observation.progressEvents += 1
                        if observation.progressEvents == 1 {
                            firstEvent.continuation.yield(())
                            firstEvent.continuation.finish()
                            var iterator = gate.stream.makeAsyncIterator()
                            _ = await iterator.next()
                        }
                    case .finished: observation.finishedEvents += 1
                    }
                }
            } catch is CancellationError {
                // Cancellation may finish normally or throw CancellationError.
            } catch {
                observation.unexpectedError = true
            }
            firstEvent.continuation.finish()
            completion.continuation.yield(observation)
            completion.continuation.finish()
            return observation
        }
        defer {
            consumer.cancel()
            firstEvent.continuation.finish()
            gate.continuation.finish()
            completion.continuation.finish()
        }
        let acknowledged = try await Self.withinTenSeconds {
            var iterator = firstEvent.stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        #expect(acknowledged)
        consumer.cancel()
        // Await a cancellation-responsive stream rather than an unstructured Task.value:
        // the timeout can then release its waiter even if the consumer fails to terminate.
        let observation = try await Self.withinTenSeconds {
            var iterator = completion.stream.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        // Observed under heavy parallel load in Phase 15: the traversal can finish and
        // buffer events before the cancel lands. The consumer contract (mirrored from
        // ExplorerStore) is that nothing is applied after cancellation.
        #expect(observation.progressEvents == 1)
        #expect(observation.finishedEvents == 0)
        #expect(!observation.unexpectedError)

        let fresh = try await Self.withinTenSeconds {
            try await Self.collect(request, searcher: LocalFilenameSearcher(batchInterval: 0))
        }
        expectResults(fresh, expected)
        #expect(fresh.batches.count > 1)
        #expect(fresh.coverage.foldersSearched == 601)
        #expect(fresh.coverage.isComplete)
    }

    /// NATIVE-P14 / FR-SEARCH-002; MAC-063: breadth-first batches are deltas, coverage cumulative.
    @Test
    func zeroIntervalBatchesHaveNoDuplicateIDsExactBreadthFirstResultsAndCumulativeCoverage() async throws {
        for path in ["needle-root.txt", "A/needle-a.txt", "B/needle-b.txt",
                     "A/Deep/needle-a-deep.txt", "B/Deep/needle-b-deep.txt"] {
            try file(path)
        }
        let run = try await Self.collect(request("needle"), searcher: LocalFilenameSearcher(batchInterval: 0))
        let expected = ["needle-root.txt", "A/needle-a.txt", "B/needle-b.txt",
                        "A/Deep/needle-a-deep.txt", "B/Deep/needle-b-deep.txt"]
        expectResults(run, expected)
        #expect(run.results.map { $0.item.url.path } == expected.map { root.appendingPathComponent($0).path })
        #expect(run.batches.map(\.count) == [1, 1, 1, 1, 1])
        #expect(Set(run.results.map(\.id)).count == run.results.count)
        #expect(run.batches.flatMap { $0 }.map(\.id) == run.results.map(\.id))
        #expect(run.progressCoverage.map(\.foldersSearched) == [1, 2, 3, 4, 5])
        #expect(run.progressCoverage.allSatisfy { $0.isComplete })
        var expectedCoverage = SearchCoverage()
        expectedCoverage.foldersSearched = 5
        #expect(run.coverage == expectedCoverage)
        #expect(run.progressCoverage.last == run.coverage)
    }

    /// NATIVE-P14 / MAC-063: deterministic synchronous traversal seam, not a timed filesystem race.
    @Test
    func queuedFolderThatVanishesOrIsReplacedCountsAsChangedWithoutStaleResults() async throws {
        for replace in [false, true] {
            let prefix = replace ? "Replaced" : "Vanished"
            let fixture = try directory(prefix)
            try file("\(prefix)/Changed/needle-stale.txt")
            try file("\(prefix)/Healthy/needle-ok.txt")
            let changed = fixture.appendingPathComponent("Changed", isDirectory: true)
            let parked = root.appendingPathComponent("\(prefix)-parked", isDirectory: true)
            let request = try request("needle", searchRoot: fixture)
            let run = try await BlockingIO.run(on: .read) { cancellation in
                var run = Run()
                var moved = false
                var mutationFailure: Error?
                run.coverage = try LocalFilenameSearcher.traverse(request, batchInterval: 0, maximumDepth: 64,
                    cancellation: cancellation) { results, coverage in
                    run.results.append(contentsOf: results)
                    run.progressCoverage.append(coverage)
                    if !moved {
                        moved = true
                        do {
                            // Retain the old inode outside the search root to prevent immediate reuse.
                            try FileManager.default.moveItem(at: changed, to: parked)
                            if replace {
                                try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
                            }
                        } catch { mutationFailure = error }
                    }
                }
                if let mutationFailure { throw mutationFailure }
                return run
            }
            expectResults(run, ["Healthy/needle-ok.txt"], under: fixture)
            var expected = SearchCoverage()
            expected.foldersSearched = 2
            expected.changedFolders = 1
            #expect(run.coverage == expected)
            #expect(!run.coverage.isComplete)
        }
    }

    /// NATIVE-P14 / MAC-062/063/065: search and listing share lexical, no-follow row metadata.
    @Test
    func sharedRowBuilderKeepsLexicalURLsEntryIdentitiesAndUnknownDirectoryAndLinkSizes() throws {
        let real = try directory("Real")
        let text = try file("Real/needle.txt", bytes: 22, modified: Self.referenceDate)
        let folder = try directory("Real/Folder")
        let package = try directory("Real/Bundle.app")
        let link = real.appendingPathComponent("needle-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        let lexical = root.appendingPathComponent("Lexical")
        try FileManager.default.createSymbolicLink(at: lexical, withDestinationURL: real)
        for url in [text, folder, package, link] {
            let item = LocalDirectoryLoader.item(for: url, displayedIn: lexical, supportsLocalIdentity: true)
            #expect(item.url.path == lexical.appendingPathComponent(url.lastPathComponent).path)
            #expect(item.name == url.lastPathComponent)
            #expect(item.identity == (try Self.identity(url)))
            if url == text {
                #expect(item.size == 22)
                #expect(item.modifiedAt == Self.referenceDate)
            } else {
                #expect(item.size == nil)
            }
            #expect(item.isDirectory == (url == folder))
            #expect(item.isSymbolicLink == (url == link))
            let unsupported = LocalDirectoryLoader.item(for: url, displayedIn: lexical, supportsLocalIdentity: false)
            #expect(unsupported.identity == nil)
        }
    }

    /// NATIVE-P14 / MAC-063 regression: optional display metadata must not erase readable structural metadata.
    @Test
    func unavailableLocalizedTypeDescriptionMustNotEraseIndependentlyReadableMetadata() throws {
        let file = try file("needle.txt", bytes: 22, modified: Self.referenceDate)
        let folder = try directory("Folder")
        // These independent reads establish that the fixture is readable and its metadata exists.
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        #expect(values.fileSize == 22)
        #expect(values.contentModificationDate == Self.referenceDate)
        #expect(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let fileRow = LocalDirectoryLoader.item(for: file, displayedIn: root, supportsLocalIdentity: true)
        let folderRow = LocalDirectoryLoader.item(for: folder, displayedIn: root, supportsLocalIdentity: true)
        #expect(fileRow.size == 22)
        #expect(fileRow.modifiedAt == Self.referenceDate)
        #expect(folderRow.isDirectory)
    }

    /// NATIVE-P14 / MAC-063: every exclusion independently prevents a completeness claim.
    @Test
    func coverageIsPartialForEveryExclusionAndCompleteForSuccessfulFolderCountsAlone() {
        let counters: [WritableKeyPath<SearchCoverage, Int>] = [
            \.unreadableFolders, \.changedFolders, \.otherVolumeFolders,
            \.unavailableFolders, \.depthLimitedFolders
        ]
        var complete = SearchCoverage()
        complete.foldersSearched = 17
        #expect(complete.isComplete)
        for counter in counters {
            var partial = complete
            partial[keyPath: counter] = 1
            #expect(!partial.isComplete)
        }
        complete.reachedResultLimit = true
        #expect(!complete.isComplete)
    }
}
