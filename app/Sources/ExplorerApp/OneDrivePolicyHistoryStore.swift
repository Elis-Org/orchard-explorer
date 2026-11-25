import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Security

/// Display-only history. This API never supplies command authority.
/// File coordination and all filesystem work run on the independent worker.
/// A ticket belongs to an observation that has not started yet. Completion must
/// retain that exact ticket even if another process has since invalidated it.
final class OneDrivePolicyHistoryStore: @unchecked Sendable {
    struct Namespace: Equatable, Sendable {
        let rootURL: String
        let rootIdentity: LocalFileIdentity
        let providerIdentifier: String
        let providerVersion: String
        let providerStamp: String
    }
    struct Identity: Sendable {
        let namespace: Namespace
        let parentURL: String
        let parentIdentity: LocalFileIdentity
        let fileURL: String
        let fileIdentity: LocalFileIdentity
        let version: LocalFileStatusVersion
    }
    struct Key: Hashable, Sendable {
        let route: String
        let full: String
    }
    struct Ticket: Hashable, Sendable {
        let incarnation: UUID
        let key: Key
        let epoch: UUID
    }
    struct Hint: Sendable {
        let policy: OneDriveRetentionPolicy
        let confirmedAt: Date
    }
    struct Prepared: Sendable {
        let ticket: Ticket
        let hint: Hint?
    }
    struct Limits: Sendable {
        var entries: Int = 2_048
        var fences: Int = 2_048
        var bytes: Int = 4 * 1_024 * 1_024
        var retention: TimeInterval = 7 * 24 * 60 * 60
        var writeDelay: TimeInterval = 0.25
    }
    private struct StoreID: Codable {
        let schema: Int
        let cacheID: UUID
        var incarnation: UUID
        let salt: Data
    }
    private struct StoredHint: Codable {
        let route: String
        let full: String
        var epoch: UUID
        let policy: String
        let confirmedAt: Double
    }
    private struct Fence: Codable { let route: String; let epoch: UUID }
    private struct Document: Codable {
        let schema: Int
        let cacheID: UUID
        let incarnation: UUID
        let records: [StoredHint]
        let fences: [Fence]

        private enum CodingKeys: String, CodingKey { case schema, cacheID, incarnation, records, fences }
        init(state: State) {
            schema = 1; cacheID = state.id.cacheID; incarnation = state.id.incarnation
            records = state.records.values.sorted { $0.full < $1.full }
            fences = state.fences.map { Fence(route: $0.key, epoch: $0.value) }.sorted { $0.route < $1.route }
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schema = try values.decode(Int.self, forKey: .schema)
            cacheID = try values.decode(UUID.self, forKey: .cacheID)
            incarnation = try values.decode(UUID.self, forKey: .incarnation)
            var rows = try values.nestedUnkeyedContainer(forKey: .records)
            guard let count = rows.count, count <= 2_048 else { throw Failure.invalidDocument }
            var decoded: [StoredHint] = []
            decoded.reserveCapacity(count)
            // A damaged observation can be skipped; a damaged fence cannot.
            while !rows.isAtEnd {
                let row = try rows.superDecoder()
                if let value = try? StoredHint(from: row) { decoded.append(value) }
            }
            records = decoded
            var epochs = try values.nestedUnkeyedContainer(forKey: .fences)
            guard let count = epochs.count, count <= 2_048 else { throw Failure.invalidDocument }
            var decodedFences: [Fence] = []
            decodedFences.reserveCapacity(count)
            while !epochs.isAtEnd { decodedFences.append(try epochs.decode(Fence.self)) }
            fences = decodedFences
        }
    }
    private struct State {
        var id: StoreID
        var records: [String: StoredHint] = [:]
        var fences: [String: UUID] = [:]
        func epoch(for route: String) -> UUID { fences[route] ?? id.incarnation }
    }
    private struct Published {
        let incarnation: UUID
        let fences: [String: UUID]
        let prepared: Set<Key>
    }
    private enum Failure: String, Error { case invalidDocument, unavailable, unsafeLocation }
    enum Phase: String, Sendable {
        case idle, directoryURL, parentQualification, parentOpen, leafOpen
        case coordination, read, initialization, commit, ready, identityRejected
    }
    struct Diagnostic: Sendable, CustomStringConvertible {
        var phase: Phase = .idle
        var failure: String?
        var code: Int = 0
        var description: String { "\(phase.rawValue)/\(failure ?? "none")/\(code)" }
    }

