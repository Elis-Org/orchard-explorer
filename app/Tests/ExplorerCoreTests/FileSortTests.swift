import Foundation
import Testing
@testable import ExplorerCore

final class FileSortTests {
    private func item(_ name: String, directory: Bool = false, size: Int64? = 1,
                      modified: TimeInterval = 1, kind: String = "Text Document") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/fixture").appendingPathComponent(name),
                 name: name, isDirectory: directory, isSymbolicLink: false,
                 size: directory ? nil : size, modifiedAt: Date(timeIntervalSince1970: modified),
                 kind: directory ? "Folder" : kind)
    }

    /// FR-VIEW-009 / EV-0334 / AT-VIEW-009. Captured descending reverses folders too.
    @Test
    func testNaturalNameOrderAndFullDescendingReversal() {
        let items = [item("zero bytes.txt", size: 0), item("Alpha 10.txt"),
                     item("Target", directory: true), item("Alpha 2.txt"),
                     item("Empty", directory: true)]
        let ascending = FileSort().sorted(items)
        #expect(ascending.map(\.name) == ["Empty", "Target", "Alpha 2.txt", "Alpha 10.txt", "zero bytes.txt"])
        let descending = FileSort(key: .name, ascending: false).sorted(items)
        #expect(descending.map(\.id) == ascending.reversed().map(\.id))
        #expect(descending.first?.name == "zero bytes.txt")
        #expect(descending.last?.name == "Empty")
    }

    /// EV-0334 mixed-case/accented file ordering. POSIX uppercase grouping is not the oracle.
    @Test
    func testMixedCaseAndAccentedNamesFollowCapturedEnglishOrder() {
        let names = ["Open Alpha", "Café 東京 (v1) [draft].txt", "Alpha 10.txt",
                     "one page.pdf", "color sample.png", "bundle.zip", "Alpha 2.txt"]
        #expect(FileSort().sorted(names.map { item($0) }).map(\.name) ==
                ["Alpha 2.txt", "Alpha 10.txt", "bundle.zip", "Café 東京 (v1) [draft].txt",
                 "color sample.png", "one page.pdf", "Open Alpha"])
    }

    /// FR-VIEW-002 / EV-9003 / AT-VIEW-002 is documented; tests the chosen macOS comparator.
    @Test
    func testModifiedDateAndSizeCriteriaOrderDistinctFiles() {
        let items = [item("old-large.txt", size: 90, modified: 1),
                     item("new-small.txt", size: 2, modified: 3),
                     item("middle.txt", size: 50, modified: 2)]
        #expect(FileSort(key: .modifiedAt).sorted(items).map(\.name) == ["old-large.txt", "middle.txt", "new-small.txt"])
        #expect(FileSort(key: .size).sorted(items).map(\.name) == ["new-small.txt", "middle.txt", "old-large.txt"])
        #expect(FileSort(key: .size, ascending: false).sorted(items).map(\.name) == ["old-large.txt", "middle.txt", "new-small.txt"])
    }

    @Test
    func testEqualMetadataHasStableNameTieBreakAcrossInputOrder() {
        let items = [item("beta.txt"), item("alpha.txt"), item("gamma.txt")]
        for key in [SortKey.modifiedAt, .size, .kind] {
            let sort = FileSort(key: key)
            #expect(sort.sorted(items).map(\.id) == sort.sorted(Array(items.reversed())).map(\.id))
            #expect(Set(sort.sorted(items).map(\.id)) == Set(items.map(\.id)))
        }
    }
}
