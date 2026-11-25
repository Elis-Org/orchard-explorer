import CoreServices
import Darwin
import FileProvider
import Foundation

public struct SidebarVolume: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let symbol: String

    public init(id: String, title: String, url: URL, symbol: String) {
        self.id = id
        self.title = title
        self.url = url
        self.symbol = symbol
    }

    /// Mount identity collapses aliases, including the startup-disk link under /Volumes.
    public static func mounted() -> [Self] {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                            options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        return ([root] + mounts).compactMap { url in
            var sample = stat()
            guard stat(url.path, &sample) == 0 else { return nil }
            let id = "mount:" + String(sample.st_dev)
            guard seen.insert(id).inserted else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let title = values?.volumeLocalizedName ?? (url.path == "/" ? "Startup disk" : url.lastPathComponent)
            let symbol = values?.volumeIsLocal == false ? "network" :
                (url.path == "/" || values?.volumeIsInternal == true ? "internaldrive.fill" : "externaldrive.fill")
            return Self(id: id, title: title, url: url, symbol: symbol)
        }
    }
}

public struct SidebarAccount: Identifiable, Equatable, Sendable {
    public enum Provider: String, Sendable { case oneDrive }
    public let provider: Provider
    public let id: String
    public let title: String
    public let url: URL

    private let hasLocalizedDisplayName: Bool

    public func sidebarTitle(isOnlyAccount: Bool) -> String {
        isOnlyAccount && !hasLocalizedDisplayName ? "OneDrive" : title
    }

    static func candidateName(_ name: String) -> Bool {
        (name == "OneDrive" || name.hasPrefix("OneDrive-")) && !name.hasPrefix("OneDrive-SharedLibraries")
    }

    /// A folder name or a saved marker alone cannot identify a live File Provider root.
    static func oneDrive(url: URL, localizedName: String, marker: String?, liveDomain: String?, isRoot: Bool) -> Self? {
        guard isRoot, candidateName(url.lastPathComponent), let marker, let liveDomain, !liveDomain.isEmpty,
              ["com.microsoft.OneDrive.FileProvider/", "com.microsoft.OneDrive-mac.FileProvider/"]
                .contains(where: { marker == $0 + liveDomain }) else { return nil }
        // Foundation also returns the compact on-disk basename when no localized label is available.
        let hasLocalizedDisplayName = !localizedName.isEmpty && localizedName != url.lastPathComponent
        let fallback = liveDomain.hasPrefix("OneDrive - ") ? liveDomain : url.lastPathComponent
        return Self(provider: .oneDrive, id: marker, title: hasLocalizedDisplayName ? localizedName : fallback,
                    url: url, hasLocalizedDisplayName: hasLocalizedDisplayName)
    }

    public static func discover(homeURL: URL, volumes: [SidebarVolume]) async -> [Self] {
        let candidates: [URL] = (try? HydrationMaterializationPolicy().disabled { _ -> [URL] in
            let cloud = homeURL.appendingPathComponent("Library/CloudStorage", isDirectory: true)
            var urls: [URL] = []
            if let enumerator = FileManager.default.enumerator(at: cloud, includingPropertiesForKeys: [],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                for case let url as URL in enumerator.prefix(128) where candidateName(url.lastPathComponent) {
                    urls.append(url)
                }
            }
            // macOS 15+ can host domains directly on a local external drive. Query
            // the index there; walking the disk, network mounts or any account is unnecessary.
            let external = volumes.compactMap { volume -> URL? in
                guard volume.url.path != "/",
                      let properties = try? volume.url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey]),
                      properties.volumeIsLocal == true, properties.volumeIsInternal == false else { return nil }
                return volume.url
            }
            if !external.isEmpty, let query = MDQueryCreate(nil,
                "kMDItemFSName == 'OneDrive*' && kMDItemContentType == 'public.folder'" as CFString, nil, nil) {
                MDQuerySetSearchScope(query, external as CFArray, 0)
                MDQuerySetMaxCount(query, 32)
                if MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) {
                    for index in 0..<MDQueryGetResultCount(query) {
                        guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
                        let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                        guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        if candidateName(url.lastPathComponent) { urls.append(url) }
                    }
                }
            }
            return urls
        }) ?? []
        var seen = Set<String>()
        var accounts: [Self] = []
        for url in candidates {
            guard !Task.isCancelled else { break }
            // Microsoft documents this exact xattr to identify the configured edition.
            // Read only a bounded root attribute; also require Apple's live domain proof.
            let marker = try? HydrationMaterializationPolicy().disabled { _ -> String? in
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = getxattr(url.path, "com.apple.file-provider-domain-id", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
                guard n > 0 else { return nil }
                return String(bytes: buffer.prefix(n), encoding: .utf8)
            }
            guard let marker, marker.hasPrefix("com.microsoft.OneDrive"),
                  let (item, domain) = try? await NSFileProviderManager.identifierForUserVisibleFile(at: url),
                  item == .rootContainer else { continue }
            let name = (try? HydrationMaterializationPolicy().disabled { _ in
                try url.resourceValues(forKeys: [.localizedNameKey]).localizedName
            }) ?? url.lastPathComponent
            if let account = oneDrive(url: url, localizedName: name, marker: marker, liveDomain: domain.rawValue,
                                      isRoot: true), seen.insert(account.id).inserted {
                accounts.append(account)
            }
        }
        return accounts.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
