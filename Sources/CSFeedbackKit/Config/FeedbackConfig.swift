import Foundation

/// The whole system, described by one JSON file in the host app.
/// Schema: `Schemas/csfeedbackkit.config.v1.schema.json`.
///
/// The file says *what* happens. Code supplies only what a file can't hold,
/// registered by name: auth handlers (`destinations[].auth`), checks (`enabledWhen`),
/// and field values (session and screen providers).
///
/// `${NAME}` in destination URLs and header values resolves from the app's Info.plist.
public struct FeedbackConfig: Codable, Sendable, Equatable {
    public static let supportedVersion = 1

    public var version: Int
    /// Build environments where the package runs. Elsewhere it's inert.
    public var enabledIn: [FeedbackEnvironment]
    /// Name of a check registered in code, e.g. "staffAccess". Optional.
    public var enabledWhen: String?
    public var tester: TesterConfig
    public var fields: [FieldConfig]
    public var tags: [TagConfig]
    public var destinations: [DestinationConfig]
    public var attachments: AttachmentsConfig
    public var triggers: [TriggerConfig]
    public var session: SessionConfig
    /// Where attachments go for destinations with `"attachments": "link"`. Absent: no uploads.
    public var storage: StorageConfig?
    public var copy: CopyConfig

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabledIn = try c.decodeIfPresent([FeedbackEnvironment].self, forKey: .enabledIn) ?? [.xcode, .testflight]
        enabledWhen = try c.decodeIfPresent(String.self, forKey: .enabledWhen)
        tester = try c.decodeIfPresent(TesterConfig.self, forKey: .tester) ?? TesterConfig()
        fields = try c.decodeIfPresent([FieldConfig].self, forKey: .fields) ?? []
        tags = try c.decodeIfPresent([TagConfig].self, forKey: .tags) ?? []
        destinations = try c.decode([DestinationConfig].self, forKey: .destinations)
        attachments = try c.decodeIfPresent(AttachmentsConfig.self, forKey: .attachments) ?? AttachmentsConfig()
        triggers = try c.decodeIfPresent([TriggerConfig].self, forKey: .triggers) ?? []
        session = try c.decodeIfPresent(SessionConfig.self, forKey: .session) ?? SessionConfig()
        storage = try c.decodeIfPresent(StorageConfig.self, forKey: .storage)
        copy = try c.decodeIfPresent(CopyConfig.self, forKey: .copy) ?? CopyConfig()
    }
}

/// Where the running build came from.
public enum FeedbackEnvironment: String, Codable, Sendable, CaseIterable {
    /// Run from Xcode (debug or locally signed).
    case xcode
    /// Installed through TestFlight.
    case testflight
    /// Installed from the App Store.
    case appstore
}

// MARK: - Tester

public struct TesterConfig: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Don't send tester identity.
        case none
        /// Ask once, remember on device.
        case prompt
        /// Read from a declared field, e.g. the logged-in user's email.
        case field
    }

    public var source: Source
    /// Field key when `source` is `field`.
    public var field: String?
    /// Prompt title when `source` is `prompt`.
    public var prompt: String

    public init(source: Source = .none, field: String? = nil, prompt: String = "Your name or email") {
        self.source = source
        self.field = field
        self.prompt = prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .none
        field = try c.decodeIfPresent(String.self, forKey: .field)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? "Your name or email"
    }
}

// MARK: - Fields

/// A project-specific value sent under `custom` in the payload.
/// Declared here, supplied by code (or by `value` for static fields).
public struct FieldConfig: Codable, Sendable, Equatable {
    public enum ValueType: String, Codable, Sendable {
        case string
        case number
        case bool
        case stringArray
    }

    public enum Source: String, Codable, Sendable {
        /// Registered once, e.g. after login: `Feedback.session.provide(key) { … }`.
        case session
        /// From the visible screen's `FeedbackContextProvider`. Wins over session.
        case screen
    }

    public var key: String
    /// Label in the composer. Defaults to `key`.
    public var label: String
    public var type: ValueType
    /// Fixed value. When set, the field is static and `sources` is ignored.
    public var value: FeedbackValue?
    public var sources: [Source]
    /// Composer asks the tester to fill it when no provider supplies it.
    public var required: Bool
    /// Masked in the composer. Still sent in full.
    public var sensitive: Bool
    /// Shown in the composer's context section.
    public var visible: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        type = try c.decodeIfPresent(ValueType.self, forKey: .type) ?? .string
        value = try c.decodeIfPresent(FeedbackValue.self, forKey: .value)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? [.screen, .session]
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }

    public var isStatic: Bool { value != nil }
}

// MARK: - Tags

public struct TagConfig: Codable, Sendable, Equatable {
    public var id: String
    /// Chip text. Defaults to `#id`.
    public var label: String
    /// Starts selected in the composer.
    public var selected: Bool
    /// Opaque. Sent with the tag so receivers can route on it.
    public var metadata: [String: JSONValue]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "#\(id)"
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }
}

// MARK: - Destinations

