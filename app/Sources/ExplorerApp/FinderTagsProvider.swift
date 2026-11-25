import CoreFoundation
import Foundation

struct FinderTagItem: Equatable, Sendable, Identifiable {
    let url: URL
    let isDirectory: Bool
    private(set) var tags: [String]
    var id: URL { url }
    var name: String { url.lastPathComponent }

    init?(indexedURL: URL, tags: [String], contentTypes: [String], matchingAny selected: Set<String>? = nil) {
        guard indexedURL.isFileURL, !HomeFileLocations.isInTrash(indexedURL) else { return nil }
        guard selected?.isDisjoint(with: tags) != true else { return nil }
        let names = FinderTagsSnapshot.tagNames(from: tags)
        guard !names.isEmpty else { return nil }
        self.tags = names
        url = indexedURL.standardizedFileURL
        isDirectory = contentTypes.contains("public.directory")
            && !contentTypes.contains("com.apple.package") && !contentTypes.contains("com.apple.bundle")
    }

    mutating func mergeMemberships(_ other: FinderTagItem) {
        guard tags != other.tags else { return }
        tags = FinderTagsSnapshot.tagNames(from: tags + other.tags)
    }
}

struct FinderTagGroup: Equatable, Sendable, Identifiable {
    let name: String
    let items: [FinderTagItem]
    var id: String { name }
}

struct FinderTagsSnapshot: Equatable, Sendable {
    static let previewLimit = 500
    let names: [String]
    let items: [FinderTagItem]
    var hasMoreItems = false
    var indexedColorHints: [String: Int] = [:]

    static func tagNames(from values: [Any]) -> [String] {
        var names = Set<String>()
        for value in values {
            let tags = value as? [String] ?? (value as? String).map { [$0] } ?? []
            for name in tags where !name.isEmpty { names.insert(name.precomposedStringWithCanonicalMapping) }
        }
        return names.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }

    /// A multi-tag item's single filesystem label cannot identify a particular tag's color.
    static func colorHints(from samples: some Sequence<(names: [String], label: Any?)>) -> [String: Int] {
        var hints: [String: Int] = [:]
        var conflicting: Set<String> = []
        for sample in samples {
            guard let number = sample.label as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (0...7).contains(number.intValue), number.doubleValue == Double(number.intValue) else { continue }
            let names = tagNames(from: sample.names)
            guard names.count == 1, let name = names.first, !conflicting.contains(name) else { continue }
            if let previous = hints[name], previous != number.intValue {
                hints.removeValue(forKey: name)
                conflicting.insert(name)
            } else { hints[name] = number.intValue }
        }
        return hints
    }

    func groups(for scope: FinderTagScope, matching: (String) -> Bool) -> [FinderTagGroup] {
        switch scope {
        case .names: return []
        case .named(let name):
            return [FinderTagGroup(name: name.precomposedStringWithCanonicalMapping,
                                   items: items.filter { $0.tags.contains(name) && matching($0.name) })]
        case .selected, .allTagged:
            let selected = scope.selectedNames
            var members: [String: [FinderTagItem]] = [:]
            for item in items where matching(item.name) {
                for name in item.tags where selected?.contains(name) != false {
                    members[name, default: []].append(item)
                }
            }
            let names = Self.tagNames(from: Array(selected ?? Set(members.keys)))
            return names.map { FinderTagGroup(name: $0, items: members[$0] ?? []) }
        }
    }

    static func indexedItems(count: Int, scope: FinderTagScope, previewLimit: Int = FinderTagsSnapshot.previewLimit,
                             cancelled: () -> Bool, itemAt: (Int, Set<String>?) -> FinderTagItem?) -> Self {
        let selected = scope.selectedNames
        let limit = scope == .allTagged ? previewLimit : nil
        var positions: [URL: Int] = [:]
        var items: [FinderTagItem] = []
        var hasMore = false
        for index in 0..<count {
            guard !cancelled() else { return Self(names: [], items: []) }
            guard let item = itemAt(index, selected) else { continue }
            if let position = positions[item.url] {
                items[position].mergeMemberships(item)
                continue
            }
            if let limit, items.count >= limit { hasMore = true; break }
            positions[item.url] = items.count
            items.append(item)
        }
        items.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        return Self(names: [], items: items, hasMoreItems: hasMore)
    }
}

