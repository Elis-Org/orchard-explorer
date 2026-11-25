import Darwin
import Foundation

public struct PreparedFileDrop: Sendable {
    public let entries: [TransferEntry]
    public let destination: FileOperationContext
    public let kind: TransferKind

    public init(entries: [TransferEntry], destination: FileOperationContext, kind: TransferKind) {
        self.entries = entries
        self.destination = destination
        self.kind = kind
    }
}

public protocol FileDropPreparing: Sendable {
    func prepare(entries: [TransferEntry], destinationURL: URL,
                 expectedDestinationIdentity: LocalFileIdentity?, expectedEntryIdentity: LocalFileIdentity?,
                 kind: TransferKind) async throws -> PreparedFileDrop
}

/// NATIVE-P13; FR-DROP-001/002/004, EV-9001/0265–0270, corresponding ATs.
/// Read-only, advisory preparation: no staging, publication or source removal.
/// The transfer service remains the final authority; these samples do not freeze
/// a tree, provide a transaction, confer access or broaden MAC-031 provider support.
public struct LocalFileDropPreparer: FileDropPreparing {
    private let maximumAncestryDepth: Int

    public init() { maximumAncestryDepth = 1_024 }

    // Exercise the bounded refusal without creating a path beyond PATH_MAX.
    init(maximumAncestryDepth: Int) {
        precondition(maximumAncestryDepth > 0)
        self.maximumAncestryDepth = maximumAncestryDepth
    }

