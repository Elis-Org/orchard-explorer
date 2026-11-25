import ExplorerCore
import Foundation

/// MAC-082 — requests from other applications to open items in Maxplorer.
///
/// macOS delivers "open these items" to the app for `open -a Maxplorer …`, for the
/// Open With menu and, when `NSFileViewer` names Maxplorer, for other apps' "Show in
/// Finder" (observed as an ordinary open request carrying the item). A file manager
/// shows items rather than opening them in another application:
/// - a folder (not a package) opens in its own tab;
/// - any other item — a file, package, alias or link — is revealed: its folder
///   opens in a tab with that item selected. Items sharing a folder share one tab.
/// Non-file URLs are ignored; duplicates are dropped; request order is kept.
struct OpenRequestPlan: Equatable {
    struct Target: Equatable {
        let folder: URL
        let reveal: [URL]
        /// Identities sampled for revealed items (by standardized path), when local.
        var identities: [String: LocalFileIdentity] = [:]
        /// Other spellings of the folder's path with links resolved (`realpath`, e.g.
        /// /private/var/…, and Foundation's, e.g. /var/…), so an open tab spelled
        /// either way is recognized (MAC-083).
        var alternateFolderPaths: [String] = []
        /// The folder's identity as its listing would record it (local volumes), so a
        /// tab opened through a link or another spelling is recognized (review e73b0f67).
        var folderIdentity: LocalFileIdentity? = nil
    }

    let targets: [Target]
    var isEmpty: Bool { targets.isEmpty }

    static func make(_ urls: [URL], isFolder: (URL) -> Bool,
                     identity: (URL) -> LocalFileIdentity? = { _ in nil }) -> OpenRequestPlan {
        var targets: [Target] = []
        // One target per folder path, whether the folder itself or items in it were
        // requested, so a folder request can never cancel a reveal in the same folder
        // (review dfdb1ba9 finding 5).
        var targetIndex: [String: Int] = [:]
        var seen = Set<String>()
        for raw in urls where raw.isFileURL {
            let url = raw.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            if isFolder(url) {
                if targetIndex[url.path] == nil {
                    targetIndex[url.path] = targets.count
                    targets.append(Target(folder: url, reveal: []))
                }
                continue
            }
            let folder = url.deletingLastPathComponent()
            let index: Int
            if let existing = targetIndex[folder.path] { index = existing } else {
                index = targets.count
                targetIndex[folder.path] = index
                targets.append(Target(folder: folder, reveal: []))
            }
            var target = targets[index]
            target = Target(folder: target.folder, reveal: target.reveal + [url], identities: target.identities)
            if let sampled = identity(url) { target.identities[url.path] = sampled }
            targets[index] = target
        }
        return OpenRequestPlan(targets: targets)
    }

    /// A folder Maxplorer navigates into: a directory that is not a package. A link
    /// to such a folder opens it too; the tab keeps the requested (link) path.
    static func isOpenableFolder(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard var values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isSymbolicLink == true {
            guard let target = try? FileSystemPath.resolvingExisting(url).resourceValues(forKeys: keys) else { return false }
            values = target
        }
        return values.isDirectory == true && values.isPackage != true
    }

    /// The identity used for the reveal's name-variant fallback, sampled only where a
    /// case or normalization variant cannot name a different entry: a local volume
    /// known to be case-insensitive (APFS/HFS+ are also normalization-insensitive).
    /// On case-sensitive or unknown volumes matching stays path-only (review 865f9739).
    static func fallbackIdentity(of url: URL) -> LocalFileIdentity? {
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values?.volumeSupportsCaseSensitiveNames == false else { return nil }
        return RoutingTargetValidation.requestedIdentity(of: url)
    }

    /// Targets that reach the same folder through different spellings (a link and its
    /// target) become one target in the first spelling, so one tab receives every
    /// requested item and identity (review e73b0f67 finding 3).
    /// Without an identity (non-local volumes) the link-resolved path is the key.
    static func mergingSameFolder(_ targets: [Target]) -> [Target] {
        var merged: [Target] = []
        var indexByKey: [String: Int] = [:]
        for target in targets {
            let key = target.folderIdentity.map { "identity:\($0.device):\($0.inode):\($0.birthSeconds):\($0.birthNanoseconds)" }
                ?? "path:" + (target.alternateFolderPaths.first ?? target.folder.standardizedFileURL.path)
            guard let index = indexByKey[key] else {
                indexByKey[key] = merged.count
                merged.append(target)
                continue
            }
            var combined = merged[index]
            var reveal = combined.reveal
            for item in target.reveal {
                let respelled = combined.folder.appendingPathComponent(item.lastPathComponent)
                guard !reveal.contains(where: { $0.path == respelled.path }) else { continue }
                reveal.append(respelled)
                if let sampled = target.identities[item.path] { combined.identities[respelled.path] = sampled }
            }
            combined = Target(folder: combined.folder, reveal: reveal, identities: combined.identities,
                              alternateFolderPaths: combined.alternateFolderPaths, folderIdentity: combined.folderIdentity)
            merged[index] = combined
        }
        return merged
    }

    /// Link-resolved spellings of `folder` other than its own path.
    static func alternateSpellings(of folder: URL) -> [String] {
        var paths: [String] = []
        if let real = realpath(folder.path, nil) { paths.append(String(cString: real)); free(real) }
        paths.append(folder.resolvingSymlinksInPath().path)
        var seen: Set<String> = [folder.standardizedFileURL.path]
        return paths.filter { seen.insert($0).inserted }
    }

    /// Classifies off the main thread (resource reads can be slow on remote volumes).
    static func classify(_ urls: [URL]) async -> OpenRequestPlan {
        await Task.detached(priority: .userInitiated) {
            let plan = make(urls, isFolder: isOpenableFolder, identity: fallbackIdentity(of:))
            let annotated = plan.targets.map { target in
                var resolved = target
                resolved.alternateFolderPaths = alternateSpellings(of: target.folder)
                resolved.folderIdentity = RoutingTargetValidation.folderIdentity(of: target.folder)
                return resolved
            }
            return OpenRequestPlan(targets: mergingSameFolder(annotated))
        }.value
    }
}
