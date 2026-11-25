import Foundation

/// One provider boundary for physical and archive navigation. Injecting a
/// DirectoryListing into the App still replaces the complete browsing service.
public struct BrowsingDirectoryLoader: DirectoryListing {
    private let physical: any DirectoryListing
    private let archive: any DirectoryListing
    public init(physical: any DirectoryListing = LocalDirectoryLoader(),
                archive: any DirectoryListing = LocalZIPDirectoryLoader()) {
        self.physical = physical; self.archive = archive
    }
    public func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await snapshot(of: url, showHidden: showHidden).items
    }
    public func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        guard let location = BrowsingLocation(url: url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        switch location {
        case .page: throw CocoaError(.fileReadUnsupportedScheme)
        case .filesystem: return try await physical.snapshot(of: location.url, showHidden: showHidden)
        case .archive: return try await archive.snapshot(of: location.url, showHidden: showHidden)
        }
    }
}

/// Physical completion retains its bounded native implementation. Virtual child
/// popups reuse the same injected browsing provider as the committed listing.
public struct BrowsingFolderSuggester: FolderSuggesting {
    private let loader: any DirectoryListing
    private let physical: any FolderSuggesting
    public init(loader: any DirectoryListing = BrowsingDirectoryLoader(),
                physical: any FolderSuggesting = LocalFolderSuggester()) {
        self.loader = loader; self.physical = physical
    }
    public func folders(in directory: URL, prefix: String, showHidden: Bool) async throws -> FolderSuggestions {
        guard let location = BrowsingLocation(url: directory) else { throw CocoaError(.fileReadUnsupportedScheme) }
        if case .page = location { return FolderSuggestions(urls: [], isTruncated: false) }
        if case .filesystem = location { return try await physical.folders(in: location.url, prefix: prefix, showHidden: showHidden) }
        let snapshot = try await loader.snapshot(of: location.url, showHidden: showHidden)
        try Task.checkCancellation()
        let matches = FileSort().sorted(snapshot.items.filter {
            $0.isDirectory && (prefix.isEmpty || $0.name.range(of: prefix,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) != nil)
        })
        return FolderSuggestions(urls: matches.prefix(200).map(\.url), isTruncated: matches.count > 200)
    }
}
