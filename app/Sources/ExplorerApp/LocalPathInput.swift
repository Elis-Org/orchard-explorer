import Foundation

/// Parses user-entered local paths without interpreting them as commands.
enum LocalPathInput {
    enum Failure: LocalizedError {
        case empty, invalid, absoluteRequired

        var errorDescription: String? {
            switch self {
            case .empty: return "Enter a local path or file URL."
            case .invalid: return "This address is not valid. Enter a local path or file URL."
            case .absoluteRequired: return "Enter an absolute local path or file URL."
            }
        }
    }

    struct Parsed {
        let components: [String]
        let requiresDirectory: Bool
        let isExplicitFileURL: Bool

        var url: URL {
            URL(fileURLWithPath: "/" + components.joined(separator: "/"),
                isDirectory: requiresDirectory || components.isEmpty)
        }
    }

    /// With no base, ordinary paths must be absolute or expand from a tilde.
    static func resolve(_ text: String, relativeTo directory: URL? = nil) throws -> URL {
        try parse(text, relativeToPath: directory?.path).url
    }

    static func parse(_ text: String, relativeToPath base: String?) throws -> Parsed {
        guard !text.isEmpty else { throw Failure.empty }
        guard !text.contains("\0") else { throw Failure.invalid }
        let isFileURL = text.prefix(5).lowercased() == "file:"
        let path: String
        if isFileURL {
            path = try decodeFilePath(text.dropFirst(5))
        } else {
            guard text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil else {
                throw Failure.invalid
            }
            path = text.hasPrefix("~") ? (text as NSString).expandingTildeInPath : text
        }
        var components: [String]
        if path.hasPrefix("/") {
            components = []
        } else if let base, base.hasPrefix("/") {
            components = base.split(separator: "/").map(String.init)
        } else {
            throw Failure.absoluteRequired
        }
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(String(component))
            }
        }
        return Parsed(components: components, requiresDirectory: path.hasSuffix("/") || path.hasSuffix("/."),
                      isExplicitFileURL: isFileURL)
    }

    /// Validate the existing URL-based folder-navigation boundary separately
    /// from raw text. A Foundation file URL can encode literal POSIX names.
    static func isValidFileURL(_ url: URL) -> Bool {
        url.isFileURL && isLocalAuthority(url.host ?? "") && url.user == nil
            && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && !url.path(percentEncoded: false).contains("\0")
    }

    private static func isLocalAuthority(_ value: String) -> Bool {
        value.isEmpty || value.lowercased() == "localhost"
    }

    private static func decodeFilePath(_ suffix: Substring) throws -> String {
        var encoded = suffix
        if encoded.hasPrefix("//") {
            let authorityAndPath = encoded.dropFirst(2)
            guard let slash = authorityAndPath.firstIndex(of: "/"),
                  isLocalAuthority(String(authorityAndPath[..<slash])) else { throw Failure.invalid }
            encoded = authorityAndPath[slash...]
        }
        // Inspect the raw URI before Foundation can repair invalid escapes or
        // canonicalize a percent-encoded authority. Decode each component once.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/%")
        guard encoded.hasPrefix("/"), encoded.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.invalid
        }
        let components = try encoded.split(separator: "/", omittingEmptySubsequences: false).map { part in
            guard let decoded = String(part).removingPercentEncoding,
                  !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("\0") else {
                throw Failure.invalid
            }
            return decoded
        }
        return components.joined(separator: "/")
    }
}