    public func prepare(entries: [TransferEntry], destinationURL: URL,
                        expectedDestinationIdentity: LocalFileIdentity? = nil,
                        expectedEntryIdentity: LocalFileIdentity? = nil,
                        kind: TransferKind) async throws -> PreparedFileDrop {
        let result = try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            guard !entries.isEmpty, entries.count <= 1_024 else {
                throw FileOperationError.unsupported("A drop must contain between 1 and 1,024 entries.")
            }
            let targetURL = try Self.canonicalDestination(destinationURL)
            // A row's link identity belongs to the lexical entry, while a tab's
            // directory identity belongs to its resolved folder. Never compare
            // those identities to each other or resolve before checking the leaf.
            let targetEntry = try expectedEntryIdentity.map {
                try Self.captureTargetEntry(targetURL, expected: $0, cancellation: cancellation)
            }
            let resolved = try LocalFileOperations.resolveDirectory(targetURL)
            let values: URLResourceValues
            do {
                values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey,
                    .volumeSupportsExclusiveRenamingKey])
            } catch {
                if FileAccessFailure.isMissingLocation(error) { throw FileOperationError.staleParent }
                throw error
            }
            guard values.isDirectory == true else { throw FileOperationError.staleParent }
            guard values.volumeIsLocal == true else {
                throw FileOperationError.unsupported("Drop destinations must be confirmed local folders.")
            }
            guard values.volumeSupportsExclusiveRenaming == true else {
                throw FileOperationError.unsupported("The destination does not advertise exclusive publication support.")
            }
            guard let identity = try LocalFileIdentity.read(at: resolved, ifLocal: true) else {
                throw FileOperationError.unsupported("The drop destination has no supported local identity.")
            }
            guard expectedDestinationIdentity == nil || expectedDestinationIdentity == identity else {
                throw FileOperationError.staleParent
            }
            let destination = FileOperationContext(directoryURL: destinationURL, directoryIdentity: identity)
            return try LocalFileOperations.withParent(destination) { descriptor, openedRoot in
                // Re-resolution during withParent must not silently substitute a
                // different route even when it happens to reach the same folder.
                guard LocalFileOperations.sameBytes(resolved.path, openedRoot.path) else {
                    throw FileOperationError.staleParent
                }
                let destinationStat = try Self.descriptorStat(descriptor)
                guard destinationStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      destinationStat.st_flags & UInt32(SF_DATALESS) == 0 else {
                    throw FileOperationError.unsupported("Placeholder drop destinations are unsupported.")
                }
                var sourceDirectories = Set<LocalFileIdentity>()
                for entry in entries {
                    try cancellation.checkCancellation()
                    try LocalFileOperations.validateName(entry.item.name)
                    try LocalFileOperations.validateURL(entry.item.url)
                    guard entry.item.name == entry.item.url.lastPathComponent,
                          LocalFileOperations.sameBytes(entry.item.url.deletingLastPathComponent().standardizedFileURL.path,
                                                        entry.source.directoryURL.standardizedFileURL.path),
                          let expected = entry.item.identity else { throw FileOperationError.staleSource }
                    // MAC-066: cross-volume moves are supported when the original can be removed.
                    let crossDeviceMove = kind == .move
                        && (expected.device != identity.device || entry.source.directoryIdentity.device != identity.device)
                    if kind == .move {
                        guard entry.source.directoryIdentity != identity else {
                            throw FileOperationError.unsupported("Items cannot be moved into their current folder.")
                        }
                    }
                    try LocalFileOperations.withParent(entry.source) { sourceFD, sourceRoot in
                        if crossDeviceMove {
                            var filesystem = statfs()
                            guard fstatfs(sourceFD, &filesystem) == 0,
                                  filesystem.f_flags & UInt32(MNT_RDONLY) == 0 else {
                                throw FileOperationError.unsupported("The source is on a read-only volume, so it cannot be moved. Hold Option to copy instead.")
                            }
                        }
                        let sample = try Self.entryStat(entry.item.name, at: sourceFD, missing: .staleSource)
                        guard LocalFileIdentity.fromStat(sample) == expected else { throw FileOperationError.staleSource }
                        let type = sample.st_mode & mode_t(S_IFMT)
                        guard sample.st_flags & UInt32(SF_DATALESS) == 0,
                              [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type),
                              UInt64(UInt32(bitPattern: sample.st_dev)) == entry.source.directoryIdentity.device else {
                            throw FileOperationError.unsupported("Drop sources must be supported local files, folders or symbolic links. Placeholders and mounted roots are unsupported.")
                        }
                        if type == mode_t(S_IFDIR) { sourceDirectories.insert(expected) }
                        try LocalFileOperations.revalidateRoute(entry.source, resolved: sourceRoot)
                    }
                }
                if !sourceDirectories.isEmpty {
                    try Self.rejectDescendant(descriptor, of: sourceDirectories,
                        maximumDepth: maximumAncestryDepth, cancellation: cancellation)
                }
                if let targetEntry { try Self.revalidateTargetEntry(targetEntry, cancellation: cancellation) }
                try LocalFileOperations.revalidateRoute(destination, resolved: openedRoot)
                try cancellation.checkCancellation()
                return PreparedFileDrop(entries: entries, destination: destination, kind: kind)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private struct TargetEntry {
        let context: FileOperationContext
        let resolvedParent: URL
        let name: String
        let identity: LocalFileIdentity
    }

    private static func captureTargetEntry(_ url: URL, expected: LocalFileIdentity,
                                           cancellation: BlockingIOCancellation) throws -> TargetEntry {
        let parent = url.deletingLastPathComponent()
        let resolvedParent = try LocalFileOperations.resolveDirectory(parent)
        let values = try resolvedParent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard values.isDirectory == true, values.volumeIsLocal == true,
              let identity = try LocalFileIdentity.read(at: resolvedParent, ifLocal: true) else {
            throw FileOperationError.unsupported("The drop target entry must have a verified local parent.")
        }
        let context = FileOperationContext(directoryURL: parent, directoryIdentity: identity)
        return try LocalFileOperations.withParent(context) { descriptor, openedRoot in
            try cancellation.checkCancellation()
            guard LocalFileOperations.sameBytes(resolvedParent.path, openedRoot.path) else {
                throw FileOperationError.staleParent
            }
            let sample = try entryStat(url.lastPathComponent, at: descriptor, missing: .staleParent)
            guard LocalFileIdentity.fromStat(sample) == expected else { throw FileOperationError.staleParent }
            let type = sample.st_mode & mode_t(S_IFMT)
            guard [mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type),
                  sample.st_flags & UInt32(SF_DATALESS) == 0,
                  UInt64(UInt32(bitPattern: sample.st_dev)) == context.directoryIdentity.device else {
                throw FileOperationError.unsupported("The drop target must be a local folder or folder link.")
            }
            try LocalFileOperations.revalidateRoute(context, resolved: openedRoot)
            return TargetEntry(context: context, resolvedParent: openedRoot,
                               name: url.lastPathComponent, identity: expected)
        }
    }

    private static func revalidateTargetEntry(_ entry: TargetEntry,
                                              cancellation: BlockingIOCancellation) throws {
        try LocalFileOperations.withParent(entry.context) { descriptor, resolved in
            try cancellation.checkCancellation()
            guard LocalFileOperations.sameBytes(entry.resolvedParent.path, resolved.path),
                  LocalFileIdentity.fromStat(try entryStat(entry.name, at: descriptor, missing: .staleParent)) == entry.identity else {
                throw FileOperationError.staleParent
            }
            try LocalFileOperations.revalidateRoute(entry.context, resolved: resolved)
        }
    }

    private static func canonicalDestination(_ url: URL) throws -> URL {
        guard let parts = URLComponents(string: url.absoluteString, encodingInvalidCharacters: false),
              parts.scheme?.lowercased() == "file",
              parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0"), !path.contains("//"),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              parts.percentEncodedPath.range(of: "%2f", options: .caseInsensitive) == nil else {
            throw FileOperationError.unsupported("Drop destinations require a canonical local folder URL.")
        }
        var entryPath = path
        while entryPath.count > 1 && entryPath.last == "/" { entryPath.removeLast() }
        return URL(fileURLWithPath: entryPath, isDirectory: false)
    }

    private static func entryStat(_ name: String, at descriptor: Int32, missing: FileOperationError) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw missing }
            throw LocalFileOperations.failure(errno, operation: "Inspect drop entry", name: name)
        }
        return value
    }

    private static func descriptorStat(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Inspect drop folder", name: "")
        }
        return value
    }

    private static func rejectDescendant(_ destination: Int32, of sources: Set<LocalFileIdentity>,
                                         maximumDepth: Int, cancellation: BlockingIOCancellation) throws {
        var current = openat(destination, ".", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw LocalFileOperations.failure(errno, operation: "Open drop ancestry", name: "") }
        defer { close(current) }
        for _ in 0..<maximumDepth {
            try cancellation.checkCancellation()
            guard let identity = LocalFileIdentity.fromStat(try descriptorStat(current)) else {
                throw FileOperationError.unsupported("Could not verify drop destination ancestry.")
            }
            guard !sources.contains(identity) else {
                throw FileOperationError.unsupported("A folder cannot be dropped into itself or its descendants.")
            }
            let parent = openat(current, "..", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw LocalFileOperations.failure(errno, operation: "Open drop ancestor", name: "") }
            let parentIdentity: LocalFileIdentity?
            do { parentIdentity = LocalFileIdentity.fromStat(try descriptorStat(parent)) }
            catch { close(parent); throw error }
            if identity == parentIdentity { close(parent); return }
            close(current)
            current = parent
        }
        throw FileOperationError.unsupported("Drop destination ancestry exceeds the supported verification depth.")
    }
}
