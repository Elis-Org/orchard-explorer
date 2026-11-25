import Darwin
import Foundation

/// A captured entry and its own parent, allowing selections from several folders.
/// These local observations are not access grants or persistent identifiers.
public struct TransferEntry: Sendable {
    public let source: FileOperationContext
    public let item: FileItem

    public init(source: FileOperationContext, item: FileItem) {
        self.source = source
        self.item = item
    }
}

public protocol FileTransferImporting: Sendable {
    /// Preserve serialized pasteboard values until the worker resolves them:
    /// bridging an NSURL file reference into Swift URL eagerly loses its form.
    func capture(urlStrings: [String]) async throws -> [TransferEntry]
}

/// NATIVE-P12/P13; FR-FILE-003/004, EV-0252/0255, AT-FILE-003/004.
/// Imports metadata only, without enumeration or content reads. Public file
/// references are converted through Foundation before no-follow entry sampling.
/// MAC-031 still applies: a local volume and SF_DATALESS checks do not identify
/// every materialized provider item. The transfer service revalidates before writing.
public struct LocalFileTransferImporter: FileTransferImporting {
    public init() {}

    public func capture(urlStrings: [String]) async throws -> [TransferEntry] {
        let result = try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            // Complete lexical validation precedes any reference resolution.
            // NSURL.path itself can resolve references, so validate serialized
            // URL components rather than consulting that property on inputs.
            let inputs = try Self.validate(urlStrings)
            var entries: [URL] = []
            for input in inputs {
                try cancellation.checkCancellation()
                entries.append(try Self.resolveReference(input))
            }
            try Self.validateRelationships(entries)
            var parents: [Data: FileOperationContext] = [:]
            var captured: [TransferEntry] = []
            var resolvedEntries: [URL] = []
            captured.reserveCapacity(entries.count)
            for url in entries {
                try cancellation.checkCancellation()
                let parent = url.deletingLastPathComponent().standardizedFileURL
                let key = Data(parent.path.utf8)
                let context: FileOperationContext
                if let existing = parents[key] {
                    context = existing
                } else {
                    // Resolve only the parent. A final symlink, including a broken
                    // link or one with a directory URL hint, remains an entry.
                    let resolved = try LocalFileOperations.resolveDirectory(parent)
                    let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
                    guard values.isDirectory == true, values.volumeIsLocal == true,
                          let identity = try LocalFileIdentity.read(at: resolved, ifLocal: true) else {
                        throw FileOperationError.unsupported("Transfers require a verified local source folder.")
                    }
                    context = FileOperationContext(directoryURL: parent, directoryIdentity: identity)
                    parents[key] = context
                }
                let (entry, resolvedEntry) = try LocalFileOperations.withParent(context) { descriptor, resolved in
                    try cancellation.checkCancellation()
                    let name = url.lastPathComponent
                    var value = stat()
                    guard name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                        if errno == ENOENT || errno == ENOTDIR { throw FileOperationError.staleSource }
                        throw LocalFileOperations.failure(errno, operation: "Inspect transfer source", name: name)
                    }
                    let type = value.st_mode & mode_t(S_IFMT)
                    guard value.st_flags & UInt32(SF_DATALESS) == 0,
                          [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type),
                          UInt64(UInt32(bitPattern: value.st_dev)) == context.directoryIdentity.device,
                          let identity = LocalFileIdentity.fromStat(value) else {
                        throw FileOperationError.unsupported("Only local files, folders and symbolic links with supported identity can be transferred. Placeholders and mounted roots are unsupported.")
                    }
                    try LocalFileOperations.revalidateRoute(context, resolved: resolved)
                    try cancellation.checkCancellation()
                    let metadata = FileMetadata(stat: value, capturedAt: Date())
                    let directory = type == mode_t(S_IFDIR)
                    let link = type == mode_t(S_IFLNK)
                    // Imported items are transfer inputs, not browsing rows. Do not
                    // query package/kind resources or a link's target for display.
                    let itemURL = URL(fileURLWithPath: url.path, isDirectory: directory)
                    let item = FileItem(url: itemURL, name: name, isDirectory: directory, isSymbolicLink: link,
                        size: metadata.size, modifiedAt: metadata.modifiedAt,
                        kind: link ? "Symbolic link" : directory ? "File folder" : "File", identity: identity)
                    return (TransferEntry(source: context, item: item),
                            resolved.appendingPathComponent(name, isDirectory: false))
                }
                captured.append(entry)
                resolvedEntries.append(resolvedEntry)
            }
            // Parent aliases can spell the same source or an ancestor selection
            // differently. Compare resolved parents without following any leaf.
            try Self.validateRelationships(resolvedEntries)
            for (index, input) in inputs.enumerated() where NSURL(string: input)?.isFileReferenceURL() == true {
                try cancellation.checkCancellation()
                let current = try Self.resolveReference(input)
                guard LocalFileOperations.sameBytes(current.path, entries[index].path) else {
                    throw FileOperationError.staleSource
                }
                let entry = captured[index]
                try LocalFileOperations.withParent(entry.source) { descriptor, resolved in
                    guard try LocalFileOperations.identity(of: entry.item.name, in: descriptor) == entry.item.identity else {
                        throw FileOperationError.staleSource
                    }
                    try LocalFileOperations.revalidateRoute(entry.source, resolved: resolved)
                }
            }
            try cancellation.checkCancellation()
            return captured
        }
        try Task.checkCancellation()
        return result
    }

    private static func validate(_ urlStrings: [String]) throws -> [String] {
        guard !urlStrings.isEmpty, urlStrings.count <= 1_024 else {
            throw FileOperationError.unsupported("Transfer selections must contain between 1 and 1,024 entries.")
        }
        var remainingBytes = 1_048_576
        for spelling in urlStrings {
            let byteCount = spelling.utf8.count
            guard byteCount <= remainingBytes else {
                throw FileOperationError.unsupported("The transfer URL payload exceeds 1 MiB.")
            }
            remainingBytes -= byteCount
            _ = try canonicalPath(spelling)
        }
        return urlStrings
    }

    private static func canonicalPath(_ spelling: String) throws -> String {
        guard let components = URLComponents(string: spelling, encodingInvalidCharacters: false), components.string == spelling,
              components.scheme?.lowercased() == "file",
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let path = components.percentEncodedPath.removingPercentEncoding,
              !path.contains("\0"), path.hasPrefix("/"), !path.contains("//"),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              components.percentEncodedPath.range(of: "%2f", options: .caseInsensitive) == nil else {
            throw FileOperationError.unsupported("Transfers require canonical absolute local file URLs without NUL.")
        }
        guard path != "/" else {
            throw FileOperationError.unsupported("A filesystem root cannot be transferred.")
        }
        var entryPath = path
        while entryPath.count > 1 && entryPath.last == "/" { entryPath.removeLast() }
        return entryPath
    }

    private static func resolveReference(_ spelling: String) throws -> URL {
        guard let native = NSURL(string: spelling) else {
            throw FileOperationError.unsupported("Transfers require a valid local file URL.")
        }
        let path: String
        if native.isFileReferenceURL() {
            // Apple's public conversion returns nil for unreachable/deleted objects.
            // https://developer.apple.com/documentation/foundation/nsurl/filepathurl
            // Never guess a /.file path or infer identity from serialized numbers.
            guard let pathURL = native.filePathURL else {
                throw FileOperationError.unsupported("The referenced file is unavailable. Copy the current file again.")
            }
            path = try canonicalPath(pathURL.absoluteString)
        } else {
            path = try canonicalPath(spelling)
        }
        let entry = URL(fileURLWithPath: path, isDirectory: false)
        try LocalFileOperations.validateName(entry.lastPathComponent)
        return entry
    }

    /// Common preflight for projected selections whose children already have
    /// identities. Resolve parents only, so a final symbolic link remains a leaf.
    public static func validateSelectionRelationships(_ entries: [TransferEntry]) async throws {
        guard entries.count > 1 else { return }
        try await BlockingIO.run(on: .read) { cancellation in
            try validateRelationships(entries.map(\.item.url))
            var roots: [FileOperationContextKey: URL] = [:]
            var paths: [URL] = []
            for entry in entries {
                try cancellation.checkCancellation()
                let key = FileOperationContextKey(path: Data(entry.source.directoryURL.path.utf8), identity: entry.source.directoryIdentity)
                let resolved: URL
                if let root = roots[key] { resolved = root }
                else {
                    resolved = try LocalFileOperations.withParent(entry.source) { _, actual in actual }
                    roots[key] = resolved
                }
                paths.append(resolved.appendingPathComponent(entry.item.name))
            }
            try validateRelationships(paths)
        }
    }

    private struct FileOperationContextKey: Hashable {
        let path: Data
        let identity: LocalFileIdentity
    }

    private static func validateRelationships(_ entries: [URL]) throws {
        let paths = Set(entries.map { Data($0.path.utf8) })
        guard paths.count == entries.count else {
            throw FileOperationError.unsupported("The transfer selection contains a duplicate entry.")
        }
        // Byte comparisons retain distinct Unicode spellings and hard-link names.
        // At most 1,024 entries: this bounded pass performs no filesystem reads.
        for entry in entries {
            var parent = entry.deletingLastPathComponent()
            while parent.path != "/" {
                if paths.contains(Data(parent.path.utf8)) {
                    throw FileOperationError.unsupported("A transfer selection cannot include a folder and its descendant.")
                }
                parent.deleteLastPathComponent()
            }
        }
    }
}
