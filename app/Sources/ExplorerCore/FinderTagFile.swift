import Darwin
import Foundation

/// The represented directory entry and its initial assignments. No file contents are opened.
public struct FinderTagFile: Sendable {
    public let url: URL
    public let identity: LocalFileIdentity
    public let names: [String]

    public struct WriteResult: Sendable {
        public let names: [String]
        public let otherNamesChanged: Bool
    }

    public static func identity(at url: URL) async throws -> LocalFileIdentity {
        let result = try await resultIdentity(at: url)
        guard !result.isSymbolicLink else { throw TagError.unsupported }
        return result.identity
    }

    /// A result may represent a lexical link even though tag writes cannot target it.
    public static func resultIdentity(at url: URL) async throws -> (identity: LocalFileIdentity, isSymbolicLink: Bool) {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            return try HydrationMaterializationPolicy().disabled { _ in
                let status = try entryStatus(url)
                let type = status.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFLNK), let identity = LocalFileIdentity.fromStat(status) { return (identity, true) }
                return (try checkedIdentity(status), false)
            }
        }
    }

    public static func read(at url: URL, expecting identity: LocalFileIdentity? = nil) async throws -> Self {
        try await BlockingIO.run(on: .read) { cancellation in
            try cancellation.checkCancellation()
            return try HydrationMaterializationPolicy().disabled { _ in
                try withResource(at: url, expecting: identity) { reference, current, _ in
                    Self(url: url, identity: current, names: try tagNames(reference))
                }
            }
        }
    }

    public func apply(adding: [String], removing: Set<String>) async throws -> WriteResult {
        do { return try await write(adding: adding, removing: removing, outsideProvider: false) }
        catch FinderTagNativeMetadata.Failure.needsProviderCheck {
            try Task.checkCancellation()
            guard await FinderTagNativeMetadata.outsideProvider(at: url) else { throw FinderTagNativeMetadata.Failure.colorUnavailable }
            // Resolve provider membership without holding the process-wide mutation lane.
            // Another editor may have run meanwhile, so prepare from scratch on re-entry.
            return try await write(adding: adding, removing: removing, outsideProvider: true)
        }
    }

    private func write(adding: [String], removing: Set<String>, outsideProvider: Bool) async throws -> WriteResult {
        try await BlockingIO.run(on: .mutation) { cancellation in
            try cancellation.checkCancellation()
            return try HydrationMaterializationPolicy().disabled { _ in
                try Self.withResource(at: url, expecting: identity) { reference, _, descriptor in
                    let before = try FinderTagNativeMetadata(descriptor: descriptor)
                    let previous = try Self.tagNames(reference)
                    let original = try before.representedRecords(for: previous)
                    var desired = previous.filter { !removing.contains($0) }
                    for name in adding where !desired.contains(name) { desired.append(name) }
                    guard desired != previous else { return WriteResult(names: previous, otherNamesChanged: false) }
                    let simulation = try before.simulating(desired)
                    let publicPalette = Dictionary(uniqueKeysWithValues: simulation.records.map { ($0.name, $0.color) })
                    let retained = original.filter { !removing.contains($0.name) }
                    let publicIsLossless = retained.allSatisfy { publicPalette[$0.name] == $0.color }
                    let expected: [FinderTagNativeMetadata.Record]
                    let mirror: Int
                    if publicIsLossless {
                        expected = simulation.records
                        mirror = simulation.mirror
                    } else {
                        let retainedNames = Set(retained.map(\.name))
                        expected = retained + simulation.records.filter { !retainedNames.contains($0.name) }
                        mirror = before.mirror
                        guard before.tags != nil, before.keepMirror(for: original, final: expected),
                              try FinderTagNativeMetadata.hasLocalBacking(descriptor: descriptor, at: url) else {
                            throw FinderTagNativeMetadata.Failure.colorUnavailable
                        }
                        guard outsideProvider else { throw FinderTagNativeMetadata.Failure.needsProviderCheck }
                    }

                    try cancellation.checkCancellation()
                    guard try Self.sample(url) == identity else { throw TagError.changed }
                    guard try FinderTagNativeMetadata(descriptor: descriptor) == before else {
                        throw FinderTagNativeMetadata.Failure.changed
                    }
                    if publicIsLossless { try reference.setResourceValue(desired, forKey: .tagNamesKey) }
                    else { try FinderTagNativeMetadata.replaceTags(expected, on: descriptor) }

                    let actual = try Self.tagNames(reference)
                    guard Set(adding).isSubset(of: actual), removing.isDisjoint(with: actual) else { throw TagError.unverified }
                    // A later external edit must not be overwritten by a retry. Once the
                    // requested delta landed, report differing unrelated names/colors as a warning.
                    let after = try? FinderTagNativeMetadata(descriptor: descriptor)
                    let palette = try? after?.representedRecords(for: actual)
                    let colors = palette.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.name, $0.color) }) }
                    let unchanged = colors == Dictionary(uniqueKeysWithValues: expected.map { ($0.name, $0.color) })
                        && after?.mirror == mirror && after?.unrelatedInfo == before.unrelatedInfo
                    return WriteResult(names: actual, otherNamesChanged: !unchanged)
                }
            }
        }
    }

    private static func tagNames(_ reference: NSURL) throws -> [String] {
        reference.removeCachedResourceValue(forKey: .tagNamesKey)
        var value: AnyObject?
        try reference.getResourceValue(&value, forKey: .tagNamesKey)
        return value as? [String] ?? []
    }

    private static func sample(_ url: URL) throws -> LocalFileIdentity {
        try checkedIdentity(entryStatus(url))
    }

    private static func entryStatus(_ url: URL) throws -> stat {
        guard url.isFileURL else { throw TagError.unsupported }
        var status = stat()
        let code = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &status)
        }
        guard code == 0 else { throw ContentFileIO.failure() }
        return status
    }

    private static func checkedIdentity(_ value: stat) throws -> LocalFileIdentity {
        let type = value.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR),
              let identity = LocalFileIdentity.fromStat(value) else { throw TagError.unsupported }
        return identity
    }

    /// Keep the inode alive and address Foundation's write through its file-reference URL.
    /// File systems that can only name a leaf relative to a referenced *parent* cannot
    /// provide this binding. Refuse those rather than send a write to a replacement.
    private static func withResource<Value>(at url: URL, expecting expected: LocalFileIdentity?,
                                            _ operation: (NSURL, LocalFileIdentity, Int32) throws -> Value) throws -> Value {
        let sampled = try sample(url)
        if let expected, expected != sampled { throw TagError.changed }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ContentFileIO.failure() }
        defer { Darwin.close(descriptor) }
        guard try checkedIdentity(ContentFileIO.sample(descriptor)) == sampled else { throw TagError.changed }
        guard let created = CFURLCreateFileReferenceURL(nil, url as CFURL, nil) else { throw TagError.unsupported }
        let reference = created.takeRetainedValue()
        // Apple's file-reference form is file:///.file/id=volume.object/. A further
        // path component means the object itself has no persistent file ID reference.
        let components = URLComponents(string: CFURLGetString(reference) as String)?.percentEncodedPath.split(separator: "/")
        guard let components, components.count == 2, components[0] == ".file",
              components[1].hasPrefix("id=") else { throw TagError.unsupported }
        let resource = reference as NSURL
        guard let path = resource.filePathURL, try sample(path) == sampled,
              try sample(url) == sampled else { throw TagError.changed }
        return try operation(resource, sampled, descriptor)
    }

    private enum TagError: LocalizedError {
        case unsupported, changed, unverified

        var errorDescription: String? {
            switch self {
            case .unsupported: "Finder tags require a file or folder whose identity can be verified on this volume."
            case .changed: "The item has moved or changed since it was shown."
            case .unverified: "The volume did not retain the requested Finder tags."
            }
        }
    }
}
