import Darwin
import Foundation
import Testing
@testable import ExplorerCore

private final class FolderPresenceFileSystemSpy: FolderPresenceFileSystem, @unchecked Sendable {
    enum Action: Sendable, Equatable {
        case openRoot, openSearch, openEnumeration, sample, sampleDescriptor, locality, inventory, mount, stream, read, close
    }

    struct Call: Sendable {
        let action: Action
        let descriptor: Int32?
        let mode: FolderPresenceOpenMode?
        let path: String
        let occurrence: Int
        let streamIsOpen: Bool
    }

    private struct Opened {
        let path: String
        let mode: FolderPresenceOpenMode
        var ownsStream = false
    }

    static let localMount = FolderPresenceMount(path: "/", type: "apfs", fsid: SIMD2(1, 2),
                                                flags: UInt32(MNT_LOCAL))

    private let real = DarwinFolderPresenceFileSystem()
    private let lock = NSLock()
    private var opened: [Int32: Opened] = [:]
    private var calls: [Call] = []
    private let before: @Sendable (Call) throws -> Void
    private let sampleFlags: @Sendable (String, UInt32) -> UInt32
    private let locality: @Sendable (String, Bool) throws -> Bool
    private let inventory: @Sendable () throws -> [FolderPresenceMount]
    private let descriptorMount: @Sendable (Call, FolderPresenceMount) -> FolderPresenceMount
    private let sampleIdentity: @Sendable (Call, stat) -> stat
    private let entries: [FolderPresenceEntry]?

    init(before: @escaping @Sendable (Call) throws -> Void = { _ in },
         sampleFlags: @escaping @Sendable (String, UInt32) -> UInt32 = { _, flags in flags },
         locality: @escaping @Sendable (String, Bool) throws -> Bool = { _, value in value },
         inventory: @escaping @Sendable () throws -> [FolderPresenceMount] = { [FolderPresenceFileSystemSpy.localMount] },
         descriptorMount: @escaping @Sendable (Call, FolderPresenceMount) -> FolderPresenceMount = { _, mount in mount },
         sampleIdentity: @escaping @Sendable (Call, stat) -> stat = { _, value in value },
         entries: [FolderPresenceEntry]? = nil) {
        self.before = before
        self.sampleFlags = sampleFlags
        self.locality = locality
        self.inventory = inventory
        self.descriptorMount = descriptorMount
        self.sampleIdentity = sampleIdentity
        self.entries = entries
    }

    var trace: [Call] { lock.withLock { calls } }
    var allClosed: Bool {
        lock.withLock { opened.isEmpty && !calls.contains { $0.action == .close && $0.path == "<unowned>" } }
    }

    func openRoot() throws -> Int32 {
        try record(.openRoot, descriptor: nil, path: "/")
        let descriptor = try real.openRoot()
        lock.withLock { opened[descriptor] = Opened(path: "/", mode: .search) }
        return descriptor
    }

    func open(_ name: String, in parent: Int32, mode: FolderPresenceOpenMode) throws -> Int32 {
        let path = path(of: parent, name: name)
        try record(mode == .search ? .openSearch : .openEnumeration, descriptor: parent, path: path)
        let descriptor = try real.open(name, in: parent, mode: mode)
        lock.withLock { opened[descriptor] = Opened(path: path, mode: mode) }
        return descriptor
    }

    func sample(_ name: String, in parent: Int32) throws -> stat {
        let path = path(of: parent, name: name)
        let call = try record(.sample, descriptor: parent, path: path)
        var result = try real.sample(name, in: parent)
        result.st_flags = sampleFlags(path, result.st_flags)
        return sampleIdentity(call, result)
    }

    func sampleDescriptor(_ descriptor: Int32) throws -> stat {
        let call = try record(.sampleDescriptor, descriptor: descriptor, path: path(of: descriptor))
        return sampleIdentity(call, try real.sampleDescriptor(descriptor))
    }

    func isLocal(_ descriptor: Int32) throws -> Bool {
        let path = path(of: descriptor)
        try record(.locality, descriptor: descriptor, path: path)
        return try locality(path, real.isLocal(descriptor))
    }

    func mountInventory() throws -> [FolderPresenceMount] {
        try record(.inventory, descriptor: nil, path: "/")
        return try inventory()
    }

    func mount(for descriptor: Int32) throws -> FolderPresenceMount {
        let call = try record(.mount, descriptor: descriptor, path: path(of: descriptor))
        return descriptorMount(call, try real.mount(for: descriptor))
    }

    func stream(_ descriptor: Int32) throws -> FolderPresenceStream {
        let path = path(of: descriptor)
        try record(.stream, descriptor: descriptor, path: path)
        let owned = try real.stream(descriptor)
        lock.withLock { opened[descriptor]?.ownsStream = true }
        var modeled = entries?.makeIterator()
        return FolderPresenceStream(next: {
            try self.record(.read, descriptor: descriptor, path: path)
            if modeled != nil { return modeled?.next() }
            return try owned.next()
        }, close: {
            self.recordClose(descriptor)
            owned.close()
        })
    }

    func close(_ descriptor: Int32) {
        recordClose(descriptor)
        real.close(descriptor)
    }

    private func path(of descriptor: Int32, name: String = ".") -> String {
        let path = lock.withLock { opened[descriptor]?.path ?? "<unowned>" }
        if name == "." { return path }
        return (path == "/" ? "" : path) + "/" + name
    }

    @discardableResult
    private func record(_ action: Action, descriptor: Int32?, path: String) throws -> Call {
        let call = lock.withLock {
            let occurrence = calls.lazy.filter { $0.action == action && $0.path == path }.count + 1
            let mode = descriptor.flatMap { opened[$0]?.mode }
            let call = Call(action: action, descriptor: descriptor, mode: mode, path: path, occurrence: occurrence,
                            streamIsOpen: opened.values.contains(where: \.ownsStream))
            calls.append(call)
            return call
        }
        try before(call)
        return call
    }

