import UIKit
import CSFeedbackKit

/// Finding the visible screen and the context providers around it.
@MainActor
enum ViewControllerTree {
    static func foregroundTop() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return top(from: window?.rootViewController)
    }

    static func top(from base: UIViewController?) -> UIViewController? {
        if let navigation = base as? UINavigationController {
            return top(from: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return top(from: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController, !presented.isBeingDismissed {
            return top(from: presented)
        }
        return base
    }

    /// The controller to present from: `controller` or whatever it's already presenting.
    static func presentationAnchor(for controller: UIViewController) -> UIViewController {
        var anchor = controller
        while let presented = anchor.presentedViewController, !presented.isBeingDismissed {
            anchor = presented
        }
        return anchor
    }

    /// Nearest first: visible children of `screen`, then `screen`, then its parents and presenters.
    static func contextProviders(around screen: UIViewController) -> [any FeedbackContextProvider] {
        var providers: [any FeedbackContextProvider] = []
        var seen = Set<ObjectIdentifier>()

        func add(_ controller: UIViewController) {
            guard seen.insert(ObjectIdentifier(controller)).inserted,
                  let provider = controller as? any FeedbackContextProvider else { return }
            providers.append(provider)
        }

        func visibleDescendants(of controller: UIViewController) -> [UIViewController] {
            controller.children
                .filter { $0.isViewLoaded && $0.view.window != nil && !$0.view.isHidden }
                .flatMap { visibleDescendants(of: $0) + [$0] }
        }

        visibleDescendants(of: screen).forEach(add)
        var current: UIViewController? = screen
        while let controller = current {
            add(controller)
            current = controller.parent ?? controller.presentingViewController
        }
        return providers
    }

    static func isShowingComposer(over controller: UIViewController) -> Bool {
        var current: UIViewController? = controller
        while let candidate = current {
            if candidate is FeedbackComposerViewController { return true }
            if let navigation = candidate as? UINavigationController,
               navigation.viewControllers.contains(where: { $0 is FeedbackComposerViewController }) {
                return true
            }
            current = candidate.presentedViewController
        }
        if let navigation = controller.navigationController,
           navigation.viewControllers.contains(where: { $0 is FeedbackComposerViewController }) {
            return true
        }
        return false
    }

    static func title(of controller: UIViewController) -> String? {
        for candidate in [controller.navigationItem.title, controller.title] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
