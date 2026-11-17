import UIKit

/// Wraps tag chips into balanced rows so a long label doesn't leave a chip alone.
/// Port of Shizen's `GlassTagFlowView` + `GlassPillFlowLayout`.
final class FeedbackTagFlowView: UIView {
    private static let horizontalSpacing: CGFloat = 10
    private static let verticalSpacing: CGFloat = 10

    private var tagViews: [FeedbackTagControl] = []
    private var laidOutHeight: CGFloat = 0

    func setTags(_ tags: [FeedbackTagControl]) {
        tagViews.forEach { $0.removeFromSuperview() }
        tagViews = tags
        tags.forEach { addSubview($0) }
        laidOutHeight = 0
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = nearestLaidOutWidth
        guard width > 0 else { return }
        let layout = flowLayout(in: width)
        zip(tagViews, layout.frames).forEach { $0.frame = $1 }
        if abs(layout.height - laidOutHeight) > 0.5 {
            laidOutHeight = layout.height
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = nearestLaidOutWidth
        guard width > 0, !tagViews.isEmpty else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 0)
        }
        let height = laidOutHeight > 0 ? laidOutHeight : flowLayout(in: width).height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width > 0 ? size.width : nearestLaidOutWidth
        return CGSize(width: width, height: flowLayout(in: width).height)
    }

    /// Own width, else the nearest ancestor's, so the flow can size before its first layout pass.
    private var nearestLaidOutWidth: CGFloat {
        var view: UIView? = self
        while let candidate = view {
            if candidate.bounds.width > 0 { return candidate.bounds.width }
            view = candidate.superview
        }
        return 0
    }

    private func flowLayout(in width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        Self.balancedFrames(for: tagViews.map { $0.sizeThatFits(.zero) }, in: width)
    }

    // MARK: Layout

    private static func greedyFrames(for sizes: [CGSize], in width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x != 0, x + size.width > width + 0.5 {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, sizes.isEmpty ? 0 : y + rowHeight)
    }

    /// Left-aligned rows with break points chosen so leftover space is shared across rows.
    /// A row of one chip is used only when nothing else fits.
    private static func balancedFrames(for sizes: [CGSize], in width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let count = sizes.count
        guard count > 0, width > 0 else { return ([], 0) }

        func rowWidth(from start: Int, to end: Int) -> CGFloat? {
            var used: CGFloat = 0
            for index in start..<end {
                if index > start { used += horizontalSpacing }
                used += sizes[index].width
                if used > width + 0.5 { return nil }
            }
            return used
        }

        var cost = Array(repeating: CGFloat.greatestFiniteMagnitude, count: count + 1)
        var choice = Array(repeating: 0, count: count + 1)
        cost[0] = 0
        for start in 0..<count {
            guard cost[start] < .greatestFiniteMagnitude else { continue }
            for end in (start + 1)...count {
                guard let used = rowWidth(from: start, to: end) else { break }
                let leftover = width - used
                var rowCost = leftover * leftover
                if end - start == 1, count > 1 { rowCost += 80_000 }
                let total = cost[start] + rowCost
                if total < cost[end] {
                    cost[end] = total
                    choice[end] = start
                }
            }
        }
        guard cost[count] < .greatestFiniteMagnitude else { return greedyFrames(for: sizes, in: width) }

        var spans: [(start: Int, end: Int)] = []
        var end = count
        while end > 0 {
            let start = choice[end]
            spans.append((start, end))
            end = start
        }

        var frames: [CGRect] = []
        var y: CGFloat = 0
        for (offset, span) in spans.reversed().enumerated() {
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for index in span.start..<span.end {
                let size = sizes[index]
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                x += size.width + horizontalSpacing
                rowHeight = max(rowHeight, size.height)
            }
            y += offset == spans.count - 1 ? rowHeight : rowHeight + verticalSpacing
        }
        return (frames, y)
    }
}
