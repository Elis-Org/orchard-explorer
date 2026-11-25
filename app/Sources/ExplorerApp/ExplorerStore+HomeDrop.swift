import AppKit
import ExplorerCore

@MainActor
extension ExplorerStore {
    func homeFileDropTarget(row: HomeResultRow?) -> FileDropTarget? {
        guard isCommandIdle, !address.isEditing, let scope = homeResultScope,
              let destination = homeDestination(for: row) else { return nil }
        switch destination {
        case .folder(let context):
            let receiver: HomeFileDropReceiver
            var entry: LocalFileIdentity?
            if let row, row.isDirectory {
                guard let membership = homeResultMembership(row, in: scope),
                      let identity = activeTab.homeResults.target(of: row)?.identity else { return nil }
                entry = identity
                receiver = .folder(scope, row, membership)
            } else {
                guard let origin = homeOperationOrigin else { return nil }
                receiver = .selection(origin)
            }
            return .folder(homeFileDropBinding(receiver, context: context, entry: entry))
        case .chooseFolder:
            guard row?.isDirectory != true, let origin = homeOperationOrigin else { return nil }
            return .choose(origin)
        case .unavailable: return nil
        }
    }

    func homeFileDropBinding(_ receiver: HomeFileDropReceiver, context: FileOperationContext,
                             entry: LocalFileIdentity? = nil) -> FileDropBinding {
        FileDropBinding(receiverActiveTabID: activeTabID, tabID: activeTabID, tabURL: activeTab.url,
                        tabDirectoryIdentity: nil, loadGeneration: nil, destinationURL: context.directoryURL,
                        expectedDestinationIdentity: context.directoryIdentity,
                        expectedEntryIdentity: entry, homeReceiver: receiver)
    }

    func isCurrentFileDropTarget(_ target: FileDropTarget) -> Bool {
        switch target {
        case .folder(let binding): return isCurrentFileDropBinding(binding)
        case .choose(let origin): return isCommandIdle && !address.isEditing && isHomeOperationOriginCurrent(origin)
        }
    }
}
