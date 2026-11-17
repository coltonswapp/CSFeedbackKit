import UIKit
import ObjectiveC

/// Downscaled JPEG of what's on screen, with sensitive views blacked out.
/// Port of Shizen's `LessonHostSnapshot`, rendering straight at the target size.
@MainActor
enum ViewSnapshotter {
    static func jpeg(
        of view: UIView,
        maxLongEdge: CGFloat,
        quality: CGFloat,
        redactSecureFields: Bool
    ) -> Data? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let displayScale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 1
        let longEdgePoints = max(bounds.width, bounds.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(displayScale, maxLongEdge / longEdgePoints)
        format.opaque = true

        let redactions = redactionRects(in: view, includeSecureFields: redactSecureFields)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            (view.backgroundColor ?? .systemBackground).setFill()
            context.fill(bounds)
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            UIColor.black.setFill()
            redactions.forEach { context.fill($0) }
        }
        guard let data = image.jpegData(compressionQuality: quality), !data.isEmpty else { return nil }
        return data
    }

    /// Secure text fields and anything marked `isFeedbackRedacted`, in `root` coordinates.
    private static func redactionRects(in root: UIView, includeSecureFields: Bool) -> [CGRect] {
        var rects: [CGRect] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let isSecure = includeSecureFields && ((view as? UITextField)?.isSecureTextEntry ?? false)
            if view.isFeedbackRedacted || isSecure {
                rects.append(view.convert(view.bounds, to: root))
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return rects
    }
}

nonisolated(unsafe) private var feedbackRedactedKey: UInt8 = 0

extension UIView {
    /// Blacked out in feedback screenshots, e.g. a label showing an email or address.
    public var isFeedbackRedacted: Bool {
        get { (objc_getAssociatedObject(self, &feedbackRedactedKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &feedbackRedactedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
