import ExplorerCore
import Foundation

struct HomeResultScope: Hashable {
    let tabID: UUID
    let page: BrowserPage
    let section: HomeSection
    let epoch: UUID?
    let tagGeneration: UUID
    let tagScope: FinderTagScope?
    let filter: String

    func hasSameCollection(as other: Self) -> Bool {
        tabID == other.tabID && page == other.page && section == other.section
            && tagGeneration == other.tagGeneration && tagScope == other.tagScope
    }
}

struct HomeResultTarget: Equatable, Sendable {
    let url: URL
    let recent: RecentDocument?
    let identity: LocalFileIdentity?
    let isDirectory: Bool
}

struct HomeResultRow: Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    let group: String?
    let isDirectory: Bool
    let recent: RecentDocument?

    init(recent: RecentDocument) {
        url = recent.url.standardizedFileURL
        group = nil
        isDirectory = false
        self.recent = recent
        id = "recent/" + url.path
    }

    init(item: FinderTagItem, group: String) {
        url = item.url
        self.group = group
        isDirectory = item.isDirectory
        recent = nil
        // Length-prefix the literal group. Finder permits punctuation in tag names.
        id = "tag/\(group.utf8.count)/\(group)" + url.path
    }

    func represents(_ other: Self) -> Bool {
        id == other.id && isDirectory == other.isDirectory && recent?.identity == other.recent?.identity
            && recent?.volumeUUID == other.recent?.volumeUUID && recent?.documentID == other.recent?.documentID
            && recent?.regularFile == other.recent?.regularFile
    }
}

/// Per-tab membership, selection and Spotlight results. A row can remain selected
/// through a reorder, while its removal revokes outstanding actions for that occurrence.
struct HomeResultSelection {
    let visitID = UUID()
    private(set) var operationGeneration = UUID()
    private struct Membership {
        let row: HomeResultRow
        var token = UUID()
        var identity: LocalFileIdentity?
        var isSymbolicLink: Bool?
    }
    private var members: [String: Membership] = [:]
    private(set) var rows: [HomeResultRow] = []
    private(set) var scope: HomeResultScope?
    private(set) var selection = SelectionState()
    private(set) var generation = UUID()
    var tagSnapshot: FinderTagsSnapshot?

    func membership(of row: HomeResultRow) -> UUID? {
        guard let member = members[row.id], member.row.represents(row) else { return nil }
        return member.token
    }

    func target(of row: HomeResultRow) -> HomeResultTarget? {
        guard let member = members[row.id], member.row.represents(row) else { return nil }
        return HomeResultTarget(url: row.url, recent: member.row.recent,
                                identity: member.identity, isDirectory: row.isDirectory)
    }

    func isKnownSymbolicLink(_ row: HomeResultRow) -> Bool {
        guard let member = members[row.id], member.row.represents(row) else { return false }
        return member.isSymbolicLink == true
    }

    var selectedTargets: [HomeResultTarget] {
        guard !selection.selectedIDs.isEmpty else { return [] }
        var result: [HomeResultTarget] = []
        var positions: [String: Int] = [:]
        var conflicting = Set<String>()
        for row in rows where selection.selectedIDs.contains(row.id) {
            guard let target = target(of: row) else { continue }
            let path = row.url.path
            if let position = positions[path] {
                guard !conflicting.contains(path), let identity = target.identity else { continue }
                if let previous = result[position].identity, previous != identity {
                    // Two group occurrences can have been sampled on opposite sides of a replacement.
                    conflicting.insert(path)
                    result[position] = HomeResultTarget(url: row.url, recent: nil,
                        identity: nil, isDirectory: row.isDirectory)
                } else {
                    result[position] = target
                }
            } else {
                positions[path] = result.count
                result.append(target)
            }
        }
        return result
    }

    mutating func replace(_ nextRows: [HomeResultRow], scope nextScope: HomeResultScope) {
        let sameCollection = scope?.hasSameCollection(as: nextScope) == true
        let oldSelection = selection
        var nextMembers: [String: Membership] = [:]
        nextMembers.reserveCapacity(nextRows.count)
        var retained = Set<String>()
        for row in nextRows {
            if sameCollection, let old = members[row.id], old.row.represents(row) {
                nextMembers[row.id] = old
                retained.insert(row.id)
            } else {
                nextMembers[row.id] = Membership(row: row, identity: row.recent?.identity)
            }
        }
        selection.reconcile(validIDs: retained)
        if scope != nextScope || oldSelection.selectedIDs != selection.selectedIDs {
            generation = UUID()
            operationGeneration = UUID()
        }
        if !sameCollection { tagSnapshot = nil }
        members = nextMembers
        rows = nextRows
        scope = nextScope
    }

    mutating func bind(_ identity: LocalFileIdentity?, for row: HomeResultRow, isSymbolicLink: Bool? = nil) -> Bool {
        guard row.recent == nil, var member = members[row.id], member.row.represents(row) else { return false }
        if member.identity == identity {
            guard identity != nil, let isSymbolicLink, member.isSymbolicLink != isSymbolicLink else { return false }
            member.isSymbolicLink = isSymbolicLink
            members[row.id] = member
            return true
        }
        if member.identity != nil {
            member.token = UUID()
            if selection.selectedIDs.contains(row.id) || selection.focusedID == row.id || selection.anchorID == row.id {
                selection.reconcile(validIDs: Set(members.keys).subtracting([row.id]))
                generation = UUID()
                operationGeneration = UUID()
            }
        } else if selection.selectedIDs.contains(row.id) {
            generation = UUID()
        }
        member.identity = identity
        member.isSymbolicLink = identity == nil ? nil : isSymbolicLink
        members[row.id] = member
        return true
    }

    mutating func select(_ row: HomeResultRow, extending: Bool, toggling: Bool) -> Bool {
        guard membership(of: row) != nil else { return false }
        let old = selection
        selection.select(row.id, orderedIDs: rows.map(\.id), extending: extending, toggling: toggling)
        if old.selectedIDs != selection.selectedIDs { generation = UUID(); operationGeneration = UUID() }
        return old != selection
    }
}
