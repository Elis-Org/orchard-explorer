import Darwin
import Foundation

public enum FolderChildPresence: Equatable, Sendable {
    case present, absent, unknown
}

public enum FolderChildPresenceUncertainty: Equatable, Sendable {
    case transient, structural, policyDeferred
}

public struct FolderChildPresenceRequest: Sendable {
    public let url: URL
    public let showHidden: Bool
    public let homeURL: URL
    public let openedProtectedScopes: Set<URL>
    public let options: SidebarBackgroundCheckOptions

    public init(url: URL, showHidden: Bool, homeURL: URL, openedProtectedScopes: Set<URL> = [],
                options: SidebarBackgroundCheckOptions = .init()) {
        self.url = url
        self.showHidden = showHidden
        self.homeURL = homeURL
        self.openedProtectedScopes = openedProtectedScopes
        self.options = options
    }
}

public struct FolderChildPresenceResult: Equatable, Sendable {
    public let presence: FolderChildPresence
    public let directoryIdentity: LocalFileIdentity?
    public let entriesExamined: Int
    public let uncertainty: FolderChildPresenceUncertainty?
    public let traversalOperations: Int
    public let childSamples: Int
    public let mountInventoryOperations: Int
    public var isPolicyDeferred: Bool { uncertainty == .policyDeferred }

    public init(presence: FolderChildPresence, directoryIdentity: LocalFileIdentity? = nil,
                entriesExamined: Int = 0, uncertainty: FolderChildPresenceUncertainty = .transient,
                traversalOperations: Int = 0, childSamples: Int = 0, mountInventoryOperations: Int = 0) {
        self.presence = presence
        self.directoryIdentity = directoryIdentity
        self.entriesExamined = entriesExamined
        self.uncertainty = presence == .unknown ? uncertainty : nil
        self.traversalOperations = traversalOperations
        self.childSamples = childSamples
        self.mountInventoryOperations = mountInventoryOperations
    }
}

public protocol FolderChildPresenceChecking: Sendable {
    func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult
}

// The stream and borrowed descriptor remain on the worker that opened them.
// Keeping the C stream behind these closures also lets a fixture spy observe
// each entry read and ownership transfer without exporting the Darwin handle.
struct FolderPresenceStream {
    let next: () throws -> FolderPresenceEntry?
    let close: () -> Void
}

struct FolderPresenceEntry: Sendable {
    let type: Int32
    let name: String?
    var mayBeFolder: Bool { Self.mayBeFolder(type) }

    static func mayBeFolder(_ type: Int32) -> Bool {
        type == Int32(DT_DIR) || type == Int32(DT_LNK) || type == Int32(DT_UNKNOWN)
    }
}

enum FolderPresenceOpenMode: Equatable {
    case search, enumerate
}

protocol FolderPresenceFileSystem: Sendable {
    func openRoot() throws -> Int32
    func open(_ name: String, in parent: Int32, mode: FolderPresenceOpenMode) throws -> Int32
    func sample(_ name: String, in parent: Int32) throws -> stat
    func sampleDescriptor(_ descriptor: Int32) throws -> stat
    func isLocal(_ descriptor: Int32) throws -> Bool
    func mountInventory() throws -> [FolderPresenceMount]
    func mount(for descriptor: Int32) throws -> FolderPresenceMount
    // The descriptor transfers to the returned stream on success.
    func stream(_ descriptor: Int32) throws -> FolderPresenceStream
    func close(_ descriptor: Int32)
}

