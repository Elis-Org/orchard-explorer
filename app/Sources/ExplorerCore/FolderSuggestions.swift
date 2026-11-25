import Darwin
import Foundation

public struct FolderSuggestions: Sendable {
    public let urls: [URL]
    public let isTruncated: Bool

    public init(urls: [URL], isTruncated: Bool = false) {
        self.urls = urls
        self.isTruncated = isTruncated
    }
}

public protocol FolderSuggesting: Sendable {
    func folders(in directory: URL, prefix: String, showHidden: Bool) async throws -> FolderSuggestions
}

/// NATIVE-P11 completion support. FR-NAV-005 / EV-9001 / AT-NAV-005 only
/// documents address focus; this bounded suggestion policy is a macOS choice,
/// not a claim about unobserved Windows completion behavior.
public struct LocalFolderSuggester: FolderSuggesting {
    public init() {}

    public func folders(in directory: URL, prefix: String, showHidden: Bool) async throws -> FolderSuggestions {
        let result = try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            // Check before standardizedFileURL, which can discard a file host.
            guard directory.isFileURL,
                  directory.host == nil || directory.host == "" || directory.host?.lowercased() == "localhost",
                  directory.query == nil, directory.fragment == nil,
                  !directory.path(percentEncoded: false).contains("\0") else { throw CocoaError(.fileReadUnsupportedScheme) }
            let lexicalRoot = directory.standardizedFileURL
            let resolvedRoot = try FileSystemPath.resolvingExisting(lexicalRoot)
            let rootValues = try resolvedRoot.resourceValues(forKeys: [.isDirectoryKey])
            guard rootValues.isDirectory == true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: lexicalRoot.path,
                    NSLocalizedDescriptionKey: "This location is not a folder."])
            }
            try cancellation.checkCancellation()
            guard let iterator = resolvedRoot.withUnsafeFileSystemRepresentation({ opendir($0!) }) else {
                throw Self.nativeError(errno, at: lexicalRoot)
            }
            defer { closedir(iterator) }

            let locale = Locale(identifier: "en_US")
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
            var matches: [URL] = []
            var inspected = 0
            var scanCapped = false
            while inspected < 4_096 {
                try cancellation.checkCancellation()
                errno = 0
                guard let entry = readdir(iterator) else {
                    let code = errno
                    // An iterator error must not look like a complete or partial
                    // success. Only metadata of an individual candidate may be unknown.
                    if code != 0 { throw Self.nativeError(code, at: lexicalRoot) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(validatingCString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                // Hidden, unmatched and undecodable names also consume the scan
                // budget. No unbounded scan hides behind a narrow typed prefix.
                inspected += 1
                scanCapped = inspected == 4_096
                guard let name,
                      showHidden || !name.hasPrefix("."),
                      prefix.isEmpty || name.range(of: prefix,
                          options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: locale) != nil else { continue }
                let candidate = resolvedRoot.appendingPathComponent(name, isDirectory: false)
                guard let values = try? candidate.resourceValues(forKeys: keys),
                      let isLink = values.isSymbolicLink,
                      showHidden || values.isHidden == false else { continue }
                let target = isLink ? try? FileSystemPath.resolvingExisting(candidate)
                    .resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : values
                guard target?.isDirectory == true, target?.isPackage == false else { continue }
                // Like directory listings, directory links are navigable but
                // keep their own lexical path; packages remain file-like entries.
                matches.append(lexicalRoot.appendingPathComponent(name, isDirectory: !isLink))
            }
            try cancellation.checkCancellation()
            matches.sort { left, right in
                let order = left.lastPathComponent.compare(right.lastPathComponent,
                    options: [.numeric, .caseInsensitive], locale: locale)
                return order == .orderedSame ? left.absoluteString < right.absoluteString : order == .orderedAscending
            }
            // Reaching the scan cap is conservatively incomplete, including an
            // exactly 4,096-entry folder: checking another entry would exceed it.
            return FolderSuggestions(urls: Array(matches.prefix(200)), isTruncated: scanCapped || matches.count > 200)
        }
        try Task.checkCancellation()
        return result
    }

    private static func nativeError(_ code: Int32, at url: URL) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
    }
}