public struct DestinationConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case http
    }

    public enum Encoding: String, Codable, Sendable {
        /// One JSON body. Attachments inline as base64.
        case json
        /// `payload` part with the JSON (no attachment data), plus one file part per attachment.
        case multipart
    }

    public var id: String
    public var type: Kind
    /// May contain `${NAME}` (Info.plist).
    public var url: String
    public var method: String
    /// Values may contain `${NAME}` (Info.plist).
    public var headers: [String: String]
    /// Name of an auth handler registered in code. Its headers win over `headers`.
    public var auth: String?
    public var encoding: Encoding
    public var timeoutSeconds: Double
    /// Delivery attempts before the outbox gives up on this destination.
    public var maxAttempts: Int
    /// Body size limit. Over it: shrink the screenshot, then drop logs, then the screenshot.
    /// The note itself is never dropped.
    public var maxBodyBytes: Int
    /// Sent as the payload's top-level `type`. Receivers like OpenBot route on it.
    public var eventType: String
    /// Request signing, e.g. Standard Webhooks (OpenBot, Svix, Clerk, Resend receivers).
    public var signing: SigningConfig?
    /// Body shape: `csfeedbackkit` (the v1 payload), `openbot` (OpenBot's `{type, occurredAt, data}`
    /// envelope), or the name of a format registered in code with `Feedback.start(formats:)`.
    public var format: String
    /// `inline`: attachments travel in the body. `none`: this destination gets none.
    public var attachments: AttachmentMode
    /// Only notes that match are sent here. Absent means every note.
    public var when: RouteCondition?
    /// Limit to these environments. Absent means all enabled environments.
    public var environments: [FeedbackEnvironment]?

    public enum AttachmentMode: String, Codable, Sendable {
        /// In the body (base64, or file parts for multipart).
        case inline
        /// Uploaded to `storage` once per note; the body carries a download `url` instead.
        case link
        /// Not sent to this destination.
        case none
    }

    public static let builtInFormats: Set<String> = ["csfeedbackkit", "openbot"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .http
        url = try c.decode(String.self, forKey: .url)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        auth = try c.decodeIfPresent(String.self, forKey: .auth)
        encoding = try c.decodeIfPresent(Encoding.self, forKey: .encoding) ?? .json
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 5
        maxBodyBytes = try c.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? 4_000_000
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType) ?? "feedback.submitted"
        signing = try c.decodeIfPresent(SigningConfig.self, forKey: .signing)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "csfeedbackkit"
        attachments = try c.decodeIfPresent(AttachmentMode.self, forKey: .attachments) ?? .inline
        when = try c.decodeIfPresent(RouteCondition.self, forKey: .when)
        environments = try c.decodeIfPresent([FeedbackEnvironment].self, forKey: .environments)
    }
}

/// Where attachments are uploaded for `"attachments": "link"` destinations.
public struct StorageConfig: Codable, Sendable, Equatable {
    /// `presigned`: ask `url` for a signed upload + download URL (S3, R2, GCS, anything).
    /// Any other name: an uploader registered with `Feedback.start(uploaders:)`.
    public var type: String
    /// Signer endpoint for `presigned`. May contain `${NAME}`.
    public var url: String?
    /// Sent to the signer. Values may contain `${NAME}`.
    public var headers: [String: String]
    /// Auth handler for the signer. Its headers win over `headers`.
    public var auth: String?
    public var timeoutSeconds: Double

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        auth = try c.decodeIfPresent(String.self, forKey: .auth)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 60
    }
}

/// Which notes a destination receives. Every condition given must hold.
public struct RouteCondition: Codable, Sendable, Equatable {
    /// At least one of these tag ids is selected.
    public var tags: [String]?
    /// A declared field to test. Alone: the field has a value.
    public var field: String?
    /// With `field`: the value equals this (or, for a list, contains it).
    public var equals: FeedbackValue?

    enum CodingKeys: String, CodingKey {
        case tags, field
        case equals = "is"
    }

    public func matches(_ payload: FeedbackPayload) -> Bool {
        if let tags, !tags.isEmpty, !payload.tags.contains(where: { tags.contains($0.id) }) {
            return false
        }
        if let field {
            guard let value = payload.custom[field] else { return false }
            if let equals, value != equals {
                guard case .strings(let items) = value, case .string(let wanted) = equals, items.contains(wanted) else {
                    return false
                }
            }
        }
        return true
    }
}

public struct SigningConfig: Codable, Sendable, Equatable {
    public enum Scheme: String, Codable, Sendable {
        /// https://www.standardwebhooks.com: `webhook-id`, `webhook-timestamp`,
        /// `webhook-signature: v1,<base64 HMAC-SHA256 of "id.timestamp.body">`.
        case standardWebhooks = "standard-webhooks"
        /// OpenBot's native signature: `X-OpenBot-Timestamp`, `X-OpenBot-Delivery-Id`,
        /// `X-OpenBot-Signature: sha256=<hex>` over "timestamp.id.body", keyed with the whole
        /// secret string. Pair with `"format": "openbot"`; OpenBot caps bodies at 64 KiB.
        case openbot
    }

