import Combine
import Foundation

@MainActor
final class FinderTagShortcuts: ObservableObject {
    private static let key = "nativeExplorer.visibleFinderTags.v1"
    private static let allKey = "nativeExplorer.showsAllTagged.v1"
    @Published private(set) var names: [String]
    @Published private(set) var showsAllTagged: Bool
    private let defaults: UserDefaults?
    struct Change {
        let defaultChanged: Bool
        let removedName: String?
    }
    private let changed = PassthroughSubject<Change, Never>()
    var changes: AnyPublisher<Change, Never> { changed.eraseToAnyPublisher() }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        showsAllTagged = defaults?.bool(forKey: Self.allKey) ?? false
        names = FinderTagsSnapshot.tagNames(from: defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func isVisible(_ name: String) -> Bool { names.contains(name) }

    func scope(for name: String?) -> FinderTagScope {
        if let name { return .named(name) }
        return showsAllTagged ? .allTagged : .selected(names)
    }

    func setShowsAllTagged(_ visible: Bool) {
        guard showsAllTagged != visible else { return }
        showsAllTagged = visible
        changed.send(Change(defaultChanged: true, removedName: nil))
        persist(visible, forKey: Self.allKey)
    }

    func setVisible(_ name: String, visible: Bool) {
        let tag = name.precomposedStringWithCanonicalMapping
        guard !tag.isEmpty, isVisible(tag) != visible else { return }
        if visible {
            names = FinderTagsSnapshot.tagNames(from: names + [tag])
        } else {
            names.removeAll { $0 == tag }
        }
        changed.send(Change(defaultChanged: !showsAllTagged, removedName: visible ? nil : tag))
        persist(names, forKey: Self.key)
    }

    private func persist(_ value: Any, forKey key: String) {
        if let defaults, defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] == nil {
            defaults.set(value, forKey: key)
        }
    }
}
