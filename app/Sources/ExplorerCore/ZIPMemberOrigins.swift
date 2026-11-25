import Darwin
import Foundation

/// Worker-confined budget shared by a transaction or admitted content request.
final class ZIPOriginBudget {
    let maximumAttributeBytes: Int
    let maximumCompanionBytes: Int
    let maximumTotalBytes: Int
    private(set) var usedBytes = 0
    init(maximumAttributeBytes: Int = 256 * 1_024, maximumCompanionBytes: Int = 1_024 * 1_024,
         maximumTotalBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumAttributeBytes = maximumAttributeBytes
        self.maximumCompanionBytes = maximumCompanionBytes
        self.maximumTotalBytes = maximumTotalBytes
    }
    func charge(_ bytes: Int) throws {
        guard bytes >= 0, maximumAttributeBytes >= 0, maximumCompanionBytes >= 0,
              maximumTotalBytes >= 0, usedBytes <= maximumTotalBytes,
              bytes <= maximumTotalBytes - usedBytes else { throw ZIPListingError.limitExceeded }
        usedBytes += bytes
    }
}

/// A single bounded origin boundary. Native serialization/application interprets
/// quarantine; this code never decodes, merges or repairs its private flags.
enum ZIPMemberOrigins {
    static let quarantineName = "com.apple.quarantine"
    static let whereFromsName = "com.apple.metadata:kMDItemWhereFroms"

    static func capture(from descriptor: Int32, budget: ZIPOriginBudget) throws -> ZIPOriginAttributes {
        func value(_ name: String) throws -> Data? {
            let count = fgetxattr(descriptor, name, nil, 0, 0, 0)
            if count < 0, errno == ENOATTR { return nil }
            guard count >= 0 else { throw nativeError() }
            guard count <= budget.maximumAttributeBytes, count <= 256 * 1_024 else { throw ZIPListingError.limitExceeded }
            try budget.charge(count)
            var bytes = Data(count: count)
            let received = bytes.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
            guard received == count else { throw ZIPListingError.changed }
            return bytes
        }
        return try ZIPOriginAttributes(quarantine: value(quarantineName), whereFroms: value(whereFromsName))
    }
    static func pack(_ attributes: ZIPOriginAttributes, scratchDirectory: Int32,
                     budget: ZIPOriginBudget, checkpoint: () throws -> Void) throws -> Data {
        try checkpoint()
        guard attributes.quarantine != nil || attributes.whereFroms != nil else {
            throw ArchiveOperationError.unsupported("There is no member origin to serialize.")
        }
        let source = try Scratch(in: scratchDirectory), output = try Scratch(in: scratchDirectory)
        try install(attributes, on: source.descriptor, budget: budget)
        try nativeCopy(source: source.descriptor, destination: output.descriptor,
                       flags: copyfile_flags_t(COPYFILE_XATTR | COPYFILE_PACK), originsOnly: true, checkpoint: checkpoint)
        let data = try read(output.descriptor, budget: budget)
        let fields = try parsed(data)
        guard (fields[quarantineName] != nil) == (attributes.quarantine != nil), fields[whereFromsName] == attributes.whereFroms else {
            throw ArchiveOperationError.unsupported("The system could not preserve this member's origin information.")
        }
        // A successful pack must also be readable by the system applier. No
        // original/final file is the destination of this independent check.
        let decoded = try unpack(data, scratchDirectory: scratchDirectory, budget: budget, checkpoint: checkpoint)
        guard (decoded.quarantine != nil) == (attributes.quarantine != nil), decoded.whereFroms == attributes.whereFroms else {
            throw ZIPListingError.corrupt
        }
        return data
    }
    static func validateOriginCompanion(_ data: Data) throws {
        _ = try parsed(data)
    }
    static func unpack(_ data: Data, scratchDirectory: Int32,
                       budget: ZIPOriginBudget, checkpoint: () throws -> Void) throws -> ZIPOriginAttributes {
        try checkpoint()
        guard data.count <= budget.maximumCompanionBytes else { throw ZIPListingError.limitExceeded }
        let fields = try parsed(data)
        try budget.charge(data.count)
        let source = try Scratch(in: scratchDirectory), output = try Scratch(in: scratchDirectory)
        try DescriptorIO.writeAll(data, to: source.descriptor, at: 0)
        try nativeCopy(source: source.descriptor, destination: output.descriptor,
                       flags: copyfile_flags_t(COPYFILE_UNPACK), originsOnly: false, checkpoint: checkpoint)
        let attributes = try capture(from: output.descriptor, budget: budget)
        guard (attributes.quarantine != nil) == (fields[quarantineName] != nil), attributes.whereFroms == fields[whereFromsName] else {
            throw ArchiveOperationError.unsupported("The system could not restore this member's origin information.")
        }
        return attributes
    }
    static func apply(member: ZIPOriginAttributes?, outer: ZIPOriginAttributes,
                      to destination: Int32, scratchDirectory: Int32,
                      budget: ZIPOriginBudget, checkpoint: () throws -> Void) throws -> ZIPOriginAttributes {
        try checkpoint()
        let existing = try capture(from: destination, budget: budget)
        // Container quarantine is authoritative, as in native ditto. WhereFroms
        // is advisory provenance supplied by the archive, never trusted identity.
        let attributes = ZIPOriginAttributes(quarantine: outer.quarantine ?? member?.quarantine,
                                             whereFroms: member?.whereFroms ?? outer.whereFroms)
        guard attributes.quarantine != nil || attributes.whereFroms != nil else { return existing }
        // An absent input is not an instruction to remove state the OS placed
        // on a newly created output. Native copying itself preserves quarantine.
        let effective = ZIPOriginAttributes(quarantine: attributes.quarantine, whereFroms: attributes.whereFroms ?? existing.whereFroms)
        let source = try Scratch(in: scratchDirectory)
        try install(effective, on: source.descriptor, budget: budget)
        try nativeCopy(source: source.descriptor, destination: destination,
                       flags: copyfile_flags_t(COPYFILE_XATTR), originsOnly: true, checkpoint: checkpoint)
        let actual = try capture(from: destination, budget: budget)
        guard (attributes.quarantine == nil || actual.quarantine != nil), actual.whereFroms == effective.whereFroms else {
            throw ArchiveOperationError.unsupported("The system could not preserve the exported item's origin information.")
        }
        return actual
    }

