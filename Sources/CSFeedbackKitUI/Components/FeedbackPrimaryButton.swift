import UIKit

/// Primary send button. Port of Shizen's `PrimaryButton`: press scale, haptics,
/// highlighted and disabled colors.
final class FeedbackPrimaryButton: UIButton {
    static let preferredHeight: CGFloat = 55
    static let horizontalInset: CGFloat = 16

    var colors: FeedbackAppearance.ButtonColors {
        didSet { applyAppearance() }
    }

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { resetPressAnimation(animated: false) }
            applyAppearance()
        }
    }

    private var restingBackgroundColor: UIColor = .clear
    private var isPressAnimating = false
    private var touchDownTimestamp: TimeInterval?
    private let hapticThreshold: TimeInterval = 0.15
    private let pressHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let releaseHaptic = UIImpactFeedbackGenerator(style: .light)

    init(colors: FeedbackAppearance.ButtonColors) {
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(touchCancelled), for: [.touchDragExit, .touchUpOutside, .touchCancel])
        addTarget(self, action: #selector(touchUpInside), for: .touchUpInside)
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        pressHaptic.prepare()
        releaseHaptic.prepare()
    }

    @objc private func touchDown() {
        guard isEnabled else { return }
        touchDownTimestamp = Date().timeIntervalSince1970
        pressHaptic.impactOccurred()
        isPressAnimating = true
        let pressed = colors.highlightedBackground
        UIView.animate(withDuration: 0.075, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            self.updateBackgroundColor(pressed)
        }
    }

    @objc private func touchCancelled() {
        touchDownTimestamp = nil
        resetPressAnimation(animated: true)
    }

    @objc private func touchUpInside() {
        if let timestamp = touchDownTimestamp, Date().timeIntervalSince1970 - timestamp > hapticThreshold {
            releaseHaptic.impactOccurred()
        }
        touchDownTimestamp = nil
        resetPressAnimation(animated: true)
    }

    private func resetPressAnimation(animated: Bool) {
        isPressAnimating = false
        let restore = {
            self.transform = .identity
            self.updateBackgroundColor(self.restingBackgroundColor)
        }
        guard animated else {
            restore()
            return
        }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: restore)
    }

    private func updateBackgroundColor(_ color: UIColor) {
        guard var config = configuration else { return }
        config.background.backgroundColor = color
        configuration = config
    }

    private func applyAppearance() {
        let background = isEnabled ? colors.background : colors.disabledBackground
        restingBackgroundColor = background
        let titleColor = isEnabled ? colors.title : colors.disabledTitle

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = colors.cornerRadius
        config.background.backgroundColor = isEnabled && isPressAnimating ? colors.highlightedBackground : background
        config.baseForegroundColor = titleColor
        config.image = UIImage(systemName: "paperplane.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
        configuration = config
    }
}
