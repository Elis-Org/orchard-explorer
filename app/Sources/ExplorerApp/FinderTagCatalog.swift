import AppKit
import CoreServices
import Foundation

/// Finder's configured definitions are independent of Spotlight's indexed assignments.
struct FinderTagCatalog: Sendable {
    let configuredNames: [String]
    let isAvailable: Bool
    private let names: Set<String>
    private let colors: [String: Int]

    init(configuredRows: [(String, Any?)]?, fallbackLabels: [String]) {
        isAvailable = configuredRows != nil
        // NSWorkspace pairs fileLabels and fileLabelColors by index; slot zero is
        // the absence of a label. Keep localized palette names only on a source outage.
        let rows = configuredRows ?? fallbackLabels.prefix(8).enumerated().dropFirst().map { ($0.element, $0.offset) }
        var seen: Set<String> = []
        var ordered: [String] = []
        var labels: [String: Int] = [:]
        for (raw, property) in rows {
            let name = raw.precomposedStringWithCanonicalMapping
            guard !name.isEmpty else { continue }
            let index = Self.decodeLabel(property)
            if seen.insert(name).inserted {
                ordered.append(name)
                labels[name] = index
            } else if labels[name] != index {
                labels.removeValue(forKey: name)
            }
        }
        configuredNames = ordered
        names = seen
        colors = labels
    }

    func contains(_ name: String) -> Bool { names.contains(name.precomposedStringWithCanonicalMapping) }
    func labelIndex(for name: String) -> Int? { colors[name.precomposedStringWithCanonicalMapping] }

    private static func decodeLabel(_ property: Any?) -> Int? {
        guard let property else { return 0 } // Finder omits this property on an uncolored configured row.
        guard let number = property as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              (0...7).contains(number.int64Value) else { return nil }
        return Int(number.int64Value)
    }

    private static let reader = FinderTagCatalogReader(readConfigured: { readConfigured() }, readFallback: {
        FinderTagCatalog(configuredRows: nil, fallbackLabels: NSWorkspace.shared.fileLabels)
    })

    static func load() async -> Self { await reader.load() }

    private static func readConfigured() -> Self? {
        // These read APIs are documented but deprecated. The list and color key
        // are Finder identifiers observed in the native read-only catalog probe.
        guard let list = LSSharedFileListCreate(nil, "com.apple.LSSharedFileList.ProjectsItems" as CFString, nil)?.takeRetainedValue(),
              let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(snapshot)
        guard count <= 4_096 else { return nil }
        var rows: [(String, Any?)] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(snapshot, index) else { return nil }
            let item = Unmanaged<LSSharedFileListItem>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(item) == LSSharedFileListItemGetTypeID() else { return nil }
            let displayName: Unmanaged<CFString>? = LSSharedFileListItemCopyDisplayName(item)
            guard let displayName else { return nil }
            let property = LSSharedFileListItemCopyProperty(item, "kLSSharedTagFileListItemLabel" as CFString)?.takeRetainedValue()
            rows.append((displayName.takeRetainedValue() as String, property))
        }
        return Self(configuredRows: rows, fallbackLabels: [])
    }
}

/// All windows share one synchronous system-service call. Timing out releases
/// every waiter while that call unwinds. No further native call queues behind it.
actor FinderTagCatalogReader {
    typealias Timer = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "Maxplorer.FinderTagCatalog", qos: .userInitiated)
    private let readConfigured: @Sendable () -> FinderTagCatalog?
    private let readFallback: @Sendable () -> FinderTagCatalog
    private let scheduleTimeout: Timer
    private var generation: UUID?
    private var expired = false
    private var waiters: [UUID: CheckedContinuation<FinderTagCatalog, Never>] = [:]
    private var fallback = FinderTagCatalog(configuredRows: nil, fallbackLabels: [])
    var waiterCount: Int { waiters.count }
    var readInProgress: Bool { generation != nil }

    init(readConfigured: @escaping @Sendable () -> FinderTagCatalog?, readFallback: @escaping @Sendable () -> FinderTagCatalog,
         scheduleTimeout: @escaping Timer = { action in
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: action)
         }) {
        self.readConfigured = readConfigured
        self.readFallback = readFallback
        self.scheduleTimeout = scheduleTimeout
    }

    func load() async -> FinderTagCatalog {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !expired else { continuation.resume(returning: fallback); return }
                waiters[id] = continuation
                if generation == nil { start() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func start() {
        let id = UUID()
        generation = id
        scheduleTimeout { Task { await self.timeOut(id) } }
        let palette = readFallback
        queue.async {
            let localized = palette()
            Task { await self.startConfiguredRead(id, localized: localized) }
        }
    }

    private func startConfiguredRead(_ id: UUID, localized: FinderTagCatalog) {
        guard generation == id else { return }
        fallback = localized
        guard !expired else { finish(id, result: localized); return }
        let read = readConfigured
        queue.async {
            let result = read() ?? localized
            Task { await self.finish(id, result: result) }
        }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(returning: fallback) }

    private func timeOut(_ id: UUID) {
        guard generation == id else { return }
        expired = true
        resumeWaiters(with: fallback)
    }

    private func finish(_ id: UUID, result: FinderTagCatalog) {
        guard generation == id else { return }
        if !expired { resumeWaiters(with: result) }
        generation = nil
        expired = false
    }

    private func resumeWaiters(with result: FinderTagCatalog) {
        let current = waiters
        waiters.removeAll()
        for continuation in current.values { continuation.resume(returning: result) }
    }
}
