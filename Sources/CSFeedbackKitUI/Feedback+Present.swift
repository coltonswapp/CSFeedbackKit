import UIKit
import CSFeedbackKit

@MainActor
extension Feedback {
    /// Composer styling and app hooks (toast, sheet tweaks). Set once at launch.
    public static var appearance = FeedbackAppearance()

    /// Opens the composer for the visible screen.
    ///
    /// Freezes context first (fields, tester, time), then snapshots the window, so what's
    /// sent matches what the tester was looking at, not what's on screen when they hit Send.
    ///
    /// - Parameters:
    ///   - screen: The screen the note is about. Default: the top view controller.
    ///   - forcesScreenshot: Start with the screenshot chip on, ignoring the last choice.
    /// - Returns: `false` when inactive (environment, `enabledWhen`), nothing to present from,
    ///   or a composer is already open.
    @discardableResult
    public static func present(from screen: UIViewController? = nil, forcesScreenshot: Bool = false) -> Bool {
        guard isActive, let configuration else { return false }
        guard let screen = screen ?? ViewControllerTree.foregroundTop() else { return false }
        guard !ViewControllerTree.isShowingComposer(over: screen) else { return false }

        let providers = ViewControllerTree.contextProviders(around: screen) + SwiftUIContextRegistry.providersNearestFirst
        let source = FeedbackPayload.Source(
            screen: String(describing: type(of: screen)),
            title: ViewControllerTree.title(of: screen)
        )
        guard let captured = Feedback.capture(source: source, contextProviders: providers) else { return false }

        var screenshot: Data?
        if let config = configuration.attachments.screenshot, config.enabled,
           config.environments.allowsEnvironment(captured.environment) {
            // The whole window, so nav bars and tab bars are in the picture.
            let target: UIView = screen.view.window ?? screen.view
            screenshot = ViewSnapshotter.jpeg(
                of: target,
                maxLongEdge: CGFloat(config.maxLongEdge),
                quality: CGFloat(config.jpegQuality),
                redactSecureFields: config.redactSecureFields
            )
        }

        let composer = FeedbackComposerViewController(
            capture: captured,
            configuration: configuration,
            appearance: appearance,
            screenshotJPEG: screenshot,
            forcesScreenshot: forcesScreenshot
        )
        let sheet = UINavigationController(rootViewController: composer)
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.selectedDetentIdentifier = .large
            presentation.prefersGrabberVisible = true
            appearance.configureSheet?(presentation)
        }
        ViewControllerTree.presentationAnchor(for: screen).present(sheet, animated: true)
        return true
    }
}
