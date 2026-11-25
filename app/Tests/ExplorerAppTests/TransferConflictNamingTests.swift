import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

struct TransferConflictNamingTests {
    private func item() -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/synthetic/report.tar.gz"), name: "report.tar.gz",
                 isDirectory: false, isSymbolicLink: false, size: 12, modifiedAt: nil, kind: "Archive")
    }

    @Test(arguments: [false, true])
    func ordinaryCollisionRequiresChoiceBeforeGeneratingAnyName(archive: Bool) throws {
        var naming = TransferConflictNaming(item: item(), mode: archive ? .archive : .physical)
        let advancedBeforeChoice = naming.advanceAfterCollision()
        #expect(!advancedBeforeChoice)
        #expect(naming.name == "report.tar.gz")
        try naming.keepBoth()
        #expect(naming.name == (archive ? "report.tar - Copy.gz" : "report.tar (2).gz"))
        if archive {
            let advancedAutomatically = naming.advanceAfterCollision()
            #expect(!advancedAutomatically)
            #expect(naming.name == "report.tar - Copy.gz")
            try naming.keepBoth()
        } else {
            let advancedAutomatically = naming.advanceAfterCollision()
            #expect(advancedAutomatically)
        }
        #expect(naming.name == (archive ? "report.tar - Copy (2).gz" : "report.tar (3).gz"))
    }

    @Test
    func physicalThresholdStopsAutomaticRetryButKeepsExplicitChoice() throws {
        var naming = TransferConflictNaming(item: item(), mode: .physical)
        try naming.keepBoth()
        var retries = 0
        for _ in 2...10_000 { if naming.advanceAfterCollision() { retries += 1 } }
        #expect(retries == 9_999)
        #expect(naming.name == "report.tar (10001).gz")
        let advancedAtThreshold = naming.advanceAfterCollision()
        #expect(!advancedAtThreshold)
        try naming.keepBoth()
        #expect(naming.name == "report.tar (10002).gz")
        let advancedAfterExplicitChoice = naming.advanceAfterCollision()
        #expect(!advancedAfterExplicitChoice)
    }

    @Test
    func archiveLimitRefusesAnAdditionalGeneratedDestination() throws {
        var naming = TransferConflictNaming(item: item(), mode: .archive)
        for _ in 1...10_000 { try naming.keepBoth() }
        #expect(naming.name == "report.tar - Copy (10000).gz")
        do {
            try naming.keepBoth()
            Issue.record("Archive naming exceeded its hard limit")
        } catch ArchiveOperationError.collision(let name) {
            #expect(name == "report.tar - Copy (10000).gz")
        }
        #expect(naming.name == "report.tar - Copy (10000).gz")
        let advancedAfterLimit = naming.advanceAfterCollision()
        #expect(!advancedAfterLimit)
    }

    @Test
    func physicalNumericNamesPreserveExistingStemRules() throws {
        let cases: [(String, Bool, Bool, String)] = [
            ("a.txt", false, false, "a (2).txt"),
            ("archive.tar.gz", false, false, "archive.tar (2).gz"),
            (".hidden.txt", false, false, ".hidden.txt (2)"),
            ("folder.ext", true, false, "folder.ext (2)"),
            ("shortcut.txt", false, true, "shortcut.txt (2)"),
            ("already (7).txt", false, false, "already (7) (2).txt")
        ]
        for (name, directory, link, expected) in cases {
            let item = FileItem(url: URL(fileURLWithPath: "/synthetic/" + name), name: name,
                isDirectory: directory, isSymbolicLink: link, size: nil, modifiedAt: nil, kind: "Test")
            var naming = TransferConflictNaming(item: item, mode: .physical)
            try naming.keepBoth()
            #expect(naming.name == expected)
        }
    }

    @Test(arguments: [false, true])
    func firstInspectedIdentityFixesStyleThroughLaterChoicesAndThreshold(sameItem: Bool) throws {
        var naming = TransferConflictNaming(item: item(), mode: .physical)
        try naming.keepBoth(sameItem: sameItem)
        #expect(naming.name == (sameItem ? "report.tar - Copy.gz" : "report.tar (2).gz"))
        // A later explicit choice can compare a different candidate; the style
        // still belongs to the first conflict, never to that candidate's name.
        try naming.keepBoth(sameItem: !sameItem)
        #expect(naming.name == (sameItem ? "report.tar - Copy (2).gz" : "report.tar (3).gz"))
        var retries = 0
        for _ in 3...10_000 { if naming.advanceAfterCollision() { retries += 1 } }
        #expect(retries == 9_998)
        #expect(naming.name == (sameItem ? "report.tar - Copy (10000).gz" : "report.tar (10001).gz"))
        let pastThreshold = naming.advanceAfterCollision()
        #expect(!pastThreshold)
        try naming.keepBoth(sameItem: !sameItem)
        #expect(naming.name == (sameItem ? "report.tar - Copy (10001).gz" : "report.tar (10002).gz"))
    }
}
