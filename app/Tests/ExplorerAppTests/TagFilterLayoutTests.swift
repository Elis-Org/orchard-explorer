import CoreGraphics
import Testing
@testable import ExplorerApp

@MainActor
struct TagFilterLayoutTests {
    private func frames(_ widths: [CGFloat], available: CGFloat?) -> [CGRect] {
        let sizes = widths.map { CGSize(width: $0, height: 30) }
        return TagFilterLayout.frames(for: sizes, availableWidth: available, spacing: 6)
    }

    @Test func wideRowRetainsEveryButtonsIntrinsicWidth() {
        let widths: [CGFloat] = [88, 188, 212, 172, 156, 92]
        let proposals: [CGFloat?] = [1_100, nil, CGFloat.infinity]
        for proposal in proposals {
            let result = frames(widths, available: proposal)
            #expect(result.map(\.width) == widths)
            #expect(result.map(\.minX) == [0, 94, 288, 506, 684, 846])
            #expect(result.allSatisfy { $0.minY == 0 })
        }
    }

    @Test func nextRowStartsOnlyWhenTheNextButtonWouldOverflow() {
        let result = frames([80, 134, 190, 85], available: 220)
        #expect(result.map(\.minX) == [0, 86, 0, 0])
        #expect(result.map(\.minY) == [0, 0, 36, 72])
        #expect(result.map(\.width) == [80, 134, 190, 85])
    }

    @Test func oversizedTagOccupiesOneRowAndMoreRemainsReachable() {
        let result = frames([80, 430, 85], available: 210)
        #expect(result.map(\.width) == [80, 210, 85])
        #expect(result.map(\.minY) == [0, 36, 72])
        #expect(result.allSatisfy { $0.minX >= 0 && $0.maxX <= 210 })
    }
}