    public var scheme: Scheme
    /// `whsec_<base64>` for standard-webhooks; the routine secret as given for openbot.
    /// Use `${NAME}` and supply it via `variables:`; never commit it.
    public var secret: String
}

// MARK: - Attachments

/// Each section absent means off. Present means on unless `enabled` is false.
public struct AttachmentsConfig: Codable, Sendable, Equatable {
    public var screenshot: ScreenshotConfig?
    public var device: DeviceConfig?
    public var logs: LogsConfig?

    public init(
        screenshot: ScreenshotConfig? = nil,
        device: DeviceConfig? = nil,
        logs: LogsConfig? = nil
    ) {
        self.screenshot = screenshot
        self.device = device
        self.logs = logs
    }
}

public struct ScreenshotConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Toggle starts on in the composer.
    public var defaultOn: Bool
    public var maxLongEdge: Double
    public var jpegQuality: Double
    /// Blacks out secure text fields before encoding.
    public var redactSecureFields: Bool
    public var environments: [FeedbackEnvironment]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        defaultOn = try c.decodeIfPresent(Bool.self, forKey: .defaultOn) ?? true
        maxLongEdge = try c.decodeIfPresent(Double.self, forKey: .maxLongEdge) ?? 1200
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.6
        redactSecureFields = try c.decodeIfPresent(Bool.self, forKey: .redactSecureFields) ?? true
        environments = try c.decodeIfPresent([FeedbackEnvironment].self, forKey: .environments)
    }
}

public struct DeviceConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var environments: [FeedbackEnvironment]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        environments = try c.decodeIfPresent([FeedbackEnvironment].self, forKey: .environments)
    }
}

public struct LogsConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// `OSLog` subsystems to include. Empty means the app's bundle id.
    public var subsystems: [String]
    public var lastMinutes: Double
    public var maxBytes: Int
    public var environments: [FeedbackEnvironment]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        subsystems = try c.decodeIfPresent([String].self, forKey: .subsystems) ?? []
        lastMinutes = try c.decodeIfPresent(Double.self, forKey: .lastMinutes) ?? 5
        maxBytes = try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 200_000
        environments = try c.decodeIfPresent([FeedbackEnvironment].self, forKey: .environments)
    }
}

// MARK: - Triggers

/// Ways the composer opens on its own. `Feedback.present(from:)` always works.
/// Needs `Feedback.installTriggers()` from CSFeedbackKitUI.
public struct TriggerConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The user takes a screenshot. The package snapshots the app itself.
        case screenshot
    }

    public var type: Kind
    /// Alert title before opening. Absent opens the composer directly.
    public var prompt: String?
    public var environments: [FeedbackEnvironment]?
}

// MARK: - Session (tray)

public struct SessionConfig: Codable, Sendable, Equatable {
    /// Quick-capture several items, review, then submit together.
    public var enabled: Bool
    public var maxItems: Int

    public init(enabled: Bool = false, maxItems: Int = 25) {
        self.enabled = enabled
        self.maxItems = maxItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? 25
    }
}

// MARK: - Copy

public struct CopyConfig: Codable, Sendable, Equatable {
    public var composerTitle: String
    public var notePlaceholder: String
    public var sendButton: String
    public var sentToast: String
    /// Saved on device; will be retried.
    public var queuedToast: String
    public var failedTitle: String
    /// Screenshot prompt: the button that opens the composer.
    public var promptAction: String
    /// Screenshot prompt: the button that dismisses it.
    public var promptCancel: String

    public init(
        composerTitle: String = "Feedback",
        notePlaceholder: String = "What happened?",
        sendButton: String = "Send",
        sentToast: String = "Sent",
        queuedToast: String = "Saved. It’ll send when you’re back online.",
        failedTitle: String = "Couldn’t send",
        promptAction: String = "Write a note",
        promptCancel: String = "Not now"
    ) {
        self.composerTitle = composerTitle
        self.notePlaceholder = notePlaceholder
        self.sendButton = sendButton
        self.sentToast = sentToast
        self.queuedToast = queuedToast
        self.failedTitle = failedTitle
        self.promptAction = promptAction
        self.promptCancel = promptCancel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CopyConfig()
        composerTitle = try c.decodeIfPresent(String.self, forKey: .composerTitle) ?? defaults.composerTitle
        notePlaceholder = try c.decodeIfPresent(String.self, forKey: .notePlaceholder) ?? defaults.notePlaceholder
        sendButton = try c.decodeIfPresent(String.self, forKey: .sendButton) ?? defaults.sendButton
        sentToast = try c.decodeIfPresent(String.self, forKey: .sentToast) ?? defaults.sentToast
        queuedToast = try c.decodeIfPresent(String.self, forKey: .queuedToast) ?? defaults.queuedToast
        failedTitle = try c.decodeIfPresent(String.self, forKey: .failedTitle) ?? defaults.failedTitle
        promptAction = try c.decodeIfPresent(String.self, forKey: .promptAction) ?? defaults.promptAction
        promptCancel = try c.decodeIfPresent(String.self, forKey: .promptCancel) ?? defaults.promptCancel
    }
}