enum FinderTagScope: Hashable, Sendable {
    case names, allTagged, named(String), selected([String])

    var selectedNames: Set<String>? {
        switch self {
        case .names, .allTagged: return nil
        case .named(let name): return [name]
        case .selected(let names): return Set(names)
        }
    }
}

struct FinderTagsProvider {
    private static let tagsKey = "kMDItemUserTags"

    private static let colorSampleLimit = 100

    // Keep a single Spotlight session and bound its literal expression size. Larger choices
    // use its indexed tagged-items predicate and the same exact in-memory membership filter.
    static let selectedLiteralLimit = 64

    private static func spellings(of name: String) -> [String] {
        let variants = [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping, name]
        var encodings = Set<[UInt8]>()
        return variants.filter { encodings.insert(Array($0.utf8)).inserted }
    }

    private static func exactPredicate(_ literals: [String]) -> NSPredicate {
        let predicates = literals.map { NSPredicate(format: "%K == %@", tagsKey, $0) }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }

    static func namedPredicate(for name: String) -> NSPredicate { exactPredicate(spellings(of: name)) }

    static func itemPredicate(for scope: FinderTagScope) -> NSPredicate? {
        switch scope {
        case .named(let name): return namedPredicate(for: name)
        case .selected(let names):
            guard !names.isEmpty else { return nil }
            if names.count <= selectedLiteralLimit {
                let literals = names.flatMap(spellings(of:))
                if literals.count <= selectedLiteralLimit { return exactPredicate(literals) }
            }
        case .allTagged, .names: break
        }
        return NSPredicate(format: "%K LIKE %@", tagsKey, "*")
    }

    func snapshots(for tag: String?) -> AsyncThrowingStream<FinderTagsSnapshot, Error> {
        snapshots(for: tag.map(FinderTagScope.named) ?? .names)
    }

    func snapshots(for scope: FinderTagScope) -> AsyncThrowingStream<FinderTagsSnapshot, Error> {
        guard let predicate = Self.itemPredicate(for: scope) else {
            return AsyncThrowingStream { continuation in
                continuation.yield(FinderTagsSnapshot(names: [], items: []))
                continuation.finish()
            }
        }
        return SpotlightSnapshots.live(name: "Finder tag search", configure: { query in
            query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
            query.predicate = predicate
            if scope == .names { query.valueListAttributes = [Self.tagsKey] }
            if scope == .allTagged {
                query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true),
                                         NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
            }
        }, snapshot: { query, cancelled in
            if scope == .names {
                let values = (query.valueLists[Self.tagsKey] ?? []).compactMap(\.value)
                var samples: [(names: [String], label: Any?)] = []
                for index in 0..<min(Self.colorSampleLimit, query.resultCount) {
                    guard !cancelled() else { break }
                    guard let metadata = query.result(at: index) as? NSMetadataItem,
                          let names = metadata.value(forAttribute: Self.tagsKey) as? [String] else { continue }
                    samples.append((names, metadata.value(forAttribute: "kMDItemFSLabel")))
                }
                return FinderTagsSnapshot(names: FinderTagsSnapshot.tagNames(from: values), items: [],
                                          indexedColorHints: FinderTagsSnapshot.colorHints(from: samples))
            }
            return FinderTagsSnapshot.indexedItems(count: query.resultCount, scope: scope, cancelled: cancelled) { index, selected in
                guard let metadata = query.result(at: index) as? NSMetadataItem,
                      let names = metadata.value(forAttribute: Self.tagsKey) as? [String],
                      selected?.isDisjoint(with: names) != true,
                      let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                let types = metadata.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
                return FinderTagItem(indexedURL: URL(fileURLWithPath: path, isDirectory: false), tags: names, contentTypes: types)
            }
        })
    }
}
