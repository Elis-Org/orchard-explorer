import Darwin
import Foundation

public enum NewFileTemplate: String, CaseIterable, Sendable {
    case bitmapImage, textDocument, zipArchive

    public var defaultName: String {
        switch self {
        case .bitmapImage: "New Bitmap image.bmp"
        case .textDocument: "New Text Document.txt"
        case .zipArchive: "New Compressed (zipped) Folder.zip"
        }
    }

    public var contents: Data {
        switch self {
        case .bitmapImage, .textDocument: Data()
        case .zipArchive: Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
        }
    }
}
public protocol FileCreating: Sendable {
    func createFile(named name: String, template: NewFileTemplate, in context: FileOperationContext) async throws -> FileOperationResult
}
public struct LocalFileCreator: FileCreating {
    /// Test seams: `afterCreate` runs right after the exclusive create; `failWrite`
    /// injects a write failure.
    let afterCreate: (@Sendable (URL) -> Void)?
    let failWrite: Bool
    public init() { afterCreate = nil; failWrite = false }
    init(afterCreate: @escaping @Sendable (URL) -> Void, failWrite: Bool) { self.afterCreate = afterCreate; self.failWrite = failWrite }
    public func createFile(named name: String, template: NewFileTemplate, in context: FileOperationContext) async throws -> FileOperationResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try LocalFileOperations.validateName(name)
            return try LocalFileOperations.withParent(context) { parent, resolved in
                try LocalFileOperations.revalidateRoute(context, resolved: resolved)
                try cancellation.checkCancellation()
                let fd = openat(parent, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o666)
                guard fd >= 0 else { throw LocalFileOperations.failure(errno, operation: "Create file", name: name) }
                afterCreate?(resolved.appendingPathComponent(name))
                // Ownership comes from the created descriptor, never a later pathname sample:
                // a replacement at `name` is neither reported as created nor removed on failure.
                var created = stat()
                let expected: LocalFileIdentity? = fstat(fd, &created) == 0 ? LocalFileIdentity.fromStat(created) : nil
                do {
                    if failWrite { throw LocalFileOperations.failure(EIO, operation: "Write file", name: name) }
                    try template.contents.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw LocalFileOperations.failure(count == 0 ? EIO : errno, operation: "Write file", name: name) }
                            offset += count
                        }
                    }
                } catch {
                    close(fd)
                    if let expected, (try? LocalFileOperations.identity(of: name, in: parent)) == expected { unlinkat(parent, name, 0) }
                    throw error
                }
                let closeResult = close(fd)
                let result = LocalFileOperations.committedResult(at: context.directoryURL.appendingPathComponent(name), name: name,
                    descriptor: parent, context: context, resolved: resolved, expected: expected,
                    operation: "The file was created")
                if closeResult != 0 {
                    return FileOperationResult(url: result.url, identity: result.identity, warning: "The file was created, but closing it failed. " + (result.warning ?? ""))
                }
                return result
            }
        }
    }
}
