import Foundation

/// NATIVE-P20: a lexical location inside one physical archive. This non-file
/// URL is navigation state, never a path or authority for filesystem operations.
public struct ArchiveLocation: Hashable, Sendable {
    public let archiveURL: URL
    public let components: [String]
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(archiveURL: URL, components: [String] = []) throws {
        guard Self.validPhysicalURL(archiveURL) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let path = archiveURL.standardizedFileURL.path
        guard path != "/", components.count <= 128,
              components.allSatisfy(Self.validComponent) else { throw ZIPListingError.invalidPath }
        self.archiveURL = URL(fileURLWithPath: path, isDirectory: false)
        self.components = components
    }

    public init?(url: URL) {
        guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parsed.scheme == "maxplorer-zip", parsed.host == "archive",
              parsed.user == nil, parsed.password == nil, parsed.port == nil,
              parsed.fragment == nil, let query = parsed.queryItems, query.count == 1,
              query[0].name == "file", let text = query[0].value,
              let archive = URL(string: text), Self.validPhysicalURL(archive) else { return nil }
        // Split before decoding: an escaped slash must never manufacture a
        // component or move the physical/virtual boundary.
        let encoded = parsed.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first == "", encoded.count > 1 else { return nil }
        var parts: [String] = []
        for part in encoded.dropFirst() {
            guard let value = String(part).removingPercentEncoding,
                  !value.isEmpty, !value.contains("/"), !value.contains("\0") else { return nil }
            parts.append(value)
        }
        let physical = archive.standardizedFileURL.path.split(separator: "/").map(String.init)
        guard parts.count >= physical.count,
              zip(parts, physical).allSatisfy({ Data($0.utf8) == Data($1.utf8) }),
              let location = try? Self(archiveURL: archive, components: Array(parts.dropFirst(physical.count))),
              location.url.absoluteString == url.absoluteString else { return nil }
        self = location
    }

    public var url: URL {
        var value = URLComponents()
        value.scheme = "maxplorer-zip"
        value.host = "archive"
        let physical = archiveURL.path.split(separator: "/").map(String.init)
        value.percentEncodedPath = "/" + (physical + components).map(Self.escape).joined(separator: "/")
        // queryItems intentionally does not escape every query delimiter. Encode
        // the complete nested URL exactly once, with ASCII unreserved bytes only.
        value.percentEncodedQueryItems = [URLQueryItem(name: "file", value: Self.escape(archiveURL.absoluteString))]
        return value.url!
    }

    public var displayPath: String { archiveURL.path + (components.isEmpty ? "" : "/" + components.joined(separator: "/")) }
    public var name: String { components.last ?? archiveURL.lastPathComponent }
    public var parentURL: URL {
        if components.isEmpty { return archiveURL.deletingLastPathComponent() }
        return try! Self(archiveURL: archiveURL, components: Array(components.dropLast())).url
    }
    public var breadcrumbURLs: [URL] {
        var result = BrowsingLocation.filesystem(archiveURL.deletingLastPathComponent()).breadcrumbURLs
        result.append(try! Self(archiveURL: archiveURL).url)
        for index in components.indices {
            result.append(try! Self(archiveURL: archiveURL, components: Array(components.prefix(index + 1))).url)
        }
        return result
    }

    public static func isZIPFile(_ url: URL) -> Bool { validPhysicalURL(url) && url.pathExtension.lowercased() == "zip" }
    static func validPhysicalURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.query == nil && url.fragment == nil && !url.path.contains("\0")
    }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.contains("\0") && value.utf8.count <= 4_096
    }
    private static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.archiveURL.path == rhs.archiveURL.path
            && lhs.components.map { Data($0.utf8) } == rhs.components.map { Data($0.utf8) }
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(archiveURL.path)
        for component in components { hasher.combine(Data(component.utf8)) }
    }
}

/// A built-in navigation destination. A page URL represents a view.
public enum BrowserPage: Hashable, Sendable {
    case home, thisMac, tag(String)

