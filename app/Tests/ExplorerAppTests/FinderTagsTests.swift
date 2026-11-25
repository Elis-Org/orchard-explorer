import Foundation
import Testing
@testable import ExplorerApp

struct FinderTagsTests {
    private func itemSnapshot(_ items: [FinderTagItem], limit: Int = FinderTagsSnapshot.previewLimit) -> FinderTagsSnapshot {
        FinderTagsSnapshot.indexedItems(count: items.count, scope: .allTagged, previewLimit: limit, cancelled: { false }) { index, _ in
            items[index]
        }
    }

    @Test func chooserUsesCanonicalDistinctNamesWithoutFoldingCaseOrAccents() {
        let names = FinderTagsSnapshot.tagNames(from: [
            "Re\u{301}sume\u{301}", "Résumé", "résumé", ["Resume", "Budget 2026", "Résumé"], "", 123
        ])
        #expect(Set(names) == ["Résumé", "résumé", "Resume", "Budget 2026"])
        #expect(names.count == 4)
        #expect(names.first(where: { $0 == "Résumé" })?.utf8.elementsEqual("Résumé".utf8) == true)
    }

    @Test func matchesExactMetadataIncludingMultipleTagsAndSpecialCharacters() throws {
        let file = URL(fileURLWithPath: "/unmounted/Two tags.txt")
        let tags = ["Re\u{301}sume\u{301}", "Work / \"Q2\" *"]
        func match(_ tag: String) -> FinderTagItem? {
            FinderTagItem(indexedURL: file, tags: tags, contentTypes: ["public.plain-text"], matchingAny: [tag])
        }
        #expect(match("Résumé")?.url == file)
        #expect(match("Work / \"Q2\" *")?.name == "Two tags.txt")
        #expect(match("résumé") == nil)
        #expect(match("Resume") == nil)
        #expect(match("*") == nil)
    }

    @Test func namedPredicateIncludesBothUnicodeSpellingsWithoutFoldingCaseOrAccents() throws {
        let composed = "Résumé", decomposed = "Re\u{301}sume\u{301}"
        for input in [composed, decomposed] {
            let either = try #require(FinderTagsProvider.namedPredicate(for: input) as? NSCompoundPredicate)
            #expect(either.compoundPredicateType == .or)
            let comparisons = try #require(either.subpredicates as? [NSComparisonPredicate])
            #expect(comparisons.count == 2 && comparisons.allSatisfy { $0.options.isEmpty })
            let literals = comparisons.compactMap { $0.rightExpression.constantValue as? String }.map { Array($0.utf8) }
            #expect(Set(literals) == [Array(composed.utf8), Array(decomposed.utf8)])
        }
        let partial = "Résume\u{301}"
        let mixed = try #require(FinderTagsProvider.namedPredicate(for: partial) as? NSCompoundPredicate)
        let mixedComparisons = try #require(mixed.subpredicates as? [NSComparisonPredicate])
        let mixedBytes = mixedComparisons.compactMap { $0.rightExpression.constantValue as? String }.map { Array($0.utf8) }
        #expect(Set(mixedBytes) == [Array(composed.utf8), Array(decomposed.utf8), Array(partial.utf8)])
        let literal = try #require(FinderTagsProvider.namedPredicate(for: "Work *") as? NSComparisonPredicate)
        #expect(literal.predicateOperatorType == .equalTo && literal.rightExpression.constantValue as? String == "Work *")
    }

    @Test func indexedDirectoryCanNavigateAndPackageUsesFileOpen() {
        let url = URL(fileURLWithPath: "/unmounted/Example")
        func match(types: [String]) -> FinderTagItem? {
            FinderTagItem(indexedURL: url, tags: ["A"], contentTypes: types, matchingAny: ["A"])
        }
        #expect(match(types: ["public.folder", "public.directory"])?.isDirectory == true)
        #expect(match(types: ["com.apple.package", "public.directory"])?.isDirectory == false)
        #expect(match(types: ["public.plain-text"])?.isDirectory == false)
    }

