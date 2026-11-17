import UIKit
import CSFeedbackKit

/// Styling and app hooks for the composer. Set once at launch:
///
/// ```swift
/// Feedback.appearance = FeedbackAppearance(
///     sendButton: .yellow,
///     configureSheet: { $0.applySolidNonLargeBackground(.secondarySystemBackground) },
///     showToast: { presenter, toast in presenter.showToast(text: toast.text, sentiment: toast.kind == .error ? .negative : .positive) }
/// )
/// ```
@MainActor
public struct FeedbackAppearance {
    public struct ButtonColors: Sendable {
        public var background: UIColor
        public var title: UIColor
        public var highlightedBackground: UIColor
        public var disabledBackground: UIColor
        public var disabledTitle: UIColor
        public var cornerRadius: CGFloat

        public init(
            background: UIColor,
            title: UIColor,
            highlightedBackground: UIColor,
            disabledBackground: UIColor,
            disabledTitle: UIColor,
            cornerRadius: CGFloat = 14
        ) {
            self.background = background
            self.title = title
            self.highlightedBackground = highlightedBackground
            self.disabledBackground = disabledBackground
            self.disabledTitle = disabledTitle
            self.cornerRadius = cornerRadius
        }

        public static let blue = ButtonColors(
            background: UIColor(red: 1 / 255, green: 140 / 255, blue: 253 / 255, alpha: 1),
            title: .white,
            highlightedBackground: UIColor(red: 0 / 255, green: 122 / 255, blue: 222 / 255, alpha: 1),
            disabledBackground: UIColor(red: 168 / 255, green: 184 / 255, blue: 201 / 255, alpha: 1),
            disabledTitle: UIColor(red: 244 / 255, green: 247 / 255, blue: 250 / 255, alpha: 1)
        )

        public static let yellow = ButtonColors(
            background: UIColor(red: 253 / 255, green: 200 / 255, blue: 1 / 255, alpha: 1),
            title: UIColor(red: 144 / 255, green: 114 / 255, blue: 2 / 255, alpha: 1),
            highlightedBackground: UIColor(red: 245 / 255, green: 190 / 255, blue: 0 / 255, alpha: 1),
            disabledBackground: UIColor(red: 210 / 255, green: 205 / 255, blue: 188 / 255, alpha: 1),
            disabledTitle: UIColor(red: 132 / 255, green: 124 / 255, blue: 108 / 255, alpha: 1)
        )
    }

    public typealias ToastHandler = @MainActor (_ presenter: UIViewController, _ toast: FeedbackToast) -> Void

    /// Sheet background.
    public var pageBackground: UIColor
    public var sendButton: ButtonColors
    /// Fill of a selected tag chip.
    public var selectedTagTint: UIColor
    /// Last chance to adjust the sheet (detents, backgrounds) before it's presented.
    public var configureSheet: (@MainActor (UISheetPresentationController) -> Void)?
    /// Show a toast with the app's own component. Default: a small built-in pill.
    public var showToast: ToastHandler

    public init(
        pageBackground: UIColor = FeedbackAppearance.defaultPageBackground,
        sendButton: ButtonColors = .blue,
        selectedTagTint: UIColor = .systemBlue,
        configureSheet: (@MainActor (UISheetPresentationController) -> Void)? = nil,
        showToast: ToastHandler? = nil
    ) {
        self.pageBackground = pageBackground
        self.sendButton = sendButton
        self.selectedTagTint = selectedTagTint
        self.configureSheet = configureSheet
        self.showToast = showToast ?? { presenter, toast in BuiltInToast.show(toast, over: presenter) }
    }

    public static let defaultPageBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGroupedBackground
            : UIColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1)
    }
}

public struct FeedbackToast: Sendable, Equatable {
    public enum Kind: Sendable {
        case success
        /// Saved but not delivered yet.
        case info
        case error
    }

    public var text: String
    public var kind: Kind
}

/// Minimal fallback toast: a pill near the top of the window that fades out.
@MainActor
enum BuiltInToast {
    static func show(_ toast: FeedbackToast, over presenter: UIViewController) {
        guard let window = presenter.view.window ?? presenter.presentingViewController?.view.window else { return }

        let label = PaddedLabel()
        label.text = toast.text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.backgroundColor = {
            switch toast.kind {
            case .success: return UIColor.black.withAlphaComponent(0.85)
            case .info: return UIColor.darkGray.withAlphaComponent(0.92)
            case .error: return UIColor.systemRed.withAlphaComponent(0.92)
            }
        }()
        label.layer.cornerRadius = 18
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityTraits = .staticText

        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -40),
        ])
        UIAccessibility.post(notification: .announcement, argument: toast.text)

        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    private final class PaddedLabel: UILabel {
        private let insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: insets))
        }

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
        }

        override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
            let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
            return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
        }
    }
}