    private func recordClose(_ descriptor: Int32) {
        lock.withLock {
            let item = opened.removeValue(forKey: descriptor)
            calls.append(Call(action: .close, descriptor: descriptor, mode: item?.mode,
                              path: item?.path ?? "<unowned>", occurrence: 1,
                              streamIsOpen: opened.values.contains(where: \.ownsStream)))
        }
    }
}

struct FolderChildPresenceTests {
    @Test
    func knownCloudOptionAdmitsMaterializedFolder() async throws {
        let home = try fixture()
        defer { remove(home) }
        let library = try folder("Library", in: home)
        let cloud = try folder("CloudStorage", in: library)
        let target = try folder("ExampleProvider", in: cloud)
        try Data().write(to: target.appendingPathComponent("file.txt"))

        let checker = LocalFolderChildPresenceChecker()
        let disabled = await checker.check(.init(url: target, showHidden: false, homeURL: home))
        #expect(disabled.isPolicyDeferred)

        let enabled = await checker.check(.init(url: target, showHidden: false, homeURL: home,
                                                options: .init(cloud: true)))
        #expect(enabled.presence == .absent && enabled.entriesExamined == 1 && enabled.directoryIdentity != nil)
    }

    @Test
    func shallowProbeClassifiesFilesAndPreservesHiddenAndPackageUncertainty() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let checker = LocalFolderChildPresenceChecker()
        func check(_ hidden: Bool = false) async -> FolderChildPresenceResult {
            await checker.check(.init(url: fixture, showHidden: hidden, homeURL: fixture))
        }
        let empty = await check()
        #expect(empty.presence == .absent && empty.entriesExamined == 0 && empty.directoryIdentity != nil)
        #expect(empty.traversalOperations > 0 && empty.childSamples == 0)
        try Data().write(to: fixture.appendingPathComponent("file.txt"))
        let fileOnly = await check()
        #expect(fileOnly.presence == .absent && fileOnly.entriesExamined == 1 && fileOnly.childSamples == 0)

