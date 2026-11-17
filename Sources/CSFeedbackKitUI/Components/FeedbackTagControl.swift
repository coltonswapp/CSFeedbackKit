import UIKit

/// Glass pill that toggles on tap. Port of Shizen's `GlassTagControl`.
/// Width is measured at the selected (semibold) weight so toggling never reflows the row.
final class FeedbackTagControl: UIControl {
    private static let cornerRadius: CGFloat = 18
    private static let contentInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    private static var regularFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .regular))
    }
    private static var selectedFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
    }
    static var fixedHeight: CGFloat {
        ceil(selectedFont.lineHeight) + contentInsets.top + contentInsets.bottom
    }

    let title: String
    private let tint: UIColor
    private let glassView: UIVisualEffectView
    /// Selected fill on OS versions without glass tint.
    private let selectedFillView = UIView()
    private let titleLabel = UILabel()
    private let selectionHaptic = UISelectionFeedbackGenerator()

    init(title: String, tint: UIColor) {
        self.title = title
        self.tint = tint
        glassView = Self.makeGlass()
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = title

        Self.applyPillStyle(to: glassView)
        glassView.isUserInteractionEnabled = false

        selectedFillView.translatesAutoresizingMaskIntoConstraints = false
        selectedFillView.backgroundColor = tint
        selectedFillView.layer.cornerRadius = Self.cornerRadius
        selectedFillView.layer.cornerCurve = .continuous
        selectedFillView.isUserInteractionEnabled = false
        selectedFillView.alpha = 0

        titleLabel.text = title
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassView)
        addSubview(selectedFillView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectedFillView.topAnchor.constraint(equalTo: topAnchor),
            selectedFillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectedFillView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectedFillView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(toggleSelected), for: .touchUpInside)
        applySelectionAppearance(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            applySelectionAppearance(animated: true)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            animatePress(down: isHighlighted)
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        selectionHaptic.prepare()
    }

    /// Sets selection without animation, e.g. for the initial state.
    func setSelectedWithoutAnimation(_ selected: Bool) {
        UIView.performWithoutAnimation { isSelected = selected }
    }

    @objc private func toggleSelected() {
        isSelected.toggle()
        selectionHaptic.selectionChanged()
        sendActions(for: .valueChanged)
    }

    private func applySelectionAppearance(animated: Bool) {
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        titleLabel.font = isSelected ? Self.selectedFont : Self.regularFont

        let fillAlpha: CGFloat
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.isInteractive = false
            if isSelected { glassEffect.tintColor = tint }
            glassView.effect = glassEffect
            fillAlpha = 0
        } else {
            fillAlpha = isSelected ? 1 : 0
        }

        let updates = { [self] in
            selectedFillView.alpha = fillAlpha
            titleLabel.textColor = isSelected ? .white : .label
            glassView.layer.borderColor = isSelected
                ? UIColor.clear.cgColor
                : UIColor.white.withAlphaComponent(0.22).cgColor
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: updates)
        } else {
            updates()
        }
    }

    private func animatePress(down: Bool) {
        UIView.animate(
            withDuration: down ? 0.12 : 0.28,
            delay: 0,
            usingSpringWithDamping: down ? 1 : 0.6,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.transform = down ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleWidth = ceil(title.size(withAttributes: [.font: Self.selectedFont]).width)
        return CGSize(
            width: titleWidth + Self.contentInsets.left + Self.contentInsets.right,
            height: Self.fixedHeight
        )
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(.zero)
    }

    // MARK: Glass (from InteractionKit's LiquidGlassEffectView pill style)

    private static func makeGlass() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.isInteractive = false
            return UIVisualEffectView(effect: glassEffect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    }

    private static func applyPillStyle(to view: UIVisualEffectView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        view.clipsToBounds = false
        view.layer.masksToBounds = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.layer.shadowRadius = 12
        view.layer.shadowOpacity = 0.3
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        } else {
            view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        }
    }
}
