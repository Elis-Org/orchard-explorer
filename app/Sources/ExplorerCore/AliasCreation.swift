import Darwin
import Foundation

public struct AliasCreationError: LocalizedError, Sendable {
    public let completed: [FileOperationResult]
    public let failedName: String
    public let cause: String
    public var errorDescription: String? { "Could not create an alias for “\(failedName)”: \(cause)" }
}
/// An inspected target retains both the original directory entry and the
/// physical target so replacing either invalidates a pending shortcut draft.
public struct ShortcutTarget: Sendable {
    public let url: URL
    fileprivate let entry: LocalFileIdentity
    fileprivate let resolvedURL: URL
    fileprivate let resolvedEntry: LocalFileIdentity

    private static func sample(_ url: URL, allowingLink: Bool) throws -> LocalFileIdentity {
        guard try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw FileOperationError.unsupported("The target must have a supported local identity.")
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Inspect target", name: url.lastPathComponent)
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) || (allowingLink && kind == mode_t(S_IFLNK)) else {
            throw FileOperationError.unsupported("Choose a file or folder as the shortcut target.")
        }
        guard let identity = LocalFileIdentity.fromStat(metadata) else {
            throw FileOperationError.unsupported("The target must have a supported local identity.")
        }
        return identity
    }

    fileprivate static func inspect(_ url: URL) throws -> Self {
        // Verify the spelling (including a trailing slash) before removing the
        // directory marker for the original entry's no-follow sample.
        let resolved = try FileSystemPath.resolvingExisting(url)
        let path = url.path
        let entryURL = URL(fileURLWithPath: path, isDirectory: false)
        let entry = try sample(entryURL, allowingLink: true)
        let resolvedEntry = try sample(resolved, allowingLink: false)
        let target = Self(url: url, entry: entry, resolvedURL: resolved, resolvedEntry: resolvedEntry)
        try target.verify()
        return target
    }

    fileprivate func verify() throws {
        do {
            let current = try FileSystemPath.resolvingExisting(url)
            let entryURL = URL(fileURLWithPath: url.path, isDirectory: false)
            guard LocalFileOperations.sameBytes(current.path, resolvedURL.path),
                  try Self.sample(entryURL, allowingLink: true) == entry,
                  try Self.sample(current, allowingLink: false) == resolvedEntry else {
                throw FileOperationError.staleSource
            }
        } catch {
            throw FileOperationError.staleSource
        }
    }
}

public struct ShortcutPreparation: Sendable {
    public let target: ShortcutTarget
    public let suggestedName: String
}

public protocol AliasCreating: Sendable {
    func makeAliases(for items: [FileItem], in context: FileOperationContext) async throws -> [FileOperationResult]
    func prepareShortcut(to url: URL, in destination: FileOperationContext) async throws -> ShortcutPreparation
    func createAlias(to target: ShortcutTarget, named name: String, in context: FileOperationContext) async throws -> FileOperationResult
}

public extension AliasCreating {
    func prepareShortcut(to url: URL, in destination: FileOperationContext) async throws -> ShortcutPreparation {
        throw FileOperationError.unsupported("Creating a shortcut is unavailable.")
    }

    func createAlias(to target: ShortcutTarget, named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        throw FileOperationError.unsupported("Creating a shortcut is unavailable.")
    }
}

public struct LocalAliasCreator: AliasCreating {
    public init() {}

    public func prepareShortcut(to url: URL, in destination: FileOperationContext) async throws -> ShortcutPreparation {
        try await BlockingIO.run(on: .read) { cancellation in
            let target = try ShortcutTarget.inspect(url)
            return try LocalFileOperations.withParent(destination) { parent, resolved in
                let leaf = url.lastPathComponent
                let base = leaf == "/" || leaf.isEmpty ? "Shortcut" : leaf
                let name = try Self.availableShortcutName(basedOn: base, parent: parent, cancellation: cancellation)
                try LocalFileOperations.revalidateRoute(destination, resolved: resolved)
                return ShortcutPreparation(target: target, suggestedName: name)
            }
        }
    }

