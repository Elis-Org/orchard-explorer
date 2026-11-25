import ExplorerCore
import Foundation

/// Shared presentation/classification only; existence and operation authority
/// remain the responsibility of the listing and filesystem services.
enum BrowsingPresentation {
    static func path(_ url: URL) -> String { BrowsingLocation(url: url)?.displayPath ?? url.path }
    static func title(_ url: URL) -> String {
        guard let location = BrowsingLocation(url: url) else { return url.lastPathComponent }
        return location.physicalURL?.path == "/" ? "Macintosh HD" : location.name
    }
    static func parentPath(_ url: URL) -> String {
        BrowsingLocation(url: url)?.parentURL.map(path) ?? path(url)
    }
    static func isPhysical(_ item: FileItem) -> Bool {
        item.archiveRevision == nil && BrowsingLocation(url: item.url)?.physicalURL != nil
    }
}

enum FileActivationTarget: Sendable {
    case physicalFolder(URL), physicalZIP(URL), virtualFolder(URL), virtualFile, ordinaryFile(URL), unsupported

    init(_ item: FileItem) {
        guard let location = BrowsingLocation(url: item.url) else { self = .unsupported; return }
        switch location {
        case .page: self = .unsupported
        case .archive:
            guard item.archiveRevision != nil, !item.isSymbolicLink else { self = .unsupported; return }
            self = item.isDirectory && !item.isSymbolicLink ? .virtualFolder(location.url) : .virtualFile
        case .filesystem:
            guard item.archiveRevision == nil else { self = .unsupported; return }
            if item.isDirectory { self = .physicalFolder(location.url) }
            else { self = Self.physicalFile(location.url) }
        }
    }

    private static func physicalFile(_ url: URL) -> Self {
        if ArchiveLocation.isZIPFile(url), let archive = try? ArchiveLocation(archiveURL: url) {
            return .physicalZIP(archive.url)
        }
        return .ordinaryFile(url)
    }

    /// Sample only metadata. The path given to navigation or the default
    /// application keeps the requested spelling, including any symlink.
    static func resolvePhysicalAddress(_ url: URL) async throws -> Self {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let resolved = try FileSystemPath.resolvingExisting(url)
            let type = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if type.isDirectory == true {
                guard let isPackage = try FileSystemPath.packageStatus(at: resolved) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let directory = URL(fileURLWithPath: url.path, isDirectory: true)
                return isPackage ? .ordinaryFile(directory) : .physicalFolder(directory)
            }
            guard !url.hasDirectoryPath, type.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                    NSLocalizedDescriptionKey: "Enter a folder path or a supported file without a trailing slash."
                ])
            }
            return physicalFile(url)
        }
    }

    var browsingURL: URL? {
        switch self {
        case .physicalFolder(let url), .physicalZIP(let url), .virtualFolder(let url): return url
        default: return nil
        }
    }
    var canOpen: Bool {
        if browsingURL != nil { return true }
        if case .ordinaryFile = self { return true }
        if case .virtualFile = self { return true }
        return false
    }
}

enum NavigationSelectionIntent: Equatable, Sendable { case ordinary, ancestor, history }
