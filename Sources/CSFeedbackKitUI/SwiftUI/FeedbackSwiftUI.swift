import SwiftUI
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
