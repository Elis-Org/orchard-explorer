import Darwin
import Foundation

/// Physical paths for inspecting an existing target. Display/history URLs and
/// no-follow entry identities remain separate from this resolved target URL.
public enum FileSystemPath {
    /// Read package metadata independently of structural file-type keys so a
    /// caller can distinguish an opaque directory from unavailable metadata.
    public static func packageStatus(at url: URL) throws -> Bool? {
        try url.resourceValues(forKeys: [.isPackageKey]).isPackage
    }

    /// Foundation resolution/standardization can turn /private/etc, /private/tmp
    /// and /private/var back into final-component links. Keep realpath's spelling
    /// unstandardized so resource metadata describes the target. This does not
    /// establish local-volume support, persistent identity, or write authority.
    /// Missing, inaccessible and cyclic targets retain their POSIX error.
    public static func resolvingExisting(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              !url.path.contains("\0") else { throw CocoaError(.fileReadUnsupportedScheme) }
        let physical = url.withUnsafeFileSystemRepresentation { path -> UnsafeMutablePointer<CChar>? in
            guard let path else { errno = EINVAL; return nil }
            return Darwin.realpath(path, nil)
        }
        guard let physical else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { Darwin.free(physical) }
        return URL(fileURLWithFileSystemRepresentation: physical, isDirectory: false, relativeTo: nil)
    }
}
