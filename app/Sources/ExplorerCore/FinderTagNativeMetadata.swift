import Darwin
import FileProvider
import Foundation

/// Metadata used to check whether Foundation can preserve the existing Finder colors.
struct FinderTagNativeMetadata: Equatable {
    static let tagsKey = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfoKey = "com.apple.FinderInfo"
    let tags: Data?
    let finderInfo: Data?
    let records: [Record]

    struct Record: Equatable {
        let token: String
        let name: String
        let color: Int

        init(_ token: String) throws {
            let parts = token.components(separatedBy: "\n")
            guard parts.count <= 2, let name = parts.first, !name.isEmpty else { throw Failure.unknown }
            self.name = name
            self.token = token
            if parts.count == 1 { color = 0 }
            else {
                let bytes = Array(parts[1].utf8)
                guard bytes.count == 1, (48...55).contains(bytes[0]) else { throw Failure.unknown }
                color = Int(bytes[0] - 48)
            }
        }
    }

    var mirror: Int { Int(((finderInfo?[9] ?? 0) & 0x0e) >> 1) }
    var unrelatedInfo: Data {
        var data = finderInfo ?? Data(count: 32)
        data[9] &= ~0x0e
        return data
    }

    init(descriptor: Int32) throws {
        finderInfo = try Self.attribute(Self.finderInfoKey, on: descriptor, limit: 32)
        guard finderInfo == nil || finderInfo?.count == 32 else { throw Failure.unknown }
        tags = try Self.attribute(Self.tagsKey, on: descriptor, limit: 64 * 1024)
        if let tags {
            guard let tokens = try PropertyListSerialization.propertyList(from: tags, format: nil) as? [String],
                  tokens.count <= 1_024 else { throw Failure.unknown }
            records = try tokens.map(Record.init)
            guard Set(records.map(\.name)).count == records.count else { throw Failure.unknown }
        } else { records = [] }
    }

    func representedRecords(for publicNames: [String]) throws -> [Record] {
        if tags == nil && mirror != 0 && publicNames.count == 1 {
            return [try Record(publicNames[0] + "\n" + String(mirror))]
        }
        guard Set(publicNames) == Set(records.map(\.name)), publicNames.count == records.count else { throw Failure.unknown }
        return records
    }

    /// Simulate a public write on an exclusively created private, unindexed temporary file.
    /// This asks Finder's API for the user's actual palette, including custom named colors.
    func simulating(_ desired: [String]) throws -> Self {
        guard desired.count <= 1_024,
              desired.allSatisfy({ !$0.isEmpty && !$0.contains("\n") }),
              desired.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else { throw Failure.unknown }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Maxplorer-Tag-\(UUID()).noindex", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw ContentFileIO.failure() }
        defer { rmdir(directory.path) }
        let scratch = directory.appendingPathComponent("palette")
        let fd = Darwin.open(scratch.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ContentFileIO.failure() }
        defer { Darwin.close(fd); unlink(scratch.path) }
        if let tags { try Self.setAttribute(tags, key: Self.tagsKey, on: fd, flags: XATTR_CREATE) }
        if mirror != 0 {
            var info = Data(count: 32)
            info[9] = UInt8(mirror << 1)
            try Self.setAttribute(info, key: Self.finderInfoKey, on: fd, flags: 0)
        }
        try (scratch as NSURL).setResourceValue(desired, forKey: .tagNamesKey)
        let simulation = try Self(descriptor: fd)
        guard Set(simulation.records.map(\.name)) == Set(desired) else { throw Failure.unknown }
        return simulation
    }

    func keepMirror(for original: [Record], final: [Record]) -> Bool {
        // Finder mirrors the last colored assignment, including when neutral tags follow it.
        let old = original.last(where: { $0.color != 0 })
        let new = final.last(where: { $0.color != 0 })
        if mirror == 0 { return old == new }
        return old?.color == mirror && new?.color == mirror
    }

    static func replaceTags(_ records: [Record], on descriptor: Int32) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: records.map(\.token), format: .binary, options: 0)
        guard data.count <= 64 * 1024 else { throw Failure.unknown }
        try setAttribute(data, key: tagsKey, on: descriptor, flags: XATTR_REPLACE)
    }

    private static func setAttribute(_ data: Data, key: String, on descriptor: Int32, flags: Int32) throws {
        let result = data.withUnsafeBytes { fsetxattr(descriptor, key, $0.baseAddress, $0.count, 0, flags) }
        guard result == 0 else { throw ContentFileIO.failure() }
    }

    private static func attribute(_ key: String, on descriptor: Int32, limit: Int) throws -> Data? {
        let count = fgetxattr(descriptor, key, nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0 else { throw ContentFileIO.failure() }
        guard count <= limit else { throw Failure.unknown }
        var value = Data(count: count)
        let received = value.withUnsafeMutableBytes { fgetxattr(descriptor, key, $0.baseAddress, $0.count, 0, 0) }
        guard received == count else { throw Failure.changed }
        return value
    }

    static func hasLocalBacking(descriptor: Int32, at url: URL) throws -> Bool {
        let status = try ContentFileIO.sample(descriptor)
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw ContentFileIO.failure() }
        let fsType = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let path = url.resolvingSymlinksInPath()
        let ubiquitous = try path.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem
        return hasLocalPreconditions(fsType: fsType, local: volume.f_flags & UInt32(MNT_LOCAL) != 0,
                               dataless: status.st_flags & UInt32(SF_DATALESS) != 0, ubiquitous: ubiquitous,
                               path: path.pathComponents)
    }

    static func hasLocalPreconditions(fsType: String, local: Bool, dataless: Bool, ubiquitous: Bool?, path: [String]) -> Bool {
        // Non-ubiquitous local items can return nil. A separate, affirmative
        // File Provider nonmembership check is always required before using the fd writer.
        guard fsType == "apfs", local, !dataless, ubiquitous != true else { return false }
        return !zip(path, path.dropFirst()).contains { $0 == "Library" && ($1 == "CloudStorage" || $1 == "Mobile Documents") }
    }

    static func outsideProvider(at url: URL) async -> Bool {
        do {
            _ = try await NSFileProviderManager.identifierForUserVisibleFile(at: url)
            return false
        } catch {
            // File Provider returns Cocoa fileNoSuchFile for an existing ordinary local
            // item. The caller checks that bound identity again on the write lane.
            let ns = error as NSError
            return ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
        }
    }

    enum Failure: LocalizedError {
        case unknown, changed, needsProviderCheck, colorUnavailable

        var errorDescription: String? {
            switch self {
            case .unknown: "The existing Finder tag metadata could not be safely interpreted."
            case .changed: "The Finder tag metadata changed while preparing the edit. Try again."
            case .needsProviderCheck, .colorUnavailable: "This edit would change an existing Finder tag color or label on this item."
            }
        }
    }
}
