import Foundation
import Testing
@testable import ExplorerApp

struct FinderTagCatalogTests {
    @Test func configuredRowsKeepNativeOrderAndUnusedColorlessNames() {
        let catalog = FinderTagCatalog(configuredRows: [
            ("Unused custom", nil), ("Colored custom", NSNumber(value: 7)), ("No color", NSNumber(value: 0)),
        ], fallbackLabels: ["None", "Palette one"])
        #expect(catalog.isAvailable)
        #expect(catalog.configuredNames == ["Unused custom", "Colored custom", "No color"])
        #expect(catalog.labelIndex(for: "Unused custom") == 0)
        #expect(catalog.labelIndex(for: "Colored custom") == 7)
        #expect(catalog.labelIndex(for: "No color") == 0)
        #expect(catalog.labelIndex(for: "Palette one") == nil)
    }

    @Test func duplicateCanonicalSpellingsCollapseWithoutFoldingCaseOrAccent() {
        let catalog = FinderTagCatalog(configuredRows: [
            ("Re\u{301}sume\u{301}", 3), ("Résumé", 3), ("résumé", 1), ("Resume", 2), ("", 5),
        ], fallbackLabels: [])
        #expect(catalog.configuredNames == ["Résumé", "résumé", "Resume"])
        #expect(catalog.configuredNames[0].utf8.elementsEqual("Résumé".utf8))
        #expect(catalog.labelIndex(for: "Re\u{301}sume\u{301}") == 3)
        #expect(catalog.labelIndex(for: "résumé") == 1)
        #expect(catalog.labelIndex(for: "Resume") == 2)
    }

    @Test func invalidLabelMetadataKeepsNamesWithUnknownColor() {
        let invalid: [Any] = [-1, 8, NSNumber(value: true), NSNumber(value: 2.5), "4", NSNull()]
        let names = invalid.indices.map { "Synthetic \($0)" }
        let catalog = FinderTagCatalog(configuredRows: names.enumerated().map { ($0.element, invalid[$0.offset]) }, fallbackLabels: [])
        #expect(catalog.configuredNames == names)
        for name in names {
            #expect(catalog.contains(name))
            #expect(catalog.labelIndex(for: name) == nil)
        }
        #expect(!catalog.contains("Not present"))
        #expect(catalog.labelIndex(for: "Not present") == nil)
    }

    @Test func stalledReadersShareOneCallAndIgnoreItsLateSuccess() async throws {
        let gate = CatalogGate()
        defer { gate.release.signal() }
        let reader = FinderTagCatalogReader(readConfigured: gate.read, readFallback: gate.fallback, scheduleTimeout: gate.schedule)
        let one = Task { await reader.load() }
        let two = Task { await reader.load() }
        try await waitForCatalog { await reader.waiterCount == 2 && gate.started }
        #expect(gate.calls == 1)
        gate.expire()
        let first = await one.value
        let second = await two.value
        #expect(!first.isAvailable && !second.isAvailable)
        #expect(first.labelIndex(for: "Fallback") == 1)
        let duringStall = await reader.load()
        #expect(!duringStall.isAvailable && gate.calls == 1)
        gate.release.signal()
        try await waitForCatalog { await !reader.readInProgress }
        let retry = await reader.load()
        #expect(retry.isAvailable && retry.contains("Read 2") && !retry.contains("Read 1"))
        #expect(gate.calls == 2)
    }

    @Test func cancellingOneSharedReadPreservesTheOtherWaiter() async throws {
        let gate = CatalogGate()
        defer { gate.release.signal() }
        let reader = FinderTagCatalogReader(readConfigured: gate.read, readFallback: gate.fallback, scheduleTimeout: gate.schedule)
        let cancelled = Task { await reader.load() }
        let retained = Task { await reader.load() }
        try await waitForCatalog { await reader.waiterCount == 2 && gate.started }
        cancelled.cancel()
        let stopped = await cancelled.value
        #expect(!stopped.isAvailable)
        gate.release.signal()
        let found = await retained.value
        #expect(found.configuredNames == ["Read 1"] && gate.calls == 1)
    }

    @Test func emptyConfiguredListAndUnavailableListHaveDifferentMeaning() {
        let labels = ["No label", "Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange", "Extra"]
        let unavailable = FinderTagCatalog(configuredRows: nil, fallbackLabels: labels)
        #expect(!unavailable.isAvailable)
        #expect(unavailable.configuredNames == Array(labels[1...7]))
        #expect(unavailable.labelIndex(for: "Rouge") == 6)
        #expect(unavailable.labelIndex(for: "No label") == nil)
        #expect(unavailable.labelIndex(for: "Extra") == nil)
        let empty = FinderTagCatalog(configuredRows: [], fallbackLabels: labels)
        #expect(empty.isAvailable)
        #expect(empty.configuredNames.isEmpty)
        #expect(empty.labelIndex(for: "Rouge") == nil)
    }
}

private final class CatalogGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var timeout: (@Sendable () -> Void)?
    var calls: Int { lock.withLock { count } }
    var started: Bool { lock.withLock { count > 0 && timeout != nil } }

    func schedule(_ action: @escaping @Sendable () -> Void) { lock.withLock { timeout = action } }
    func expire() { let action = lock.withLock { timeout }; action?() }

    func read() -> FinderTagCatalog? {
        let index = lock.withLock { count += 1; return count }
        if index == 1 { _ = release.wait(timeout: .now() + 5) }
        return FinderTagCatalog(configuredRows: [("Read \(index)", 4)], fallbackLabels: [])
    }

    func fallback() -> FinderTagCatalog { FinderTagCatalog(configuredRows: nil, fallbackLabels: ["None", "Fallback"]) }
}

private func waitForCatalog(_ ready: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await ready()) {
        guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(for: .milliseconds(2))
    }
}
