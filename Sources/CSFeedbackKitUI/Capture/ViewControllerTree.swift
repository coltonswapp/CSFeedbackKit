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
        if let base, let child = fillingChild(of: base) {
            return top(from: child)
        }
        return base
    }

    /// The visible child that is the parent's content, not an accessory inside it.
    ///
    /// Covers wrappers (a hosting controller around a representable, custom root containers):
    /// the largest visible child, if it covers most of the parent. Coverage, not an exact size
    /// match, so a child inset by the safe area still counts and a mini player or card doesn't.
    private static func fillingChild(of base: UIViewController) -> UIViewController? {
        guard base.isViewLoaded else { return nil }
        let bounds = base.view.bounds
        let parentArea = bounds.width * bounds.height
        guard parentArea > 0 else { return nil }

        let candidates = base.children.compactMap { child -> (UIViewController, CGFloat)? in
            guard child.isViewLoaded, child.view.window != nil, !child.view.isHidden, child.view.alpha > 0.01
            else { return nil }
            let frame = child.view.convert(child.view.bounds, to: base.view).intersection(bounds)
            guard !frame.isNull else { return nil }
            return (child, frame.width * frame.height)
        }
        guard let (child, area) = candidates.max(by: { $0.1 < $1.1 }),
              area >= parentArea * minimumChildCoverage else { return nil }
        return child
    }

    /// Share of the parent a child must cover to be treated as the screen.
    /// iPhone safe-area insets take roughly 11%, so 0.75 leaves room for them.
    private static let minimumChildCoverage: CGFloat = 0.75

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

    /// The screen name for the payload: a SwiftUI `.feedbackScreen` name inside `controller`, else its type.
    static func screenName(of controller: UIViewController) -> String {
        SwiftUIScreenRegistry.name(within: controller) ?? String(describing: type(of: controller))
    }

    static func title(of controller: UIViewController) -> String? {
        for candidate in [controller.navigationItem.title, controller.title] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
