import Foundation
import UniformTypeIdentifiers

enum SystemRecentProvider {
    private static let typeKey = "kMDItemContentTypeTree"
    private static let usedKey = "kMDItemLastUsedDate"
    private static let window: TimeInterval = 90 * 24 * 60 * 60
    private static let documentTypes = ["public.content", "public.composite-content", "com.apple.rtfd",
        "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.numbers",
        "com.apple.iwork.keynote.key"]
    private static let excludedTypes = ["com.apple.application", "com.apple.application-bundle", "public.executable",
        "com.apple.alias-file", "public.symlink"]
    private static let knownPackages: Set<String> = ["app", "appex", "framework", "bundle", "plugin", "rtfd", "pages",
        "numbers", "key", "photoslibrary", "xcodeproj", "xcworkspace", "playground"]

    static func snapshots(_ suppressionCount: Int) -> AsyncThrowingStream<[RecentDocument], Error> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SpotlightSnapshots.live(name: "Recent document search", configure: { query in
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey],
                                                                options: [.skipHiddenVolumes]) ?? []
            let visibleVolumes = mounted.filter {
                $0.path.hasPrefix("/Volumes/") && (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
            }
            query.searchScopes = [home, URL(fileURLWithPath: "/Users/Shared", isDirectory: true)] + visibleVolumes
            query.predicate = predicate(since: Date().addingTimeInterval(-window))
            query.sortDescriptors = [NSSortDescriptor(key: usedKey, ascending: false)]
        }, snapshot: { query, cancelled in
            let now = Date(), cutoff = now.addingTimeInterval(-window)
            return collect(resultCount: query.resultCount, suppressionCount: suppressionCount, cancelled: cancelled) { index in
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let used = item.value(forAttribute: usedKey) as? Date, used >= cutoff, used <= now,
                      (item.value(forAttribute: "kMDItemFSInvisible") as? NSNumber)?.boolValue != true,
                      let types = item.value(forAttribute: typeKey) as? [String], isDocument(types),
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      allows(path: path, home: home.path) else { return nil }
                return (URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL, used)
            }
        })
    }

    /// Eligibility uses indexed metadata first. Removal is identity-aware and
    /// belongs to the merger after the physical sample, never to a path filter.
    static func collect(resultCount: Int, suppressionCount: Int, cancelled: () -> Bool,
                        capture: (URL) -> RecentDocument? = { RecentDocument.capture($0, followingLinks: false) },
                        candidate: (Int) -> (URL, Date)?) -> [RecentDocument] {
        let limit = min(resultCount, 200 + min(suppressionCount, 100))
        var seen = Set<String>(), documents: [RecentDocument] = []
        var sampled = 0
        for index in 0..<limit {
            if cancelled() || sampled >= 100 { break }
            guard let (url, used) = candidate(index), seen.insert(url.path).inserted else { continue }
            sampled += 1
            guard var entry = capture(url) else { continue }
            entry.openedAt = used
            documents.append(entry)
        }
        return documents
    }

    private static func predicate(since: Date) -> NSPredicate {
        func hasType(_ type: String) -> NSPredicate { NSPredicate(format: "%K == %@", typeKey, type) }
        let document = NSCompoundPredicate(orPredicateWithSubpredicates: documentTypes.map(hasType))
        let excluded = NSCompoundPredicate(orPredicateWithSubpredicates: excludedTypes.map(hasType))
        let allowedDirectory = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSCompoundPredicate(notPredicateWithSubpredicate: hasType("public.directory")), hasType("com.apple.package")
        ])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K >= %@", usedKey, since as NSDate), document, allowedDirectory,
            NSCompoundPredicate(notPredicateWithSubpredicate: excluded)
        ])
    }

    static func isDocument(_ types: [String]) -> Bool {
        documentTypes.contains(where: types.contains) && !excludedTypes.contains(where: types.contains)
            && (!types.contains("public.directory") || types.contains("com.apple.package"))
    }

    static func allows(path: String, home: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        let relative: [Substring]
        if path.hasPrefix(home + "/") {
            relative = Array(path.dropFirst(home.count + 1).split(separator: "/"))
            if relative.first == "Library" {
                guard relative.count >= 3, ["CloudStorage", "Mobile Documents"].contains(relative[1]) else { return false }
            } else if relative.first == "Applications" { return false }
        } else if path.hasPrefix("/Users/Shared/") {
            relative = Array(components.dropFirst(2))
        } else if components.first == "Volumes", components.count >= 3 {
            relative = Array(components.dropFirst(2))
            if let first = relative.first, ["System", "Library", "Applications", "private", "usr"].contains(first) { return false }
            if relative.count >= 3, relative[0] == "Users", relative[2] == "Library" { return false }
        } else { return false }

        return !relative.dropLast().contains { component in
            let suffix = (String(component) as NSString).pathExtension.lowercased()
            guard !suffix.isEmpty else { return false }
            if knownPackages.contains(suffix) { return true }
            return UTType(filenameExtension: suffix)?.conforms(to: .package) == true
        }
    }
}
