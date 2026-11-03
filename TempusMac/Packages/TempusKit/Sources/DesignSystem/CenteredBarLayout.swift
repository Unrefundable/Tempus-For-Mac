import SwiftUI

/// Three views across a bar, the middle one centered on the bar itself: a player bar's titles,
/// transport and buttons, as Music lays them out. The middle takes a share of the width, kept
/// between its bounds, and the two sides split the rest equally, so the titles shrink (and
/// truncate) with the window instead of being pushed out by the transport.
///
/// Lay out exactly three subviews: leading, middle, trailing. The trailing one keeps its ideal
/// width; the middle gives way to it before the bar runs out of room.
public struct CenteredBarLayout: Layout {
    /// The widths of the side columns and the middle one.
    public struct Columns: Equatable, Sendable {
        public let side: CGFloat
        public let middle: CGFloat
    }

    public let spacing: CGFloat
    /// The part of the bar's width the middle takes, before `middleWidths` clamps it.
    public let middleShare: CGFloat
    public let middleWidths: ClosedRange<CGFloat>

    public init(spacing: CGFloat, middleShare: CGFloat, middleWidths: ClosedRange<CGFloat>) {
        self.spacing = spacing
        self.middleShare = middleShare
        self.middleWidths = middleWidths
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        if let width = proposal.width, width.isFinite, let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: height)
        }
        // Unspecified or unbounded: the ideal, so an unbounded parent never gets an infinite bar.
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideals.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        let idealHeight = ideals.map(\.height).max() ?? 0
        return CGSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth,
            height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? idealHeight
        )
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void
    ) {
        guard subviews.count == 3 else {
            assertionFailure("CenteredBarLayout lays out three views, not \(subviews.count)")
            return
        }
        let (leading, middle, trailing) = (subviews[0], subviews[1], subviews[2])
        let columns = columns(
            width: bounds.width,
            middleMinimum: middle.sizeThatFits(ProposedViewSize(width: 0, height: bounds.height)).width,
            trailingMinimum: trailing.sizeThatFits(.unspecified).width
        )
        let side = ProposedViewSize(width: columns.side, height: bounds.height)
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: side)
        middle.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: columns.middle, height: bounds.height)
        )
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: side)
    }

    /// The columns for a bar `width` wide, whose middle needs at least `middleMinimum` and whose
    /// trailing view needs `trailingMinimum`. Both sides always get the same width.
    func columns(width: CGFloat, middleMinimum: CGFloat, trailingMinimum: CGFloat) -> Columns {
        let floor = max(middleWidths.lowerBound, middleMinimum)
        let gaps = 2 * spacing
        var middle = max(floor, min(middleWidths.upperBound, width * middleShare))
        if (width - middle - gaps) / 2 < trailingMinimum {
            middle = max(floor, width - gaps - 2 * trailingMinimum)
        }
        return Columns(side: max(0, (width - middle - gaps) / 2), middle: middle)
    }
}
