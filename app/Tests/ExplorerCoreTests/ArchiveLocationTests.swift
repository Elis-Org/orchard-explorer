import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ArchiveLocationTests {
    @Test func canonicalEncodingHasExplicitContainerBoundary() throws {
        let location = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/Bundle.zip"), components: ["inside"])
        #expect(location.url.absoluteString == "maxplorer-zip://archive/tmp/Bundle.zip/inside?file=file%3A%2F%2F%2Ftmp%2FBundle.zip")
        #expect(location.displayPath == "/tmp/Bundle.zip/inside")
        #expect(ArchiveLocation(url: location.url) == location)
        #expect(!location.url.isFileURL)
    }

    @Test func delimiterUnicodeAndNormalizationVariantsRoundTripWithoutColliding() throws {
        let container = URL(fileURLWithPath: "/tmp/A & = + % # ? ; space 東京.zip")
        let names = ["&=+%#?; space 東京", "café", "cafe\u{301}", "Case", "case"]
        let values = try names.map { try ArchiveLocation(archiveURL: container, components: [$0]) }
        #expect(Set(values).count == names.count)
        #expect(Set(values.map(\.url.absoluteString)).count == names.count)
        for (value, name) in zip(values, names) {
            let decoded = try #require(ArchiveLocation(url: value.url))
            #expect(Data(decoded.components[0].utf8) == Data(name.utf8))
            #expect(decoded.archiveURL.path == container.path)
        }
    }

    @Test func noncanonicalAndAmbiguousURLsAreRejected() throws {
        let root = try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/Bundle.zip"))
        for text in [
            root.url.absoluteString + "&extra=1",
            root.url.absoluteString + "#fragment",
            "maxplorer-zip://archive/tmp/Bundle.zip/../escape?file=file%3A%2F%2F%2Ftmp%2FBundle.zip",
            "maxplorer-zip://archive/tmp/Bundle.zip/a%2Fb?file=file%3A%2F%2F%2Ftmp%2FBundle.zip",
            "maxplorer-zip://archive/tmp/Other.zip/a?file=file%3A%2F%2F%2Ftmp%2FBundle.zip",
            "maxplorer-zip://archive/tmp/Bundle.zip/?file=file%3A%2F%2F%2Ftmp%2FBundle.zip",
            "maxplorer-zip://archive/tmp/Bundle.zip?file=file:///tmp/Bundle.zip"
        ] { #expect(ArchiveLocation(url: try #require(URL(string: text))) == nil) }
    }

    @Test func parentsBreadcrumbsAndDepartedChildCrossBoundary() throws {
        let archive = URL(fileURLWithPath: "/tmp/Fixture/Bundle.zip")
        let nested = try ArchiveLocation(archiveURL: archive, components: ["inside", "nested"])
        let root = try ArchiveLocation(archiveURL: archive)
        let inside = try ArchiveLocation(archiveURL: archive, components: ["inside"])
        let physicalParent = URL(fileURLWithPath: "/tmp/Fixture", isDirectory: true)
        #expect(nested.parentURL == inside.url)
        #expect(root.parentURL.path == physicalParent.path)
        #expect(nested.breadcrumbURLs.map { BrowsingLocation(url: $0)!.name } == ["/", "tmp", "Fixture", "Bundle.zip", "inside", "nested"])
        #expect(BrowsingLocation.childOnPath(from: nested.url, to: physicalParent) == archive)
        #expect(BrowsingLocation.childOnPath(from: nested.url, to: root.url) == inside.url)
        #expect(BrowsingLocation.childOnPath(from: root.url, to: nested.url) == nil)
    }

    @Test func physicalTrailingSlashStillDeduplicatesWhileArchiveBytesRemainDistinct() throws {
        let a = try #require(BrowsingLocation(url: URL(fileURLWithPath: "/tmp/a", isDirectory: false)))
        let b = try #require(BrowsingLocation(url: URL(fileURLWithPath: "/tmp/a", isDirectory: true)))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        var history = NavigationHistory(initialURL: a.url)
        history.navigate(to: b.url)
        #expect(!history.canGoBack)
        for bad in [[".."], ["."], ["a/b"], ["a\\b"], [""], ["a\0b"]] {
            #expect(throws: Error.self) { try ArchiveLocation(archiveURL: URL(fileURLWithPath: "/tmp/a.zip"), components: bad) }
        }
    }
}
