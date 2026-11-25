import Darwin
import Foundation

public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tar
    public var fileExtension: String { rawValue }
    public var title: String { self == .zip ? "ZIP File" : "TAR File" }
}
public protocol ArchiveCreating: Sendable {
    func compress(_ items: [FileItem], in context: FileOperationContext, format: ArchiveFormat,
                  control: TransferControl) async throws -> FileOperationResult
}
public struct LocalArchiveCreator: ArchiveCreating {
    /// Test seam: runs once the stage exists, before anything is written into it.
    let afterStaging: (@Sendable (URL) -> Void)?
    public init() { afterStaging = nil }
    init(afterStaging: @escaping @Sendable (URL) -> Void) { self.afterStaging = afterStaging }
    public func compress(_ items: [FileItem], in context: FileOperationContext, format: ArchiveFormat,
                         control: TransferControl) async throws -> FileOperationResult {
        try await BlockingIO.run(on: .copy, onCancel: { control.cancel() }) { cancellation in
            guard !items.isEmpty else { throw FileOperationError.unsupported("Select at least one item to compress.") }
            guard Set(items.map(\.name)).count == items.count else { throw FileOperationError.unsupported("Select each item only once.") }
            return try LocalFileOperations.withParent(context) { parent, resolved in
                try LocalFileOperations.revalidateRoute(context, resolved: resolved)
                for item in items { try ServiceStage.verify(item, context: context, parent: parent) }
                try cancellation.checkCancellation(); try control.checkpoint()
                let stage = try ServiceStage(parent: parent, url: resolved, prefix: ".explorer-archive-")
                defer { stage.clean() }
                afterStaging?(stage.url)
                // MAC-078: the tool never opens a pathname inside the stage. The archive and
                // its diagnostics are created exclusively relative to the held stage
                // descriptor and handed to the tool as stdout/stderr, so a renamed or
                // substituted stage cannot redirect its writes. ZIP output duplicates
                // the inherited regular-file stdout via /dev/fd/1 to avoid bsdtar's
                // stdout block padding; keep this a regular file, not a pipe.
                let (payload, expected) = try stage.createFile("payload")
                let (errors, _) = try stage.createFile("stderr")
                defer { try? payload.close(); try? errors.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                if format == .zip {
                    // Suppress generated metadata and housekeeping below selected roots.
                    // Prefix operands so @names are literal; strip only that prefix from
                    // stored paths, leaving symlink targets and explicit dotfiles intact.
                    process.arguments = ["--format", "zip", "--no-mac-metadata", "--no-xattrs", "--no-acls",
                                         "--exclude", "./*/.DS_Store", "--exclude", "./*/._*", "--exclude", "./*/__MACOSX",
                                         "-s", ",^\\./,,S", "-cf", "/dev/fd/1", "-C", resolved.path, "--"]
                        + items.map { "./" + $0.name }
                    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
                } else {
                    process.arguments = ["--format", "pax", "-cf", "-", "-C", resolved.path, "--"] + items.map(\.name)
                }
                // A file avoids pipe-buffer deadlock even when the tool emits abundant diagnostics.
                process.standardError = errors
                process.standardOutput = payload
                do { try process.run() } catch { throw FileOperationError.unsupported("Could not start archive tool: \(error.localizedDescription)") }
                do {
                    while process.isRunning {
                        try cancellation.checkCancellation(); try control.checkpoint()
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    process.waitUntilExit()
                    try cancellation.checkCancellation(); try control.checkpoint()
                } catch {
                    if process.isRunning {
                        process.terminate()
                        let deadline = Date().addingTimeInterval(0.25)
                        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    throw error
                }
                guard process.terminationStatus == 0 else {
                    try errors.seek(toOffset: 0)
                    let data = try errors.read(upToCount: 4096) ?? Data()
                    let message = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw FileOperationError.unsupported("Archive tool failed (\(process.terminationStatus)): \(message)")
                }
                let base = items.count == 1 ? items[0].name : "Archive"
                try payload.close()
                return try stage.publish(context: context, resolved: resolved, payload: expected, name: { suffix in
                    base + (suffix == 1 ? "" : " \(suffix)") + "." + format.fileExtension
                }, beforePublish: {
                    try cancellation.checkCancellation(); try control.checkpoint()
                    for item in items { try ServiceStage.verify(item, context: context, parent: parent) }
                })
            }
        }
    }
}

/// Private destination-side container shared by archive and Finder bookmark writers.
final class ServiceStage {
    let parent: Int32
    let descriptor: Int32
    let name: String
    let url: URL
    let identity: LocalFileIdentity
    init(parent: Int32, url: URL, prefix: String) throws {
        self.parent = parent
        name = prefix + UUID().uuidString
        self.url = url.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(parent, name, 0o700) == 0 else { throw LocalFileOperations.failure(errno, operation: "Create staging", name: name) }
        descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { unlinkat(parent, name, AT_REMOVEDIR); throw POSIXError(.EIO) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, let identity = LocalFileIdentity.fromStat(metadata) else {
            close(descriptor); unlinkat(parent, name, AT_REMOVEDIR); throw POSIXError(.EIO)
        }
        self.identity = identity
        // Remove inherited extended ACLs, then restrict access to this owner.
        guard let emptyACL = acl_init(0) else { close(descriptor); unlinkat(parent, name, AT_REMOVEDIR); throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        let aclResult = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        let aclError = errno
        guard fchmod(descriptor, 0o700) == 0, aclResult == 0 || aclError == ENOTSUP || aclError == EOPNOTSUPP else {
            close(descriptor); unlinkat(parent, name, AT_REMOVEDIR); throw POSIXError(.EACCES)
        }
    }
    deinit { close(descriptor) }
    /// Creates `name` exclusively inside the held stage (never through a pathname)
    /// and returns a read-write handle with the created file's identity.
    func createFile(_ name: String) throws -> (FileHandle, LocalFileIdentity) {
        let fd = openat(descriptor, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalFileOperations.failure(errno, operation: "Create staging file", name: name) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, let identity = LocalFileIdentity.fromStat(metadata) else {
            close(fd); unlinkat(descriptor, name, 0); throw POSIXError(.EIO)
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), identity)
    }
    func clean() {
        guard (try? LocalFileOperations.identity(of: name, in: parent)) == identity else { return }
        // Only two owned regular files can exist in this container; never recurse through links.
        unlinkat(descriptor, "payload", 0)
        unlinkat(descriptor, "stderr", 0)
        unlinkat(parent, name, AT_REMOVEDIR)
    }
    static func verify(_ item: FileItem, context: FileOperationContext, parent: Int32) throws {
        guard (try? LocalFileOperations.validateName(item.name)) != nil,
              item.url.isFileURL,
              LocalFileOperations.sameBytes(item.url.deletingLastPathComponent().standardizedFileURL.path, context.directoryURL.standardizedFileURL.path),
              item.url.lastPathComponent == item.name, let expected = item.identity else { throw FileOperationError.staleSource }
        do { guard try LocalFileOperations.identity(of: item.name, in: parent) == expected else { throw FileOperationError.staleSource } }
        catch FileOperationError.systemFailure(_, let code) where code == ENOENT { throw FileOperationError.staleSource }
    }
    enum CollisionPolicy { case unique, exact }

    /// Publishes the stage's `payload`, which must still be the file created as
    /// `expected`, under the requested naming policy without replacing an entry.
    func publish(context: FileOperationContext, resolved: URL, payload expected: LocalFileIdentity,
                 collision: CollisionPolicy = .unique, name makeName: (Int) -> String, beforePublish: () throws -> Void) throws -> FileOperationResult {
        var suffix = 1
        while true {
            let destination = makeName(suffix)
            try LocalFileOperations.validateName(destination)
            try LocalFileOperations.revalidateRoute(context, resolved: resolved)
            guard try LocalFileOperations.identity(of: name, in: parent) == identity,
                  try LocalFileOperations.identity(of: "payload", in: descriptor) == expected else { throw FileOperationError.staleSource }
            try beforePublish()
            if renameatx_np(descriptor, "payload", parent, destination, UInt32(RENAME_EXCL)) == 0 {
                return LocalFileOperations.committedResult(at: context.directoryURL.appendingPathComponent(destination), name: destination,
                    descriptor: parent, context: context, resolved: resolved, expected: expected, operation: "The item was created")
            }
            let code = errno
            guard code == EEXIST else { throw LocalFileOperations.failure(code, operation: "Publish", name: destination) }
            if collision == .exact { throw FileOperationError.collision(destination) }
            suffix += 1
        }
    }
}
