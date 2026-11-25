import Darwin
import Foundation

public struct FileOperationContext: Equatable, Sendable {
    public let directoryURL: URL
    public let directoryIdentity: LocalFileIdentity
    public init(directoryURL: URL, directoryIdentity: LocalFileIdentity) {
        self.directoryURL = directoryURL
        self.directoryIdentity = directoryIdentity
    }

    /// Capture a chosen directory without listing its children. The writer
    /// reopens and verifies this same directory before changing anything.
    public static func verifiedDirectory(at url: URL) async throws -> Self {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            let resolved = try LocalFileOperations.resolveDirectory(url)
            let local = try resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            guard let identity = try LocalFileIdentity.read(at: resolved, ifLocal: local) else {
                throw FileOperationError.staleParent
            }
            let context = Self(directoryURL: url, directoryIdentity: identity)
            return try LocalFileOperations.withParent(context) { _, route in
                try LocalFileOperations.revalidateRoute(context, resolved: resolved)
                guard LocalFileOperations.sameBytes(route.path, resolved.path) else { throw FileOperationError.staleParent }
                return context
            }
        }
    }
}

/// Why a cross-volume move kept its original (MAC-066/067). Destination-side
/// causes never attempted removal; `originalNotRemovable` failed at the source.
public enum SourceRetentionCause: Equatable, Sendable {
    case destinationNotVerified, metadataNotPreserved, originalNotRemovable
}

public struct FileOperationResult: Sendable {
    public let url: URL
    public let identity: LocalFileIdentity?
    public let warning: String?
    public let accessFailure: FileAccessFailure?
    /// MAC-066/067: set when a cross-volume move published its copy but kept
    /// (all or part of) the original. Such a result is never a completed move.
    public let sourceRetention: String?
    /// Folder holding the kept original, and why it was kept.
    public let retainedOriginalLocation: URL?
    public let sourceRetentionCause: SourceRetentionCause?
    /// Where `accessFailure` occurred, when it is not the published item's folder.
    public let accessFailureLocation: URL?
    /// Authoritative work for this item (MAC-069): copied regular-file bytes and
    /// copied entries, or one entry for a same-volume rename. nil when unknown.
    public let transferredBytes: Int64?
    public let transferredEntries: Int?
    /// MAC-071: the replaced existing item's Trash receipt (recoverable via Recently Trashed).
    public let replacedReceipt: TrashReceipt?
    public init(url: URL, identity: LocalFileIdentity?, warning: String?, accessFailure: FileAccessFailure? = nil,
                sourceRetention: String? = nil, retainedOriginalLocation: URL? = nil,
                sourceRetentionCause: SourceRetentionCause? = nil, accessFailureLocation: URL? = nil,
                transferredBytes: Int64? = nil, transferredEntries: Int? = nil,
                replacedReceipt: TrashReceipt? = nil) {
        self.url = url
        self.identity = identity
        self.warning = warning
        self.accessFailure = accessFailure
        self.sourceRetention = sourceRetention
        self.retainedOriginalLocation = retainedOriginalLocation
        self.sourceRetentionCause = sourceRetentionCause
        self.accessFailureLocation = accessFailureLocation
        self.transferredBytes = transferredBytes
        self.transferredEntries = transferredEntries
        self.replacedReceipt = replacedReceipt
    }
}

public enum FileOperationError: LocalizedError, Equatable, Sendable {
    case invalidName(String)
    case collision(String)
    case staleParent
    case staleSource
    case unsupported(String)
    case systemFailure(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason): return reason
        case .collision(let name): return "An item named “\(name)” already exists. Choose a different name."
        case .staleParent: return "The folder changed since it was displayed. Refresh before trying again."
        case .staleSource: return "The selected item changed or disappeared. Refresh before trying again."
        case .unsupported(let reason): return reason
        case .systemFailure(let operation, let code):
            return "\(operation) failed. \(String(cString: strerror(code)))"
        }
    }
}

