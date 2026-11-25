import Foundation
import Testing
@testable import ExplorerCore

/// NATIVE-P20 / FR-EXT-005/007. Virtual locations never become local-file
/// authority; URL history must distinguish the containing archive as well as
/// the member path. These regressions compile against the pre-ZIP baseline.
@Suite struct ZIPBoundaryTests {
    private func location(_ archive: String, _ member: String = "") throws -> URL {
        try ArchiveLocation(archiveURL: URL(fileURLWithPath: archive),
                            components: member.isEmpty ? [] : member.split(separator: "/").map(String.init)).url
    }

    @Test func archiveRootParentReturnsToContainingPhysicalFolder() throws {
        let root = try location("/tmp/Maxplorer-P20/Example.zip")
        let history = NavigationHistory(initialURL: root)
        #expect(history.current == root)
        #expect(history.parent == URL(fileURLWithPath: "/tmp/Maxplorer-P20", isDirectory: true))
    }

    @Test func sameMemberInDifferentArchivesCreatesIndependentHistoryEntries() throws {
        let first = try location("/tmp/Maxplorer-P20/First.zip", "inside/nested")
        let second = try location("/tmp/Maxplorer-P20/Second.zip", "inside/nested")
        var history = NavigationHistory(initialURL: first)
        history.navigate(to: second)
        #expect(history.current == second)
        #expect(history.backStack == [first])
        #expect(history.goBack() == first)
        #expect(history.goForward() == second)
    }

    @Test func archiveParentsPreserveContainerAndVirtualScheme() throws {
        let nested = try location("/tmp/Maxplorer-P20/Example.zip", "inside/nested")
        let parent = try location("/tmp/Maxplorer-P20/Example.zip", "inside")
        #expect(NavigationHistory(initialURL: nested).parent == parent)
        #expect(parent.isFileURL == false)
    }

    @Test func archiveEntriesWithoutLocalIdentityCannotPassPhysicalRoutingValidation() async throws {
        let virtual = try location("/tmp/Maxplorer-P20/Example.zip", "note.txt")
        let item = FileItem(url: virtual, name: "note.txt", isDirectory: false,
                            isSymbolicLink: false, size: 12, modifiedAt: nil, kind: "Text document")
        #expect(item.url == virtual)
        #expect(item.url.isFileURL == false)
        #expect(await RoutingTargetValidation.isCurrent(item) == false)
        #expect(await RoutingTargetValidation.isCurrentFolder(virtual, identity: nil) == false)
    }
}
