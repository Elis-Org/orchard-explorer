import Foundation

/// One instance per tab. Commit navigation only after its directory read succeeds.
/// FR-NAV-002/003/004, FR-TAB-005; EV-0290; AT-NAV-002/003/004, AT-TAB-005.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []

    public init(initialURL: URL) { current = BrowsingLocation(url: initialURL)?.url ?? initialURL }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var parent: URL? {
        BrowsingLocation(url: current)?.parentURL
    }

    public mutating func navigate(to url: URL) {
        let destination = BrowsingLocation(url: url)?.url ?? url
        if let old = BrowsingLocation(url: current), let next = BrowsingLocation(url: destination) {
            guard old != next else { return }
        } else if destination == current { return }
        backStack.append(current)
        current = destination
        forwardStack.removeAll()
    }

    /// Resolve an uncommitted navigation destination without inventing a second
    /// Back entry or rewriting unrelated locations already in either stack.
    public mutating func replaceCurrent(with url: URL) {
        current = BrowsingLocation(url: url)?.url ?? url
    }

    /// Reconciles committed renames without representing a new user navigation.
    /// Ordering and repeated history entries are preserved exactly.
    public mutating func remapLocations(_ transform: (URL) -> URL) {
        func mapped(_ url: URL) -> URL {
            guard let location = BrowsingLocation(url: url) else { return url }
            if case .page = location { return url }
            let value = transform(url)
            return BrowsingLocation(url: value)?.url ?? value
        }
        current = mapped(current)
        backStack = backStack.map(mapped)
        forwardStack = forwardStack.map(mapped)
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return current
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return current
    }
}
