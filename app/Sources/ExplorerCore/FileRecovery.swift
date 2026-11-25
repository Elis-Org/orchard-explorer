import Darwin
import Foundation

public struct TrashReceipt: Identifiable, Sendable {
    public let id: UUID
    public let original: FileItem
    public let originalContext: FileOperationContext
    public let trashed: FileItem
    public let trashContext: FileOperationContext
    public let trashedAt: Date

    public init(id: UUID = UUID(), original: FileItem, originalContext: FileOperationContext,
                trashed: FileItem, trashContext: FileOperationContext, trashedAt: Date = Date()) {
        self.id = id
        self.original = original
        self.originalContext = originalContext
        self.trashed = trashed
        self.trashContext = trashContext
        self.trashedAt = trashedAt
    }
}

public struct TrashResult: Sendable {
    public let receipt: TrashReceipt?
    public let warning: String?
    public let accessFailure: FileAccessFailure?
    /// The location the system reported, kept even when no receipt could be verified.
    public let trashedURL: URL?
    public init(receipt: TrashReceipt?, warning: String?, accessFailure: FileAccessFailure? = nil, trashedURL: URL? = nil) {
        self.receipt = receipt
        self.warning = warning
        self.accessFailure = accessFailure
        self.trashedURL = trashedURL ?? receipt?.trashed.url
    }
}

public enum FileRecoveryError: LocalizedError, Sendable {
    case outcomeUncertain(String, accessFailure: FileAccessFailure? = nil)
    public var errorDescription: String? {
        switch self {
        case .outcomeUncertain(let detail, _):
            return "The system reported a Trash error, and the original item could not be verified unchanged. Its outcome is uncertain. Inspect the original folder and Trash before trying again. \(detail)"
        }
    }
}

public protocol FileRecovering: Sendable {
    func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult
    func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult
}

/// FR-FILE-005/007 / EV-0448, EV-0453 / AT-FILE-005/007 filesystem subsets.
/// The system Trash API is path-based: immediate parent/entry checks reduce stale
/// requests but cannot provide descriptor-anchored or atomic source comparison.
/// Receipts cover only verified successful operations in the current app session.
public struct LocalFileRecovery: FileRecovering {
    private let nativeTrash: @Sendable (URL) throws -> URL?

