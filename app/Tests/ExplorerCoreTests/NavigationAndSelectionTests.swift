import Foundation
import Testing
@testable import ExplorerCore

final class NavigationAndSelectionTests {
    private let fixture = URL(fileURLWithPath: "/tmp/fixture", isDirectory: true)

    /// FR-NAV-002/003/004, FR-TAB-005 / EV-0290 / AT-NAV-002/003/004, AT-TAB-005.
    @Test
    func testBackForwardAndParentAreIndependentPerHistory() throws {
        let source = fixture.appendingPathComponent("Source", isDirectory: true)
        let target = fixture.appendingPathComponent("Target", isDirectory: true)
        var first = NavigationHistory(initialURL: fixture)
        var second = NavigationHistory(initialURL: target)
        first.navigate(to: source)
        #expect(second.parent?.path == fixture.path)
        second.navigate(to: try #require(second.parent))

        #expect(first.goBack()?.path == fixture.path)
        #expect(first.canGoForward)
        #expect(first.goForward()?.path == source.path)
        #expect(second.goBack()?.path == target.path)
        #expect(first.current.path == source.path)
    }

    @Test
    func virtualLocationsRequireCanonicalTokensAndStayOutOfRenameRemapping() throws {
        let home = try #require(URL(string: "maxplorer-page://home"))
        let tag = try #require(URL(string: "maxplorer-page://home/tag/VMOpYW0gLyDDiXR1ZGU"))
        let parsed = try #require(BrowsingLocation(url: tag))
        #expect(parsed.name == "Téam / Étude")
        #expect(parsed.url == tag)
        #expect(parsed.breadcrumbURLs == [home, tag])
        #expect(parsed.parentURL == home && parsed.physicalURL == nil)
        for spelling in ["maxplorer-page://home/", "maxplorer-page://home/tag/",
                         "maxplorer-page://home/tag/VMOpYW0gLyDDiXR1ZGU=",
                         "maxplorer-page://home/tag/AA", "maxplorer-page://home?view=tags",
                         "maxplorer-page://other", "maxplorer-page://this-mac/#volume"] {
            let invalid = try #require(URL(string: spelling))
            #expect(BrowsingLocation(url: invalid) == nil)
        }
        var history = NavigationHistory(initialURL: fixture)
        history.navigate(to: home)
        history.navigate(to: tag)
        let renamed = fixture.appendingPathComponent("Renamed")
        history.remapLocations { _ in renamed }
        #expect(history.current == tag)
        #expect(history.goBack() == home)
        #expect(history.goBack() == renamed)
    }

    @Test
    func testNewNavigationAfterBackDiscardsOnlyForwardBranch() {
        var history = NavigationHistory(initialURL: fixture)
        let source = fixture.appendingPathComponent("Source", isDirectory: true)
        let target = fixture.appendingPathComponent("Target", isDirectory: true)
        history.navigate(to: source)
        _ = history.goBack()
        history.navigate(to: target)
        #expect(!(history.canGoForward))
        #expect(history.goForward() == nil)
        #expect(history.goBack()?.path == fixture.path)
    }

    @Test
    func testHistoryBoundariesAndRootParentDoNotInventDestinations() {
        var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/", isDirectory: true))
        #expect(!(history.canGoBack))
        #expect(!(history.canGoForward))
        #expect(history.goBack() == nil)
        #expect(history.goForward() == nil)
        #expect(history.parent == nil)
        #expect(history.current.path == "/")
    }

    @Test
    func testRevisitingCurrentURLDoesNotAddDuplicateHistoryEntry() {
        var history = NavigationHistory(initialURL: fixture)
        history.navigate(to: fixture)
        #expect(!(history.canGoBack))
        #expect(history.backStack.isEmpty)
    }

    /// FR-SEL-001/002/007 / EV-0213, EV-0218, EV-9008 / AT-SEL-001/002/007.
    @Test
    func testSelectionRangeUsesAnchorAndToggleAddsNonadjacentItem() {
        let rows = ["alpha2", "alpha10", "alphaCSV", "last"]
        var selection = SelectionState()
        selection.select(rows[0], orderedIDs: rows)
        #expect(selection.selectedIDs == [rows[0]])
        selection.select(rows[1], orderedIDs: rows, extending: true)
        #expect(selection.selectedIDs == [rows[0], rows[1]])
        #expect(selection.anchorID == rows[0])
        #expect(selection.focusedID == rows[1])
        selection.select(rows[3], orderedIDs: rows, toggling: true)
        #expect(selection.selectedIDs == [rows[0], rows[1], rows[3]])
        #expect(!(selection.selectedIDs.contains(rows[2])))
        selection.select(rows[1], orderedIDs: rows, toggling: true)
        #expect(selection.selectedIDs == [rows[0], rows[3]])
    }

    /// FR-SEL-003/008 / EV-0218 / AT-SEL-003/008. UI focus/paint are separate assertions.
    @Test
    func testSelectAllClearAndReconcileKeepOnlyVisibleIdentities() {
        let rows = ["one", "two", "three"]
        var selection = SelectionState()
        selection.selectAll(rows)
        #expect(selection.selectedIDs == Set(rows))
        selection.reconcile(validIDs: ["two", "three"])
        #expect(selection.selectedIDs == ["two", "three"])
        selection.clear()
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test
    func testReconcileRemovesInvalidFocusAndAnchor() {
        var selection = SelectionState()
        selection.select("removed", orderedIDs: ["removed", "remaining"])
        selection.reconcile(validIDs: ["remaining"])
        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.focusedID != "removed")
        #expect(selection.anchorID != "removed")
    }
}
