import Foundation

/// MAC-078: routing commands (Open with several items, Open With, Open in New
/// Tab/Window, Open in Terminal) act only on the entry their menu captured. A
/// local entry is re-sampled without following links and must keep its identity;
/// an entry without a local identity cannot be verified and is routed by path,
/// as activation is.
public enum RoutingTargetValidation {
    public static func isCurrent(_ item: FileItem) async -> Bool {
        guard item.url.isFileURL else { return false }
        guard let expected = item.identity else { return true }
        let url = item.url
        return (try? await BlockingIO.run(on: .read) { _ in
            try LocalFileIdentity.read(at: url, ifLocal: true) == expected
        }) ?? false
    }

    /// MAC-082: the identity of an item another application named, sampled without
    /// following a final link and only on a local volume (nil otherwise). Lets a reveal
    /// find the entry even when the request spells its name differently (case,
    /// Unicode normalization) from the listing.
    public static func requestedIdentity(of url: URL) -> LocalFileIdentity? {
        guard let local = try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal else { return nil }
        return try? LocalFileIdentity.read(at: url, ifLocal: local)
    }

    /// MAC-083: a requested folder's identity computed exactly as a listing computes
    /// its `directoryIdentity` (links resolved, local volumes only), so a request and
    /// an open tab are recognized as the same folder whichever spelling either uses.
    public static func folderIdentity(of url: URL) -> LocalFileIdentity? {
        guard let resolved = try? FileSystemPath.resolvingExisting(url),
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey]),
              values.isDirectory == true else { return nil }
        return try? LocalFileIdentity.read(at: resolved, ifLocal: values.volumeIsLocal)
    }

    /// A displayed folder is identified as the listing does: its resolved path,
    /// sampled without following a final link, on a local volume only.
    public static func isCurrentFolder(_ url: URL, identity expected: LocalFileIdentity?) async -> Bool {
        guard url.isFileURL else { return false }
        guard let expected else { return true }
        return (try? await BlockingIO.run(on: .read) { _ in
            let resolved = try FileSystemPath.resolvingExisting(url)
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
            guard values.isDirectory == true else { return false }
            return try LocalFileIdentity.read(at: resolved, ifLocal: values.volumeIsLocal) == expected
        }) ?? false
    }
}
