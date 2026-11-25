import ExplorerCore
import Foundation

enum HomeFileLocations {
    /// Resolve only lexical dot components. Filesystem URL standardization can
    /// change the spelling of a filename before its bytes are compared.
    static func pathKey(_ url: URL) -> Data {
        let slash: UInt8 = 0x2F
        var result = Data([slash])
        for component in url.path(percentEncoded: false).utf8.split(separator: slash) {
            if component.elementsEqual(".".utf8) { continue }
            if component.elementsEqual("..".utf8) {
                if let end = result.lastIndex(of: slash) { result.removeSubrange(max(1, end)..<result.endIndex) }
            } else {
                if result.count > 1 { result.append(slash) }
                result.append(contentsOf: component)
            }
        }
        return result
    }

    private static let userTrash = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents + [".Trash"]
    static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        if path.starts(with: userTrash) { return true }
        guard let index = path.firstIndex(of: ".Trashes") else { return false }
        if index == 1 || (index == 3 && path[1] == "Volumes") { return true }
        // A volume can be mounted outside /Volumes (including a mounted image).
        // Inspect only the potential root; a normal nested .Trashes is not Trash.
        let parent = URL(fileURLWithPath: NSString.path(withComponents: Array(path.prefix(index))), isDirectory: true)
        guard let volume = try? parent.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return parent.resolvingSymlinksInPath().standardizedFileURL.path == volume.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum HomeOperationDestination: Equatable {
    case chooseFolder, unavailable
    case folder(FileOperationContext)
}

struct HomeOperationOrigin: Equatable {
    struct Occurrence: Equatable {
        let row: HomeResultRow
        let membership: UUID
        let identity: LocalFileIdentity?
    }
    let scope: HomeResultScope
    let visit: UUID
    let activation: UUID
    let generation: UUID
    let occurrences: [Occurrence]
    let selectedUniqueCount: Int
    let complete: Bool

    func hasSameSelection(as other: Self) -> Bool {
        scope == other.scope && visit == other.visit && activation == other.activation && generation == other.generation
    }
}

@MainActor
final class HomeFileOperationState {
    var activeTab: UUID?
    var activation = UUID()
    var origin: HomeOperationOrigin?
    var preparation: Task<HomePreparedSelection, Error>?
    var prepared: HomePreparedSelection?
    var unavailable = false
    var command: Task<Void, Never>?
    var commandID: UUID?
    deinit { preparation?.cancel(); command?.cancel() }
}

struct HomePreparedSelection: Sendable {
    let entries: [TransferEntry]
    let byPath: [Data: TransferEntry]
    let sourceError: (any Error)?

    init(targets: [HomeResultTarget], reading read: @escaping HomeInspector.ReadEntry) async throws {
        let entries = try await HomeFileOperationSampler.sample(targets, reading: read)
        guard let byPath = HomeFileOperationSampler.indexedEntries(entries) else { throw ItemContentError.staleSource }
        self.entries = entries
        self.byPath = byPath
        do {
            try await LocalFileTransferImporter.validateSelectionRelationships(entries)
            sourceError = nil
        } catch {
            try Task.checkCancellation()
            sourceError = error
        }
    }
}

enum HomeFileOperationSampler {
    static func indexedEntries(_ entries: [TransferEntry]) -> [Data: TransferEntry]? {
        var indexed: [Data: TransferEntry] = [:]
        for entry in entries {
            let key = HomeFileLocations.pathKey(entry.item.url)
            guard indexed.updateValue(entry, forKey: key) == nil else { return nil }
        }
        return indexed
    }

    /// Merge duplicate physical paths only after considering every occurrence's proof.
    static func targets(in origin: HomeOperationOrigin) throws -> [HomeResultTarget] {
        guard origin.complete, (1...1_024).contains(origin.selectedUniqueCount) else { throw ItemContentError.staleSource }
        var targets: [HomeResultTarget] = []
        var indices: [Data: Int] = [:]
        var byteCount = 0
        for member in origin.occurrences {
            let row = member.row, key = HomeFileLocations.pathKey(row.url)
            guard row.url.isFileURL, !HomeFileLocations.isInTrash(row.url) else { throw ItemContentError.staleSource }
            let target = HomeResultTarget(url: row.url, recent: row.recent, identity: member.identity, isDirectory: row.isDirectory)
            if let index = indices[key] {
                let old = targets[index]
                guard old.url.path.utf8.elementsEqual(target.url.path.utf8), old.isDirectory == target.isDirectory,
                      old.identity == nil || target.identity == nil || old.identity == target.identity else { throw ItemContentError.staleSource }
                if old.identity == nil { targets[index] = target }
            } else {
                byteCount += row.url.absoluteString.utf8.count
                guard byteCount <= 1_048_576 else { throw FileOperationError.unsupported("The selection exceeds the transfer URL limit.") }
                indices[key] = targets.count
                targets.append(target)
            }
        }
        guard targets.count == origin.selectedUniqueCount else { throw ItemContentError.staleSource }
        return targets
    }

    /// Only the selected children are sampled. Bounded concurrency also bounds
    /// queued metadata I/O when a large range is replaced by another selection.
    static func sample(_ targets: [HomeResultTarget], reading read: @escaping HomeInspector.ReadEntry) async throws -> [TransferEntry] {
        try await withThrowingTaskGroup(of: (Int, TransferEntry).self) { group in
            var slots = [TransferEntry?](repeating: nil, count: targets.count)
            for index in targets.indices {
                try Task.checkCancellation()
                let target = targets[index]
                group.addTask {
                    try Task.checkCancellation()
                    let entry: TransferEntry
                    if target.recent == nil {
                        entry = try await read(target.url)
                        guard target.identity == nil || entry.item.identity == target.identity,
                              entry.item.isSymbolicLink || entry.item.isDirectory == target.isDirectory
                        else { throw ItemContentError.staleSource }
                    } else {
                        let checked = try await HomeInspector.sample(target, reading: read)
                        guard let physical = checked.physicalEntry else { throw ItemContentError.staleSource }
                        entry = physical
                    }
                    guard HomeFileLocations.pathKey(entry.item.url) == HomeFileLocations.pathKey(target.url),
                          entry.item.identity != nil, !HomeFileLocations.isInTrash(entry.item.url) else { throw ItemContentError.staleSource }
                    return (index, entry)
                }
                if index >= 3, let (completed, entry) = try await group.next() { slots[completed] = entry }
            }
            for try await (completed, entry) in group { slots[completed] = entry }
            try Task.checkCancellation()
            let entries = slots.compactMap { $0 }
            guard entries.count == targets.count else { throw ItemContentError.staleSource }
            return entries
        }
    }

    static func agrees(_ lhs: TransferEntry, _ rhs: TransferEntry) -> Bool {
        lhs.source.directoryIdentity == rhs.source.directoryIdentity
            && HomeFileLocations.pathKey(lhs.source.directoryURL) == HomeFileLocations.pathKey(rhs.source.directoryURL)
            && HomeFileLocations.pathKey(lhs.item.url) == HomeFileLocations.pathKey(rhs.item.url)
            && lhs.item.identity == rhs.item.identity && lhs.item.isDirectory == rhs.item.isDirectory
            && lhs.item.isSymbolicLink == rhs.item.isSymbolicLink
    }
}
