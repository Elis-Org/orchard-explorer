import Foundation

enum FolderPresencePath {
    static func components(_ path: String) -> [String]? {
        guard path.utf8.first == 47, !path.utf8.contains(0) else { return nil }
        if path == "/" { return [] }
        let components = path.utf8.dropFirst().split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return components
    }

    static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func contains(_ path: String, under root: String) -> Bool {
        let bytes = path.utf8
        let prefix = root.utf8
        guard bytes.starts(with: prefix) else { return false }
        if root == "/" { return true }
        let remainder = bytes.dropFirst(prefix.count)
        return remainder.isEmpty || remainder.first == 47
    }

    static func foldCase(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func policyPath(_ path: String) -> String {
        let components = foldCase(path).utf8.split(separator: 47)
        var normalized: [String] = []
        for bytes in components {
            let component = String(decoding: bytes, as: UTF8.self)
            if component == ".." { if !normalized.isEmpty { normalized.removeLast() } }
            else if component != "." { normalized.append(component) }
        }
        var value = "/" + normalized.joined(separator: "/")
        for prefix in ["/system/volumes/data", "/private"] where contains(value, under: prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        return value == "/" ? "" : value
    }

    // The input here has already been normalized for conservative policy matching.
    static func isVolumePath(_ path: String) -> Bool {
        contains(path, under: "/volumes")
    }
}

struct FolderPresenceLexicalPolicy: Sendable {
    enum Scope: Equatable, Sendable {
        case ordinary, exactOpen, protectedOptIn, cloudOptIn

        var isOptedIn: Bool { self == .protectedOptIn || self == .cloudOptIn }
    }

    struct Target: Sendable {
        let path: String
        let components: [String]
        let scope: Scope
        let requiresNetwork: Bool
    }

    let options: SidebarBackgroundCheckOptions
    private let homePrefix: String
    private let openedProtectedScopes: Set<URL>

    init(_ request: FolderChildPresenceRequest) {
        options = request.options
        homePrefix = FolderPresencePath.policyPath(request.homeURL.path) + "/"
        openedProtectedScopes = request.openedProtectedScopes
    }

    func target(for url: URL) -> Target? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
            return nil
        }
        let path = url.path
        let normalized = FolderPresencePath.policyPath(path)
        guard let components = FolderPresencePath.components(path),
              let scope = scope(at: path, normalized: normalized) else { return nil }
        return Target(path: path, components: components, scope: scope,
                      requiresNetwork: FolderPresencePath.isVolumePath(normalized))
    }

    func permitsChild(_ path: String) -> Bool {
        scope(at: path, normalized: FolderPresencePath.policyPath(path)) != nil
    }

    private func scope(at path: String, normalized: String) -> Scope? {
        func under(_ root: String) -> Bool { FolderPresencePath.contains(normalized, under: root) }

        guard !under("/network"), !under("/net"), !under("/home"),
              normalized != "/volumes", !under("/volumes") || options.network else { return nil }

        guard normalized.utf8.starts(with: homePrefix.utf8) else { return .ordinary }
        let relative = String(decoding: normalized.utf8.dropFirst(homePrefix.utf8.count), as: UTF8.self)
        func inHome(_ root: String) -> Bool { FolderPresencePath.contains(relative, under: root) }
        func hasExactGrant() -> Bool {
            openedProtectedScopes.contains { FolderPresencePath.exact($0.path, path) }
        }

        let mobileDocuments = "library/mobile documents"
        if inHome("library/cloudstorage") || inHome(mobileDocuments) {
            guard options.cloud else { return nil }
            let cloudDrive = mobileDocuments + "/com~apple~clouddocs"
            if inHome(cloudDrive + "/desktop") || inHome(cloudDrive + "/documents") {
                guard options.protectedLocal || hasExactGrant() else { return nil }
            }
            return .cloudOptIn
        }
        if ["desktop", "documents", "downloads", "library", "pictures", "music", "movies"]
            .contains(where: inHome) {
            if options.protectedLocal { return .protectedOptIn }
            return hasExactGrant() ? .exactOpen : nil
        }
        return .ordinary
    }
}