    /// Keeps the existing mutation hook signature while making native error
    /// callbacks authoritative (copyfile otherwise ignores some quarantine errors).
    static func copyMetadata(source: Int32, destination: Int32) -> Int32 {
        do {
            try nativeCopy(source: source, destination: destination, flags: copyfile_flags_t(COPYFILE_METADATA), originsOnly: false, checkpoint: {})
            return 0
        } catch let error as POSIXError { errno = error.code.rawValue; return -1 }
        catch { errno = EIO; return -1 }
    }

    private static func install(_ attributes: ZIPOriginAttributes, on descriptor: Int32, budget: ZIPOriginBudget) throws {
        let empty = try capture(from: descriptor, budget: budget)
        guard empty.quarantine == nil, empty.whereFroms == nil else { throw ArchiveOperationError.changed }
        for (name, value) in [(quarantineName, attributes.quarantine), (whereFromsName, attributes.whereFroms)] {
            guard let value else { continue }
            guard value.count <= budget.maximumAttributeBytes, value.count <= 256 * 1_024 else { throw ZIPListingError.limitExceeded }
            try budget.charge(value.count)
            guard value.withUnsafeBytes({ fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else { throw nativeError() }
        }
        guard try capture(from: descriptor, budget: budget) == attributes else {
            throw ArchiveOperationError.unsupported("The system changed the captured origin while preparing metadata.")
        }
    }

    private final class Scratch {
        let descriptor: Int32
        init(in parent: Int32) throws {
            let name = ".origin-" + UUID().uuidString
            let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw ZIPMemberOrigins.nativeError() }
            do {
                var held = stat(), named = stat()
                guard fstat(fd, &held) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_nlink == 1,
                      LocalFileIdentity.fromStat(held) == LocalFileIdentity.fromStat(named) else { throw ArchiveOperationError.changed }
                guard unlinkat(parent, name, 0) == 0 else { throw ZIPMemberOrigins.nativeError() }
                guard fstat(fd, &held) == 0, held.st_nlink == 0 else { throw ArchiveOperationError.changed }
                descriptor = fd
            } catch { close(fd); throw error }
        }
        deinit { close(descriptor) }
    }

    private final class CopyContext {
        let checkpoint: () throws -> Void
        let originsOnly: Bool
        var error: Error?
        init(originsOnly: Bool, checkpoint: @escaping () throws -> Void) {
            self.originsOnly = originsOnly; self.checkpoint = checkpoint
        }
    }

    private static func nativeCopy(source: Int32, destination: Int32, flags: copyfile_flags_t,
                                   originsOnly: Bool, checkpoint: () throws -> Void) throws {
        try withoutActuallyEscaping(checkpoint) { escaped in
            guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
            defer { copyfile_state_free(state) }
            let context = CopyContext(originsOnly: originsOnly, checkpoint: escaped)
            let callback: copyfile_callback_t = { what, stage, state, _, _, raw in
                guard let raw else { return COPYFILE_QUIT }
                let context = Unmanaged<CopyContext>.fromOpaque(raw).takeUnretainedValue()
                do {
                    if stage == COPYFILE_ERR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    try context.checkpoint()
                    if context.originsOnly, what == COPYFILE_COPY_XATTR, stage == COPYFILE_START {
                        var value: UnsafePointer<CChar>?
                        guard copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &value) == 0, let value else { throw POSIXError(.EIO) }
                        let name = String(cString: value)
                        if name != "com.apple.quarantine" && name != "com.apple.metadata:kMDItemWhereFroms" { return COPYFILE_SKIP }
                    }
                    return COPYFILE_CONTINUE
                } catch { context.error = error; return COPYFILE_QUIT }
            }
            guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
                  copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0 else { throw nativeError() }
            let result = withExtendedLifetime(context) { fcopyfile(source, destination, state, flags) }
            if let error = context.error { throw error }
            guard result == 0 else { throw nativeError() }
            try checkpoint()
        }
    }

