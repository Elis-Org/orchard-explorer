import AppKit
import ExplorerCore

/// FR-VIEW-008/010, UI-VIEW-004 / AT-VIEW-008/010, AT-UIVIEW-004.
/// Inspected EV-0306/0307, EV-0318/0319, EV-0320/0321, EV-0322/0323,
/// EV-0324/0325, EV-0326/0327, EV-0328/0329. Screenshots establish the
/// visible layout families; paired UIA has no bounds. These point dimensions
/// are a native comparison baseline, not measured Windows geometry equality.
struct CollectionGeometry {
    struct Metrics {
        let itemSize: NSSize
        let iconSide: CGFloat
        let horizontalSpacing: CGFloat
        let verticalSpacing: CGFloat
    }

    static var inset: CGFloat { 12.pt }

    let mode: FolderViewMode
    let viewport: NSSize
    let itemSize: NSSize
    let columns: Int
    let rows: Int
    let frames: [NSRect]
    let contentSize: NSSize

    init(count: Int, viewport: NSSize, mode: FolderViewMode) {
        self.mode = mode
        self.viewport = Self.normalizedViewport(viewport)
        let count = max(0, count)
        let metrics = Self.metrics(for: mode)
        let horizontalInset = min(Self.inset, max(0, (self.viewport.width - 1) / 2))
        let availableWidth = max(1, self.viewport.width - horizontalInset * 2)
        let fillsWidth = mode == .content || mode == .details
        let width = fillsWidth ? availableWidth : min(metrics.itemSize.width, availableWidth)
        itemSize = NSSize(width: width, height: metrics.itemSize.height)

        if fillsWidth || mode == .list {
            columns = 1
        } else {
            let capacity = floor((availableWidth + metrics.horizontalSpacing)
                                 / (width + metrics.horizontalSpacing))
            // Limit conversion before turning an arbitrarily large viewport into
            // an Int. No layout needs more columns than its existing items.
            columns = capacity >= CGFloat(max(1, count)) ? max(1, count) : max(1, Int(capacity))
        }
        rows = count == 0 ? 0 : 1 + (count - 1) / columns
        let pitchX = width + metrics.horizontalSpacing
        let pitchY = itemSize.height + metrics.verticalSpacing
        let columnCount = columns
        let cellHeight = itemSize.height
        frames = (0..<count).map { index in
            NSRect(x: horizontalInset + CGFloat(index % columnCount) * pitchX,
                   y: Self.inset + CGFloat(index / columnCount) * pitchY,
                   width: width, height: cellHeight)
        }
        let usedHeight = rows == 0 ? 0
            : Self.inset * 2 + CGFloat(rows - 1) * pitchY + itemSize.height
        contentSize = NSSize(width: self.viewport.width, height: max(self.viewport.height, usedHeight))
    }