    public func createAlias(to target: ShortcutTarget, named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try LocalFileOperations.validateName(name)
            return try LocalFileOperations.withParent(context) { parent, resolved in
                try Self.writeAlias(to: target.resolvedURL, in: context, parent: parent, resolved: resolved,
                                    collision: .exact, name: { _ in name }, cancellation: cancellation,
                                    verify: target.verify)
            }
        }
    }

    public func makeAliases(for items: [FileItem], in context: FileOperationContext) async throws -> [FileOperationResult] {
        try await BlockingIO.run(on: .mutation) { cancellation in
            var completed: [FileOperationResult] = []
            for item in items {
                do {
                    let result = try LocalFileOperations.withParent(context) { parent, resolved in
                        try Self.writeAlias(to: item.url, in: context, parent: parent, resolved: resolved,
                                            collision: .unique, name: { Self.suggestedAliasName(for: item.name, suffix: $0) },
                                            cancellation: cancellation) {
                            try ServiceStage.verify(item, context: context, parent: parent)
                        }
                    }
                    completed.append(result)
                } catch { throw AliasCreationError(completed: completed, failedName: item.name, cause: error.localizedDescription) }
            }
            return completed
        }
    }

    /// Look up candidate names on the destination volume without enumerating
    /// the folder, following links, or inferring its filename comparison rules.
    private static func availableShortcutName(basedOn leaf: String, parent: Int32,
                                              cancellation: BlockingIOCancellation) throws -> String {
        var base = leaf
        var suffix = 0
        while true {
            try cancellation.checkCancellation()
            let candidate = suffix == 0 ? base : suggestedAliasName(for: base, suffix: suffix)
            var metadata = stat()
            if fstatat(parent, candidate, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                suffix += 1
                continue
            }
            let code = errno
            if code == ENOENT { return candidate }
            // A full-length existing leaf may not fit an appended suffix.
            if code == ENAMETOOLONG, base != "Shortcut" {
                base = "Shortcut"
                suffix = 0
                continue
            }
            throw LocalFileOperations.failure(code, operation: "Check shortcut name", name: candidate)
        }
    }

    /// The original Make Alias suffix sequence also handles Shortcut defaults
    /// when the target's leaf name is occupied in the destination.
    private static func suggestedAliasName(for leaf: String, suffix: Int) -> String {
        leaf + " alias" + (suffix == 1 ? "" : " \(suffix)")
    }

    private static func writeAlias(to target: URL, in context: FileOperationContext, parent: Int32, resolved: URL,
                                   collision: ServiceStage.CollisionPolicy, name: (Int) -> String,
                                   cancellation: BlockingIOCancellation, verify: () throws -> Void) throws -> FileOperationResult {
        try LocalFileOperations.revalidateRoute(context, resolved: resolved)
        try verify()
        try cancellation.checkCancellation()
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try cancellation.checkCancellation()
        let stage = try ServiceStage(parent: parent, url: resolved, prefix: ".explorer-alias-")
        defer { stage.clean() }
        let (payload, expected) = try stage.createFile("payload")
        defer { try? payload.close() }
        try writeAliasFile(data, into: payload)
        try payload.close()
        return try stage.publish(context: context, resolved: resolved, payload: expected, collision: collision, name: name) {
            try verify()
            try cancellation.checkCancellation()
        }
    }

    /// Foundation writes alias files only by pathname, so it writes into a fresh
    /// owner-only directory under the user's temporary folder; the bytes and the
    /// Finder alias flag are then copied into the stage's exclusively created
    /// payload through descriptors. Nothing in the destination folder is opened by path.
    static func writeAliasFile(_ bookmark: Data, into destination: FileHandle) throws {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-alias-XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw LocalFileOperations.failure(errno, operation: "Create alias scratch", name: "alias") }
        let scratch = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("alias")
        try URL.writeBookmarkData(bookmark, to: file)
        let source = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw LocalFileOperations.failure(errno, operation: "Read alias", name: "alias") }
        defer { close(source) }
        guard fcopyfile(source, destination.fileDescriptor, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) == 0 else {
            throw LocalFileOperations.failure(errno, operation: "Write alias", name: "alias")
        }
    }
}