        let package = fixture.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Contents", isDirectory: true),
                                                withIntermediateDirectories: true)
        let packageSnapshot = try await LocalDirectoryLoader().snapshot(of: fixture)
        try #require(packageSnapshot.items.first { $0.name == "Demo.app" }?.isDirectory == false)
        #expect(packageSnapshot.isStructureComplete)
        #expect(await check().uncertainty == .structural)
        try FileManager.default.removeItem(at: package)

        _ = try folder(".hidden", in: fixture)
        let flagged = try folder("Flagged", in: fixture)
        try #require(flagged.path.withCString { chflags($0, UInt32(UF_HIDDEN)) } == 0)
        #expect(await check().presence == .absent)
        #expect(await check(true).uncertainty == .structural)
        _ = try folder("Ordinary", in: fixture)
        #expect(await check().uncertainty == .structural)
    }

    @Test
    func rootAndAncestorLinksAreDeferredEvenAfterExplicitListingAndChildLinksStayUncertain() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let target = try folder("Target", in: fixture)
        let child = try folder("Child", in: target)
        let source = try folder("Source", in: fixture)
        let link = source.appendingPathComponent("Link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let listing = try await LocalDirectoryLoader().snapshot(of: link)
        #expect(listing.items.first?.name == "Child")
        #expect(listing.isStructureComplete)

        let spy = FolderPresenceFileSystemSpy()
        let checker = LocalFolderChildPresenceChecker(fileSystem: spy)
        let aliasChild = link.appendingPathComponent("Child", isDirectory: true)
        for url in [link, aliasChild] {
            let result = await checker.check(.init(url: url, showHidden: false, homeURL: fixture,
                                                  openedProtectedScopes: [url]))
            #expect(result.isPolicyDeferred)
        }
        #expect(!spy.trace.contains { $0.path == target.path || $0.path == child.path || $0.action == .stream })
        let parentResult = await checker.check(.init(url: source, showHidden: false, homeURL: fixture))
        #expect(parentResult.uncertainty == .structural && parentResult.childSamples == 1)
        #expect(spy.allClosed)

        try FileManager.default.removeItem(at: target)
        let broken = try await LocalDirectoryLoader().snapshot(of: source)
        #expect(!broken.isStructureComplete)
        #expect(broken.items.allSatisfy { !$0.isDirectory })
    }

    @Test
    func blockedSpellingsAndNestedProtectedFoldersMakeNoFilesystemCalls() async {
        let home = URL(fileURLWithPath: "/Users/Café", isDirectory: true)
        let openedLibrary = URL(fileURLWithPath: "/Users/Café/Library", isDirectory: true)
        let spy = FolderPresenceFileSystemSpy()
        let checker = LocalFolderChildPresenceChecker(fileSystem: spy)
        let denied = [
            "/Volumes/Fake", "/private/Network/Server", "/net/host", "/private/home/other",
            "/Users/Café/Library/Containers/Fake", "/Users/Café/Library/Group Containers/Fake",
            "/SYSTEM//Volumes/DATA/Users/Cafe\u{301}/Library/CloudStorage/Fake",
            "/Users/CAFÉ/Library/Mobile Documents/Fake", "/Users/Café/Plain/../Documents/Fake",
        ]
        for path in denied {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var opened: Set<URL> = [openedLibrary]
            if path.contains("CloudStorage") || path.contains("Mobile Documents") { opened.insert(url) }
            let result = await checker.check(.init(url: url, showHidden: false, homeURL: home,
                                                  openedProtectedScopes: opened))
            #expect(result.isPolicyDeferred, "\(path)")
        }
        #expect(spy.trace.isEmpty)
        let request = FolderChildPresenceRequest(url: openedLibrary, showHidden: false, homeURL: home,
                                                 openedProtectedScopes: [openedLibrary])
        #expect(FolderPresenceLexicalPolicy(request).target(for: openedLibrary) != nil)
    }

    @Test
    func replacingAnExplicitlyOpenedAncestorWithALinkCannotRedirectTheRelativeOpen() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let ancestor = try folder("Documents", in: fixture)
        let requested = try folder("Requested", in: ancestor)
        let other = try folder("Other", in: fixture)
        _ = try folder("Requested", in: other)
        let previous = fixture.appendingPathComponent("OldDocuments", isDirectory: true)
        let spy = FolderPresenceFileSystemSpy(before: { call in
            if call.action == .openSearch, call.path == ancestor.path {
                try FileManager.default.moveItem(at: ancestor, to: previous)
                try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: other)
            }
        })
        let result = await LocalFolderChildPresenceChecker(fileSystem: spy).check(
            .init(url: requested, showHidden: false, homeURL: fixture, openedProtectedScopes: [ancestor, requested]))
        #expect(result.uncertainty == .transient)
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(spy.trace.contains { $0.action == .sample && $0.path == ancestor.path && $0.descriptor != nil })
        #expect(!spy.trace.contains { $0.path == requested.path || $0.path.hasPrefix(other.path) || $0.action == .stream })
        #expect(spy.allClosed)
    }

    @Test
    func rootReplacementDoesNotPublishTheHeldDirectoryAsTheNewPathsLeaf() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let root = try folder("Root", in: fixture)
        try Data().write(to: root.appendingPathComponent("old.txt"))
        let previous = fixture.appendingPathComponent("OldRoot", isDirectory: true)
        let spy = FolderPresenceFileSystemSpy(before: { call in
            if call.action == .openEnumeration, call.path == root.path {
                try FileManager.default.moveItem(at: root, to: previous)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("NewChild", isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
        })
        let result = await LocalFolderChildPresenceChecker(fileSystem: spy).check(.init(url: root,
            showHidden: false, homeURL: fixture))
        #expect(result.uncertainty == .transient && result.directoryIdentity == nil)
        #expect(result.entriesExamined == 1 && result.childSamples == 0)
        #expect(spy.trace.filter { $0.action == .openRoot }.count == 2)
        #expect(spy.allClosed)
    }

    @Test
    func childSubstitutionIsSampledWithoutFollowingItsNewLink() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let root = try folder("Root", in: fixture)
        let child = try folder("Candidate", in: root)
        let other = try folder("Other", in: fixture)
        let retired = fixture.appendingPathComponent("OldChild", isDirectory: true)
        let spy = FolderPresenceFileSystemSpy(before: { call in
            if call.action == .sample, call.path == child.path {
                try FileManager.default.moveItem(at: child, to: retired)
                try FileManager.default.createSymbolicLink(at: child, withDestinationURL: other)
            }
        })
        let result = await LocalFolderChildPresenceChecker(fileSystem: spy).check(.init(url: root,
            showHidden: false, homeURL: fixture))
        #expect(result.uncertainty == .structural && result.childSamples == 1)
        #expect(FileManager.default.fileExists(atPath: retired.path))
        #expect(!spy.trace.contains { $0.path.hasPrefix(other.path) || ($0.action == .openSearch && $0.path == child.path) })
        #expect(spy.allClosed)
    }

    @Test
    func nonlocalUnknownLocalityAndDatalessSamplesStopBeforeTheNextLookup() async throws {
        let fixture = try fixture()
        defer { remove(fixture) }
        let mounted = try folder("Mounted", in: fixture)
        let requested = try folder("Requested", in: mounted)
        let spies = [
            FolderPresenceFileSystemSpy(sampleFlags: { path, flags in
                path == mounted.path ? flags | UInt32(SF_DATALESS) : flags
            }),
            FolderPresenceFileSystemSpy(locality: { path, local in path == mounted.path ? false : local }),
            FolderPresenceFileSystemSpy(locality: { path, local in
                if path == mounted.path { throw POSIXError(.EIO) }
                return local
            }),
        ]
        for spy in spies {
            let result = await LocalFolderChildPresenceChecker(fileSystem: spy).check(.init(url: requested,
                showHidden: false, homeURL: fixture))
            #expect(result.isPolicyDeferred)
            #expect(!spy.trace.contains { $0.path == requested.path || $0.action == .stream })
            #expect(spy.allClosed)
        }
    }


    @Test
    func optionsIndependentlyGateLocalAndModeledRemoteTargets() async throws {
        let home = try fixture()
        defer { remove(home) }
        let ordinary = try folder("Ordinary", in: home)
        let protected = try folder("Documents", in: home)
        let library = try folder("Library", in: home)
        let project = try folder("Project", in: library)
        let cloud = try folder("CloudStorage", in: library)
        let remote = try folder("Remote", in: home)

        for mask in 0..<8 {
            let protectedOn = mask & 1 != 0
            let cloudOn = mask & 2 != 0
            let networkOn = mask & 4 != 0
            let options = SidebarBackgroundCheckOptions(protectedLocal: protectedOn, cloud: cloudOn, network: networkOn)
            let cases: [(URL, modeledRemote: Bool, allowed: Bool)] = [
                (ordinary, false, true),
                (protected, false, protectedOn),
                (project, false, protectedOn),
                (cloud, false, cloudOn),
                (remote, true, networkOn),
                (protected, true, protectedOn && networkOn),
                (cloud, true, cloudOn && networkOn),
            ]
            for (url, modeledRemote, allowed) in cases {
                let spy = modeledRemote ? remoteSpy(mount: share(at: url)) : FolderPresenceFileSystemSpy()
                let result = await probe(url, home: home, options: options, spy: spy)
                if allowed {
                    #expect(result.presence == .absent, "mask \(mask), \(url.lastPathComponent), remote \(modeledRemote)")
                    #expect((result.directoryIdentity == nil) == modeledRemote)
                    #expect(result.mountInventoryOperations == (networkOn ? 1 : 0))
                } else {
                    #expect(result.isPolicyDeferred)
                    #expect(!spy.trace.contains { $0.action == .stream })
                }
                #expect(spy.allClosed)
            }
        }
    }

    @Test
    func iCloudDesktopAndDocumentsRequireBothLexicalPermissions() async throws {
        let home = try fixture()
        defer { remove(home) }
        let library = try folder("Library", in: home)
        let mobile = try folder("Mobile Documents", in: library)
        let drive = try folder("com~apple~CloudDocs", in: mobile)
        for name in ["Desktop", "Documents"] {
            let alias = try folder(name, in: drive)
            let nested = try folder("Nested", in: alias)
            for url in [alias, nested] {
                let denied = FolderPresenceFileSystemSpy()
                #expect(await probe(url, home: home, options: .init(protectedLocal: true), spy: denied).isPolicyDeferred)
                #expect(await probe(url, home: home, options: .init(cloud: true), grants: [drive], spy: denied)
                    .isPolicyDeferred)
                #expect(denied.trace.isEmpty)

                for (options, grants) in [
                    (SidebarBackgroundCheckOptions(protectedLocal: true, cloud: true), Set<URL>()),
                    (.init(cloud: true), [url]),
                ] {
                    let spy = FolderPresenceFileSystemSpy(entries: [])
                    #expect(await probe(url, home: home, options: options, grants: grants, spy: spy).presence == .absent)
                    #expect(spy.allClosed)
                }
            }
        }
        let spy = FolderPresenceFileSystemSpy(entries: [])
        #expect(await probe(drive, home: home, options: .init(cloud: true), spy: spy).presence == .absent)
    }

    @Test
    func exactProtectedGrantRemainsAvailableWithAllOptionsOff() async throws {
        let home = try fixture()
        defer { remove(home) }
        let protected = try folder("Desktop", in: home)
        let nested = try folder("Nested", in: protected)
        let denied = FolderPresenceFileSystemSpy()
        #expect(await probe(nested, home: home, grants: [protected], spy: denied).isPolicyDeferred)
        #expect(denied.trace.isEmpty)
        let allowed = FolderPresenceFileSystemSpy()
        let result = await probe(nested, home: home, grants: [nested], spy: allowed)
        #expect(result.presence == .absent && result.directoryIdentity != nil && result.mountInventoryOperations == 0)
        #expect(allowed.allClosed)
    }

    @Test
    func optInPermissionDenialsStopWithoutAnyFurtherProbeOperations() async throws {
        let home = try fixture()
        defer { remove(home) }
        let protected = try folder("Documents", in: home)
        let library = try folder("Library", in: home)
        let cloud = try folder("CloudStorage", in: library)
        let mobile = try folder("Mobile Documents", in: library)
        let cloudDrive = try folder("com~apple~CloudDocs", in: mobile)
        let cloudAlias = try folder("Desktop", in: cloudDrive)
        let remote = try folder("Remote", in: home)
        let targets: [(URL, SidebarBackgroundCheckOptions, Set<URL>, Bool)] = [
            (protected, .init(protectedLocal: true), [], false),
            (cloud, .init(cloud: true), [], false),
            (cloudAlias, .init(cloud: true), [cloudAlias], false),
            (remote, .init(network: true), [], true),
        ]
        for (url, options, rootGrants, modeledRemote) in targets {
            let blocked = url.appendingPathComponent("Blocked")
            try Data().write(to: blocked)
            let later = try folder("Later", in: url)
            // A cloud Desktop grant is exact. Admit both children so the
            // injected permission denial, not a lexical refusal, stops this scan.
            let grants = url == cloudAlias ? rootGrants.union([blocked, later]) : rootGrants
            let entries = [entry(DT_UNKNOWN, "Blocked"), entry(DT_DIR, "Later")]
            let stages: [(FolderPresenceFileSystemSpy.Action, String, Int, POSIXErrorCode)] = [
                (.openRoot, "/", 1, .EPERM),
                (.sample, url.path, 1, .EACCES),
                (.sampleDescriptor, url.path, 1, .EPERM),
                (.openEnumeration, url.path, 1, .EACCES),
                (.stream, url.path, 1, .EPERM),
                (.read, url.path, 1, .EACCES),
                (.sample, blocked.path, 1, .EPERM),
                (.openRoot, "/", 2, .EACCES),
            ]
            for (action, path, occurrence, error) in stages {
                // For final-walk injection, let the listing reach EOF.
                let before: @Sendable (FolderPresenceFileSystemSpy.Call) throws -> Void = {
                    if $0.action == action, $0.path == path, $0.occurrence == occurrence { throw POSIXError(error) }
                }
                let stream = occurrence == 2 ? [] : entries
                let spy = modeledRemote
                    ? remoteSpy(mount: share(at: url), before: before, entries: stream)
                    : FolderPresenceFileSystemSpy(before: before, entries: stream)
                let result = await probe(url, home: home, options: options, grants: grants, spy: spy)
                let stage = "\(url.lastPathComponent), \(action), attempt \(occurrence)"
                #expect(result.isPolicyDeferred, "\(stage)")
                let trace = spy.trace
                let denial = try #require(trace.firstIndex {
                    $0.action == action && $0.path == path && $0.occurrence == occurrence
                }, "Fixture must reach the injected denial at \(stage)")
                #expect(trace.dropFirst(denial + 1).allSatisfy { $0.action == .close })
                if path == blocked.path { #expect(!trace.contains { $0.path == later.path }) }
                #expect(spy.allClosed)
            }
        }
    }

    @Test
    func legacyPermissionErrorsRetainTransientAndStructuralPrecedence() async throws {
        let home = try fixture()
        defer { remove(home) }
        let ordinary = try folder("Ordinary", in: home)
        let protected = try folder("Downloads", in: home)
        let cases: [(URL, SidebarBackgroundCheckOptions, Bool)] = [
            (ordinary, .init(), false), (ordinary, .init(network: true), false), (protected, .init(), true),
        ]
        for (url, options, exactGrant) in cases {
            let denied = url.appendingPathComponent("Denied")
            let later = url.appendingPathComponent("Later", isDirectory: true)
            if !FileManager.default.fileExists(atPath: denied.path) {
                try Data().write(to: denied)
                _ = try folder("Later", in: url)
            }
            let grants: Set<URL> = exactGrant ? [url, denied, later] : []
            let spy = FolderPresenceFileSystemSpy(before: {
                if $0.action == .sample, $0.path == denied.path { throw POSIXError(.EACCES) }
            }, entries: [entry(DT_UNKNOWN, "Denied"), entry(DT_DIR, "Later")])
            let result = await probe(url, home: home, options: options, grants: grants, spy: spy)
            #expect(result.uncertainty == .structural && result.childSamples == 2)
            #expect(spy.trace.contains { $0.action == .sample && $0.path == later.path })
            #expect(spy.allClosed)

            let readerDenied = FolderPresenceFileSystemSpy(before: {
                if $0.action == .openEnumeration { throw POSIXError(.EPERM) }
            })
            #expect(await probe(url, home: home, options: options, grants: grants, spy: readerDenied)
                .uncertainty == .transient)
            #expect(readerDenied.allClosed)
        }

        // Before opt-ins, a failed initial locality proof already deferred.
        let localityDenied = FolderPresenceFileSystemSpy(before: {
            if $0.action == .locality, $0.path == ordinary.path { throw POSIXError(.EACCES) }
        })
        #expect(await probe(ordinary, home: home, spy: localityDenied).isPolicyDeferred)
        #expect(localityDenied.allClosed)

        let finalWalkDenied = FolderPresenceFileSystemSpy(before: {
            if $0.action == .openRoot, $0.occurrence == 2 { throw POSIXError(.EPERM) }
        }, entries: [])
        #expect(await probe(ordinary, home: home, spy: finalWalkDenied).uncertainty == .transient)
        #expect(finalWalkDenied.allClosed)
    }

    @Test
    func cloudAndNetworkBudgetsIncludeDotHiddenAndEOFAttempts() async throws {
        let home = try fixture()
        defer { remove(home) }
        let library = try folder("Library", in: home)
        let cloud = try folder("CloudStorage", in: library)
        let remote = try folder("Remote", in: home)
        for (url, options) in [(cloud, SidebarBackgroundCheckOptions(cloud: true)), (remote, .init(network: true))] {
            try Data().write(to: url.appendingPathComponent("File"))
            let dots = [entry(DT_DIR, "."), entry(DT_DIR, "..")]
            let hidden = [entry(DT_UNKNOWN, ".Hidden")]
            for (fileCount, reads, isLeaf) in [(251, 255, true), (252, 256, true), (253, 256, false)] {
                let entries = dots + hidden + Array(repeating: entry(DT_REG, nil), count: fileCount)
                let spy = options.network
                    ? remoteSpy(mount: share(at: url), entries: entries)
                    : FolderPresenceFileSystemSpy(entries: entries)
                let result = await probe(url, home: home, options: options, spy: spy)
                #expect(result.presence == (isLeaf ? .absent : .unknown))
                #expect(result.isPolicyDeferred == !isLeaf)
                #expect(result.entriesExamined == fileCount + 1 && result.childSamples == 0)
                #expect(spy.trace.filter { $0.action == .read }.count == reads)
                #expect(spy.allClosed)
            }

            for (fileCount, isLeaf) in [(32, true), (33, false)] {
                let entries = dots + hidden + Array(repeating: entry(DT_UNKNOWN, "File"), count: fileCount)
                let spy = options.network
                    ? remoteSpy(mount: share(at: url), entries: entries)
                    : FolderPresenceFileSystemSpy(entries: entries)
                let result = await probe(url, home: home, options: options, spy: spy)
                #expect(result.presence == (isLeaf ? .absent : .unknown))
                #expect(result.isPolicyDeferred == !isLeaf)
                #expect(result.childSamples == 32)
                #expect(spy.trace.filter { $0.action == .sample && $0.path.hasSuffix("/File") }.count == 32)
                #expect(spy.trace.filter { $0.action == .read }.count == 36)
                #expect(spy.allClosed)
            }
        }
    }

    @Test
    func ordinaryAndProtectedLocalChecksCanExceedCloudBudgets() async throws {
        let home = try fixture()
        defer { remove(home) }
        let ordinary = try folder("Ordinary", in: home)
        let protected = try folder("Documents", in: home)
        let options = SidebarBackgroundCheckOptions(protectedLocal: true, cloud: true, network: true)
        for url in [ordinary, protected] {
            try Data().write(to: url.appendingPathComponent("File"))
            let entries = Array(repeating: entry(DT_UNKNOWN, "File"), count: 33)
                + Array(repeating: entry(DT_REG, nil), count: 224)
            let spy = FolderPresenceFileSystemSpy(entries: entries)
            let result = await probe(url, home: home, options: options, spy: spy)
            #expect(result.presence == .absent && result.entriesExamined == 257 && result.childSamples == 33)
            #expect(spy.trace.filter { $0.action == .read }.count == 258)
            #expect(spy.allClosed)
        }
    }

    @Test
    func cloudOptionStillRefusesDatalessAndLinkedPaths() async throws {
        let home = try fixture()
        defer { remove(home) }
        let library = try folder("Library", in: home)
        let cloud = try folder("CloudStorage", in: library)
        let placeholder = try folder("Placeholder", in: cloud)
        let sibling = try folder("Ordinary", in: home)
        let link = cloud.appendingPathComponent("Linked", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)
        let options = SidebarBackgroundCheckOptions(cloud: true)
        let spy = FolderPresenceFileSystemSpy(sampleFlags: { path, flags in
            path == placeholder.path ? flags | UInt32(SF_DATALESS) : flags
        })
        for url in [placeholder, link] {
            #expect(await probe(url, home: home, options: options, spy: spy).isPolicyDeferred)
        }
        let blockedPaths = [placeholder.path, link.path, sibling.path]
        #expect(!spy.trace.contains {
            $0.action == .stream || ($0.action == .openSearch && blockedPaths.contains($0.path))
        })
        #expect(spy.allClosed)
    }

    @Test
    func networkProofUsesBothFilesystemIDHalvesOnTheEnumeratedDescriptor() async throws {
        let home = try fixture()
        defer { remove(home) }
        let remote = try folder("Remote", in: home)
        let target = try folder("Target", in: remote)
        let mount = share(at: remote)
        let base = FolderPresenceFileSystemSpy.localMount
        let options = SidebarBackgroundCheckOptions(network: true)

        for type in ["smbfs", "nfs", "webdav", "afpfs"] {
            let candidate = FolderPresenceMount(path: mount.path, type: type, fsid: mount.fsid, flags: 0)
            let spy = remoteSpy(mount: candidate, sampleIdentity: { call, original in
                var value = original
                if call.path == remote.path || call.path == target.path { value.st_dev = 467 }
                return value
            })
            let result = await probe(target, home: home, options: options, spy: spy)
            #expect(result.presence == .absent && result.directoryIdentity == nil)
            #expect(result.mountInventoryOperations == 1)
            let trace = spy.trace
            let streamIndex = try #require(trace.firstIndex { $0.action == .stream })
            let stream = trace[streamIndex]
            #expect(trace[..<streamIndex].contains {
                $0.action == .mount && $0.mode == .enumerate && $0.descriptor == stream.descriptor
            })
            #expect(trace[..<streamIndex].contains {
                $0.action == .sampleDescriptor && $0.mode == .enumerate && $0.descriptor == stream.descriptor
            })
            #expect(trace.filter { $0.action == .mount && $0.path == target.path && $0.mode == .search }.count == 2)
            #expect(spy.allClosed)
        }

        let substitutions = [
            FolderPresenceMount(path: mount.path, type: mount.type, fsid: SIMD2(0, mount.fsid.y), flags: 0),
            FolderPresenceMount(path: mount.path, type: mount.type, fsid: SIMD2(mount.fsid.x, 0), flags: 0),
            FolderPresenceMount(path: target.path, type: mount.type, fsid: mount.fsid, flags: 0),
            FolderPresenceMount(path: mount.path, type: "nfs", fsid: mount.fsid, flags: 0),
            base,
        ]
        for substituted in substitutions {
            let spy = remoteSpy(mount: mount, changeMount: { call, proven in
                call.mode == .enumerate ? substituted : proven
            })
            #expect(await probe(target, home: home, options: options, spy: spy).isPolicyDeferred)
            #expect(!spy.trace.contains { $0.action == .stream })
            #expect(spy.allClosed)
        }

        for readerOnly in [true, false] {
            let spy = remoteSpy(mount: mount, sampleIdentity: { call, original in
                var value = original
                if call.path == target.path, call.action == .sampleDescriptor,
                   !readerOnly || call.mode == .enumerate {
                    value.st_dev &+= 1
                }
                return value
            })
            #expect(await probe(target, home: home, options: options, spy: spy).isPolicyDeferred)
            #expect(!spy.trace.contains { $0.action == .stream })
            #expect(spy.allClosed)
        }
    }

    @Test
    func networkMountBoundariesFailClosedBeforeNamedLookup() async throws {
        let home = try fixture()
        defer { remove(home) }
        let outer = try folder("Outer", in: home)
        let inner = try folder("Inner", in: outer)
        let eligible = share(at: outer)
        let nested = share(at: inner)
        let root = FolderPresenceFileSystemSpy.localMount
        let options = SidebarBackgroundCheckOptions(protectedLocal: true, cloud: true, network: true)
        let denied = [
            FolderPresenceMount(path: outer.path, type: "other", fsid: eligible.fsid, flags: 0),
            FolderPresenceMount(path: outer.path, type: "autofs", fsid: eligible.fsid, flags: 0),
            FolderPresenceMount(path: outer.path, type: eligible.type, fsid: eligible.fsid, flags: UInt32(MNT_AUTOMOUNTED)),
            FolderPresenceMount(path: outer.path, type: eligible.type, fsid: .zero, flags: 0),
        ]
        let inventories = denied.map { [root, $0] } + [[root, eligible, eligible], [root, eligible, nested]]
        for (index, inventory) in inventories.enumerated() {
            let spy = FolderPresenceFileSystemSpy(inventory: { inventory })
            let result = await probe(inner, home: home, options: options, spy: spy)
            #expect(result.isPolicyDeferred && result.mountInventoryOperations == 1)
            if index < denied.count {
                #expect(!spy.trace.contains { $0.action == .sample && $0.path == outer.path })
            }
            #expect(!spy.trace.contains { $0.action == .sample && $0.path == inner.path })
            #expect(!spy.trace.contains { $0.action == .stream })
            #expect(spy.allClosed)
        }
        let casing = FolderPresenceMount(path: outer.path.lowercased(), type: eligible.type, fsid: eligible.fsid, flags: 0)
        let aliasSpy = FolderPresenceFileSystemSpy(inventory: { [root, casing] })
        #expect(await probe(outer, home: home, options: options, spy: aliasSpy).isPolicyDeferred)
        #expect(!aliasSpy.trace.contains { $0.action == .sample && $0.path == outer.path })
        #expect(aliasSpy.allClosed)

        let localExternal = URL(fileURLWithPath: "/Volumes/SyntheticLocal", isDirectory: true)
        let external = FolderPresenceMount(path: localExternal.path, type: "apfs", fsid: SIMD2(9, 8),
                                           flags: UInt32(MNT_LOCAL))
        let externalSpy = FolderPresenceFileSystemSpy(inventory: { [root, external] })
        #expect(await probe(localExternal, home: home, options: options, spy: externalSpy).isPolicyDeferred)
        #expect(!externalSpy.trace.contains { $0.action == .sample && $0.path == localExternal.path })

        let childSpy = remoteSpy(mount: eligible, additionalMounts: [nested], entries: [entry(DT_DIR, "Inner")])
        let parentResult = await probe(outer, home: home, options: options, spy: childSpy)
        #expect(parentResult.isPolicyDeferred && parentResult.childSamples == 0)
        #expect(!childSpy.trace.contains { $0.action == .sample && $0.path == inner.path })
        #expect(childSpy.allClosed)

        let unlistedSpy = FolderPresenceFileSystemSpy(descriptorMount: { call, actual in
            call.path == outer.path ? eligible : actual
        })
        #expect(await probe(inner, home: home, options: options, spy: unlistedSpy).isPolicyDeferred)
        #expect(!unlistedSpy.trace.contains { $0.action == .sample && $0.path == inner.path })
        #expect(unlistedSpy.allClosed)
    }

    @Test
    func remoteIdentityOrMaterializationFailureDefersBeforeEnumeration() async throws {
        let home = try fixture()
        defer { remove(home) }
        let remote = try folder("Remote", in: home)
        let mount = share(at: remote)
        let options = SidebarBackgroundCheckOptions(network: true)
        let cases = [
            ("missing birth time", remoteSpy(mount: mount, sampleIdentity: { call, original in
                var value = original
                if call.path == remote.path { value.st_birthtimespec = timespec() }
                return value
            })),
            ("dataless", remoteSpy(mount: mount, sampleIdentity: { call, original in
                var value = original
                if call.path == remote.path { value.st_flags |= UInt32(SF_DATALESS) }
                return value
            })),
        ]
        for (reason, spy) in cases {
            let result = await probe(remote, home: home, options: options, spy: spy)
            #expect(result.isPolicyDeferred, "\(reason)")
            #expect(!spy.trace.contains { $0.action == .stream }, "\(reason)")
            #expect(spy.allClosed)
        }
    }

    @Test
    func changedRemoteMountDuringFinalWalkDiscardsEnumeration() async throws {
        let home = try fixture()
        defer { remove(home) }
        let remote = try folder("Remote", in: home)
        try Data().write(to: remote.appendingPathComponent("File"))
        let spy = remoteSpy(mount: share(at: remote), changeMount: { call, proven in
            guard call.mode == .search, call.streamIsOpen else { return proven }
            return FolderPresenceMount(path: proven.path, type: proven.type,
                                       fsid: SIMD2(proven.fsid.x, 700), flags: proven.flags)
        })
        let result = await probe(remote, home: home, options: .init(network: true), spy: spy)
        #expect(result.isPolicyDeferred && result.directoryIdentity == nil && result.entriesExamined == 1)
        let trace = spy.trace
        let mounts = trace.filter { $0.action == .mount && $0.path == remote.path }
        #expect(mounts.map(\.mode) == [.search, .enumerate, .search])
        #expect(mounts.map(\.streamIsOpen) == [false, false, true])
        let finalMount = try #require(trace.lastIndex { $0.action == .mount && $0.path == remote.path })
        #expect(trace.dropFirst(finalMount + 1).allSatisfy { $0.action == .close })
        #expect(spy.allClosed)
    }

    @Test
    func datalessRootDuringFinalWalkDefersOptInWhileLegacyErrorsKeepTheirOutcome() async throws {
        let home = try fixture()
        defer { remove(home) }
        let library = try folder("Library", in: home)
        let cloud = try folder("CloudStorage", in: library)
        let remote = try folder("Remote", in: home)
        let local = try folder("Ordinary", in: home)
        let cases: [(URL, SidebarBackgroundCheckOptions, FolderChildPresenceUncertainty)] = [
            (cloud, .init(cloud: true), .policyDeferred),
            (remote, .init(network: true), .policyDeferred),
            (local, .init(), .transient),
        ]
        for (url, options, expected) in cases {
            let change: @Sendable (FolderPresenceFileSystemSpy.Call, stat) -> stat = { call, original in
                var value = original
                if call.action == .sample, call.path == url.path, call.occurrence == 2 {
                    value.st_flags |= UInt32(SF_DATALESS)
                }
                return value
            }
            let spy = options.network
                ? remoteSpy(mount: share(at: url), sampleIdentity: change, entries: [])
                : FolderPresenceFileSystemSpy(sampleIdentity: change, entries: [])
            let result = await probe(url, home: home, options: options, spy: spy)
            #expect(result.uncertainty == expected && result.directoryIdentity == nil)
            let trace = spy.trace
            #expect(trace.contains { $0.action == .stream })
            let refusal = try #require(trace.firstIndex {
                $0.action == .sample && $0.path == url.path && $0.occurrence == 2
            })
            #expect(trace.dropFirst(refusal + 1).allSatisfy { $0.action == .close })
            #expect(spy.allClosed)
        }

        let localityError = FolderPresenceFileSystemSpy(before: {
            if $0.action == .locality, $0.path == cloud.path, $0.occurrence == 2 { throw POSIXError(.EIO) }
        }, entries: [])
        #expect(await probe(cloud, home: home, options: .init(cloud: true), spy: localityError)
            .uncertainty == .transient)
        #expect(localityError.allClosed)
    }

    @Test
    func malformedAndExcludedPathsAvoidMountInventoryEvenWhenAllOptionsAreOn() async throws {
        let home = try fixture()
        defer { remove(home) }
        let options = SidebarBackgroundCheckOptions(protectedLocal: true, cloud: true, network: true)
        let invalid = [
            try #require(URL(string: "file://remote.invalid/private/tmp/Target")),
            try #require(URL(string: "https://example.invalid/folder")),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
            URL(fileURLWithPath: "/Network/Share", isDirectory: true),
            URL(fileURLWithPath: "/private/net/host", isDirectory: true),
            URL(fileURLWithPath: "/System/Volumes/Data/home/elsewhere", isDirectory: true),
            URL(fileURLWithPath: home.path + "/Bad/../Target", isDirectory: true),
            URL(fileURLWithPath: home.path + "/Bad//Target", isDirectory: true),
        ]
        let spy = FolderPresenceFileSystemSpy()
        for url in invalid {
            #expect(await probe(url, home: home, options: options, spy: spy).isPolicyDeferred, "\(url)")
        }
        #expect(spy.trace.isEmpty)
    }

    @Test
    func mountInventoryErrorsAndFullBuffersFailClosed() async throws {
        let home = try fixture()
        defer { remove(home) }
        let spy = FolderPresenceFileSystemSpy(inventory: { throw POSIXError(.EIO) })
        let result = await probe(home, home: home, options: .init(network: true), spy: spy)
        #expect(result.isPolicyDeferred && result.mountInventoryOperations == 1)
        #expect(spy.trace.map(\.action) == [.inventory])

        for (reported, fill, expectedCalls) in [(-1, 0, 1), (0, 0, 1), (1_024, 0, 1), (1_023, -1, 2),
                                                (1_023, 1_024, 2), (1_023, 1_025, 2)] {
            var calls = 0
            #expect(throws: FolderPresenceMountSnapshot.Failure.self) {
                try DarwinFolderPresenceFileSystem.readMountInventory { buffer, bytes, flags in
                    calls += 1
                    #expect(flags == MNT_NOWAIT)
                    if buffer == nil {
                        #expect(bytes == 0)
                        return Int32(reported)
                    }
                    #expect(Int(bytes) == 1_024 * MemoryLayout<statfs>.stride)
                    return Int32(fill)
                }
            }
            #expect(calls == expectedCalls)
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func nativeUnprivilegedMountInventoryAndDescriptorAgreeOnNonzeroFilesystemID() async throws {
        let home = try fixture()
        defer { remove(home) }
        let fileSystem = DarwinFolderPresenceFileSystem()
        let descriptor = home.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        try #require(descriptor >= 0)
        defer { fileSystem.close(descriptor) }
        let sample = try fileSystem.mount(for: descriptor)
        let inventory = try fileSystem.mountInventory()
        let entry = try #require(inventory.first { $0.path == sample.path && $0.type == sample.type })
        #expect(sample.isLocal && sample.fsid != .zero && entry.fsid != .zero && sample.fsid == entry.fsid)
        print("Unprivileged mount proof type=\(sample.type) fstatfs=\(sample.fsid.x),\(sample.fsid.y) getfsstat=\(entry.fsid.x),\(entry.fsid.y) local=\(sample.isLocal)")
        let result = await LocalFolderChildPresenceChecker().check(
            .init(url: home, showHidden: false, homeURL: home, options: .init(network: true)))
        #expect(result.presence == .absent && result.directoryIdentity != nil && result.mountInventoryOperations == 1)
    }

    private func probe(_ url: URL, home: URL, options: SidebarBackgroundCheckOptions = .init(),
                       grants: Set<URL> = [], spy: FolderPresenceFileSystemSpy) async -> FolderChildPresenceResult {
        await LocalFolderChildPresenceChecker(fileSystem: spy).check(
            .init(url: url, showHidden: false, homeURL: home, openedProtectedScopes: grants, options: options))
    }

    private func entry<T: BinaryInteger>(_ type: T, _ name: String?) -> FolderPresenceEntry {
        FolderPresenceEntry(type: Int32(type), name: name)
    }

    private func share(at url: URL) -> FolderPresenceMount {
        FolderPresenceMount(path: url.path, type: "smbfs", fsid: SIMD2(Int32.min + 1, Int32.max), flags: 0)
    }

    private func remoteSpy(
        mount: FolderPresenceMount, additionalMounts: [FolderPresenceMount] = [],
        before: @escaping @Sendable (FolderPresenceFileSystemSpy.Call) throws -> Void = { _ in },
        changeMount: @escaping @Sendable (FolderPresenceFileSystemSpy.Call, FolderPresenceMount) -> FolderPresenceMount =
            { _, value in value },
        sampleIdentity: @escaping @Sendable (FolderPresenceFileSystemSpy.Call, stat) -> stat = { _, value in value },
        entries: [FolderPresenceEntry]? = nil
    ) -> FolderPresenceFileSystemSpy {
        let applies: @Sendable (String) -> Bool = { $0 == mount.path || $0.hasPrefix(mount.path + "/") }
        return FolderPresenceFileSystemSpy(before: before, locality: { path, local in !applies(path) && local },
            inventory: { [FolderPresenceFileSystemSpy.localMount, mount] + additionalMounts },
            descriptorMount: { call, actual in applies(call.path) ? changeMount(call, mount) : actual },
            sampleIdentity: sampleIdentity, entries: entries)
    }

    @Test
    func uncertainForegroundPackageClassificationDoesNotProveAbsence() {
        let url = URL(fileURLWithPath: "/fictional/package-check", isDirectory: true)
        let result = LocalDirectoryLoader.structuralFolder(at: url, isDirectory: true, isSymbolicLink: false,
            packageStatus: { _ in throw CocoaError(.fileReadNoPermission) })
        #expect(!result.isFolder && !result.isKnown)
    }

    private func fixture() throws -> URL {
        let url = try folder("ExplorerPresence-" + UUID().uuidString, in: FileManager.default.temporaryDirectory)
        return try FileSystemPath.resolvingExisting(url)
    }

    private func folder(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
