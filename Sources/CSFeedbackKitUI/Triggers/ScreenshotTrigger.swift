import UIKit
import CSFeedbackKit

@MainActor
extension Feedback {
    /// Lets the config's `triggers` open the composer. Call once, right after `Feedback.start`.
    ///
    /// With `{ "type": "screenshot" }`, a screenshot offers the composer for the visible screen
    /// (an alert titled `prompt`, or straight to the composer when `prompt` is absent).
    /// The system screenshot is ignored; the composer takes its own snapshot of the app.
    public static func installTriggers() {
        triggerHandler = { trigger in
            switch trigger.type {
            case .screenshot:
                ScreenshotPrompt.offer(trigger)
            }
        }
    }

    /// Return `false` to skip the screenshot prompt on a screen, e.g. while the app's own
    /// sheet is open. Called with the visible view controller.
    public static var shouldOfferScreenshotPrompt: ((UIViewController) -> Bool)?
}

@MainActor
enum ScreenshotPrompt {
    private static var isOffering = false

    static func offer(_ trigger: TriggerConfig) {
        guard !isOffering, let configuration = Feedback.configuration,
              let screen = ViewControllerTree.foregroundTop() else { return }
        guard !(screen is UIAlertController),
              !ViewControllerTree.isShowingComposer(over: screen),
              Feedback.shouldOfferScreenshotPrompt?(screen) ?? true else { return }

        guard let title = trigger.prompt else {
            Feedback.present(from: screen, forcesScreenshot: true)
            return
        }

        let copy = configuration.copy
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: copy.promptCancel, style: .cancel) { _ in
            isOffering = false
        })
        alert.addAction(UIAlertAction(title: copy.promptAction, style: .default) { _ in
            isOffering = false
            afterAlertDismisses(on: screen) {
                Feedback.present(from: screen, forcesScreenshot: true)
            }
        })
        isOffering = true
        ViewControllerTree.presentationAnchor(for: screen).present(alert, animated: true)
    }

    /// Opens the composer once the alert's dismissal finishes, so the snapshot doesn't include it.
    private static func afterAlertDismisses(on screen: UIViewController, _ open: @escaping @MainActor () -> Void) {
        guard let coordinator = screen.transitionCoordinator else {
            DispatchQueue.main.async { open() }
            return
        }
        coordinator.animate(alongsideTransition: nil) { _ in
            DispatchQueue.main.async { open() }
        }
    }
}