    private static let homeAddress = "maxplorer-page://home"
    private static let macAddress = "maxplorer-page://this-mac"
    private static let tagPrefix = homeAddress + "/tag/"

    public init?(url: URL) {
        let address = url.absoluteString
        switch address {
        case Self.homeAddress: self = .home
        case Self.macAddress: self = .thisMac
        default:
            guard address.hasPrefix(Self.tagPrefix) else { return nil }
            let token = address.dropFirst(Self.tagPrefix.count)
            let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padding = String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64 + padding), let name = String(data: bytes, encoding: .utf8),
                  !name.isEmpty, !name.contains("\0") else { return nil }
            self = .tag(name)
            guard self.url.absoluteString == address else { return nil }
        }
    }

    public var url: URL {
        switch self {
        case .home: return URL(string: Self.homeAddress)!
        case .thisMac: return URL(string: Self.macAddress)!
        case .tag(let name):
            let bytes = Data(name.precomposedStringWithCanonicalMapping.utf8)
            let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return URL(string: Self.tagPrefix + token)!
        }
    }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .thisMac: return "This Mac"
        case .tag(let name): return name
        }
    }

    public var parent: BrowserPage? {
        if case .tag = self { return .home }
        return nil
    }
}

/// Centralizes lexical navigation policy. It does not assert that a physical
/// URL exists or is a directory, nor grant permission to mutate it.
public enum BrowsingLocation: Hashable, Sendable {
    case filesystem(URL)
    case archive(ArchiveLocation)
    case page(BrowserPage)

    public init?(url: URL) {
        if ArchiveLocation.validPhysicalURL(url) { self = .filesystem(url.standardizedFileURL) }
        else if let page = BrowserPage(url: url) { self = .page(page) }
        else if let location = ArchiveLocation(url: url) { self = .archive(location) }
        else { return nil }
    }
    public var url: URL {
        switch self {
        case .filesystem(let url): return url.standardizedFileURL
        case .archive(let value): return value.url
        case .page(let page): return page.url
        }
    }
    public var displayPath: String {
        switch self {
        case .filesystem: return url.path
        case .archive(let value): return value.displayPath
        case .page(let page): return page.parent.map { $0.title + " › Tags › " + page.title } ?? page.title
        }
    }
    public var name: String {
        if case .page(let page) = self { return page.title }
        return displayPath == "/" ? "/" : url.lastPathComponent
    }
    public var physicalURL: URL? { if case .filesystem = self { return url }; return nil }
    public var parentURL: URL? {
        switch self {
        case .page(let page): return page.parent?.url
        case .archive(let value): return value.parentURL
        case .filesystem:
            let parent = url.deletingLastPathComponent().standardizedFileURL
            return parent.path == url.path ? nil : parent
        }
    }
    public var breadcrumbURLs: [URL] {
        if case .page(let page) = self { return [page.parent?.url, page.url].compactMap { $0 } }
        if case .archive(let value) = self { return value.breadcrumbURLs }
        var result: [URL] = [], current = url
        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return result.reversed()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.filesystem, .filesystem): return lhs.url.path == rhs.url.path
        case let (.archive(a), .archive(b)): return a == b
        case let (.page(a), .page(b)): return a == b
        default: return false
        }
    }
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .filesystem: hasher.combine(0); hasher.combine(url.path)
        case .archive(let value): hasher.combine(1); hasher.combine(value)
        case .page(let page): hasher.combine(2); hasher.combine(page)
        }
    }

    /// Immediate displayed child on a strict ancestor path. Archive root is
    /// represented by its physical ZIP row when the ancestor is outside it.
    public static func childOnPath(from origin: URL, to destination: URL) -> URL? {
        guard var child = Self(url: origin), let ancestor = Self(url: destination), child != ancestor else { return nil }
        while let parentURL = child.parentURL, let parent = Self(url: parentURL) {
            if parent == ancestor {
                if case .archive(let archive) = child, archive.components.isEmpty { return archive.archiveURL }
                return child.url
            }
            child = parent
        }
        return nil
    }
}
