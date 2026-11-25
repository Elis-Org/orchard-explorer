import Foundation
import UniformTypeIdentifiers

public protocol DirectoryListing: Sendable {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem]
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot
}

public extension DirectoryListing {
    /// Existing providers retain their read contract. Without supported identity,
    /// only exact-path refresh retention is available; rename tracking is unknown.
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        DirectorySnapshot(items: try await contents(of: url, showHidden: showHidden))
    }
}

/// Read-only snapshots run on concurrent Dispatch workers. Cancellation releases
/// the waiting caller; an in-flight OS call may finish later and is discarded.
public struct LocalDirectoryLoader: DirectoryListing {
    public init() {}

    /// A virtual result has no enumerated parent. Bind only its named entry to
    /// the current local parent, without reading siblings or materializing bytes.
    public static func inspectorEntry(at url: URL) async throws -> TransferEntry {
        try await singleEntry(at: url, forOperation: false)
    }

    /// Operations on collection results have the same local entry constraints
    /// as file transfer and Trash. Read-only display can still describe placeholders.
    public static func operationEntry(at url: URL) async throws -> TransferEntry {
        try await singleEntry(at: url, forOperation: true)
    }

    private static func singleEntry(at url: URL, forOperation: Bool) async throws -> TransferEntry {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            return try HydrationMaterializationPolicy().disabled { _ in
                guard url.isFileURL else { throw ItemContentError.staleSource }
                let parent = url.deletingLastPathComponent().standardizedFileURL
                let resolved = try FileSystemPath.resolvingExisting(parent)
                let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
                guard values.isDirectory == true, values.volumeIsLocal == true,
                      let root = try LocalFileIdentity.read(at: resolved, ifLocal: true)
                else { throw ItemContentError.staleSource }
                let child = resolved.appendingPathComponent(url.lastPathComponent)
                guard let status = try LocalFileIdentity.sample(at: child, ifLocal: true), let before = status.identity
                else { throw ItemContentError.staleSource }
                let sample = Self.sample(for: child, displayedIn: parent, supportsLocalIdentity: true)
                if forOperation {
                    guard !status.isDataless, before.device == root.device,
                          status.isRegularFile || status.isDirectory || sample.item.isSymbolicLink else {
                        throw FileOperationError.unsupported("The selection includes an unsupported file or volume.")
                    }
                }
                let after = try FileSystemPath.resolvingExisting(parent)
                guard sample.structureKnown, sample.item.identity == before,
                      after == resolved, try LocalFileIdentity.read(at: after, ifLocal: true) == root,
                      try LocalFileIdentity.read(at: child, ifLocal: true) == before
                else { throw ItemContentError.staleSource }
                try cancellation.checkCancellation()
                return TransferEntry(source: FileOperationContext(directoryURL: parent, directoryIdentity: root),
                                     item: sample.item)
            }
        }
    }

    /// A resident search result omitted membership during enumeration. Sample
    /// only its captured visible entry, with the parent and raw version checked
    /// on both sides of the metadata query. No OneDrive command or file read.
    public static func visibleCloudAvailability(_ entry: TransferEntry) async -> FileAvailability {
        (try? await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            return try visibleCloudAvailability(entry) {
                try $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
            }
        }) ?? .unknown
    }

    static func visibleCloudAvailability(_ entry: TransferEntry, membership: (URL) throws -> Bool) throws -> FileAvailability {
        let target = try OneDriveRetentionTarget(entry)
        guard target.matchesListedStatusVersion else { return .unknown }
        if try target.sample() { return .onlineOnly }
        let member = try HydrationMaterializationPolicy().disabled { _ in try membership(target.url) }
        if try target.sample() { return .onlineOnly }
        return member ? .availableLocally : .unknown
    }

    public func contents(of url: URL, showHidden: Bool = false) async throws -> [FileItem] {
        let result = try await snapshot(of: url, showHidden: showHidden)
        return result.items
    }

    public func snapshot(of url: URL, showHidden: Bool = false) async throws -> DirectorySnapshot {
        let snapshot = try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let directory = url.standardizedFileURL
            let resolvedDirectory = try FileSystemPath.resolvingExisting(directory)
            let targetValues = try resolvedDirectory.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
            guard targetValues.isDirectory == true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path,
                    NSLocalizedDescriptionKey: "This location is not a folder."])
            }

            // Local stat identity is intentionally unavailable for opaque/non-local
            // providers. It is never a persistent grant or an operation authority.
            let supportsLocalIdentity = targetValues.volumeIsLocal == true
            let directoryIdentity = try LocalFileIdentity.read(at: resolvedDirectory,
                                                               ifLocal: targetValues.volumeIsLocal)

            let manager = FileManager()
            // Foundation enumeration can reject a final-component directory symlink.
            // Read its resolved destination, but retain the requested path for UI/history.
            let urls = try manager.contentsOfDirectory(at: resolvedDirectory,
                includingPropertiesForKeys: Array(Self.entryKeys.union(Self.presentationKeys)), options: showHidden ? [] : [.skipsHiddenFiles])
            var entries: [FileItem] = []
            var structureComplete = true
            entries.reserveCapacity(urls.count)
            for entryURL in urls {
                try cancellation.checkCancellation()
                let sample = Self.sample(for: entryURL, displayedIn: directory,
                                         supportsLocalIdentity: supportsLocalIdentity)
                entries.append(sample.item)
                structureComplete = structureComplete && sample.structureKnown
            }
            try cancellation.checkCancellation()
            // Re-resolve the lexical path to detect a retargeted directory link,
            // then verify the actual root did not change during enumeration.
            let resolvedAfter = try FileSystemPath.resolvingExisting(directory)
            let identityAfter = try LocalFileIdentity.read(at: resolvedAfter, ifLocal: supportsLocalIdentity)
            guard resolvedDirectory.path == resolvedAfter.path,
                  !supportsLocalIdentity || directoryIdentity == identityAfter else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path,
                    NSLocalizedDescriptionKey: "The folder changed while it was being read. Refresh to try again."])
            }
            return DirectorySnapshot(items: entries, directoryIdentity: directoryIdentity,
                                     isStructureComplete: structureComplete)
        }
        try Task.checkCancellation()
        return snapshot
    }

    /// Structural keys are read separately from optional presentation keys:
    /// a Launch Services failure for a type description or package lookup must
    /// not erase independently readable directory, size and date metadata.
    static let entryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey]
    static let presentationKeys: Set<URLResourceKey> = [.isPackageKey, .isAliasFileKey,
        .localizedTypeDescriptionKey]

    /// Shared by folder listing and filename search so both present identical
    /// row semantics. `entryURL` is the enumerated (resolved) child; the row URL
    /// keeps the displayed directory spelling.
    static func item(for entryURL: URL, displayedIn directory: URL, supportsLocalIdentity: Bool) -> FileItem {
        sample(for: entryURL, displayedIn: directory, supportsLocalIdentity: supportsLocalIdentity).item
    }

    /// `structureKnown` is false when directory/link structure could not be read,
    /// so a search cannot tell whether a subtree was skipped (MAC-063).
    static func sample(for entryURL: URL, displayedIn directory: URL,
                       supportsLocalIdentity: Bool, readCloudMetadata: Bool = true,
                       cloudMembership: (URL) throws -> Bool = { url in
                           try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
                       }) -> (item: FileItem, structureKnown: Bool) {
        // A metadata failure must not silently remove an otherwise listed entry.
        // Unknown values stay unavailable; opening the item will revalidate the target.
        let values = try? entryURL.resourceValues(forKeys: entryKeys)
        let presentation = try? entryURL.resourceValues(forKeys: [.isAliasFileKey, .localizedTypeDescriptionKey])
        let isLink = values?.isSymbolicLink == true
        let structure = structuralFolder(at: entryURL, isDirectory: values?.isDirectory,
                                         isSymbolicLink: values?.isSymbolicLink)
        let isDirectory = structure.isFolder
        let kind: String
        if isLink { kind = "Symbolic link" }
        else if presentation?.isAliasFile == true { kind = "Alias" }
        else if isDirectory { kind = "File folder" }
        else { kind = presentation?.localizedTypeDescription
            ?? UTType(filenameExtension: entryURL.pathExtension)?.localizedDescription
            ?? "File" }
        let displayedURL = directory.appendingPathComponent(entryURL.lastPathComponent,
            isDirectory: entryURL.hasDirectoryPath)
        let local = try? LocalFileIdentity.sample(at: entryURL, ifLocal: supportsLocalIdentity)
        // Optional provider metadata is separate from structural keys/prefetch.
        // Search skips it entirely; dataless state already answers availability.
        let ubiquitous = !isLink && readCloudMetadata && local?.isDataless == false
            ? (try? cloudMembership(entryURL)) == true : false
        let availability = isLink ? FileAvailability.unknown
            : local?.availability(isUbiquitous: ubiquitous) ?? .unknown
        let item = FileItem(url: displayedURL, name: entryURL.lastPathComponent,
            isDirectory: isDirectory, isSymbolicLink: isLink,
            size: values?.isDirectory == true || isLink ? nil : values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate, kind: kind,
            identity: local?.identity, availability: availability, isRegularFile: local?.isRegularFile,
            statusVersion: local?.statusVersion, isDataless: local?.isDataless)
        return (item, structure.isKnown)
    }

    /// Packages remain file rows. A confirmed directory link retains the existing
    /// traversable fallback when only package metadata is unavailable.
    static func structuralFolder(at entry: URL, isDirectory: Bool?, isSymbolicLink: Bool?,
                                 resolveLink: (URL) throws -> URL = FileSystemPath.resolvingExisting,
                                 packageStatus: (URL) throws -> Bool? = FileSystemPath.packageStatus)
        -> (isFolder: Bool, isKnown: Bool) {
        let isLink = isSymbolicLink == true
        let target = isLink ? try? resolveLink(entry) : entry
        let targetIsDirectory = isLink
            ? (try? target?.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            : isDirectory
        let known = isDirectory != nil && isSymbolicLink != nil && targetIsDirectory != nil
        guard targetIsDirectory == true, let target else { return (false, known) }
        if let package = try? packageStatus(target) { return (!package, known) }
        return (isLink, known && isLink)
    }
}
