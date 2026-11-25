import Darwin
import Foundation

struct FolderPresenceMount: Equatable, Sendable {
    let path: String
    let type: String
    let fsid: SIMD2<Int32>
    let flags: UInt32

    var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    var isAutomounted: Bool { type == "autofs" || flags & UInt32(MNT_AUTOMOUNTED) != 0 }

    var supportsNetworkProbe: Bool {
        !isLocal && !isAutomounted && fsid != .zero
            && ["smbfs", "nfs", "webdav", "afpfs"].contains(type)
    }

    func proves(_ mount: Self) -> Bool {
        supportsNetworkProbe && fsid == mount.fsid && type == mount.type
            && FolderPresencePath.exact(path, mount.path)
    }
}

struct FolderPresenceMountSnapshot {
    enum Failure: Error { case incomplete, ambiguous }

    static let maximumEntries = 1_024
    private let boundaries: [String: FolderPresenceMount]
    private let restrictedAliases: Set<String>

    init(_ entries: [FolderPresenceMount]) throws {
        guard !entries.isEmpty, entries.count < Self.maximumEntries else { throw Failure.incomplete }
        var boundaries: [String: FolderPresenceMount] = [:]
        var restrictedAliases: Set<String> = []
        for entry in entries {
            guard FolderPresencePath.components(entry.path) != nil, !entry.type.isEmpty else {
                throw Failure.incomplete
            }
            let key = FolderPresencePath.foldCase(entry.path)
            guard boundaries.updateValue(entry, forKey: key) == nil else { throw Failure.ambiguous }
            let alias = FolderPresencePath.policyPath(entry.path)
            if !entry.isLocal || entry.isAutomounted || FolderPresencePath.isVolumePath(alias) {
                guard restrictedAliases.insert(alias).inserted else { throw Failure.ambiguous }
            }
        }
        self.boundaries = boundaries
        self.restrictedAliases = restrictedAliases
    }

    func networkMount(containing path: String) -> FolderPresenceMount? {
        let deepest = boundaries.values.lazy
            .filter { FolderPresencePath.contains(path, under: $0.path) }
            .max { $0.path.utf8.count < $1.path.utf8.count }
        guard deepest?.supportsNetworkProbe == true else { return nil }
        return deepest
    }

    func permitsBoundary(at path: String, selectedMount: FolderPresenceMount?) -> Bool {
        if let boundary = boundaries[FolderPresencePath.foldCase(path)] {
            guard FolderPresencePath.exact(path, boundary.path) else { return false }
            if let selectedMount, FolderPresencePath.contains(path, under: selectedMount.path) {
                return FolderPresencePath.exact(path, selectedMount.path)
            }
            return boundary.isLocal && !boundary.isAutomounted
                && !FolderPresencePath.isVolumePath(FolderPresencePath.policyPath(path))
        }
        // These alternate spellings can flag a boundary to refuse. They can
        // never supply positive proof that a particular mount was selected.
        return restrictedAliases.isEmpty || !restrictedAliases.contains(FolderPresencePath.policyPath(path))
    }
}

extension DarwinFolderPresenceFileSystem {
    func mountInventory() throws -> [FolderPresenceMount] {
        try Self.readMountInventory(getfsstat)
    }

    static func readMountInventory(_ read: (UnsafeMutablePointer<statfs>?, Int32, Int32) -> Int32)
        throws -> [FolderPresenceMount] {
        let limit = FolderPresenceMountSnapshot.maximumEntries
        let reported = Int(read(nil, 0, MNT_NOWAIT))
        guard reported > 0, reported < limit else { throw FolderPresenceMountSnapshot.Failure.incomplete }

        let capacity = min(limit, reported + 16)
        var storage: [statfs] = Array(repeating: statfs(), count: capacity)
        let filled = storage.withUnsafeMutableBufferPointer { buffer in
            Int(read(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        }
        // A full buffer cannot distinguish a complete result from truncation.
        guard filled > 0, filled < capacity else { throw FolderPresenceMountSnapshot.Failure.incomplete }
        return try storage.prefix(filled).map { try Self.decodeMount($0) }
    }

    func mount(for descriptor: Int32) throws -> FolderPresenceMount {
        var value = statfs()
        guard fstatfs(descriptor, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try Self.decodeMount(value)
    }

    private static func decodeMount(_ value: statfs) throws -> FolderPresenceMount {
        func string<Field>(_ field: Field) throws -> String {
            try withUnsafeBytes(of: field) { bytes in
                guard let end = bytes.firstIndex(of: 0),
                      let result = String(bytes: bytes[..<end], encoding: .utf8), !result.isEmpty else {
                    throw FolderPresenceMountSnapshot.Failure.incomplete
                }
                return result
            }
        }
        return try FolderPresenceMount(path: string(value.f_mntonname), type: string(value.f_fstypename),
                                       fsid: SIMD2(value.f_fsid.val.0, value.f_fsid.val.1), flags: value.f_flags)
    }
}
