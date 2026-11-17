import Foundation

/// Everything known the moment the tester asked to give feedback. Values are frozen here,
/// so a later logout or screen change doesn't alter what the note says.
public struct FeedbackCapture: Sendable, Equatable {
    /// Becomes the payload `id` and idempotency key.
    public let id: String
    public let createdAt: Date
    public let environment: FeedbackEnvironment
    public let source: FeedbackPayload.Source?
    public let fields: ResolvedFields
    /// From the configured field or the remembered prompt answer.
    public let testerIdentity: String?
}

/// What the tester wrote and chose in the composer.
public struct FeedbackDraft: Sendable, Equatable {
    public var note: String
    /// Selected tag ids. Sent in config order; unknown ids are ignored.
    public var tagIDs: Set<String>
    /// Values the tester typed, e.g. for required fields nobody supplied.
    public var filledFields: FeedbackValues
    /// Already downscaled and encoded by the capture layer.
    public var screenshotJPEG: Data?
    public var includeLogs: Bool
    /// Prompt answer. Remembered on device when `tester.source` is `prompt`.
    public var testerIdentity: String?
    /// Set by the tray when items are submitted together.
    public var sessionId: String?

    public init(
        note: String,
        tagIDs: Set<String> = [],
        filledFields: FeedbackValues = [:],
        screenshotJPEG: Data? = nil,
        includeLogs: Bool = true,
        testerIdentity: String? = nil,
        sessionId: String? = nil
    ) {
        self.note = note
        self.tagIDs = tagIDs
        self.filledFields = filledFields
        self.screenshotJPEG = screenshotJPEG
        self.includeLogs = includeLogs
        self.testerIdentity = testerIdentity
        self.sessionId = sessionId
    }
}

public enum FeedbackError: Error, Equatable, LocalizedError {
    /// `Feedback.start` wasn't called, or the config was invalid.
    case notStarted
    /// Wrong environment, or the `enabledWhen` check failed.
    case notActive
    case emptyNote
    /// Labels of required fields still empty.
    case missingRequiredFields([String])
    /// No destination is enabled for this environment.
    case noDestinations
    /// Couldn't save the note on device.
    case storageFailed(String)
    /// Every destination refused it or gave up. The note stays in the queue for a manual resend.
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "Feedback isn’t set up."
        case .notActive: return "Feedback isn’t available in this build."
        case .emptyNote: return "Write a note first."
        case .missingRequiredFields(let labels): return "Fill in: \(labels.joined(separator: ", "))."
        case .noDestinations: return "No destination is set up for this build."
        case .storageFailed(let detail): return "Couldn’t save the note: \(detail)"
        case .rejected(let detail): return "Not delivered (\(detail)). It’s saved in the feedback queue."
        }
    }
}
