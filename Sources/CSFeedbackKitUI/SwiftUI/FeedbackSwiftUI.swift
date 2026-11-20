import SwiftUI
import UIKit
import CSFeedbackKit

// MARK: - Context from SwiftUI screens

extension View {
    /// Supplies screen-source field values while this view is on screen.
    ///
    /// ```swift
    /// GrillDetailView(grill: grill)
    ///     .feedbackContext(["grillId": .string(grill.id), "firmware": .string(grill.firmware)])
    /// ```
    ///
    /// Values update whenever they change. When several screens supply the same key,
    /// the most recently shown wins. UIKit context providers on the visible controller
    /// still come first.
    public func feedbackContext(_ values: FeedbackValues) -> some View {
        modifier(FeedbackContextModifier(values: values))
    }
}

private struct FeedbackContextModifier: ViewModifier {
    let values: FeedbackValues
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let id = id
        let values = values
        return content
            .task(id: values) {
                await MainActor.run { SwiftUIContextRegistry.set(id, values) }
            }
            .onDisappear {
                SwiftUIContextRegistry.remove(id)
            }
    }
}

@MainActor
enum SwiftUIContextRegistry {
    private struct Entry {
        let id: UUID
        var values: FeedbackValues
    }

    private struct Provider: FeedbackContextProvider {
        let values: FeedbackValues
        func feedbackValues() -> FeedbackValues { values }
    }

    /// Order shown, oldest first.
    private static var entries: [Entry] = []

    static func set(_ id: UUID, _ values: FeedbackValues) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].values = values
        } else {
            entries.append(Entry(id: id, values: values))
        }
    }

    static func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    static var providersNearestFirst: [any FeedbackContextProvider] {
        entries.reversed().map { Provider(values: $0.values) }
    }
}

// MARK: - Naming SwiftUI screens

extension View {
    /// Names this screen in the payload's `source.screen`, in place of the hosting controller's type
    /// (`UIHostingController<AnyView>` and the like).
    ///
    /// ```swift
    /// RecipeDetailView(recipe: recipe)
    ///     .feedbackScreen("RecipeDetail")
    /// ```
    ///
    /// The name only applies while this view is on screen inside the controller the note is about.
    /// If several named views are visible there, the most deeply nested one wins.
    public func feedbackScreen(_ name: String) -> some View {
        background(FeedbackScreenMarker(name: name).allowsHitTesting(false).accessibilityHidden(true))
    }
}

private struct FeedbackScreenMarker: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isUserInteractionEnabled = false
        view.name = name
        SwiftUIScreenRegistry.add(view)
        return view
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.name = name
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        SwiftUIScreenRegistry.remove(view)
    }

    final class MarkerView: UIView {
        var name = ""
    }
}

@MainActor
enum SwiftUIScreenRegistry {
    private struct Entry {
        weak var view: FeedbackScreenMarker.MarkerView?
    }

    /// Order added, oldest first.
    private static var entries: [Entry] = []

    fileprivate static func add(_ view: FeedbackScreenMarker.MarkerView) {
        entries.removeAll { $0.view == nil }
        entries.append(Entry(view: view))
    }

    fileprivate static func remove(_ view: FeedbackScreenMarker.MarkerView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    /// The name of the deepest visible marker inside `controller`'s view; ties go to the most recent.
    static func name(within controller: UIViewController) -> String? {
        guard controller.isViewLoaded, let root = controller.view else { return nil }
        var best: (name: String, depth: Int)?
        for view in entries.compactMap(\.view) {
            guard !view.name.isEmpty, isVisible(view, within: root) else { continue }
            let depth = depth(of: view)
            if best.map({ depth >= $0.depth }) ?? true {
                best = (view.name, depth)
            }
        }
        return best?.name
    }

    private static func isVisible(_ view: UIView, within root: UIView) -> Bool {
        guard let window = view.window, view.isDescendant(of: root) else { return false }
        var current: UIView? = view
        while let candidate = current, candidate !== window {
            if candidate.isHidden || candidate.alpha <= 0.01 { return false }
            current = candidate.superview
        }
        // Off-screen pages (paged TabView, carousels) stay in the window but outside its bounds.
        let frame = view.convert(view.bounds, to: window)
        return frame.intersects(window.bounds) || (frame.isEmpty && window.bounds.contains(frame.origin))
    }

    private static func depth(of view: UIView) -> Int {
        var depth = 0
        var current = view.superview
        while let candidate = current {
            depth += 1
            current = candidate.superview
        }
        return depth
    }
}

// MARK: - Opening the composer from SwiftUI

/// A button that opens the composer for the current screen. Hidden when feedback is inactive.
///
/// ```swift
/// .toolbar { FeedbackButton() }
/// ```
public struct FeedbackButton<Label: View>: View {
    private let label: Label

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        if Feedback.isActive {
            Button {
                Feedback.present()
            } label: {
                label
            }
        }
    }
}

extension FeedbackButton where Label == SwiftUI.Label<Text, Image> {
    public init(_ title: String = "Feedback") {
        self.init { SwiftUI.Label(title, systemImage: "text.bubble") }
    }
}