    private static func read(_ descriptor: Int32, budget: ZIPOriginBudget) throws -> Data {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw nativeError() }
        guard value.st_size >= 0, value.st_size <= 1_024 * 1_024, value.st_size <= Int64(budget.maximumCompanionBytes) else { throw ZIPListingError.limitExceeded }
        let count = Int(value.st_size)
        try budget.charge(count)
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < bytes.count {
                let read = pread(descriptor, bytes.baseAddress!.advanced(by: done), bytes.count - done, off_t(done))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw nativeError() }
                done += read
            }
        }
        return data
    }

    /// Strict origin-only native AppleDouble envelope. The untrusted record may
    /// never ask UNPACK to apply an ACL, FinderInfo, fork, unknown name or overlap.
    private static func parsed(_ data: Data) throws -> [String: Data] {
        func invalid() -> ArchiveOperationError { .unsupported("This item has AppleDouble metadata beyond supported download origins, or its metadata is malformed.") }
        guard data.count >= 120, data.count <= 1_024 * 1_024 else { throw invalid() }
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at <= data.count - 2 else { throw invalid() }
            return Int(data[at]) << 8 | Int(data[at + 1])
        }
        func u32(_ at: Int) throws -> Int {
            guard at >= 0, at <= data.count - 4 else { throw invalid() }
            return Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
        }
        guard try u32(0) == 0x00051607, try u32(4) == 0x00020000, try u16(24) == 2,
              try u32(26) == 9, try u32(30) == 50, try u32(34) == data.count - 50,
              try u32(38) == 2, try u32(42) == data.count, try u32(46) == 0,
              data[50..<84].allSatisfy({ $0 == 0 }), try u32(84) == 0x41545452,
              try u32(88) == 0, try u32(92) == data.count,
              data[104..<118].allSatisfy({ $0 == 0 }) else { throw invalid() }
        let start = try u32(96), length = try u32(100), count = try u16(118)
        guard start >= 120, start <= data.count, length == data.count - start, (1...2).contains(count) else { throw invalid() }
        var cursor = 120, result: [String: Data] = [:], ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor <= start - 11 else { throw invalid() }
            let offset = try u32(cursor), size = try u32(cursor + 4), flags = try u16(cursor + 8), nameLength = Int(data[cursor + 10])
            guard flags == 0, nameLength > 1, nameLength <= 128, nameLength <= start - cursor - 11 else { throw invalid() }
            let nameBytes = data[(cursor + 11)..<(cursor + 11 + nameLength)]
            guard nameBytes.last == 0, !nameBytes.dropLast().contains(0), let name = String(data: nameBytes.dropLast(), encoding: .utf8),
                  name == quarantineName || name == whereFromsName, result[name] == nil,
                  offset >= start, offset <= data.count, size <= data.count - offset,
                  size <= 256 * 1_024 + (name == quarantineName ? 64 : 0) else { throw invalid() }
            let next = (cursor + 11 + nameLength + 3) & ~3
            guard next <= start, data[(cursor + 11 + nameLength)..<next].allSatisfy({ $0 == 0 }) else { throw invalid() }
            result[name] = data.subdata(in: offset..<(offset + size))
            ranges.append(offset..<(offset + size)); cursor = next
        }
        guard cursor == start else { throw invalid() }
        var end = start
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == end else { throw invalid() }
            end = range.upperBound
        }
        guard end == data.count else { throw invalid() }
        return result
    }

    private static func nativeError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

