import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class SuggestionFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerSuggestions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit {
        _ = root.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned suggestion fixture cleanup failed: \(root.path): \(error)") }
    }
    @discardableResult
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @discardableResult
    func file(_ name: String, bytes: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

/// NATIVE-P11 service tests. FR-NAV-005 / EV-9001 / AT-NAV-005 establishes
/// address focus, not this native completion ordering/cap/filter policy.
struct FolderSuggestionTests {
    @Test
    func emptyFolderAndEmptyPrefixAreCompleteAndOnlyImmediateFoldersAppear() async throws {
        let fixture = try SuggestionFixture()
        let empty = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(empty.urls.isEmpty && !empty.isTruncated)
        let folder = try fixture.folder("Folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested"), withIntermediateDirectories: false)
        let payload = Data("suggestions must not read this payload".utf8)
        let file = try fixture.file("File.txt", bytes: payload)
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(result.urls.map(\.lastPathComponent) == ["Folder"])
        #expect(!result.isTruncated)
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test
    func prefixIsAnchoredCaseAndDiacriticInsensitiveWithActualUnicodePaths() async throws {
        let fixture = try SuggestionFixture()
        for name in ["Café 東京", "CAFETERIA", "decaf", "[draft] 東京"] { try fixture.folder(name) }
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "cafe", showHidden: false)
        #expect(Set(result.urls.map(\.lastPathComponent)) == ["Café 東京", "CAFETERIA"])
        #expect(!result.isTruncated)
        for url in result.urls {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        let literal = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "[draft]", showHidden: false)
        #expect(literal.urls.map(\.lastPathComponent) == ["[draft] 東京"])
        let unmatched = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "東京", showHidden: false)
        #expect(unmatched.urls.isEmpty && !unmatched.isTruncated)
    }

    @Test
    func sortingIsNaturalCaseInsensitiveAndStable() async throws {
        let fixture = try SuggestionFixture()
        for name in ["alpha 10", "Alpha 2", "beta", "Zulu", "alpha 02"] { try fixture.folder(name) }
        let first = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        let second = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(first.urls == second.urls)
        let names = first.urls.map(\.lastPathComponent)
        #expect(names.last == "Zulu")
        #expect(try #require(names.firstIndex(of: "Alpha 2")) < #require(names.firstIndex(of: "alpha 10")))
        #expect(try #require(names.firstIndex(of: "alpha 02")) < #require(names.firstIndex(of: "alpha 10")))
        let tied = first.urls.filter { ["Alpha 2", "alpha 02"].contains($0.lastPathComponent) }
        #expect(tied == tied.sorted { $0.absoluteString < $1.absoluteString })
    }

    @Test
    func dotAndNativeHiddenFoldersRespectTheExplicitFlag() async throws {
        let fixture = try SuggestionFixture()
        try fixture.folder("Visible")
        try fixture.folder(".dot-hidden")
        let native = try fixture.folder("NativeHidden")
        try #require(native.withUnsafeFileSystemRepresentation { chflags($0!, UInt32(UF_HIDDEN)) } == 0)
        defer { _ = native.withUnsafeFileSystemRepresentation { chflags($0!, 0) } }
        let visible = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(visible.urls.map(\.lastPathComponent) == ["Visible"])
        let all = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: true)
        #expect(Set(all.urls.map(\.lastPathComponent)) == ["Visible", ".dot-hidden", "NativeHidden"])
        #expect(!all.isTruncated)
    }

    @Test
    func linksPreserveTheirLexicalEntryAndPackagesAndBrokenLinksAreExcluded() async throws {
        let fixture = try SuggestionFixture()
        let folder = try fixture.folder("Target")
        let package = try fixture.folder("Example.app")
        let file = try fixture.file("plain.txt")
        for (name, target) in [("FolderLink", folder), ("PackageLink", package), ("FileLink", file),
                               ("BrokenLink", fixture.root.appendingPathComponent("missing"))] {
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(name), withDestinationURL: target)
        }
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(Set(result.urls.map(\.lastPathComponent)) == ["Target", "FolderLink"])
        let link = try #require(result.urls.first { $0.lastPathComponent == "FolderLink" })
        #expect(link.path == fixture.root.appendingPathComponent("FolderLink").path)
        #expect(link.path != folder.path)
        #expect(!link.hasDirectoryPath)
    }

    @Test
    func linkedInputFolderKeepsItsRequestedLexicalRoute() async throws {
        let fixture = try SuggestionFixture()
        let target = try fixture.folder("Target")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Child"), withIntermediateDirectories: false)
        let route = fixture.root.appendingPathComponent("Route")
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: target)
        let result = try await LocalFolderSuggester().folders(in: route, prefix: "", showHidden: false)
        #expect(result.urls.count == 1)
        #expect(result.urls.first?.path == route.appendingPathComponent("Child").path)
    }

    @Test
    func matchingCapReturnsFirstTwoHundredSortedAndReportsTruncation() async throws {
        let fixture = try SuggestionFixture()
        for number in (0...200).reversed() { try fixture.folder("Folder \(number)") }
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "folder", showHidden: false)
        #expect(result.urls.map(\.lastPathComponent) == (0..<200).map { "Folder \($0)" })
        #expect(result.isTruncated)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Folder 200"))
        let exactly = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "folder", showHidden: false)
        #expect(exactly.urls.count == 200 && !exactly.isTruncated)
    }

    @Test
    func scanCapCountsHiddenUnmatchedEntriesAndReportsAnIncompleteEmptyResult() async throws {
        let fixture = try SuggestionFixture()
        for number in 0..<4_096 { try fixture.file(".unmatched-\(number)") }
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "wanted", showHidden: false)
        #expect(result.urls.isEmpty && result.isTruncated)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".unmatched-4095"))
        let belowCap = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "wanted", showHidden: false)
        #expect(belowCap.urls.isEmpty && !belowCap.isTruncated)
    }

    @Test
    func unsupportedMissingAndRegularFileInputsThrowInsteadOfReturningEmpty() async throws {
        let fixture = try SuggestionFixture()
        let file = try fixture.file("file.txt", bytes: Data("unchanged".utf8))
        let unsupported = ["https://example.invalid/folder", "file://remote.invalid/folder",
                           "file:///tmp/bad%00name", "file:///tmp/folder?query", "file:///tmp/folder#fragment"]
            .map { URL(string: $0)! }
        for url in unsupported {
            do { _ = try await LocalFolderSuggester().folders(in: url, prefix: "", showHidden: false); Issue.record("Unsupported URL accepted") }
            catch { #expect((error as NSError).code == CocoaError.fileReadUnsupportedScheme.rawValue) }
        }
        for url in [file, fixture.root.appendingPathComponent("missing")] {
            do { _ = try await LocalFolderSuggester().folders(in: url, prefix: "", showHidden: false); Issue.record("Non-folder returned suggestions") }
            catch { #expect(!(error is CancellationError)) }
        }
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    @Test
    func deniedEnumerationRetainsPermissionClassificationAndWorksAfterRepair() async throws {
        let fixture = try SuggestionFixture()
        try fixture.folder("Child")
        try #require(fixture.root.withUnsafeFileSystemRepresentation { chmod($0!, 0) } == 0)
        do { _ = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false); Issue.record("Denied enumeration returned suggestions") }
        catch { #expect(FileAccessFailure.classify(error) == .permissionDenied) }
        try #require(fixture.root.withUnsafeFileSystemRepresentation { chmod($0!, mode_t(0o700)) } == 0)
        let result = try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        #expect(result.urls.map(\.lastPathComponent) == ["Child"])
    }

    @Test
    func preCancelledCallDoesNotProduceSuggestions() async throws {
        let fixture = try SuggestionFixture()
        try fixture.folder("Child")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalFolderSuggester().folders(in: fixture.root, prefix: "", showHidden: false)
        }
        do { _ = try await task.value; Issue.record("Cancelled suggestion read succeeded") }
        catch is CancellationError {}
    }
}
