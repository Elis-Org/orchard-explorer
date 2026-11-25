import Foundation

public enum SortKey: String, CaseIterable, Sendable {
    case name, modifiedAt, kind, size
}

public struct FileSort: Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// FR-VIEW-009 / AT-VIEW-009 / EV-0334: descending Name reverses the whole order,
    /// including folders. Date, kind, size ordering is a deterministic macOS adaptation.
    public func sorted(_ items: [FileItem]) -> [FileItem] {
        let ordered = items.sorted { left, right in
            let result = compare(left, right)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return ordered
    }

    private func compare(_ left: FileItem, _ right: FileItem) -> ComparisonResult {
        if left.isDirectory != right.isDirectory {
            return left.isDirectory ? .orderedAscending : .orderedDescending
        }
        let primary: ComparisonResult
        switch key {
        case .name: primary = naturalCompare(left.name, right.name)
        case .kind: primary = naturalCompare(left.kind, right.kind)
        case .size: primary = compareOptional(left.size, right.size)
        case .modifiedAt: primary = compareOptional(left.modifiedAt, right.modifiedAt)
        }
        if primary != .orderedSame { return primary }
        let nameOrder = naturalCompare(left.name, right.name)
        if nameOrder != .orderedSame { return nameOrder }
        // A case/Unicode collation tie must still produce a stable order for unique entries.
        if left.id == right.id { return .orderedSame }
        return left.id < right.id ? .orderedAscending : .orderedDescending
    }

    private func naturalCompare(_ left: String, _ right: String) -> ComparisonResult {
        // Match the en-US reference's linguistic ordering: POSIX collation can put
        // uppercase names before lowercase names despite case-insensitive comparison.
        left.compare(right, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US"))
    }

    private func compareOptional<T: Comparable>(_ left: T?, _ right: T?) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (left?, right?):
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
    }
}
