import Foundation

/// A screen that knows more about what the tester is looking at.
///
/// The composer walks from the visible view controller up through parents and presenters.
/// Every provider found contributes; the nearest one wins on conflicts. Only keys declared
/// in `fields` with `"screen"` in `sources` are kept.
///
/// ```swift
/// extension GrillDetailViewController: FeedbackContextProvider {
///     func feedbackValues() -> FeedbackValues {
///         ["grillId": .string(grill.id), "firmware": .string(grill.firmwareVersion)]
///     }
/// }
/// ```
@MainActor
public protocol FeedbackContextProvider {
    func feedbackValues() -> FeedbackValues
}

/// Types a session provider may return.
public protocol FeedbackValueConvertible {
    var feedbackValue: FeedbackValue { get }
}

extension FeedbackValue: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { self }
}

extension String: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { .string(self) }
}

extension Int: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { .number(Double(self)) }
}

extension Double: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { .number(self) }
}

extension Bool: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { .bool(self) }
}

extension UUID: FeedbackValueConvertible {
    public var feedbackValue: FeedbackValue { .string(uuidString) }
}

extension Array: FeedbackValueConvertible where Element == String {
    public var feedbackValue: FeedbackValue { .strings(self) }
}
