import Darwin
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ZIPAddDescriptorTests {
    @Test func heldAliasIgnoresSubstitutedStageBeforeAndDuringProvider() throws {
        for beforeOpen in [true, false] {
            let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing", contents: Data([7]))])
            try withCandidate(fixture) { fd, stage, payload in
                let moved = fixture.root.appendingPathComponent("moved"), sentinel = Data("sentinel must remain".utf8)
                func substitute() throws {
                    try FileManager.default.moveItem(at: stage, to: moved)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    try sentinel.write(to: payload)
                }
                if beforeOpen { try substitute() }
                var substituted = beforeOpen
                let bytes = Data(repeating: 42, count: 90_000)
                let entries = [
                    ZIPFoundationAddAdapter.Entry(path: "café", directory: false, size: UInt64(bytes.count), modifiedAt: Date(), permissions: 0o6751, compressed: true, provider: { position, count in
                        if !substituted { try substitute(); substituted = true }
                        return bytes.subdata(in: Int(position)..<(Int(position) + count))
                    }),
                    ZIPFoundationAddAdapter.Entry(path: "cafe\u{301}", directory: false, size: 1, modifiedAt: Date(), permissions: 0o640, compressed: false, provider: { _, _ in Data([5]) }),
                    ZIPFoundationAddAdapter.Entry(path: "empty/", directory: true, size: 0, modifiedAt: Date(), permissions: 0o755, compressed: false, provider: { _, _ in Data() })
                ]
                let result = try ZIPFoundationAddAdapter.add(entries, to: fd, diagnosticURL: payload, checkpoint: {})
                #expect(result.manifest.records.count == 4)
                #expect(Set(result.entries.map(\.pathKey)).count == 3)
                #expect(result.manifest.records[1].unixPermissions == 0o751)
                #expect(result.manifest.records[1].flags & 0x800 != 0)
                #expect(result.manifest.records[2].flags & 0x800 != 0)
                #expect(try Data(contentsOf: payload) == sentinel)
                #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
                var held = stat(), movedStat = stat()
                #expect(fstat(fd, &held) == 0)
                #expect(moved.appendingPathComponent("payload").withUnsafeFileSystemRepresentation { fstatat(AT_FDCWD, $0!, &movedStat, 0) } == 0)
                #expect(held.st_ino == movedStat.st_ino && held.st_dev == movedStat.st_dev)
                #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) == ["fixture.zip", "stage", "moved"])
            }
        }
    }

    @Test func cancellationAndProviderErrorNeverMutateOriginalOrReuseCandidate() throws {
        for cancelled in [true, false] {
            let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing")])
            try withCandidate(fixture) { fd, _, payload in
                let entry = ZIPFoundationAddAdapter.Entry(path: "new", directory: false, size: 2, modifiedAt: Date(), permissions: 0o644, compressed: true) { _, _ in
                    if cancelled { throw CancellationError() }
                    throw ArchiveOperationError.contentMismatch
                }
                #expect(throws: (any Error).self) { try ZIPFoundationAddAdapter.add([entry], to: fd, diagnosticURL: payload, checkpoint: {}) }
                #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
                // The adapter throws; its caller owns disposal and never reuses
                // potentially partial output. This test deletes only this inode.
                var held = stat(), named = stat()
                #expect(fstat(fd, &held) == 0)
                #expect(payload.withUnsafeFileSystemRepresentation { fstatat(AT_FDCWD, $0!, &named, AT_SYMLINK_NOFOLLOW) } == 0)
                #expect(held.st_ino == named.st_ino)
                try FileManager.default.removeItem(at: payload)
            }
        }
    }

    @Test func corruptOrTruncatedNominalSuccessFailsIndependentPostvalidation() throws {
        for truncated in [true, false] {
            let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing")])
            try withCandidate(fixture) { fd, _, payload in
                let entry = ZIPFoundationAddAdapter.Entry(path: "new", directory: false, size: 3, modifiedAt: Date(), permissions: 0o644, compressed: false) { _, _ in Data([1, 2, 3]) }
                #expect(throws: (any Error).self) {
                    try ZIPFoundationAddAdapter.add([entry], to: fd, diagnosticURL: payload, checkpoint: {}, afterLibrary: {
                        if truncated { #expect(ftruncate(fd, 9) == 0) }
                        else {
                            let reader = try ZIPFileReader(duplicating: fd, url: payload, validatesPath: false)
                            let manifest = try ZIPArchiveManifest.read(from: reader)
                            let layout = try ZIPRecordValidation.validate(manifest: manifest, reader: reader, scope: .mutation)
                            let last = try #require(manifest.records.last), member = try #require(layout.records[last.id])
                            try DescriptorIO.writeAll(Data([99]), to: fd, at: member.payloadRange.offset)
                        }
                    })
                }
                let originalBytes = try Data(contentsOf: fixture.url)
                #expect(originalBytes == fixture.bytes)
            }
        }
    }

    @Test func readonlyAndClosedDescriptorsRefuseWithoutPathFallback() throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing")])
        let fd = open(fixture.url.path, O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        #expect(throws: (any Error).self) { try ZIPFoundationAddAdapter.add([], to: fd, diagnosticURL: fixture.url, checkpoint: {}) }
        close(fd)
        #expect(throws: (any Error).self) { try ZIPFoundationAddAdapter.add([], to: -1, diagnosticURL: fixture.url, checkpoint: {}) }
        #expect(try Data(contentsOf: fixture.url) == fixture.bytes)
    }

    @Test func fakeEndSignatureInValidCommentRefusesBeforeProviderAllocation() throws {
        var fake = [UInt8](repeating: 0, count: 30)
        ZIPBytes.put32(0x06054b50, into: &fake, at: 0)
        ZIPBytes.put32(UInt32.max - 1, into: &fake, at: 12)
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing")], comment: Data(fake))
        try withCandidate(fixture) { fd, _, payload in
            var called = false
            let entry = ZIPFoundationAddAdapter.Entry(path: "new", directory: false, size: 1, modifiedAt: Date(), permissions: 0o644, compressed: false) { _, _ in called = true; return Data([1]) }
            #expect(throws: ArchiveOperationError.self) { try ZIPFoundationAddAdapter.add([entry], to: fd, diagnosticURL: payload, checkpoint: {}) }
            #expect(!called)
            let unchanged = try Data(contentsOf: payload)
            #expect(unchanged == fixture.bytes)
        }
    }

    @Test func optionalZIP64EnvelopeRefusesBeforeReadingProvider() throws {
        let fixture = try ZIPOperationTestFixture(entries: [ZIPOperationTestEntry("existing")])
        try withCandidate(fixture) { fd, _, payload in
            let old = Array(fixture.bytes), end = old.count - 22
            var record = [UInt8](repeating: 0, count: 56), locator = [UInt8](repeating: 0, count: 20)
            ZIPBytes.put32(0x06064b50, into: &record, at: 0); ZIPBytes.put64(44, into: &record, at: 4)
            ZIPBytes.put16(45, into: &record, at: 12); ZIPBytes.put16(45, into: &record, at: 14)
            ZIPBytes.put64(1, into: &record, at: 24); ZIPBytes.put64(1, into: &record, at: 32)
            ZIPBytes.put64(UInt64(ZIPBytes.u32(old, end + 12)), into: &record, at: 40)
            ZIPBytes.put64(UInt64(ZIPBytes.u32(old, end + 16)), into: &record, at: 48)
            ZIPBytes.put32(0x07064b50, into: &locator, at: 0); ZIPBytes.put64(UInt64(end), into: &locator, at: 8)
            ZIPBytes.put32(1, into: &locator, at: 16)
            let bytes = Data(old[..<end]) + Data(record) + Data(locator) + Data(old[end...])
            try DescriptorIO.writeAll(bytes, to: fd, at: 0)
            var called = false
            let entry = ZIPFoundationAddAdapter.Entry(path: "new", directory: false, size: 1, modifiedAt: Date(), permissions: 0o644, compressed: false) { _, _ in called = true; return Data([1]) }
            #expect(throws: ArchiveOperationError.self) { try ZIPFoundationAddAdapter.add([entry], to: fd, diagnosticURL: payload, checkpoint: {}) }
            #expect(!called)
            #expect(try Data(contentsOf: payload) == bytes)
        }
    }

    @Test func mandatoryZIP64CountRemainsValidWhenAddingThe65536thRecord() throws {
        let fixture = try ZIPOperationTestFixture(entries: (0..<65_535).map { ZIPOperationTestEntry("entry-\($0)") })
        try withCandidate(fixture) { fd, _, payload in
            let old = Array(fixture.bytes), end = old.count - 22
            var record = [UInt8](repeating: 0, count: 56), locator = [UInt8](repeating: 0, count: 20)
            ZIPBytes.put32(0x06064b50, into: &record, at: 0); ZIPBytes.put64(44, into: &record, at: 4)
            ZIPBytes.put16(45, into: &record, at: 12); ZIPBytes.put16(45, into: &record, at: 14)
            ZIPBytes.put64(65_535, into: &record, at: 24); ZIPBytes.put64(65_535, into: &record, at: 32)
            ZIPBytes.put64(UInt64(ZIPBytes.u32(old, end + 12)), into: &record, at: 40)
            ZIPBytes.put64(UInt64(ZIPBytes.u32(old, end + 16)), into: &record, at: 48)
            ZIPBytes.put32(0x07064b50, into: &locator, at: 0); ZIPBytes.put64(UInt64(end), into: &locator, at: 8)
            ZIPBytes.put32(1, into: &locator, at: 16)
            let bytes = Data(old[..<end]) + Data(record) + Data(locator) + Data(old[end...])
            try DescriptorIO.writeAll(bytes, to: fd, at: 0)
            let entry = ZIPFoundationAddAdapter.Entry(path: "last", directory: false, size: 1, modifiedAt: Date(), permissions: 0o644, compressed: false) { _, _ in Data([9]) }
            let result = try ZIPFoundationAddAdapter.add([entry], to: fd, diagnosticURL: payload, checkpoint: {})
            #expect(result.manifest.records.count == 65_536)
            let zip64 = try #require(result.manifest.envelope.rawZIP64Record)
            #expect(ZIPBytes.u64(Array(zip64), 32) == 65_536)
            #expect(result.manifest.records.last?.pathKey == Data("last".utf8))
            #expect(result.entries.first?.crc32 == zipOperationReferenceCRC(Data([9])))
        }
    }

    private func withCandidate(_ fixture: ZIPOperationTestFixture, _ body: (Int32, URL, URL) throws -> Void) throws {
        let stage = fixture.root.appendingPathComponent("stage"), payload = stage.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let fd = open(payload.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        try DescriptorIO.writeAll(fixture.bytes, to: fd, at: 0)
        try body(fd, stage, payload)
    }
}
