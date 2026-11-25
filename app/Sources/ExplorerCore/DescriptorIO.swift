import Darwin
import Foundation

/// Descriptor mechanics only. Callers retain traversal, metadata and cleanup
/// authority, resource budgets, and their own user-facing error mapping.
enum DescriptorIO {
    enum DirectoryEntryError: Error { case invalidUTF8 }

    static func writeAll(_ data: Data, to descriptor: Int32, at offset: UInt64) throws {
        let maximum = UInt64(off_t.max)
        guard offset <= maximum, UInt64(data.count) <= maximum - offset else { throw POSIXError(.EFBIG) }
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress!.advanced(by: done), bytes.count - done,
                                   off_t(offset) + off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else { throw POSIXError(.EIO) }
                done += count
            }
        }
    }

    static func forEachDirectoryEntry(in descriptor: Int32, checkpoint: () throws -> Void = {},
                                      visit: (String) throws -> Void) throws {
        // dup shares the caller's directory offset. Open a separate cursor and
        // close only that owned stream, including when a callback throws.
        let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cursor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try forEachDirectoryEntry(consuming: cursor, checkpoint: checkpoint) { name, _ in try visit(name) }
    }

    /// Ownership transfers at entry, including failure. The callback descriptor
    /// is borrowed from the owned stream; never close it or retain it afterward.
    static func forEachDirectoryEntry(consuming descriptor: Int32, checkpoint: () throws -> Void = {},
                                      visit: (String, Int32) throws -> Void) throws {
        guard let directory = fdopendir(descriptor) else {
            let error = errno; close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        defer { closedir(directory) }
        while true {
            try checkpoint()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            let name = try withUnsafePointer(to: &entry.pointee.d_name) {
                try $0.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    try decodeDirectoryName(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen)))
                }
            }
            if name != ".", name != ".." { try visit(name, dirfd(directory)) }
        }
    }

    static func decodeDirectoryName(_ bytes: UnsafeBufferPointer<UInt8>) throws -> String {
        guard let name = String(bytes: bytes, encoding: .utf8) else { throw DirectoryEntryError.invalidUTF8 }
        return name
    }

    static func clearExtendedACL(_ descriptor: Int32) throws {
        guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) != 0 {
            let code = errno
            guard code == ENOTSUP || code == EOPNOTSUPP else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
    }
}
