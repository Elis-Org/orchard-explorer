import ExplorerCore
import Foundation

enum HomeFileDropReceiver: Equatable {
    case selection(HomeOperationOrigin)
    case folder(HomeResultScope, HomeResultRow, UUID)
    case chosen(HomeOperationOrigin)
}

enum FileDropTarget: Equatable {
    case folder(FileDropBinding)
    case choose(HomeOperationOrigin)
}

/// A receiving tab and a proposed destination. A URL alone never supplies write authority.
/// `expectedEntryIdentity` describes the row/link itself; `expectedDestinationIdentity`
/// describes an already displayed directory after route resolution.
struct FileDropBinding: Equatable {
    let receiverActiveTabID: UUID
    let tabID: UUID
    let tabURL: URL
    let tabDirectoryIdentity: LocalFileIdentity?
    let loadGeneration: UUID?
    let destinationURL: URL
    let expectedDestinationIdentity: LocalFileIdentity?
    let expectedEntryIdentity: LocalFileIdentity?
    var homeReceiver: HomeFileDropReceiver? = nil
}
