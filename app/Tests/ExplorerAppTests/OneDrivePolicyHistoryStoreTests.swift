import Darwin
import Foundation
import Testing
@testable import ExplorerCore
@testable import ExplorerApp

private final class PolicyHistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ seconds: TimeInterval = 2_000_000_000) { value = Date(timeIntervalSince1970: seconds) }
    func read() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

private struct PolicyHistoryFixture {
    typealias Store = OneDrivePolicyHistoryStore
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("policy-history-\(UUID().uuidString)", isDirectory: true)
    let clock = PolicyHistoryClock()
    func store(limits: Store.Limits = .init()) -> Store {
        Store(directory: directory, limits: limits, wallNow: clock.read)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func identity(_ leaf: String = "private-distinctive-leaf-%25.txt", inode: UInt64 = 17,
                  nanos: Int64 = 19, root: String = "private-account-distinctive",
                  parentInode: UInt64 = 11, provider: String = "26.1 (17)",
                  linkCount: UInt64 = 1) -> Store.Identity {
        let rootURL = "file:///Users/synthetic/Library/CloudStorage/OneDrive-\(root)/"
        return .init(namespace: .init(rootURL: rootURL,
            rootIdentity: .init(device: 1, inode: 7, birthSeconds: 100, birthNanoseconds: 3),
            providerIdentifier: "com.microsoft.OneDrive", providerVersion: provider,
            providerStamp: "private-provider-stamp"),
            parentURL: rootURL + "private-parent/",
            parentIdentity: .init(device: 1, inode: parentInode, birthSeconds: 101, birthNanoseconds: 5),
            fileURL: rootURL + "private-parent/" + leaf,
            fileIdentity: .init(device: 1, inode: inode, birthSeconds: 102, birthNanoseconds: 7,
                                linkCount: linkCount),
            version: .init(size: 4_096, modificationSeconds: 1_999_999_900, modificationNanoseconds: nanos))
    }
    func prepared(_ store: Store, _ identity: Store.Identity? = nil) async throws -> Store.Prepared {
        let values = await store.prepare([identity ?? self.identity()])
        #expect(values[0] != nil, Comment(rawValue: "History setup: \(store.diagnostic)"))
        return try #require(values.first ?? nil)
    }
    func save(_ store: Store, _ identity: Store.Identity? = nil,
              policy: OneDriveRetentionPolicy = .pinned, date: Date? = nil) async throws -> Store.Ticket {
        let prepared = try await prepared(store, identity)
        store.enqueue(.init(policy: policy, confirmedAt: date ?? clock.read()), ticket: prepared.ticket)
        await store.flush()
        return prepared.ticket
    }
    var dataURL: URL { directory.appendingPathComponent("history-v1.json") }
    var idURL: URL { directory.appendingPathComponent("store-id-v1.json") }
    func object(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func rewrite(_ value: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
}

struct OneDrivePolicyHistoryStoreTests {
    typealias Store = OneDrivePolicyHistoryStore

    @Test func confirmedPoliciesRoundTripWithOriginalDates() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let first = f.store()
        let policies: [OneDriveRetentionPolicy] = [.none, .pinned, .unpinned]
        for (index, policy) in policies.enumerated() {
            _ = try await f.save(first, f.identity("leaf-\(index)", inode: UInt64(20 + index)),
                policy: policy, date: f.clock.read().addingTimeInterval(-Double(index)))
        }
        let second = f.store()
        for (index, policy) in policies.enumerated() {
            let value = try await f.prepared(second, f.identity("leaf-\(index)", inode: UInt64(20 + index)))
            #expect(value.hint?.policy == policy)
            #expect(value.hint?.confirmedAt == f.clock.read().addingTimeInterval(-Double(index)))
        }
    }

    @Test func hashedIdentitySeparatesRawSpellingNamespaceAndVersion() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let store = f.store(), base = try await f.prepared(store)
        let variants = [f.identity(nanos: 20), f.identity(inode: 18), f.identity(parentInode: 12),
                        f.identity(provider: "26.1 (18)"), f.identity(root: "another-account"),
                        f.identity("private-distinctive-leaf-%2525.txt")]
        let results = await store.prepare(variants)
        for value in results { #expect(value?.ticket.key.full != base.ticket.key.full) }
        #expect(results[0]?.ticket.key.route == base.ticket.key.route)
        #expect(results[1]?.ticket.key.route == base.ticket.key.route)
        #expect(results[2]?.ticket.key.route == base.ticket.key.route)
        #expect(results[3]?.ticket.key.route != base.ticket.key.route)
        #expect(results[4]?.ticket.key.route != base.ticket.key.route)
        let linked = try await f.prepared(store, f.identity(linkCount: 2))
        #expect(linked.ticket.key == base.ticket.key)
        let unicode = await store.prepare([f.identity("caf\u{00e9}"), f.identity("cafe\u{0301}")])
        #expect(unicode[0]?.ticket.key != unicode[1]?.ticket.key)
        #expect(base.ticket.key.route != base.ticket.key.full)
        let other = PolicyHistoryFixture(); defer { other.clean() }
        let differentlySalted = try await other.prepared(other.store())
        #expect(differentlySalted.ticket.key != base.ticket.key)
    }

    @Test func documentContainsOnlyPrivateDigestsAndOwnerOnlyFiles() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        _ = try await f.save(f.store())
        let urls = try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
        for url in urls {
            let bytes = try Data(contentsOf: url)
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in ["private-distinctive-leaf", "private-account-distinctive", "private-parent",
                           "private-provider-stamp", "file:///", "com.microsoft.OneDrive"] {
                #expect(!text.contains(secret))
            }
            var value = stat()
            #expect(lstat(url.path, &value) == 0)
            #expect(value.st_mode & 0o077 == 0)
        }
        var directory = stat()
        #expect(lstat(f.directory.path, &directory) == 0)
        #expect(directory.st_mode & 0o077 == 0)
    }

    @Test func expiresAtBoundaryRejectsFutureAndHandlesClockRollback() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        var limits = Store.Limits(); limits.retention = 10
        let store = f.store(limits: limits), date = f.clock.read()
        _ = try await f.save(store)
        f.clock.set(date.addingTimeInterval(9.999))
        #expect(try await f.prepared(store).hint != nil)
        f.clock.set(date.addingTimeInterval(10))
        #expect(try await f.prepared(store).hint == nil)
        f.clock.set(date.addingTimeInterval(-1))
        #expect(try await f.prepared(store).hint == nil)
        let future = try await f.prepared(store, f.identity("future"))
        store.enqueue(.init(policy: .pinned, confirmedAt: date), ticket: future.ticket)
        store.enqueue(.init(policy: .pinned, confirmedAt: Date(timeIntervalSince1970: .nan)),
                      ticket: future.ticket)
        await store.flush()
        #expect(try await f.prepared(f.store(limits: limits), f.identity("future")).hint == nil)
    }

