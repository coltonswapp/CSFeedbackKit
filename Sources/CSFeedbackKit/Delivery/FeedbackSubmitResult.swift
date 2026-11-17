import Foundation

/// A note saved in the outbox, waiting for `Feedback.deliver`.
public struct SavedFeedback: Sendable, Equatable {
    /// Payload id, also the idempotency / delivery id.
    public let id: String
}

/// What happened right after submit.
public enum FeedbackSubmitResult: Sendable, Equatable {
    /// Every destination accepted it. `responseIds` maps destination id → `id` the receiver returned.
    case delivered(responseIds: [String: String])
    /// Saved on device; at least one destination will be retried (on reconnect, foreground,
    /// next launch, or backoff). The note is not lost.
    case queued(lastError: String?)

    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }
}