    @Test func allTaggedRequiresMembershipAndDeduplicatesMultiTagItemsByURL() throws {
        let url = URL(fileURLWithPath: "/unmounted/Tagged folder", isDirectory: false)
        func item(_ names: [String]) -> FinderTagItem? {
            FinderTagItem(indexedURL: url, tags: names, contentTypes: ["public.directory"], matchingAny: nil)
        }
        #expect(item([]) == nil)
        #expect(item([""]) == nil)
        let multi = try #require(item(["Work", "Home"]))
        #expect(multi.isDirectory)
        let duplicate = try #require(item(["Home"]))
        #expect(itemSnapshot([multi, duplicate]).items == [multi])
    }

    @Test func previewLimitCountsDistinctMatchesAndReportsOnlyActualOverflow() throws {
        func item(_ name: String) throws -> FinderTagItem {
            try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/unmounted/" + name),
                                       tags: ["Tag"], contentTypes: ["public.plain-text"], matchingAny: nil))
        }
        let a = try item("A"), b = try item("B"), c = try item("C")
        let full = itemSnapshot([b, b, a, a], limit: 2)
        #expect(full.items == [a, b] && !full.hasMoreItems)
        let overflow = itemSnapshot([b, b, a, a, c], limit: 2)
        #expect(overflow.items == [a, b] && overflow.hasMoreItems)
    }

    @Test func groupedPreviewUsesExactNamesAndCapsDistinctURLsBeforeMemberships() throws {
        func item(_ file: String, _ tags: [String]) throws -> FinderTagItem {
            try #require(FinderTagItem(indexedURL: URL(fileURLWithPath: "/synthetic/" + file),
                tags: tags, contentTypes: ["public.plain-text"], matchingAny: nil))
        }
        let first = try item("A.txt", ["Résumé", "Re\u{301}sume\u{301}", "Work"])
        let duplicate = try item("A.txt", ["résumé", "Work"])
        let second = try item("B.txt", ["Work"])
        let last = try item("C.txt", ["Outside"])
        let snapshot = itemSnapshot([first, duplicate, second, last], limit: 2)
        #expect(snapshot.items.count == 2 && snapshot.hasMoreItems)
        let groups = snapshot.groups(for: .allTagged, matching: { _ in true })
        #expect(Set(groups.map(\.name)) == ["Résumé", "résumé", "Work"])
        #expect(groups.first { $0.name == "Work" }?.items.map(\.url) == [first.url, second.url])
        #expect(groups.first { $0.name == "Résumé" }?.items.map(\.url) == [first.url])
        let filtered = snapshot.groups(for: .allTagged, matching: { $0.hasPrefix("B") })
        #expect(filtered.map(\.name) == ["Work"] && filtered.first?.items.map(\.url) == [second.url])
        let empty = snapshot.groups(for: .named("Unused"), matching: { _ in true })
        #expect(empty.map(\.name) == ["Unused"] && empty.first?.items.isEmpty == true)
        let named = itemSnapshot([last]).groups(for: .named("Outside"), matching: { _ in true })
        #expect(named.first?.items.map(\.url) == [last.url])
    }

    @Test func indexColorHintsRequireUnambiguousSingleTagIntegerMetadata() {
        let samples: [(names: [String], label: Any?)] = [
            (["Work", "Work"], 6), (["Work"], 6), (["Uncolored"], 0),
            (["Multi", "Other"], 4), (["Conflicting"], 4), (["Conflicting"], 5), (["Conflicting"], 4),
            (["Missing"], nil), (["Invalid"], 9), (["Fraction"], 2.5), (["Boolean"], true),
            (["Re\u{301}sume\u{301}", "Résumé"], 3), (["résumé"], 7)
        ]
        #expect(FinderTagsSnapshot.colorHints(from: samples) == ["Work": 6, "Uncolored": 0, "Résumé": 3, "résumé": 7])
    }

    @Test @MainActor func shortcutsStartEmptyAndPersistOnlyExplicitUnlimitedChoices() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldKey = "nativeExplorer.recentFinderTagFilters.v1"
        defaults.set(["Old suggestion"], forKey: oldKey)
        let shortcuts = FinderTagShortcuts(defaults: defaults)
        #expect(shortcuts.names.isEmpty)
        for name in ["Work", "Résumé", "résumé", "One", "Two", "Three"] {
            shortcuts.setVisible(name, visible: true)
        }
        shortcuts.setVisible("Re\u{301}sume\u{301}", visible: true)
        shortcuts.setVisible("", visible: true)
        #expect(shortcuts.names.count == 6 && shortcuts.isVisible("Re\u{301}sume\u{301}"))
        let restored = FinderTagShortcuts(defaults: defaults)
        #expect(restored.names == shortcuts.names && restored.isVisible("résumé"))
        restored.setVisible("Re\u{301}sume\u{301}", visible: false)
        restored.setVisible("Résumé", visible: false)
        #expect(!restored.isVisible("Résumé") && restored.isVisible("résumé"))
        #expect(FinderTagShortcuts(defaults: defaults).names == restored.names)
        #expect(defaults.stringArray(forKey: oldKey) == ["Old suggestion"])
    }

    @Test func selectedScopeQueriesExactNamesOrFallsBackAtTheLiteralLimit() throws {
        let limit = FinderTagsProvider.selectedLiteralLimit
        let names = (1...limit).map { "Tag \($0)" }
        #expect(FinderTagsProvider.itemPredicate(for: .selected([])) == nil)
        let exact = try #require(FinderTagsProvider.itemPredicate(for: .selected(names)) as? NSCompoundPredicate)
        #expect(exact.compoundPredicateType == .or && exact.subpredicates.count == limit)
        // Composed + decomposed spellings use two clauses, even for a single tag.
        let overflow = try #require(FinderTagsProvider.itemPredicate(for: .selected(Array(names.dropLast()) + ["Résumé"])))
        let all = try #require(FinderTagsProvider.itemPredicate(for: .allTagged))
        #expect(overflow.predicateFormat == all.predicateFormat)
    }

    @Test func selectedGroupsRetainEmptyNamesAndLateMatchesAndCancelLargeScans() throws {
        let names = ["All tagged", "Résumé", "Unused"] + (0..<128).map { "Synthetic \($0)" }
        let scope = FinderTagScope.selected(names)
        let started = ContinuousClock.now
        func item(_ index: Int, _ included: Set<String>?) -> FinderTagItem? {
            let tags = index >= 2_000 ? ["All tagged", "Re\u{301}sume\u{301}", "Other"] : ["résumé", "Other"]
            return FinderTagItem(indexedURL: URL(fileURLWithPath: "/synthetic/File-\(index)"),
                                 tags: tags, contentTypes: [], matchingAny: included)
        }
        let snapshot = FinderTagsSnapshot.indexedItems(count: 2_550, scope: scope, cancelled: { false }, itemAt: item)
        let groups = snapshot.groups(for: scope, matching: { _ in true })
        #expect(snapshot.items.count == 550 && !snapshot.hasMoreItems)
        #expect(groups.map(\.name) == FinderTagsSnapshot.tagNames(from: names))
        #expect(groups.first { $0.name == "All tagged" }?.items.count == 550)
        #expect(groups.first { $0.name == "Résumé" }?.items.count == 550)
        #expect(groups.first { $0.name == "Unused" }?.items.isEmpty == true)
        let filtered = snapshot.groups(for: scope, matching: { $0 == "File-2000" })
        #expect(filtered.count == names.count && filtered.filter { !$0.items.isEmpty }.count == 2)
        print("Grouped 2,550 indexed metadata rows with 131 selected names in \(started.duration(to: .now))")
        var reads = 0
        _ = FinderTagsSnapshot.indexedItems(count: 2_550, scope: scope, cancelled: { reads == 12 }) { index, included in
            reads += 1
            return item(index, included)
        }
        #expect(reads == 12)
    }

    @Test @MainActor func allTaggedPreferenceIsIndependentOfTheRealFinderTagAndRestoresEmpty() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["All tagged", "Old choice"], forKey: "nativeExplorer.visibleFinderTags.v1")
        let choices = FinderTagShortcuts(defaults: defaults)
        #expect(!choices.showsAllTagged && choices.scope(for: nil) == .selected(choices.names))
        choices.setShowsAllTagged(true)
        choices.setVisible("All tagged", visible: false)
        #expect(choices.showsAllTagged && choices.scope(for: nil) == .allTagged)
        #expect(choices.scope(for: "All tagged") == .named("All tagged"))
        #expect(FinderTagShortcuts(defaults: defaults).showsAllTagged)
        choices.setShowsAllTagged(false)
        choices.setVisible("Old choice", visible: false)
        let restored = FinderTagShortcuts(defaults: defaults)
        #expect(!restored.showsAllTagged && restored.names.isEmpty && restored.scope(for: nil) == .selected([]))
    }
}
