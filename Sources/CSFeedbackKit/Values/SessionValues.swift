import Foundation

/// App-wide values, registered once (e.g. after login) and read at capture time.
///
/// ```swift
/// Feedback.session.provide("userEmail") { AuthStore.shared.currentUser?.email }
/// Feedback.session.provide("grillId") { GrillStore.shared.primaryGrill?.id }
/// ```
@MainActor
public final class SessionValues {
    public typealias Provider = @MainActor () -> FeedbackValue?

    private var providers: [String: Provider] = [:]

    init() {}

    /// Registers or replaces the provider for a declared field.
    /// Return `nil` for "not set". Providers must be cheap and must not block.
    public func provide<Value: FeedbackValueConvertible>(
        _ key: String,
        _ provider: @escaping @MainActor () -> Value?
    ) {
        providers[key] = { provider()?.feedbackValue }
        Feedback.warnIfUndeclared(key, source: .session)
    }

    /// Fixed value, e.g. set once after login and cleared on logout.
    public func set<Value: FeedbackValueConvertible>(_ key: String, _ value: Value?) {
        if let value {
            let captured = value.feedbackValue
            provide(key) { captured }
        } else {
            remove(key)
        }
    }

    public func remove(_ key: String) {
        providers[key] = nil
    }

    public func removeAll() {
        providers.removeAll()
    }

    /// Calls every provider. Runs at capture time.
    func snapshot() -> FeedbackValues {
        var values: FeedbackValues = [:]
        for (key, provider) in providers {
            if let value = provider() { values[key] = value }
        }
        return values
    }

    var registeredKeys: [String] { Array(providers.keys) }
}