    @Test func twoWritersMergeUnrelatedRoutesAndKeepNewerEqualKey() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let a = f.store(), b = f.store()
        let aa = try await f.prepared(a, f.identity("a")), bb = try await f.prepared(b, f.identity("b"))
        a.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: aa.ticket)
        b.enqueue(.init(policy: .none, confirmedAt: f.clock.read()), ticket: bb.ticket)
        async let aFlushed: Void = a.flush()
        async let bFlushed: Void = b.flush()
        _ = await (aFlushed, bFlushed)
        let reader = f.store()
        #expect(try await f.prepared(reader, f.identity("a")).hint?.policy == .pinned)
        #expect(try await f.prepared(reader, f.identity("b")).hint?.policy == OneDriveRetentionPolicy.none)
        let same = try await f.prepared(b, f.identity("a"))
        b.enqueue(.init(policy: .unpinned, confirmedAt: f.clock.read().addingTimeInterval(-1)), ticket: same.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store(), f.identity("a")).hint?.policy == .pinned)
        b.enqueue(.init(policy: .unpinned, confirmedAt: f.clock.read()), ticket: same.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store(), f.identity("a")).hint?.policy == .pinned)
        f.clock.set(f.clock.read().addingTimeInterval(1))
        b.enqueue(.init(policy: .unpinned, confirmedAt: f.clock.read()), ticket: same.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store(), f.identity("a")).hint?.policy == .unpinned)
    }

    @Test func invalidationFencesOldWriterAndRefreshesItsNextTicket() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let a = f.store(), b = f.store()
        let old = try await f.prepared(b)
        let invalidated = await a.invalidate(f.identity())
        let actionTicket = try #require(invalidated)
        #expect(actionTicket.epoch != old.ticket.epoch)
        b.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: old.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store()).hint == nil)
        let fresh = try await f.prepared(b)
        #expect(fresh.ticket.epoch == actionTicket.epoch)
        b.enqueue(.init(policy: .none, confirmedAt: f.clock.read()), ticket: fresh.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store()).hint?.policy == OneDriveRetentionPolicy.none)
        #expect(try await f.prepared(f.store(), f.identity(inode: 99)).hint == nil)
    }

    @Test func invalidatingExistingRouteRemovesAllVersionsAndOperationCanSave() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let store = f.store()
        _ = try await f.save(store)
        _ = try await f.save(store, f.identity(inode: 99))
        let result = await store.invalidate(f.identity())
        let ticket = try #require(result)
        let reader = f.store()
        #expect(try await f.prepared(reader).hint == nil)
        #expect(try await f.prepared(reader, f.identity(inode: 99)).hint == nil)
        store.enqueue(.init(policy: .unpinned, confirmedAt: f.clock.read()), ticket: ticket)
        await store.flush()
        #expect(try await f.prepared(f.store()).hint?.policy == .unpinned)
    }

    @Test func fenceCompactionRotatesIncarnationWithoutChangingSaltOrSurvivingHints() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        var limits = Store.Limits(); limits.fences = 1
        let a = f.store(limits: limits), b = f.store(limits: limits)
        let saved = try await f.save(a, f.identity("saved"))
        let oldAbsent = try await f.prepared(b, f.identity("absent"))
        _ = await a.invalidate(f.identity("first"))
        _ = await a.invalidate(f.identity("second"))
        let retained = try await f.prepared(a, f.identity("saved"))
        #expect(retained.hint?.policy == .pinned)
        #expect(retained.ticket.incarnation != saved.incarnation)
        #expect(retained.ticket.key == saved.key)
        b.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: oldAbsent.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store(limits: limits), f.identity("absent")).hint == nil)
        let renewed = try await f.prepared(b, f.identity("absent"))
        #expect(renewed.ticket.incarnation == retained.ticket.incarnation)
        b.enqueue(.init(policy: .none, confirmedAt: f.clock.read()), ticket: renewed.ticket)
        await b.flush()
        #expect(try await f.prepared(f.store(limits: limits), f.identity("absent")).hint?.policy == OneDriveRetentionPolicy.none)
    }

    @Test func purgedCacheCannotBeRecreatedByOldWorkerOrItsPendingWrites() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let old = f.store(), prepared = try await f.prepared(old)
        try FileManager.default.removeItem(at: f.dataURL)
        old.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: prepared.ticket)
        await old.flush()
        #expect(!FileManager.default.fileExists(atPath: f.dataURL.path))
        let disabled = await old.prepare([f.identity()])
        #expect(disabled[0] == nil)
        let replacement = try await f.prepared(f.store())
        #expect(replacement.ticket.incarnation != prepared.ticket.incarnation)
        #expect(replacement.hint == nil)
        old.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: prepared.ticket)
        await old.flush()
        #expect(try await f.prepared(f.store()).hint == nil)
    }

    @Test func corruptedOversizedAndInterruptedPairRecoverWithoutOldHints() async throws {
        for mode in 0..<4 {
            let f = PolicyHistoryFixture(); defer { f.clean() }
            var limits = Store.Limits(); limits.bytes = 4_096
            let old = f.store(limits: limits), oldTicket = try await f.save(old)
            if mode == 0 { try Data("{broken".utf8).write(to: f.dataURL) }
            if mode == 1 { try Data(repeating: 0, count: 4_097).write(to: f.dataURL) }
            if mode == 2 {
                var object = try f.object(f.idURL); object["incarnation"] = UUID().uuidString
                try f.rewrite(object, at: f.idURL)
            }
            if mode == 3 {
                var object = try f.object(f.dataURL); object["schema"] = 99
                try f.rewrite(object, at: f.dataURL)
            }
            let new = try await f.prepared(f.store(limits: limits))
            #expect(new.hint == nil)
            #expect(new.ticket.incarnation != oldTicket.incarnation)
            old.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: oldTicket)
            await old.flush()
            #expect(try await f.prepared(f.store(limits: limits)).hint == nil)
        }
    }

    @Test func entryAndByteBoundsPruneOldestConfirmation() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        var limits = Store.Limits(); limits.entries = 2; limits.bytes = 2_048
        let store = f.store(limits: limits)
        for index in 0..<3 {
            _ = try await f.save(store, f.identity("leaf-\(index)"),
                date: f.clock.read().addingTimeInterval(Double(index) - 3))
        }
        let reader = f.store(limits: limits)
        #expect(try await f.prepared(reader, f.identity("leaf-0")).hint == nil)
        #expect(try await f.prepared(reader, f.identity("leaf-1")).hint != nil)
        #expect(try await f.prepared(reader, f.identity("leaf-2")).hint != nil)
        #expect(try Data(contentsOf: f.dataURL).count <= limits.bytes)
    }

    @Test func refusesSymbolicLinksAndLeavesTheirTargetsUntouched() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        _ = try await f.save(f.store())
        let original = try Data(contentsOf: f.dataURL)
        let target = f.directory.appendingPathComponent("unrelated-target")
        try original.write(to: target)
        try FileManager.default.removeItem(at: f.dataURL)
        try FileManager.default.createSymbolicLink(at: f.dataURL, withDestinationURL: target)
        let values = await f.store().prepare([f.identity()])
        #expect(values[0] == nil)
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func currentTicketIsOnlyAvailableForPreparedKeysAndTracksCommittedEpochs() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let a = f.store(), b = f.store()
        let previous = try await f.prepared(a)
        #expect(b.currentTicket(for: previous.ticket) == nil)
        #expect(a.currentTicket(for: previous.ticket)?.epoch == previous.ticket.epoch)
        let invalidated = await a.invalidate(f.identity())
        let next = try #require(a.currentTicket(for: previous.ticket))
        #expect(next.epoch == invalidated?.epoch)
        #expect(next.epoch != previous.ticket.epoch)
        a.enqueue(.init(policy: .pinned, confirmedAt: f.clock.read()), ticket: previous.ticket)
        await a.flush()
        #expect(try await f.prepared(f.store()).hint == nil)
        a.enqueue(.init(policy: .none, confirmedAt: f.clock.read()), ticket: next)
        await a.flush()
        #expect(try await f.prepared(f.store()).hint?.policy == OneDriveRetentionPolicy.none)
    }

    @Test func refusesRedirectedParentMissingParentAndInsecureExistingDirectory() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let real = f.directory.appendingPathComponent("real", isDirectory: true)
        let link = f.directory.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let redirected = Store(directory: link.appendingPathComponent("cache"), wallNow: f.clock.read)
        #expect((await redirected.prepare([f.identity()]))[0] == nil)
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("cache").path))
        let missing = f.directory.appendingPathComponent("missing", isDirectory: true)
        let nested = Store(directory: missing.appendingPathComponent("cache"), wallNow: f.clock.read)
        #expect((await nested.prepare([f.identity()]))[0] == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let insecure = f.directory.appendingPathComponent("insecure", isDirectory: true)
        try FileManager.default.createDirectory(at: insecure, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        let refused = Store(directory: insecure, wallNow: f.clock.read)
        #expect((await refused.prepare([f.identity()]))[0] == nil)
        var value = stat(); #expect(lstat(insecure.path, &value) == 0)
        #expect(value.st_mode & 0o777 == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: insecure.path).isEmpty)
    }

    @Test func duplicateAndInvalidRowsAreSkippedWithoutDroppingOtherObservations() async throws {
        let f = PolicyHistoryFixture(); defer { f.clean() }
        let store = f.store()
        let first = try await f.save(store, f.identity("duplicate"))
        _ = try await f.save(store, f.identity("surviving"), policy: .unpinned)
        var document = try f.object(f.dataURL)
        var rows = try #require(document["records"] as? [[String: Any]])
        let duplicate = try #require(rows.first { $0["full"] as? String == first.key.full })
        rows.append(duplicate)
        rows.append(["full": "invalid-entry", "policy": "not-a-policy"])
        document["records"] = rows
        try f.rewrite(document, at: f.dataURL)
        let read = f.store()
        #expect(try await f.prepared(read, f.identity("duplicate")).hint == nil)
        #expect(try await f.prepared(read, f.identity("surviving")).hint?.policy == .unpinned)
    }
}