struct ZIPOriginCompanionIndex {
    private let records: [Data: [ZIPCentralRecord]]
    private let members: [Int: [String]]
    init(manifest: ZIPArchiveManifest) throws {
        records = Dictionary(grouping: manifest.records, by: \.pathKey)
        let paths = Set(manifest.records.map(\.pathKey) + manifest.directories.map(\.pathKey))
        var reverse: [Int: [String]] = [:]
        for record in manifest.records {
            // Preserve the established canonical-priority consumption policy.
            // The mutation preflight below checks both possible owners instead.
            if let owner = Self.possibleMembers(for: record.components).first,
               paths.contains(ZIPArchiveManifest.pathKey(owner)) { reverse[record.id] = owner }
        }
        members = reverse
    }
    func companion(for components: [String]) throws -> ZIPCentralRecord? {
        let candidates = Self.slots(for: components).flatMap { records[ZIPArchiveManifest.pathKey($0)] ?? [] }
        guard candidates.count <= 1, candidates.first?.kind != .directory else {
            throw ArchiveOperationError.unsupported("This item has ambiguous AppleDouble metadata.")
        }
        return candidates.first
    }
    func memberComponents(forCompanionRecordID: Int) -> [String]? { members[forCompanionRecordID] }

    /// Both directions share this exact-byte naming policy. Under __MACOSX a
    /// record can imply a canonical owner and a different same-parent owner.
    static func slots(for member: [String]) -> [[String]] {
        guard let last = member.last else { return [] }
        let sibling = Array(member.dropLast()) + ["._" + last]
        return [["__MACOSX"] + sibling, sibling]
    }
    static func possibleMembers(for companion: [String]) -> [[String]] {
        guard let last = companion.last, last.hasPrefix("._"), last.utf8.count > 2 else { return [] }
        let sibling = Array(companion.dropLast()) + [String(last.dropFirst(2))]
        return companion.first == "__MACOSX" ? [Array(sibling.dropFirst()), sibling] : [sibling]
    }
    static func components(for member: [String]) -> [String] {
        slots(for: member).first ?? []
    }

    /// `companions` contains only validated coupled records or freshly generated
    /// origins, keyed by final companion path and exact final owner path. Ordinary
    /// imported bytes never gain metadata authority by their destination name.
    static func validateDestinations(introduced: [[String]], retained: [[String]], planned: [[String]],
                                     companions: [Data: Data], checkpoint: () throws -> Void) throws {
        let retainedKeys = Set(retained.map(ZIPArchiveManifest.pathKey))
        let plannedKeys = Set(planned.map(ZIPArchiveManifest.pathKey))
        var resultingNodes: Set<Data> = []
        func includeAncestors(_ path: [String]) {
            guard !path.isEmpty else { return }
            for count in 1...path.count { resultingNodes.insert(ZIPArchiveManifest.pathKey(Array(path.prefix(count)))) }
        }
        for path in retained + introduced {
            try checkpoint()
            includeAncestors(path)
        }
        for path in planned {
            try checkpoint()
            let key = ZIPArchiveManifest.pathKey(path)
            if companions[key] != nil { resultingNodes.insert(key) }
            else { includeAncestors(path) }
        }
        func refusal() -> ArchiveOperationError {
            .unsupported("This destination would attach unrelated AppleDouble metadata. Choose a different name or resolve the conflicting ZIP item before trying again.")
        }
        // Metadata-only implicit containers are not user owners. This exception
        // follows explicit plan provenance only; retained containers, explicit
        // directories and ordinary planned descendants still add all ancestors.
        // Companions themselves remain exact nodes and get forward checks too.
        for member in introduced + planned {
            try checkpoint()
            let owner = ZIPArchiveManifest.pathKey(member)
            for slot in slots(for: member) {
                let key = ZIPArchiveManifest.pathKey(slot)
                guard !retainedKeys.contains(key), !plannedKeys.contains(key) || companions[key] == owner else { throw refusal() }
            }
        }
        // Reciprocal check: a new ordinary ._name must not attach to a retained
        // or newly introduced file/directory. Check every possible owner, so a
        // reservation for the canonical owner cannot bless a second sibling.
        for path in planned + introduced {
            try checkpoint()
            let key = ZIPArchiveManifest.pathKey(path)
            for member in possibleMembers(for: path) {
                let owner = ZIPArchiveManifest.pathKey(member)
                if resultingNodes.contains(owner), companions[key] != owner { throw refusal() }
            }
        }
    }
}
