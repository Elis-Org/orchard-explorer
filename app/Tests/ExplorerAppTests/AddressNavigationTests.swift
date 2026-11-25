import Foundation
import Testing
@testable import ExplorerApp
import ExplorerCore

/// Deliberately ignores task cancellation so late filesystem callbacks exercise
/// the model's request-generation boundary. All continuations are drained.
private actor AddressSuggestionDriver: FolderSuggesting {
    struct Request: Sendable {
        let directory: URL
        let prefix: String
        let showHidden: Bool
    }
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<FolderSuggestions, Error>] = [:]
    private var stopped = false

    func folders(in directory: URL, prefix: String, showHidden: Bool) async throws -> FolderSuggestions {
        guard !stopped else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending[requests.count] = $0
            requests.append(Request(directory: directory, prefix: prefix, showHidden: showHidden))
        }
    }
    func finish(_ index: Int, urls: [URL], truncated: Bool = false) {
        pending.removeValue(forKey: index)?.resume(returning: FolderSuggestions(urls: urls, isTruncated: truncated))
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
    func shutdown() {
        stopped = true
        let calls = Array(pending.values)
        pending.removeAll()
        for call in calls { call.resume(throwing: CancellationError()) }
    }
}

/// NATIVE-P11 / MAC-052–055. FR-NAV-005 / EV-9001 / AT-NAV-005
/// documents address focus; UI-NAV-002 / EV-0404–0406 documents menu presence.
/// These are native completion/history model checks, not UI or Windows fidelity results.
@MainActor
final class AddressNavigationTests {
    private let root = URL(fileURLWithPath: "/tmp/Explorer Address Model", isDirectory: true)

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await condition()
        try #require(settled, "Address model did not settle before the bounded deadline")
    }
    private func stop(_ model: AddressNavigationModel, _ driver: AddressSuggestionDriver) {
        model.cancel()
        Task { await driver.shutdown() }
    }

    @Test
    func completionQueriesSupportAbsoluteAndHomePathsButLeaveRelativePathsForSubmission() throws {
        let absolute = try #require(AddressNavigationModel.completionQuery("/tmp/Parent/Ch"))
        #expect(absolute.directory.path == "/tmp/Parent" && absolute.prefix == "Ch")
        let trailing = try #require(AddressNavigationModel.completionQuery("/tmp/Parent/"))
        #expect(trailing.directory.path == "/tmp/Parent" && trailing.prefix.isEmpty)
        let home = try #require(AddressNavigationModel.completionQuery("~/Doc"))
        #expect(home.directory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
        #expect(home.prefix == "Doc")
        #expect(AddressNavigationModel.completionQuery("Child/Grandchild")?.directory == nil)
        #expect(AddressNavigationModel.completionQuery("")?.directory == nil)
        #expect(AddressNavigationModel.completionQuery("/tmp/bad\0name")?.directory == nil)

        let model = AddressNavigationModel()
        model.beginEditing(at: root)
        model.updateText("Child/../Target", showHidden: false)
        #expect(model.presentation == nil)
        #expect(model.submissionURL(relativeTo: root)?.path == root.path + "/Target")
        model.updateText("~/Documents", showHidden: false)
        #expect(model.submissionURL(relativeTo: root)?.path == FileManager.default.homeDirectoryForCurrentUser.path + "/Documents")
        model.updateText("bad\0name", showHidden: false)
        #expect(model.submissionURL(relativeTo: root) == nil)
        model.cancel()
        #expect(model.submissionURL(relativeTo: root) == nil)
    }

    // ND-ADDR-01/02 and design review B. Match exact UTF-8, including
    // a decomposed Unicode name and a percent escape that must remain literal.
    @Test(arguments: ["file:///tmp/", "FiLe://LOCALHOST/tmp/", "file:/tmp/"])
    func typedLocalFileURLDecodesExactlyOnce(_ prefix: String) throws {
        let model = AddressNavigationModel()
        model.beginEditing(at: root)
        model.updateText(prefix + "Cafe%CC%81%20%252F%20%23%3A.txt", showHidden: false)
        let result = try #require(model.submissionURL(relativeTo: root))
        #expect(result.isFileURL)
        #expect(result.path.utf8.elementsEqual("/tmp/Cafe\u{301} %2F #:.txt".utf8))
    }

    @Test(arguments: ["https://example.com/folder", "file://remote/tmp/folder",
                      "file://name@localhost/tmp/folder", "file://localhost:12/tmp/folder",
                      "file://%6cocalhost/tmp/folder", "file:relative.txt",
                      "file:///tmp/a?b", "file:///tmp/a#b", "file:///tmp/a%GG",
                      "file:///tmp/a%2fb", "file:///tmp/a%5Cb", "file:///tmp/a%00b",
                      "file:///tmp/a%FF"])
    func malformedOrRemoteTypedURLsRemainEditable(_ draft: String) {
        let model = AddressNavigationModel()
        model.beginEditing(at: root)
        model.updateText(draft, showHidden: false)
        #expect(model.submissionURL(relativeTo: root) == nil)
        #expect(model.errorMessage != nil)
        #expect(model.isEditing && model.text == draft)
    }

    @Test(arguments: ["notes: café %2F #.txt", "/tmp/notes: café %2F #.txt"])
    func ordinaryPOSIXTextPreservesLiteralPunctuation(_ draft: String) throws {
        let model = AddressNavigationModel()
        model.beginEditing(at: root)
        model.updateText(draft, showHidden: false)
        let result = try #require(model.submissionURL(relativeTo: root))
        let expected = draft.hasPrefix("/") ? draft : root.path + "/" + draft
        #expect(result.path == expected)
    }

    @Test
    func rapidParentPrefixAndHiddenChangesRejectLateCallbacksAndOldPopupActions() async throws {
        let driver = AddressSuggestionDriver()
        let model = AddressNavigationModel(suggester: driver, debounce: .zero)
        defer { stop(model, driver) }
        model.beginEditing(at: root)
        model.updateText("/tmp/First/A", showHidden: false)
        let firstID = model.requestID
        try await waitUntil { await driver.requests.count == 1 }
        model.updateText("/tmp/Second/B", showHidden: false)
        try await waitUntil { await driver.requests.count == 2 }
        model.updateText("/tmp/Second/Be", showHidden: true)
        try await waitUntil { await driver.requests.count == 3 }
        let requests = await driver.requests
        #expect(requests.map(\.directory.path) == ["/tmp/First", "/tmp/Second", "/tmp/Second"])
        #expect(requests.map(\.prefix) == ["A", "B", "Be"])
        #expect(requests.map(\.showHidden) == [false, false, true])
        let winner = URL(fileURLWithPath: "/tmp/Second/Better", isDirectory: true)
        await driver.finish(2, urls: [winner])
        try await waitUntil { !model.isLoading }
        await driver.finish(0, urls: [root])
        await driver.fail(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.suggestions == [winner] && model.errorMessage == nil)
        #expect(model.highlightedIndex == nil)
        #expect(model.suggestion(at: 0, requestID: firstID) == nil)
        #expect(model.suggestion(at: 0, requestID: model.requestID) == winner)
    }

    @Test
    func cancellingDebouncedTypingPreventsAReadWhileChildrenCanLoadImmediately() async throws {
        let driver = AddressSuggestionDriver()
        let model = AddressNavigationModel(suggester: driver, debounce: .seconds(10))
        defer { stop(model, driver) }
        model.beginEditing(at: root)
        model.updateText(root.path + "/C", showHidden: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(await driver.requests.isEmpty)
        model.cancel()
        model.showChildren(of: root, showHidden: true)
        try await waitUntil { await driver.requests.count == 1 }
        let request = await driver.requests[0]
        #expect(request.directory == root && request.prefix.isEmpty && request.showHidden)
        await driver.finish(0, urls: [])
        try await waitUntil { !model.isLoading }
        #expect(model.presentation == .children(root))
    }

    @Test
    func loadingEmptyTruncatedAndErrorStatesRemainDistinct() async throws {
        let driver = AddressSuggestionDriver()
        let model = AddressNavigationModel(suggester: driver, debounce: .zero)
        defer { stop(model, driver) }
        model.showChildren(of: root, showHidden: false)
        #expect(model.isLoading && model.suggestions.isEmpty && model.errorMessage == nil && !model.isTruncated)
        try await waitUntil { await driver.requests.count == 1 }
        await driver.finish(0, urls: [])
        try await waitUntil { !model.isLoading }
        #expect(model.presentation == .children(root) && model.errorMessage == nil && !model.isTruncated)
        model.showChildren(of: root, showHidden: true)
        try await waitUntil { await driver.requests.count == 2 }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        await driver.finish(1, urls: [child], truncated: true)
        try await waitUntil { !model.isLoading }
        #expect(model.suggestions == [child] && model.isTruncated && model.errorMessage == nil)
        model.showChildren(of: root, showHidden: false)
        #expect(!model.isTruncated && model.suggestions.isEmpty)
        try await waitUntil { await driver.requests.count == 3 }
        await driver.fail(2)
        try await waitUntil { !model.isLoading }
        #expect(model.errorMessage != nil && model.suggestions.isEmpty && !model.isTruncated)
    }

    @Test(arguments: [false, true])
    func dismissingOrCancellingInvalidatesPendingResultsAndCapturedActions(_ cancelEditing: Bool) async throws {
        let driver = AddressSuggestionDriver()
        let model = AddressNavigationModel(suggester: driver, debounce: .zero)
        defer { stop(model, driver) }
        model.beginEditing(at: root)
        model.updateText(root.path + "/C", showHidden: false)
        try await waitUntil { await driver.requests.count == 1 }
        let oldID = model.requestID
        if cancelEditing { model.cancel() } else { model.dismissPopup() }
        await driver.finish(0, urls: [root])
        for _ in 0..<10 { await Task.yield() }
        #expect(model.presentation == nil && model.suggestions.isEmpty && !model.isLoading)
        #expect(model.isEditing == !cancelEditing)
        #expect(model.requestID != oldID && model.suggestion(at: 0, requestID: oldID) == nil)
    }

    @Test
    func tabCompletionRequiresAnExplicitHighlightAndPreservesTheActualUnicodePath() async throws {
        let driver = AddressSuggestionDriver()
        let model = AddressNavigationModel(suggester: driver, debounce: .zero)
        defer { stop(model, driver) }
        let child = root.appendingPathComponent("Cafe\u{301} 100% #1", isDirectory: true)
        model.beginEditing(at: root)
        model.updateText(root.path + "/Ca", showHidden: false)
        try await waitUntil { await driver.requests.count == 1 }
        await driver.finish(0, urls: [child])
        try await waitUntil { !model.isLoading }
        let typed = model.text
        #expect(!model.completeHighlighted(showHidden: false) && model.text == typed)
        model.highlight(99)
        #expect(model.highlightedIndex == nil)
        model.moveHighlight(by: 1)
        #expect(model.highlightedIndex == 0)
        #expect(model.submissionURL(relativeTo: root)?.path == typed)
        #expect(model.completeHighlighted(showHidden: true))
        #expect(model.text.utf8.elementsEqual((child.path + "/").utf8))
        #expect(model.isEditing && model.recentAddresses.isEmpty && model.highlightedIndex == nil)
        try await waitUntil { await driver.requests.count == 2 }
        let completedRequest = await driver.requests[1]
        #expect(completedRequest.directory.absoluteString == child.absoluteString)
        #expect(completedRequest.prefix == "" && completedRequest.showHidden)
    }

    @Test
    func sharedHistoryIsBoundedAndDeduplicatesCanonicalFoldersAndArchiveLocations() throws {
        let history = RecentAddressHistory()
        let writer = AddressNavigationModel(recentHistory: history)
        let reader = AddressNavigationModel(recentHistory: history)
        for index in 0..<23 {
            writer.recordSuccessfulSubmission(root.appendingPathComponent("Folder\(index)", isDirectory: true))
        }
        let repeated = root.appendingPathComponent("Folder10", isDirectory: true)
        writer.recordSuccessfulSubmission(repeated.appendingPathComponent("Child/..", isDirectory: true))
        #expect(reader.recentAddresses.count == 20 && reader.recentAddresses.first?.path == repeated.path)
        #expect(reader.recentAddresses.filter { $0.path == repeated.path }.count == 1)
        #expect(!reader.recentAddresses.contains { $0.lastPathComponent == "Folder0" })
        let archive = try ArchiveLocation(archiveURL: root.appendingPathComponent("Fixture.zip"),
                                          components: ["Nested café"]).url
        writer.recordSuccessfulSubmission(archive)
        reader.recordSuccessfulSubmission(archive)
        #expect(writer.recentAddresses == reader.recentAddresses && reader.recentAddresses.count == 20)
        #expect(reader.recentAddresses.first == archive && reader.recentAddresses.filter { $0 == archive }.count == 1)
        reader.beginEditing(at: root)
        reader.showHistory()
        #expect(!reader.isEditing && reader.presentation == .history && reader.suggestions == reader.recentAddresses)
        #expect(reader.highlightedIndex == nil)
        reader.moveHighlight(by: -1)
        #expect(reader.highlightedIndex == 19)
        #expect(AddressNavigationModel().recentAddresses.isEmpty)
    }

    @Test
    func sharedHistoryChangesInvalidateOpenSnapshotsIncludingAnEmptyClear() {
        let history = RecentAddressHistory()
        let writer = AddressNavigationModel(recentHistory: history)
        let reader = AddressNavigationModel(recentHistory: history)
        let next = root.appendingPathComponent("Next", isDirectory: true)
        writer.recordSuccessfulSubmission(root)
        reader.showHistory()
        reader.highlight(0)
        let unchanged = reader.requestID
        writer.recordSuccessfulSubmission(root)
        #expect(reader.requestID == unchanged && reader.highlightedIndex == 0)
        #expect(reader.presentation == .history && reader.suggestion(at: 0, requestID: unchanged) == root)

        writer.recordSuccessfulSubmission(next)
        #expect(reader.requestID != unchanged && reader.presentation == nil && reader.highlightedIndex == nil)
        #expect(reader.suggestions.isEmpty && reader.suggestion(at: 0, requestID: unchanged) == nil)
        reader.showHistory()
        writer.showHistory()
        #expect(reader.suggestions == [next, root])
        let beforeClear = reader.requestID
        writer.clearHistory()
        #expect(history.entries.isEmpty && writer.presentation == nil && reader.presentation == nil)
        #expect(reader.requestID != beforeClear && reader.suggestion(at: 0, requestID: beforeClear) == nil)

        reader.showHistory()
        writer.showHistory()
        let empty = reader.requestID
        writer.clearHistory()
        #expect(reader.requestID != empty && reader.presentation == nil && writer.presentation == nil)
    }

    @Test(arguments: [false, true])
    func sharedHistoryMutationsPreserveUnrelatedRequestsAndDrafts(_ completion: Bool) async throws {
        let history = RecentAddressHistory()
        let writer = AddressNavigationModel(recentHistory: history)
        let driver = AddressSuggestionDriver()
        let reader = AddressNavigationModel(suggester: driver, debounce: .zero, recentHistory: history)
        defer { stop(reader, driver) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        if completion {
            reader.beginEditing(at: root)
            reader.updateText(root.path + "/Ch", showHidden: false)
        } else {
            reader.showChildren(of: root, showHidden: false)
        }
        try await waitUntil { await driver.requests.count == 1 }
        let request = reader.requestID, draft = reader.text
        let presentation: AddressNavigationModel.Presentation = completion ? .completion : .children(root)
        writer.recordSuccessfulSubmission(root)
        writer.clearHistory()
        #expect(reader.requestID == request && reader.presentation == presentation && reader.isLoading)
        #expect(reader.text == draft && reader.isEditing == completion)
        await driver.finish(0, urls: [child])
        try await waitUntil { !reader.isLoading }
        reader.highlight(0)
        writer.recordSuccessfulSubmission(root)
        #expect(reader.requestID == request && reader.presentation == presentation && reader.highlightedIndex == 0)
        #expect(reader.text == draft && reader.suggestion(at: 0, requestID: request) == child)
    }

    @Test
    func sharedHistoryDoesNotRetainTheModel() {
        let history = RecentAddressHistory()
        var reader: AddressNavigationModel? = AddressNavigationModel(recentHistory: history)
        weak var released = reader
        reader?.showHistory()
        reader = nil
        #expect(released == nil)
        let writer = AddressNavigationModel(recentHistory: history)
        writer.recordSuccessfulSubmission(root)
        #expect(history.entries == [root])
    }
}
