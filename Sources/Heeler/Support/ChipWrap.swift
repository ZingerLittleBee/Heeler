import SwiftUI

/// Wraps chips in source order so long or multiple tokens stay fully visible.
struct ChipWrap: Layout {
    var spacing: CGFloat = 5
    /// Between wrapped lines; `spacing` when nil.
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let arranged = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews)
        for item in arranged.frames {
            subviews[item.offset].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                proposal: ProposedViewSize(item.frame.size))
        }
    }

    private func arrange(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (size: CGSize, frames: [(offset: Int, frame: CGRect)]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var frames: [(offset: Int, frame: CGRect)] = []
        for (offset, subview) in subviews.enumerated() {
            let size = fittedSize(of: subview, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + (lineSpacing ?? spacing)
                x = 0
                rowHeight = 0
            }
            frames.append((offset, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            // The width reported is the sum the check above makes, bit for
            // bit: `(x + w + spacing) - spacing` can round below `x + w`, and
            // placing at the reported width would then wrap the last chip.
            let right = x + size.width
            x = right + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, right)
        }
        let height = subviews.isEmpty ? 0 : y + rowHeight
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return (CGSize(width: width, height: height), frames)
    }

    /// A chip wider than the line is measured at `maxWidth` so its `Text` can
    /// wrap; tokens stay in source order.
    private func fittedSize(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let unconstrained = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, maxWidth > 0, unconstrained.width > maxWidth else {
            return unconstrained
        }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}
