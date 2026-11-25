import CoreServices
import Darwin
import Foundation
import Testing
@testable import ExplorerCore

/// Exercises the production Add and Content boundaries together. Public
/// quarantine events and independently read xattrs are the expected results;
/// the production companion pack/unpack helpers do not construct the oracle.
@Suite struct ZIPContentOriginIntegrationTests {
    @Test(arguments: [false, true])
    func downloadedAddsAndAttributedReplacementRoundTripThroughContent(markedOuter: Bool) async throws {
        let fixture = try ZIPOperationTestFixture(entries: [
            ZIPOperationTestEntry("replace.txt", contents: Data("old plain member".utf8)),
            ZIPOperationTestEntry("keep.txt", contents: Data("untouched".utf8))
        ])
        let first = fixture.root.appendingPathComponent("first-download.txt")
        let second = fixture.root.appendingPathComponent("second-download.txt")
        let plain = fixture.root.appendingPathComponent("plain-source.txt")
        let firstBytes = Data("first downloaded bytes".utf8), secondBytes = Data("replacement downloaded bytes".utf8)
        let plainBytes = Data("plain sibling bytes".utf8)
        try firstBytes.write(to: first); try secondBytes.write(to: second); try plainBytes.write(to: plain)
        try markDownload(first, label: "First")
        try markDownload(second, label: "Second")
        if markedOuter { try markDownload(fixture.url, label: "Outer") }
        let firstOrigin = try observedOrigin(first), secondOrigin = try observedOrigin(second)
        let plainOrigin = try observedOrigin(plain), outerOrigin = try observedOrigin(fixture.url)
        let firstPublic = try publicOrigin(first), secondPublic = try publicOrigin(second), outerPublic = try publicOrigin(fixture.url)
        #expect(firstOrigin.quarantine != nil && secondOrigin.quarantine != nil)
        #expect(firstOrigin.whereFroms != secondOrigin.whereFroms)
        #expect(firstPublic[kLSQuarantineAgentNameKey as String] as? String == "First")
        #expect(secondPublic[kLSQuarantineAgentNameKey as String] as? String == "Second")
        let firstEvent = try #require(firstPublic["LSQuarantineEventIdentifier"] as? String)
        let secondEvent = try #require(secondPublic["LSQuarantineEventIdentifier"] as? String)
        #expect(firstEvent != secondEvent)
        #expect(plainOrigin == ZIPOriginAttributes(quarantine: nil, whereFroms: nil))

        let imported = try await LocalFileTransferImporter().capture(urlStrings: [first.absoluteString, second.absoluteString, plain.absoluteString])
        let firstEntry = try #require(imported.first { $0.item.name == first.lastPathComponent })
        let secondEntry = try #require(imported.first { $0.item.name == second.lastPathComponent })
        let plainEntry = try #require(imported.first { $0.item.name == plain.lastPathComponent })
        let context = try await fixture.context(), replacementLocation = try fixture.location(["replace.txt"])
        let result = try await LocalArchiveOperations().modify([
            .add(source: firstEntry, destination: fixture.location(["first.txt"]), replacing: nil),
            .add(source: secondEntry, destination: replacementLocation,
                 replacing: ArchiveReplacementTarget(member: ArchiveMemberTarget(location: replacementLocation, revision: context.revision))),
            .add(source: plainEntry, destination: fixture.location(["plain.txt"]), replacing: nil)
        ], in: context, control: TransferControl(), onProgress: { _ in })
        #expect(result.verifiedDestination != nil && result.warning == nil)
        let manifest = try ZIPArchiveManifest.read(from: ZIPFileReader(url: fixture.url))
        #expect(Set(manifest.records.map { $0.components.joined(separator: "/") }) == [
            "first.txt", "replace.txt", "plain.txt", "keep.txt", "__MACOSX/._first.txt", "__MACOSX/._replace.txt"
        ])

        let registry = ContentLeaseRegistry(rootURL: fixture.root.appendingPathComponent("owned-content"))
        let provider = LocalItemContentProvider(registry: registry)
        do {
            for (name, expectedBytes, memberOrigin, memberPublic) in [
                ("first.txt", firstBytes, firstOrigin, firstPublic),
                ("replace.txt", secondBytes, secondOrigin, secondPublic),
                ("plain.txt", plainBytes, plainOrigin, [String: Any]())
            ] {
                let location = try fixture.location(), snapshot = try await LocalZIPDirectoryLoader().snapshot(of: location.url, showHidden: true)
                let item = try #require(snapshot.items.first { $0.name == name })
                let entry = ItemOperationEntry(item: item, context: .archive(ArchiveOperationContext(location: location, revision: try #require(snapshot.archiveRevision))))
                let lease = try await provider.materialize(ContentRequest(source: entry, purpose: .transfer), control: TransferControl())
                do {
                    try await lease.validateForUse()
                    #expect(try Data(contentsOf: lease.fileURL) == expectedBytes)
                    let actual = try observedOrigin(lease.fileURL)
                    #expect(actual.whereFroms == (memberOrigin.whereFroms ?? outerOrigin.whereFroms))
                    let expectedPublic = markedOuter ? outerPublic : memberPublic
                    #expect(NSDictionary(dictionary: try publicOrigin(lease.fileURL)).isEqual(to: expectedPublic))
                    #expect((actual.quarantine != nil) == (markedOuter || memberOrigin.quarantine != nil))
                } catch {
                    _ = await lease.release()
                    throw error
                }
                #expect(await lease.release().disposition == .released)
            }
        } catch {
            _ = try await registry.shutdown()
            throw error
        }
        #expect(try await registry.shutdown().isEmpty)
        for (url, bytes, origin) in [(first, firstBytes, firstOrigin), (second, secondBytes, secondOrigin), (plain, plainBytes, plainOrigin)] {
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try observedOrigin(url) == origin)
        }
        #expect(try observedOrigin(fixture.url).whereFroms == outerOrigin.whereFroms)
        #expect(NSDictionary(dictionary: try publicOrigin(fixture.url)).isEqual(to: outerPublic))
    }

    private func markDownload(_ url: URL, label: String) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                       kLSQuarantineAgentNameKey as String: label]
        var mutable = url
        try mutable.setResourceValues(values)
        let origin = try PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/" + label], format: .binary, options: 0)
        guard origin.withUnsafeBytes({ setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw POSIXError(.EIO) }
    }

    private func publicOrigin(_ url: URL) throws -> [String: Any] {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties ?? [:]
        let keys = Set([kLSQuarantineAgentNameKey as String, kLSQuarantineTimeStampKey as String,
                        kLSQuarantineTypeKey as String, "LSQuarantineEventIdentifier"])
        return values.filter { keys.contains($0.key) }
    }

    private func observedOrigin(_ url: URL) throws -> ZIPOriginAttributes {
        func attribute(_ name: String) throws -> Data? {
            let count = getxattr(url.path, name, nil, 0, 0, 0)
            if count < 0 && errno == ENOATTR { return nil }
            guard count >= 0 && count <= 256 * 1_024 else { throw POSIXError(.EIO) }
            var value = Data(count: count)
            guard value.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }) == count else { throw POSIXError(.EIO) }
            return value
        }
        return try ZIPOriginAttributes(quarantine: attribute("com.apple.quarantine"), whereFroms: attribute("com.apple.metadata:kMDItemWhereFroms"))
    }
}