    public init() {
        nativeTrash = { url in
            var result: NSURL?
            try FileManager().trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
    }

    // Mirrors the nullable native result and native error boundary for isolated
    // tests. A successful native call must never become a retryable failure.
    init(nativeTrash: @escaping @Sendable (URL) throws -> URL?) {
        self.nativeTrash = nativeTrash
    }

    public func trash(_ item: FileItem, in context: FileOperationContext) async throws -> TrashResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try trashNow(item, in: context, cancellation: cancellation)
        }
    }

    /// The identity-checked Trash body, callable from another writer's worker
    /// (MAC-071: Replace retires the existing item through this same path).
    func trashNow(_ item: FileItem, in context: FileOperationContext,
                  cancellation: BlockingIOCancellation?) throws -> TrashResult {
        do {
            try cancellation?.checkCancellation()
            try LocalFileOperations.validateURL(item.url)
            try LocalFileOperations.validateName(item.name)
            guard item.name == item.url.lastPathComponent,
                  item.url.deletingLastPathComponent().standardizedFileURL.path == context.directoryURL.standardizedFileURL.path,
                  let expected = item.identity else { throw FileOperationError.staleSource }
            return try LocalFileOperations.withParent(context) { parentFD, resolvedParent in
                let value = try Self.entry(item.name, at: parentFD)
                guard LocalFileIdentity.fromStat(value) == expected else { throw FileOperationError.staleSource }
                try Self.validateNode(value, parent: context.directoryIdentity)
                // Resolve only the parent. Resolving the whole URL would turn a
                // selected symbolic link into a request to Trash its target.
                let source = resolvedParent.appendingPathComponent(item.name, isDirectory: item.url.hasDirectoryPath)
                try LocalFileOperations.revalidateRoute(context, resolved: resolvedParent)
                guard try LocalFileOperations.identity(of: item.name, in: parentFD) == expected else {
                    throw FileOperationError.staleSource
                }
                try cancellation?.checkCancellation()
                let returned: URL?
                do {
                    returned = try nativeTrash(source)
                } catch {
                    let nativeError = error
                    do {
                        try LocalFileOperations.revalidateRoute(context, resolved: resolvedParent)
                        guard try LocalFileOperations.identity(of: item.name, in: parentFD) == expected else {
                            throw FileOperationError.staleSource
                        }
                    } catch {
                        throw FileRecoveryError.outcomeUncertain(nativeError.localizedDescription,
                            accessFailure: FileAccessFailure.preferred(FileAccessFailure.classify(nativeError), FileAccessFailure.classify(error)))
                    }
                    throw nativeError
                }
                // Do not inspect cancellation after the native success boundary.
                // Receipt sampling failure cannot make the user retry the move.
                do {
                    guard let returned else {
                        throw FileOperationError.unsupported("The system did not return the item's Trash location.")
                    }
                    let receipt = try Self.receipt(original: item, context: context, returned: returned, expected: expected)
                    return TrashResult(receipt: receipt, warning: nil)
                } catch {
                    return TrashResult(receipt: nil, warning:
                        "The item was moved to Trash, but a safe restore receipt could not be verified. Use Finder to inspect Trash. \(error.localizedDescription)",
                        accessFailure: FileAccessFailure.classify(error), trashedURL: returned)
                }
            }
        }
    }

    /// MAC-072: put a just-replaced item back under its original name when the
    /// replacement could not be published. Exclusive; never overwrites.
    static func restoreNow(_ receipt: TrashReceipt) throws {
        let name = receipt.original.name
        try LocalFileOperations.withParent(receipt.trashContext) { trashFD, trashRoot in
            try LocalFileOperations.withParent(receipt.originalContext) { originalFD, originalRoot in
                guard try LocalFileOperations.identity(of: receipt.trashed.name, in: trashFD) == receipt.trashed.identity else {
                    throw FileOperationError.staleSource
                }
                try LocalFileOperations.revalidateRoute(receipt.trashContext, resolved: trashRoot)
                try LocalFileOperations.revalidateRoute(receipt.originalContext, resolved: originalRoot)
                let moved = receipt.trashed.name.withCString { old in name.withCString { new in
                    renameatx_np(trashFD, old, originalFD, new, UInt32(RENAME_EXCL))
                } }
                guard moved == 0 else { throw LocalFileOperations.failure(errno, operation: "Restore replaced item", name: name) }
            }
        }
    }

    public func restore(_ receipt: TrashReceipt, as name: String) async throws -> FileOperationResult {
        try await LocalFileTransfers().transfer(receipt.trashed, from: receipt.trashContext,
            to: receipt.originalContext, name: name, kind: .move, control: TransferControl(), onProgress: { _ in })
    }

    private static func receipt(original: FileItem, context: FileOperationContext,
                                returned: URL, expected: LocalFileIdentity) throws -> TrashReceipt {
        try LocalFileOperations.validateURL(returned)
        try LocalFileOperations.validateName(returned.lastPathComponent)
        // Never resolve the returned leaf: a receipt may identify a symlink.
        let parent = returned.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard values.isDirectory == true, values.volumeIsLocal == true,
              let parentIdentity = try LocalFileIdentity.read(at: parent, ifLocal: true),
              parentIdentity.device == context.directoryIdentity.device else {
            throw FileOperationError.unsupported("The returned Trash folder is not verified on the same local volume.")
        }
        let trashContext = FileOperationContext(directoryURL: parent, directoryIdentity: parentIdentity)
        return try LocalFileOperations.withParent(trashContext) { descriptor, resolved in
            let name = returned.lastPathComponent
            let value = try entry(name, at: descriptor)
            guard LocalFileIdentity.fromStat(value) == expected else { throw FileOperationError.staleSource }
            try validateNode(value, parent: parentIdentity)
            try LocalFileOperations.revalidateRoute(trashContext, resolved: resolved)
            let url = parent.appendingPathComponent(name, isDirectory: original.url.hasDirectoryPath)
            let trashed = FileItem(url: url, name: name, isDirectory: original.isDirectory,
                isSymbolicLink: value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                size: original.size, modifiedAt: original.modifiedAt, kind: original.kind, identity: expected)
            return TrashReceipt(original: original, originalContext: context, trashed: trashed, trashContext: trashContext)
        }
    }

    private static func entry(_ name: String, at descriptor: Int32) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { throw FileOperationError.staleSource }
            throw LocalFileOperations.failure(errno, operation: "Inspect Trash item", name: name)
        }
        return value
    }

    private static func validateNode(_ value: stat, parent: LocalFileIdentity) throws {
        guard value.st_flags & UInt32(SF_DATALESS) == 0,
              [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(value.st_mode & mode_t(S_IFMT)),
              UInt64(UInt32(bitPattern: value.st_dev)) == parent.device else {
            throw FileOperationError.unsupported("Trash supports regular files, folders, packages and symbolic links on the same confirmed local volume. Dataless placeholders and mounted roots are not supported.")
        }
    }
}