struct DarwinFolderPresenceFileSystem: FolderPresenceFileSystem {
    func openRoot() throws -> Int32 {
        try checkedDescriptor(Darwin.open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    func open(_ name: String, in parent: Int32, mode: FolderPresenceOpenMode) throws -> Int32 {
        let access = mode == .search ? O_SEARCH : O_RDONLY
        return try checkedDescriptor(openat(parent, name, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    func sample(_ name: String, in parent: Int32) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure() }
        return value
    }

    func sampleDescriptor(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw Self.failure() }
        return value
    }

    func isLocal(_ descriptor: Int32) throws -> Bool {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw Self.failure() }
        return volume.f_flags & UInt32(MNT_LOCAL) != 0
    }

    func stream(_ descriptor: Int32) throws -> FolderPresenceStream {
        guard let directory = fdopendir(descriptor) else { throw Self.failure() }
        return FolderPresenceStream(next: {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.failure() }
                return nil
            }
            let type = Int32(entry.pointee.d_type)
            guard FolderPresenceEntry.mayBeFolder(type) else { return FolderPresenceEntry(type: type, name: nil) }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: length + 1) {
                    try? DescriptorIO.decodeDirectoryName(UnsafeBufferPointer(start: $0, count: length))
                }
            }
            return FolderPresenceEntry(type: type, name: name)
        }, close: { _ = closedir(directory) })
    }

    func close(_ descriptor: Int32) { _ = Darwin.close(descriptor) }

    private func checkedDescriptor(_ descriptor: Int32) throws -> Int32 {
        guard descriptor >= 0 else { throw Self.failure() }
        return descriptor
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

public struct LocalFolderChildPresenceChecker: FolderChildPresenceChecking {
    private enum ProbeError: Error, Equatable { case deferred, refusedPath, mountProof, unavailable }

    private struct ScanPolicy {
        let lexical: FolderPresenceLexicalPolicy
        let target: FolderPresenceLexicalPolicy.Target
        let snapshot: FolderPresenceMountSnapshot?
        let networkMount: FolderPresenceMount?

        var isBounded: Bool { target.scope == .cloudOptIn || networkMount != nil }
        var isOptedIn: Bool { target.scope.isOptedIn || networkMount != nil }

        func defersPermission(_ error: Error) -> Bool {
            guard isOptedIn, let code = (error as? POSIXError)?.code else { return false }
            return code == .EPERM || code == .EACCES
        }

        func permitsBoundary(at path: String) -> Bool {
            snapshot?.permitsBoundary(at: path, selectedMount: networkMount) ?? true
        }

        func expectedMount(at path: String) -> FolderPresenceMount? {
            guard let networkMount, FolderPresencePath.contains(path, under: networkMount.path) else { return nil }
            return networkMount
        }
    }

    private struct Work {
        var traversal = 0
        var entries = 0
        var samples = 0
        var inventories = 0

        func result(identity: LocalFileIdentity? = nil,
                    uncertainty: FolderChildPresenceUncertainty?) -> FolderChildPresenceResult {
            FolderChildPresenceResult(presence: uncertainty == nil ? .absent : .unknown, directoryIdentity: identity,
                                      entriesExamined: entries, uncertainty: uncertainty ?? .transient,
                                      traversalOperations: traversal, childSamples: samples,
                                      mountInventoryOperations: inventories)
        }
    }

    // A remote stat tuple has meaning only on the verified mount of the
    // descriptor that supplied it. It never becomes a LocalFileIdentity.
    private struct RemoteIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int64
        let nanoseconds: Int64
        let mount: FolderPresenceMount

        init?(_ value: stat, mount: FolderPresenceMount) {
            let birth = value.st_birthtimespec
            guard value.st_ino != 0, (0..<1_000_000_000).contains(birth.tv_nsec),
                  birth.tv_sec != 0 || birth.tv_nsec != 0 else { return nil }
            device = value.st_dev
            inode = value.st_ino
            seconds = Int64(birth.tv_sec)
            nanoseconds = Int64(birth.tv_nsec)
            self.mount = mount
        }
    }

    private enum Identity: Equatable {
        case local(LocalFileIdentity)
        case remote(RemoteIdentity)

        var localIdentity: LocalFileIdentity? {
            guard case .local(let identity) = self else { return nil }
            return identity
        }
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let identity: Identity
    }

    private let fileSystem: any FolderPresenceFileSystem

    public init() { fileSystem = DarwinFolderPresenceFileSystem() }

    init(fileSystem: any FolderPresenceFileSystem) { self.fileSystem = fileSystem }

    public func check(_ request: FolderChildPresenceRequest) async -> FolderChildPresenceResult {
        let lexical = FolderPresenceLexicalPolicy(request)
        guard let target = lexical.target(for: request.url) else {
            return FolderChildPresenceResult(presence: .unknown, uncertainty: .policyDeferred)
        }
        do {
            return try await BlockingIO.run(on: .sidebarPresence) { cancellation in
                try scan(lexical: lexical, target: target, showHidden: request.showHidden, cancellation: cancellation)
            }
        } catch {
            return FolderChildPresenceResult(presence: .unknown)
        }
    }

    private static func matches(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec
            && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
    }

    private static func dataless(_ value: stat) -> Bool { value.st_flags & UInt32(SF_DATALESS) != 0 }

    private func walk(_ policy: ScanPolicy, cancellation: BlockingIOCancellation, work: inout Work)
        throws -> OpenedDirectory {
        try cancellation.checkCancellation()
        var path = "/"
        guard policy.permitsBoundary(at: path) else { throw ProbeError.mountProof }
        work.traversal += 1
        var descriptor = try fileSystem.openRoot()
        defer { if descriptor >= 0 { fileSystem.close(descriptor) } }
        work.traversal += 1
        var held = try fileSystem.sampleDescriptor(descriptor)
        for component in policy.target.components {
            try cancellation.checkCancellation()
            _ = try verifyVolume(descriptor, sample: held, expectedMount: policy.expectedMount(at: path),
                                 policy: policy, work: &work)
            let nextPath = policy.snapshot == nil ? path : (path == "/" ? "" : path) + "/" + component
            guard policy.permitsBoundary(at: nextPath) else { throw ProbeError.mountProof }

            work.traversal += 1
            let named = try fileSystem.sample(component, in: descriptor)
            let kind = named.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) || Self.dataless(named) { throw ProbeError.refusedPath }
            guard kind == mode_t(S_IFDIR) else { throw ProbeError.unavailable }

            work.traversal += 1
            let next = try fileSystem.open(component, in: descriptor, mode: .search)
            do {
                work.traversal += 1
                held = try fileSystem.sampleDescriptor(next)
                guard Self.matches(named, held) else {
                    throw policy.expectedMount(at: nextPath) == nil ? ProbeError.unavailable : ProbeError.mountProof
                }
            } catch {
                fileSystem.close(next)
                throw error
            }
            fileSystem.close(descriptor)
            descriptor = next
            path = nextPath
        }
        let remote = try verifyVolume(descriptor, sample: held, expectedMount: policy.networkMount,
                                      policy: policy, work: &work)
        let identity: Identity
        if let remote {
            identity = .remote(remote)
        } else {
            guard let local = LocalFileIdentity.fromStat(held) else { throw ProbeError.unavailable }
            identity = .local(local)
        }
        let opened = OpenedDirectory(descriptor: descriptor, identity: identity)
        descriptor = -1
        return opened
    }

    private func verifyVolume(_ descriptor: Int32, sample: stat, expectedMount: FolderPresenceMount?,
                              policy: ScanPolicy, work: inout Work) throws -> RemoteIdentity? {
        guard !Self.dataless(sample) else { throw ProbeError.refusedPath }
        do {
            if let expectedMount {
                guard let identity = RemoteIdentity(sample, mount: expectedMount) else { throw ProbeError.mountProof }
                work.traversal += 1
                guard try fileSystem.mount(for: descriptor).proves(expectedMount) else { throw ProbeError.mountProof }
                return identity
            }
            work.traversal += 1
            if policy.snapshot != nil {
                let mount = try fileSystem.mount(for: descriptor)
                guard mount.isLocal, !mount.isAutomounted else { throw ProbeError.mountProof }
            } else {
                guard try fileSystem.isLocal(descriptor) else { throw ProbeError.deferred }
            }
            return nil
        } catch {
            if policy.defersPermission(error) { throw error }
            if expectedMount != nil || (error as? ProbeError) == .mountProof { throw ProbeError.mountProof }
            // Locality was always policy-deferred in the first walk when the
            // descriptor query failed. Keep that behavior outside opt-in scope.
            throw ProbeError.deferred
        }
    }

    private func scan(lexical: FolderPresenceLexicalPolicy, target: FolderPresenceLexicalPolicy.Target,
                      showHidden: Bool, cancellation: BlockingIOCancellation) throws -> FolderChildPresenceResult {
        var work = Work()
        let snapshot: FolderPresenceMountSnapshot?
        if lexical.options.network {
            try cancellation.checkCancellation()
            work.inventories += 1
            do { snapshot = try FolderPresenceMountSnapshot(fileSystem.mountInventory()) }
            catch { return work.result(uncertainty: .policyDeferred) }
        } else {
            snapshot = nil
        }
        let policy = ScanPolicy(lexical: lexical, target: target, snapshot: snapshot,
                                networkMount: snapshot?.networkMount(containing: target.path))
        guard !target.requiresNetwork || policy.networkMount != nil else {
            return work.result(uncertainty: .policyDeferred)
        }

        do {
            let root = try walk(policy, cancellation: cancellation, work: &work)
            defer { fileSystem.close(root.descriptor) }
            try cancellation.checkCancellation()
            work.traversal += 1
            let reader = try fileSystem.open(".", in: root.descriptor, mode: .enumerate)
            var streamOwnsReader = false
            defer { if !streamOwnsReader { fileSystem.close(reader) } }
            work.traversal += 1
            let sample = try fileSystem.sampleDescriptor(reader)
            if let mount = policy.networkMount {
                guard let remote = try verifyVolume(reader, sample: sample, expectedMount: mount,
                                                    policy: policy, work: &work),
                      Identity.remote(remote) == root.identity else { throw ProbeError.mountProof }
            } else {
                guard let identity = LocalFileIdentity.fromStat(sample), Identity.local(identity) == root.identity
                else { throw ProbeError.unavailable }
                guard !Self.dataless(sample) else { throw ProbeError.refusedPath }
            }

            let stream = try fileSystem.stream(reader)
            streamOwnsReader = true
            defer { stream.close() }

            let uncertainty = try scanEntries(policy, showHidden: showHidden, reader: reader, stream: stream,
                                              cancellation: cancellation, work: &work)
            try cancellation.checkCancellation()
            let after: OpenedDirectory
            do { after = try walk(policy, cancellation: cancellation, work: &work) }
            catch { return work.result(uncertainty: failure(error, policy: policy, revalidating: true)) }
            fileSystem.close(after.descriptor)
            guard after.identity == root.identity else {
                return work.result(uncertainty: policy.networkMount == nil ? .transient : .policyDeferred)
            }
            return work.result(identity: root.identity.localIdentity, uncertainty: uncertainty)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return work.result(uncertainty: failure(error, policy: policy))
        }
    }

    private func failure(_ error: Error, policy: ScanPolicy, revalidating: Bool = false)
        -> FolderChildPresenceUncertainty {
        if policy.defersPermission(error) { return .policyDeferred }
        switch error as? ProbeError {
        case .some(.mountProof):
            return .policyDeferred
        case .some(.refusedPath) where !revalidating || policy.isOptedIn:
            return .policyDeferred
        case .some(.deferred) where !revalidating:
            return .policyDeferred
        default:
            return .transient
        }
    }

    private func scanEntries(_ policy: ScanPolicy, showHidden: Bool, reader: Int32, stream: FolderPresenceStream,
                             cancellation: BlockingIOCancellation, work: inout Work)
        throws -> FolderChildPresenceUncertainty? {
        let bounded = policy.isBounded
        var reads = 0
        var transient = false
        var deferred = false
        while true {
            try cancellation.checkCancellation()
            guard !bounded || reads < 256 else { throw ProbeError.deferred }
            reads += 1
            let entry: FolderPresenceEntry
            do {
                guard let next = try stream.next() else { break }
                entry = next
            } catch {
                if policy.defersPermission(error) { throw error }
                transient = true
                break
            }
            if entry.name == "." || entry.name == ".." { continue }
            work.entries += 1
            guard entry.mayBeFolder else { continue }
            guard let name = entry.name, !name.isEmpty, !name.utf8.contains(47), !name.utf8.contains(0) else {
                transient = true
                continue
            }
            if !showHidden, name.hasPrefix(".") { continue }
            let path = (policy.target.path == "/" ? "" : policy.target.path) + "/" + name
            guard policy.lexical.permitsChild(path), policy.permitsBoundary(at: path) else {
                deferred = true
                continue
            }

            guard !bounded || work.samples < 32 else { throw ProbeError.deferred }
            work.samples += 1
            let value: stat
            do { value = try fileSystem.sample(name, in: reader) }
            catch {
                if policy.defersPermission(error) { throw error }
                transient = true
                continue
            }
            if !showHidden, value.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
            if Self.dataless(value) { deferred = true; continue }
            let kind = value.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) || kind == mode_t(S_IFLNK) { return .structural }
        }
        return transient ? .transient : deferred ? .policyDeferred : nil
    }
}
