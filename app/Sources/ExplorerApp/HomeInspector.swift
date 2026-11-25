import ExplorerCore
import Foundation

enum HomeInspectorDetails: Equatable {
    case empty, preparing, unavailable
    case multiple(Int)
    case single(FileItem)

    static let unavailableMessage = "This item is no longer available."
    var item: FileItem? {
        if case .single(let item) = self { return item }
        return nil
    }
}

struct HomeInspectionOrigin: Equatable {
    let tab: UUID
    let generation: UUID
}

enum HomeInspector {
    typealias ReadEntry = @Sendable (URL) async throws -> TransferEntry

    static func sample(_ target: HomeResultTarget, reading read: ReadEntry) async throws -> ItemOperationEntry {
        // Recent represents the document that was opened, even through a link.
        // A Finder tag row represents the no-follow filesystem entry itself.
        if let document = target.recent {
            guard let before = await RecentDocument.sample(target.url), document.identifies(before)
            else { throw ItemContentError.staleSource }
            let entry = try await read(target.url)
            guard entry.item.isDirectory == target.isDirectory,
                  entry.item.isSymbolicLink || entry.item.identity == before.identity,
                  let after = await RecentDocument.sample(target.url), document.identifies(after),
                  after.identity == before.identity else { throw ItemContentError.staleSource }
            return ItemOperationEntry(entry)
        }
        guard let expected = target.identity else { throw ItemContentError.staleSource }
        let entry = try await read(target.url)
        guard entry.item.identity == expected, !entry.item.isSymbolicLink,
              entry.item.isDirectory == target.isDirectory else { throw ItemContentError.staleSource }
        return ItemOperationEntry(entry)
    }
}