public protocol FileOperating: Sendable {
    func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult
    func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult
}

/// FR-FILE-001 / EV-0263–0267 / AT-FILE-001; FR-FILE-018 / EV-0235 / AT-FILE-018.
/// Only immediate-child creation and exclusive same-directory rename are supported.
/// Root/source samples reduce stale writes, but are not atomic source compare-and-swap.
public struct LocalFileOperations: FileOperating {
    private let afterCommit: (@Sendable (URL) -> Void)?
    public init() { afterCommit = nil }
    // A narrow test seam exercises disappearance between a successful syscall and
    // result sampling. It cannot turn a committed mutation into a thrown failure.
    init(afterCommit: @escaping @Sendable (URL) -> Void) { self.afterCommit = afterCommit }

    public func createFolder(named name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try Self.validateName(name)
            return try Self.withParent(context) { descriptor, resolved in
                try Self.revalidateRoute(context, resolved: resolved)
                try cancellation.checkCancellation()
                let result = name.withCString { mkdirat(descriptor, $0, mode_t(0o777)) }
                guard result == 0 else { throw Self.failure(errno, operation: "Create folder", name: name) }
                // Once mkdirat succeeds, cancellation must not turn success into a retry.
                let destination = context.directoryURL.appendingPathComponent(name, isDirectory: true)
                afterCommit?(destination)
                return Self.committedResult(at: destination, name: name, descriptor: descriptor,
                                            context: context, resolved: resolved, expected: nil, operation: "The folder was created")
            }
        }
    }

    public func rename(_ item: FileItem, to name: String, in context: FileOperationContext) async throws -> FileOperationResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try Self.validateName(name)
            try Self.validateName(item.name)
            try Self.validateURL(item.url)
            // Foundation can normalize the URL component without changing the
            // enumerated filename's Unicode form. Compare this semantic relationship
            // canonically; use the original item.name for no-follow identity/syscalls.
            guard Self.sameBytes(item.url.deletingLastPathComponent().standardizedFileURL.path,
                                 context.directoryURL.standardizedFileURL.path),
                  item.name == item.url.lastPathComponent else {
                throw FileOperationError.unsupported("Rename is limited to the selected entry in the displayed folder.")
            }
            guard let expected = item.identity else {
                throw FileOperationError.unsupported("This item has no supported local identity. Refresh before renaming it.")
            }
            return try Self.withParent(context) { descriptor, resolved in
                let capabilities = try resolved.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
                guard capabilities.volumeSupportsExclusiveRenaming == true else {
                    throw FileOperationError.unsupported("This filesystem does not advertise exclusive renaming support.")
                }
                try Self.revalidateRoute(context, resolved: resolved)
                let current: LocalFileIdentity
                do { current = try Self.identity(of: item.name, in: descriptor) }
                catch FileOperationError.systemFailure(_, let code) where code == ENOENT {
                    throw FileOperationError.staleSource
                }
                guard current == expected else { throw FileOperationError.staleSource }
                try cancellation.checkCancellation()
                if Self.sameBytes(item.name, name) {
                    return FileOperationResult(url: item.url, identity: current, warning: nil)
                }
                let result = item.name.withCString { source in
                    name.withCString { destination in
                        renameatx_np(descriptor, source, descriptor, destination, UInt32(RENAME_EXCL))
                    }
                }
                guard result == 0 else { throw Self.failure(errno, operation: "Rename", name: name) }
                let destination = context.directoryURL.appendingPathComponent(name, isDirectory: item.url.hasDirectoryPath)
                afterCommit?(destination)
                return Self.committedResult(at: destination, name: name, descriptor: descriptor,
                                            context: context, resolved: resolved, expected: expected, operation: "The item was renamed")
            }
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FileOperationError.invalidName("Enter one nonempty filename without / or NUL. The names . and .. are not allowed.")
        }
    }

    static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              !url.path.contains("\0") else {
            throw FileOperationError.unsupported("File operations require a local folder URL.")
        }
    }

    /// Resolve directory targets consistently with listing, without converting
    /// realpath's /private spelling back to a final-component root symlink.
    /// Callers still establish local-volume support, identity and write authority.
    static func resolveDirectory(_ url: URL) throws -> URL {
        try validateURL(url)
        do { return try FileSystemPath.resolvingExisting(url.standardizedFileURL) }
        catch {
            if FileAccessFailure.isMissingLocation(error) { throw FileOperationError.staleParent }
            throw error
        }
    }

    static func withParent<Result>(_ context: FileOperationContext,
                                           _ body: (Int32, URL) throws -> Result) throws -> Result {
        let resolved = try resolveDirectory(context.directoryURL)
        let values: URLResourceValues
        do { values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey]) }
        catch {
            if FileAccessFailure.isMissingLocation(error) { throw FileOperationError.staleParent }
            throw error
        }
        guard values.isDirectory == true else { throw FileOperationError.staleParent }
        guard values.volumeIsLocal == true else {
            throw FileOperationError.unsupported("Writes are supported only on confirmed local volumes.")
        }
        let descriptor = resolved.withUnsafeFileSystemRepresentation { path in
            // Mutations need traversal and exact child metadata, not directory
            // enumeration. O_SEARCH retains a real identity-checked directory
            // descriptor while respecting locations that deny listing (Trash).
            path.map { Darwin.open($0, O_SEARCH | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { throw failure(errno, operation: "Open folder", name: resolved.lastPathComponent) }
        defer { Darwin.close(descriptor) }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw failure(errno, operation: "Inspect folder", name: resolved.lastPathComponent) }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileOperationError.unsupported("Writes are supported only on confirmed local volumes.")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw failure(errno, operation: "Inspect folder", name: resolved.lastPathComponent) }
        guard let identity = LocalFileIdentity.fromStat(metadata) else {
            throw FileOperationError.unsupported("The folder has no supported local identity.")
        }
        guard identity == context.directoryIdentity else { throw FileOperationError.staleParent }
        return try body(descriptor, resolved)
    }

    static func revalidateRoute(_ context: FileOperationContext, resolved: URL) throws {
        let current = try resolveDirectory(context.directoryURL)
        let identity: LocalFileIdentity?
        do { identity = try LocalFileIdentity.read(at: current, ifLocal: true) }
        catch {
            if FileAccessFailure.isMissingLocation(error) { throw FileOperationError.staleParent }
            throw error
        }
        guard sameBytes(current.path, resolved.path), identity == context.directoryIdentity else {
            throw FileOperationError.staleParent
        }
    }

    static func identity(of name: String, in descriptor: Int32) throws -> LocalFileIdentity {
        var value = stat()
        let result = name.withCString { fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw failure(errno, operation: "Read item identity", name: name) }
        guard let identity = LocalFileIdentity.fromStat(value) else {
            throw FileOperationError.unsupported("The item has no supported local identity.")
        }
        return identity
    }

    static func committedResult(at url: URL, name: String, descriptor: Int32,
                                        context: FileOperationContext, resolved: URL,
                                        expected: LocalFileIdentity?, operation: String) -> FileOperationResult {
        do {
            try revalidateRoute(context, resolved: resolved)
            let sampled = try identity(of: name, in: descriptor)
            guard expected == nil || sampled == expected else { throw FileOperationError.staleSource }
            return FileOperationResult(url: url, identity: sampled, warning: nil)
        } catch {
            return FileOperationResult(url: url, identity: nil,
                warning: "\(operation), but its current identity could not be verified. Refresh before another operation. \(error.localizedDescription)",
                accessFailure: FileAccessFailure.classify(error))
        }
    }

    static func failure(_ code: Int32, operation: String, name: String) -> FileOperationError {
        if code == EEXIST || code == ENOTEMPTY { return .collision(name) }
        if code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS || code == EXDEV {
            return .unsupported("This filesystem does not support the required exclusive operation.")
        }
        return .systemFailure(operation: operation, code: code)
    }
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