    private let requestedDirectory: URL
    private let limits: Limits
    private let wallNow: @Sendable () -> Date
    private let worker = DispatchQueue(label: "nativeExplorer.oneDrivePolicyHistory", qos: .utility)
    private let publishedLock = NSLock()
    private var published: Published?
    private var diagnosticValue = Diagnostic()
    private let pendingLock = NSLock()
    private var pending: [Ticket: Hint] = [:]
    private var scheduled = false
    // The following state belongs exclusively to worker.
    private var attemptedLoad = false
    private var state: State?
    private var directory: URL?
    private var directoryFD: Int32 = -1
    private var directoryDevice: dev_t = 0
    private var directoryInode: ino_t = 0
    private var preparedKeys = Set<Key>()
    private var preparedOrder: [Key] = []
    private let idName = "store-id-v1.json"
    private let dataName = "history-v1.json"

    init(directory: URL, limits: Limits = .init(),
         wallNow: @escaping @Sendable () -> Date = Date.init) {
        requestedDirectory = directory
        var bounded = limits
        bounded.entries = min(2_048, max(1, limits.entries))
        bounded.fences = min(2_048, max(0, limits.fences))
        bounded.bytes = min(4 * 1_024 * 1_024, max(512, limits.bytes))
        bounded.retention = limits.retention.isFinite ? min(7 * 24 * 60 * 60, max(0, limits.retention)) : 0
        bounded.writeDelay = limits.writeDelay.isFinite ? min(60, max(0, limits.writeDelay)) : 0.25
        self.limits = bounded; self.wallNow = wallNow
    }
    deinit { if directoryFD >= 0 { close(directoryFD) } }
    /// Path-free failure stages for tests/support; never logs a user's namespace.
    var diagnostic: Diagnostic { publishedLock.withLock { diagnosticValue } }
    private func phase(_ phase: Phase) {
        publishedLock.withLock { diagnosticValue = Diagnostic(phase: phase) }
    }

    func prepare(_ identities: [Identity]) async -> [Prepared?] {
        await withCheckedContinuation { continuation in
            worker.async { [self] in
                guard loadIfNeeded(), let current = state else {
                    continuation.resume(returning: Array(repeating: nil, count: identities.count)); return
                }
                let now = wallNow().timeIntervalSince1970
                let result: [Prepared?] = identities.map { identity in
                    guard let key = makeKey(identity, salt: current.id.salt) else {
                        phase(.identityRejected); return nil
                    }
                    remember(key)
                    let ticket = Ticket(incarnation: current.id.incarnation, key: key,
                                        epoch: current.epoch(for: key.route))
                    let stored = current.records[key.full]
                    let hint: Hint?
                    if let stored, stored.route == key.route, stored.epoch == ticket.epoch,
                       validDate(stored.confirmedAt, at: now),
                       let policy = OneDriveRetentionPolicy(rawValue: stored.policy) {
                        hint = Hint(policy: policy, confirmedAt: Date(timeIntervalSince1970: stored.confirmedAt))
                    } else { hint = nil }
                    return Prepared(ticket: ticket, hint: hint)
                }
                publish()
                continuation.resume(returning: result)
            }
        }
    }

    func invalidate(_ identity: Identity) async -> Ticket? {
        await withCheckedContinuation { continuation in
            worker.async { [self] in
                guard loadIfNeeded(), let old = state,
                      let key = makeKey(identity, salt: old.id.salt) else {
                    continuation.resume(returning: nil); return
                }
                do {
                    var ticket: Ticket?
                    try coordinated {
                        var current = try currentState(matching: old.id)
                        let previousID = current.id
                        current.records = current.records.filter { $0.value.route != key.route }
                        current.fences[key.route] = UUID()
                        if current.fences.count > limits.fences { rotate(&current) }
                        try commit(&current, previousID: previousID)
                        state = current
                        remember(key)
                        ticket = Ticket(incarnation: current.id.incarnation, key: key,
                                        epoch: current.epoch(for: key.route))
                    }
                    publish()
                    continuation.resume(returning: ticket)
                } catch { disable(error); continuation.resume(returning: nil) }
            }
        }
    }

    /// Only for a newly starting observation; never upgrade a completed one.
    /// This read performs no filesystem work and accepts only keys prepared by
    /// this worker in its current salt namespace. The prepared-key set is bounded.
    func currentTicket(for previous: Ticket) -> Ticket? {
        publishedLock.withLock {
            guard let view = published, view.prepared.contains(previous.key) else { return nil }
            return Ticket(incarnation: view.incarnation, key: previous.key,
                          epoch: view.fences[previous.key.route] ?? view.incarnation)
        }
    }

