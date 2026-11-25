import SwiftUI

struct TagFilterLayout: Layout {
    let spacing: CGFloat

    static func frames(for sizes: [CGSize], availableWidth: CGFloat?, spacing: CGFloat) -> [CGRect] {
        let limit = availableWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .infinity
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            let width = min(size.width, limit)
            if x > 0, x + width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            result.append(CGRect(x: x, y: y, width: width, height: size.height))
            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return result
    }

    private func frames(_ subviews: Subviews, width: CGFloat?) -> [CGRect] {
        Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, availableWidth: width, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let controls = frames(subviews, width: proposal.width)
        return CGSize(width: controls.map(\.maxX).max() ?? 0, height: controls.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (control, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            control.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