    /// Spatial moves never wrap from the last column into the next row. When a
    /// shorter final row has no item in the same column, Down leaves focus put.
    /// Single-column List/Content use Up/Down only. This is native keyboard policy.
    func neighbor(of index: Int, keyCode: UInt16) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let column = index % columns
        let candidate: Int
        switch keyCode {
        case 123:
            guard column > 0 else { return nil }
            candidate = index - 1
        case 124:
            guard column + 1 < columns else { return nil }
            candidate = index + 1
        case 125:
            guard index <= frames.count - 1 - columns else { return nil }
            candidate = index + columns
        case 126:
            guard index >= columns else { return nil }
            candidate = index - columns
        default:
            return nil
        }
        return frames.indices.contains(candidate) ? candidate : nil
    }

    /// Query only potentially visible rows, then exclude gaps and offscreen columns.
    /// This avoids a full item scan for every collection view visibility request.
    func indexes(intersecting rect: NSRect) -> [Int] {
        guard rows > 0 else { return [] }
        let clipped = rect.intersection(NSRect(origin: .zero, size: contentSize))
        guard !clipped.isEmpty, !clipped.isNull, clipped.minY.isFinite, clipped.maxY.isFinite else { return [] }
        let pitch = itemSize.height + Self.metrics(for: mode).verticalSpacing
        let first = Int(min(CGFloat(rows - 1), max(0, floor((clipped.minY - Self.inset) / pitch))))
        let last = Int(min(CGFloat(rows - 1), max(0, floor((clipped.maxY - Self.inset) / pitch))))
        let start = first * columns
        let lastStart = last * columns
        let end = lastStart + min(columns, frames.count - lastStart)
        guard start < end else { return [] }
        return (start..<end).filter { frames[$0].intersects(rect) }
    }

    /// MAC-074: reference metrics at the interface scale.
    static func metrics(for mode: FolderViewMode, scale: CGFloat = ExplorerScale.factor) -> Metrics {
        let reference = referenceMetrics(for: mode)
        return Metrics(itemSize: NSSize(width: reference.itemSize.width * scale, height: reference.itemSize.height * scale),
                       iconSide: reference.iconSide * scale,
                       horizontalSpacing: reference.horizontalSpacing * scale,
                       verticalSpacing: reference.verticalSpacing * scale)
    }

    static func referenceMetrics(for mode: FolderViewMode) -> Metrics {
        switch mode {
        case .extraLargeIcons:
            return Metrics(itemSize: NSSize(width: 184, height: 196), iconSide: 144,
                           horizontalSpacing: 6, verticalSpacing: 8)
        case .largeIcons:
            return Metrics(itemSize: NSSize(width: 104, height: 134), iconSide: 84,
                           horizontalSpacing: 6, verticalSpacing: 8)
        case .mediumIcons:
            return Metrics(itemSize: NSSize(width: 76, height: 104), iconSide: 48,
                           horizontalSpacing: 6, verticalSpacing: 8)
        case .smallIcons:
            return Metrics(itemSize: NSSize(width: 280, height: 28), iconSide: 16,
                           horizontalSpacing: 12, verticalSpacing: 4)
        case .list:
            // EV-0324 establishes one vertical icon/name column. Additional
            // column wrapping is unverified; List therefore scrolls vertically.
            return Metrics(itemSize: NSSize(width: 240, height: 28), iconSide: 16,
                           horizontalSpacing: 0, verticalSpacing: 4)
        case .details:
            // Details is a defensive geometry fallback; its real view is NSTableView.
            return Metrics(itemSize: NSSize(width: 280, height: 28), iconSide: 16,
                           horizontalSpacing: 0, verticalSpacing: 4)
        case .tiles:
            return Metrics(itemSize: NSSize(width: 280, height: 64), iconSide: 40,
                           horizontalSpacing: 12, verticalSpacing: 6)
        case .content:
            return Metrics(itemSize: NSSize(width: 280, height: 72), iconSide: 32,
                           horizontalSpacing: 0, verticalSpacing: 0)
        }
    }

    static func normalizedViewport(_ size: NSSize) -> NSSize {
        NSSize(width: size.width.isFinite ? max(1, size.width) : 1,
               height: size.height.isFinite ? max(1, size.height) : 1)
    }
}

/// Native virtualization is retained: the layout describes rectangles while
/// NSCollectionView owns item creation/reuse. All frames use top-origin coordinates.
@MainActor
final class ExplorerCollectionLayout: NSCollectionViewLayout {
    var mode: FolderViewMode = .largeIcons {
        didSet { if mode != oldValue { invalidateLayout() } }
    }
    private(set) var geometry = CollectionGeometry(count: 0, viewport: .zero, mode: .largeIcons)

    init(mode: FolderViewMode = .largeIcons) {
        self.mode = mode
        geometry = CollectionGeometry(count: 0, viewport: .zero, mode: mode)
        super.init()
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let viewport = collectionView.enclosingScrollView?.contentSize ?? collectionView.bounds.size
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        geometry = CollectionGeometry(count: count, viewport: viewport, mode: mode)
    }

    override var collectionViewContentSize: NSSize { geometry.contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        geometry.indexes(intersecting: rect).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, geometry.frames.indices.contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = geometry.frames[indexPath.item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        let viewport = collectionView?.enclosingScrollView?.contentSize ?? newBounds.size
        return CollectionGeometry.normalizedViewport(viewport) != geometry.viewport
    }
}