    func enqueue(_ hint: Hint, ticket: Ticket) {
        guard hint.confirmedAt.timeIntervalSince1970.isFinite,
              publishedLock.withLock({ published?.prepared.contains(ticket.key) == true }) else { return }
        let schedule = pendingLock.withLock { () -> Bool in
            if let previous = pending[ticket] {
                if hint.confirmedAt > previous.confirmedAt { pending[ticket] = hint }
            } else if pending.count < limits.entries { pending[ticket] = hint }
            guard !pending.isEmpty, !scheduled else { return false }
            scheduled = true; return true
        }
        if schedule {
            worker.asyncAfter(deadline: .now() + limits.writeDelay) { [self] in flushPending() }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            worker.async { [self] in flushPending(); continuation.resume() }
        }
    }

    private func flushPending() {
        let writes = pendingLock.withLock { () -> [Ticket: Hint] in
            let result = pending; pending.removeAll(keepingCapacity: true); scheduled = false
            return result
        }
        guard !writes.isEmpty, let old = state else { return }
        do {
            try coordinated {
                var current = try currentState(matching: old.id)
                let previousID = current.id
                let now = wallNow().timeIntervalSince1970
                for (ticket, hint) in writes {
                    let date = hint.confirmedAt.timeIntervalSince1970
                    guard ticket.incarnation == current.id.incarnation,
                          ticket.epoch == current.epoch(for: ticket.key.route), validDate(date, at: now) else { continue }
                    if let previous = current.records[ticket.key.full], previous.confirmedAt >= date { continue }
                    current.records[ticket.key.full] = StoredHint(route: ticket.key.route, full: ticket.key.full,
                        epoch: ticket.epoch, policy: hint.policy.rawValue, confirmedAt: date)
                }
                try commit(&current, previousID: previousID)
                // Even a rejected write learns committed epochs. Its old ticket
                // remains unchanged; only a future observation can use this view.
                state = current
            }
            publish()
        } catch { disable(error) }
    }

    private func remember(_ key: Key) {
        guard preparedKeys.insert(key).inserted else { return }
        preparedOrder.append(key)
        let cap = min(4_096, max(32, limits.entries * 2))
        if preparedOrder.count > cap { preparedKeys.remove(preparedOrder.removeFirst()) }
    }
    private func publish() {
        let value = state.map { Published(incarnation: $0.id.incarnation, fences: $0.fences, prepared: preparedKeys) }
        publishedLock.withLock { published = value }
    }
    private func disable(_ error: Error) {
        state = nil; preparedKeys.removeAll(); preparedOrder.removeAll()
        publishedLock.withLock {
            published = nil
            diagnosticValue.failure = (error as? Failure)?.rawValue ?? "foundation"
            diagnosticValue.code = (error as NSError).code
        }
        pendingLock.withLock { pending.removeAll(); scheduled = false }
    }

    private func loadIfNeeded() -> Bool {
        if attemptedLoad { return state != nil }
        attemptedLoad = true
        do {
            try openDirectory()
            try coordinated {
                do { state = try readState() }
                catch Failure.invalidDocument { state = nil }
                if state == nil {
                    phase(.initialization)
                    var salt = Data(count: 32)
                    let status = salt.withUnsafeMutableBytes {
                        SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
                    }
                    guard status == errSecSuccess else { throw Failure.unavailable }
                    var created = State(id: StoreID(schema: 1, cacheID: UUID(), incarnation: UUID(), salt: salt))
                    try commit(&created, previousID: nil)
                    state = created
                }
            }
            phase(.ready)
            publish()
            return state != nil
        } catch { disable(error); return false }
    }

    private func currentState(matching previous: StoreID) throws -> State {
        // Only first load is allowed to initialize a missing or invalid pair.
        // An old process cannot silently revive a purged cache or change salt.
        guard let current = try readState(), current.id.cacheID == previous.cacheID,
              current.id.salt == previous.salt else { throw Failure.unavailable }
        return current
    }

    private func readState() throws -> State? {
        phase(.read)
        guard let idBytes = try readFile(idName, cap: 4_096),
              let bytes = try readFile(dataName, cap: limits.bytes) else { return nil }
        let id: StoreID, document: Document
        do {
            id = try JSONDecoder().decode(StoreID.self, from: idBytes)
            document = try JSONDecoder().decode(Document.self, from: bytes)
        } catch { throw Failure.invalidDocument }
        guard id.schema == 1, id.salt.count == 32, document.schema == 1,
              document.cacheID == id.cacheID, document.incarnation == id.incarnation else { throw Failure.invalidDocument }
        var result = State(id: id)
        for fence in document.fences {
            guard validDigest(fence.route), result.fences[fence.route] == nil else { throw Failure.invalidDocument }
            result.fences[fence.route] = fence.epoch
        }
        var seen = Set<String>(), duplicated = Set<String>()
        for row in document.records {
            guard validDigest(row.full), validDigest(row.route) else { continue }
            if !seen.insert(row.full).inserted { duplicated.insert(row.full); continue }
            guard OneDriveRetentionPolicy(rawValue: row.policy) != nil,
                  row.epoch == result.epoch(for: row.route),
                  validDate(row.confirmedAt, at: wallNow().timeIntervalSince1970) else { continue }
            result.records[row.full] = row
        }
        for key in duplicated { result.records.removeValue(forKey: key) }
        pruneRecords(&result)
        return result
    }

