import Foundation

/// Row selection, keyboard focus, and range anchor are deliberately independent.
/// FR-SEL-001/002/003/007/008; EV-0213/0218; AT-SEL-001/002/003/007/008.
public struct SelectionState: Equatable, Sendable {
    public var selectedIDs: Set<String> = []
    public var focusedID: String?
    public var anchorID: String?

    public init() {}

    public mutating func select(_ id: String, orderedIDs: [String],
                                extending: Bool = false, toggling: Bool = false) {
        guard orderedIDs.contains(id) else { return }
        if extending {
            let anchor = anchorID ?? focusedID ?? id
            if let start = orderedIDs.firstIndex(of: anchor), let end = orderedIDs.firstIndex(of: id) {
                let range = Set(orderedIDs[min(start, end)...max(start, end)])
                selectedIDs = toggling ? selectedIDs.union(range) : range
                anchorID = anchor
            } else {
                selectedIDs = [id]
                anchorID = id
            }
        } else if toggling {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
            anchorID = id
        } else {
            selectedIDs = [id]
            anchorID = id
        }
        focusedID = id
    }

    public mutating func selectAll(_ ids: [String]) {
        selectedIDs = Set(ids)
        if let focusedID, !selectedIDs.contains(focusedID) { self.focusedID = nil }
        if focusedID == nil { focusedID = ids.first }
        anchorID = ids.first
    }

    public mutating func clear() {
        selectedIDs.removeAll()
        focusedID = nil
        anchorID = nil
    }

    public mutating func reconcile(validIDs: Set<String>) {
        selectedIDs.formIntersection(validIDs)
        if let focusedID, !validIDs.contains(focusedID) { self.focusedID = nil }
        if let anchorID, !validIDs.contains(anchorID) { self.anchorID = nil }
    }

    /// Native external-change policy, not a Windows fidelity claim. EV-0235
    /// observes selection after an in-app rename, not external change delivery.
    /// Compare full snapshots so unselected/hidden hard links cannot be mistaken
    /// for a unique rename. Unknown identity supports exact-path retention only.
    public mutating func reconcile(previous: DirectorySnapshot, current: DirectorySnapshot) {
        guard previous.directoryIdentity == current.directoryIdentity,
              previous.archiveRevision == current.archiveRevision else {
            clear()
            return
        }

        let previousByPath = Dictionary(grouping: previous.items, by: \.id)
        let currentByPath = Dictionary(grouping: current.items, by: \.id)
        let previousByIdentity = Dictionary(grouping: previous.items.filter { $0.identity != nil },
                                            by: { $0.identity! })
        let currentByIdentity = Dictionary(grouping: current.items.filter { $0.identity != nil },
                                           by: { $0.identity! })

        func mapped(_ id: String) -> String? {
            guard let oldEntries = previousByPath[id], oldEntries.count == 1,
                  let old = oldEntries.first else { return nil }
            if let exact = currentByPath[id], exact.count == 1,
               let candidate = exact.first, old.identity == candidate.identity {
                // Both nil is a deliberately limited path-only fallback for
                // providers/test doubles without supported local identity.
                return candidate.id
            }
            guard let identity = old.identity, identity.linkCount == 1,
                  previousByIdentity[identity]?.count == 1,
                  let matches = currentByIdentity[identity], matches.count == 1,
                  let candidate = matches.first, candidate.identity?.linkCount == 1,
                  currentByPath[candidate.id]?.count == 1 else { return nil }
            return candidate.id
        }

        selectedIDs = Set(selectedIDs.compactMap(mapped))
        focusedID = focusedID.flatMap(mapped)
        anchorID = anchorID.flatMap(mapped)
    }
}