    private func validDate(_ date: Double, at now: Double) -> Bool {
        date.isFinite && now.isFinite && date <= now && now - date < limits.retention
    }
    private func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func pruneRecords(_ value: inout State) {
        let now = wallNow().timeIntervalSince1970
        value.records = value.records.filter { validDate($0.value.confirmedAt, at: now) }
        let excess = value.records.count - limits.entries
        if excess > 0 {
            for row in oldest(value).prefix(excess) { value.records.removeValue(forKey: row.full) }
        }
    }
    private func oldest(_ value: State) -> [StoredHint] {
        value.records.values.sorted {
            $0.confirmedAt == $1.confirmedAt ? $0.full < $1.full : $0.confirmedAt < $1.confirmedAt
        }
    }
    private func rotate(_ value: inout State) {
        value.id.incarnation = UUID()
        value.fences.removeAll()
        for key in Array(value.records.keys) { value.records[key]?.epoch = value.id.incarnation }
    }
    private func commit(_ value: inout State, previousID: StoreID?) throws {
        phase(.commit)
        pruneRecords(&value)
        if value.fences.count > limits.fences { rotate(&value) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var idBytes = try encoder.encode(value.id)
        var bytes = try encoder.encode(Document(state: value))
        while idBytes.count + bytes.count > limits.bytes {
            if let row = oldest(value).first { value.records.removeValue(forKey: row.full) }
            else if !value.fences.isEmpty { rotate(&value); idBytes = try encoder.encode(value.id) }
            else { throw Failure.unavailable }
            bytes = try encoder.encode(Document(state: value))
        }
        if previousID?.incarnation != value.id.incarnation || previousID?.cacheID != value.id.cacheID {
            try replaceFile(idName, bytes: idBytes)
        }
        try replaceFile(dataName, bytes: bytes)
    }

    private func makeKey(_ identity: Identity, salt: Data) -> Key? {
        let scope = identity.namespace
        let strings = [scope.rootURL, identity.parentURL, identity.fileURL]
        guard strings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\0") }),
              scope.providerIdentifier == "com.microsoft.OneDrive", !scope.providerVersion.isEmpty,
              scope.providerVersion.utf8.count <= 256, !scope.providerStamp.isEmpty,
              scope.providerStamp.utf8.count <= 65_536,
              let root = URL(string: scope.rootURL), let parent = URL(string: identity.parentURL),
              let file = URL(string: identity.fileURL), root.isFileURL, parent.isFileURL, file.isFileURL,
              parent.pathComponents.starts(with: root.pathComponents),
              file.deletingLastPathComponent().pathComponents == parent.pathComponents,
              validIdentity(scope.rootIdentity), validIdentity(identity.parentIdentity), validIdentity(identity.fileIdentity),
              identity.version.size >= 0, (0..<1_000_000_000).contains(identity.version.modificationNanoseconds) else { return nil }
        var scopeBytes = Data()
        append(scope.rootURL, to: &scopeBytes); append(scope.rootIdentity, to: &scopeBytes)
        append(scope.providerIdentifier, to: &scopeBytes); append(scope.providerVersion, to: &scopeBytes)
        append(scope.providerStamp, to: &scopeBytes)
        append(identity.parentURL, to: &scopeBytes); append(identity.fileURL, to: &scopeBytes)
        var route = salt
        append("maxplorer.policy-history.route.v1", to: &route); route.append(scopeBytes)
        var full = salt
        append("maxplorer.policy-history.full.v1", to: &full); full.append(scopeBytes)
        append(identity.parentIdentity, to: &full); append(identity.fileIdentity, to: &full)
        append(UInt64(bitPattern: identity.version.size), to: &full)
        append(UInt64(bitPattern: identity.version.modificationSeconds), to: &full)
        append(UInt64(bitPattern: identity.version.modificationNanoseconds), to: &full)
        return Key(route: digest(route), full: digest(full))
    }
    private func validIdentity(_ value: LocalFileIdentity) -> Bool {
        value.inode != 0 && (value.birthSeconds != 0 || value.birthNanoseconds != 0)
            && (0..<1_000_000_000).contains(value.birthNanoseconds)
    }
    private func append(_ value: String, to data: inout Data) {
        append(UInt64(value.utf8.count), to: &data); data.append(contentsOf: value.utf8)
    }
    private func append(_ value: UInt64, to data: inout Data) {
        var ordered = value.bigEndian
        withUnsafeBytes(of: &ordered) { data.append(contentsOf: $0) }
    }
    private func append(_ value: LocalFileIdentity, to data: inout Data) {
        append(value.device, to: &data); append(value.inode, to: &data)
        append(UInt64(bitPattern: value.birthSeconds), to: &data)
        append(UInt64(bitPattern: value.birthNanoseconds), to: &data)
    }
    private func digest(_ value: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: value).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }

    private func openDirectory() throws {
        phase(.directoryURL)
        guard requestedDirectory.isFileURL, requestedDirectory.host == nil || requestedDirectory.host == "",
              !requestedDirectory.path.contains("\0") else { throw Failure.unsafeLocation }
        let requested = requestedDirectory.standardizedFileURL
        let parent = requested.deletingLastPathComponent()
        let leaf = requested.lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != ".." else { throw Failure.unsafeLocation }
        phase(.parentQualification)
        // Foundation standardization can spell /private/var as /var again.
        // Use the physical POSIX spelling for both comparison and no-follow walk.
        guard let physical = realpath(parent.path, nil) else { throw Failure.unsafeLocation }
        defer { free(physical) }
        let canonicalPath = String(cString: physical)
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        // macOS temporaryDirectory can use the system /var alias. No mutable,
        // user-selected ancestor may redirect the cache to a different location.
        var allowed = parent.path
        for alias in ["/var", "/tmp"] where allowed == alias || allowed.hasPrefix(alias + "/") {
            allowed = "/private" + allowed; break
        }
        guard canonicalPath == allowed,
              try canonical.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw Failure.unsafeLocation
        }
        phase(.parentOpen)
        var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Failure.unavailable }
        defer { close(parentFD) }
        // Walk existing parents by descriptor, refusing every remaining symlink.
        // Do not create intermediate directories or change their permissions.
        for component in (canonicalPath as NSString).pathComponents.dropFirst() {
            let next = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unsafeLocation }
            close(parentFD); parentFD = next
        }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0, parentStat.st_uid == geteuid() else { throw Failure.unsafeLocation }
        phase(.leafOpen)
        if mkdirat(parentFD, leaf, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        let resolved = canonical.appendingPathComponent(leaf, isDirectory: true)
        let fd = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else {
            close(fd); throw Failure.unsafeLocation
        }
        directoryFD = fd; directory = resolved
        directoryDevice = value.st_dev; directoryInode = value.st_ino
        try checkDirectory()
    }
    private func checkDirectory() throws {
        guard let directory, directoryFD >= 0 else { throw Failure.unavailable }
        var value = stat()
        guard lstat(directory.path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_dev == directoryDevice, value.st_ino == directoryInode,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw Failure.unsafeLocation }
    }
    private func coordinated(_ body: () throws -> Void) throws {
        phase(.coordination)
        try checkDirectory()
        guard let directory else { throw Failure.unavailable }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?, result: Result<Void, Error>?
        // Every participating process coordinates this same stable URL, including
        // when the ID or data file is absent. The accessor covers both files.
        coordinator.coordinate(writingItemAt: directory.appendingPathComponent(idName), options: [], error: &error) { _ in
            result = Result { try checkDirectory(); try body() }
        }
        if let error { throw error }
        guard let result else { throw Failure.unavailable }
        try result.get()
    }
    private func readFile(_ name: String, cap: Int) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unsafeLocation
        }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_nlink == 1, value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw Failure.unsafeLocation }
        guard value.st_size >= 0, value.st_size <= Int64(cap) else { throw Failure.invalidDocument }
        var bytes = Data(count: Int(value.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalidDocument }
                offset += count
            }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, after.st_size == value.st_size,
              after.st_mtimespec.tv_sec == value.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == value.st_mtimespec.tv_nsec,
              fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.unavailable }
        return bytes
    }
    private func replaceFile(_ name: String, bytes: Data) throws {
        try checkDirectory()
        var existing = stat()
        if fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), existing.st_nlink == 1,
                  existing.st_uid == geteuid(), existing.st_mode & 0o077 == 0 else { throw Failure.unsafeLocation }
        } else if errno != ENOENT { throw Failure.unavailable }
        let temporary = ".policy-history-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        try checkDirectory()
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw Failure.unavailable }
    }
}
