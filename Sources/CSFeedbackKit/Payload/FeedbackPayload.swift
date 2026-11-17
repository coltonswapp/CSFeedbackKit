import Foundation

/// The body every destination receives. Schema: `Schemas/csfeedbackkit.payload.v1.schema.json`.
///
/// Package-owned fields are fixed. Project fields live under `custom`, so receivers can
/// always tell the two apart.
public struct FeedbackPayload: Codable, Sendable, Equatable {
    public static let schemaIdentifier = "csfeedbackkit/v1"

    public var schema: String
    /// Event type for receivers that route on it. Set per destination from `eventType`.
    public var type: String?
    /// Idempotency key. Stable across retries; also sent as the `Idempotency-Key` header.
    public var id: String
    /// Shared by items submitted together from the tray. Absent for one-off notes.
    public var sessionId: String?
    /// ISO 8601, when the tester captured the note (not when it was delivered).
    public var createdAt: String
    public var note: String
    public var tags: [Tag]
    public var source: Source?
    /// Declared fields only, captured at note time.
    public var custom: FeedbackValues
    public var tester: Tester?
    public var app: AppInfo
    public var device: DeviceInfo?
    public var attachments: [Attachment]

    public init(
        id: String,
        sessionId: String? = nil,
        createdAt: Date,
        note: String,
        tags: [Tag] = [],
        source: Source? = nil,
        custom: FeedbackValues = [:],
        tester: Tester? = nil,
        app: AppInfo,
        device: DeviceInfo? = nil,
        attachments: [Attachment] = []
    ) {
        self.schema = Self.schemaIdentifier
        self.id = id
        self.sessionId = sessionId
        self.createdAt = Self.timestamp(createdAt)
        self.note = note
        self.tags = tags
        self.source = source
        self.custom = custom
        self.tester = tester
        self.app = app
        self.device = device
        self.attachments = attachments
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case schema, type, id
        case sessionId = "session_id"
        case createdAt = "created_at"
        case note, tags, source, custom, tester, app, device, attachments
    }

    // MARK: Nested

    public struct Tag: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var metadata: [String: JSONValue]?

        public init(id: String, label: String, metadata: [String: JSONValue]? = nil) {
            self.id = id
            self.label = label
            self.metadata = metadata
        }
    }

    /// The screen the note is about.
    public struct Source: Codable, Sendable, Equatable {
        /// View controller type name.
        public var screen: String
        /// Navigation title, when there is one.
        public var title: String?

        public init(screen: String, title: String? = nil) {
            self.screen = screen
            self.title = title
        }
    }

    public struct Tester: Codable, Sendable, Equatable {
        /// Whatever the tester typed, or the configured field's value.
        public var identity: String

        public init(identity: String) {
            self.identity = identity
        }
    }

    public struct AppInfo: Codable, Sendable, Equatable {
        public var bundleId: String
        public var version: String
        public var build: String
        public var environment: FeedbackEnvironment

        public init(bundleId: String, version: String, build: String, environment: FeedbackEnvironment) {
            self.bundleId = bundleId
            self.version = version
            self.build = build
            self.environment = environment
        }

        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case version, build, environment
        }
    }

    public struct DeviceInfo: Codable, Sendable, Equatable {
        /// Hardware identifier, e.g. `iPhone17,1`.
        public var model: String
        /// e.g. `iOS 26.1`.
        public var os: String
        public var locale: String
        public var timeZone: String

        public init(model: String, os: String, locale: String, timeZone: String) {
            self.model = model
            self.os = os
            self.locale = locale
            self.timeZone = timeZone
        }

        enum CodingKeys: String, CodingKey {
            case model, os, locale
            case timeZone = "time_zone"
        }
    }

    public struct Attachment: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case screenshot
            case logs
        }

        public var kind: Kind
        public var contentType: String
        public var filename: String
        /// Base64 for `json` encoding. Absent for `multipart`, where the file part
        /// is named by `filename`, and for `link`, which sends `url` instead.
        public var data: String?
        /// Download link, for destinations with `"attachments": "link"`.
        public var url: String?
        /// When `url` stops working (ISO 8601), if the storage said.
        public var expiresAt: String?

        public init(kind: Kind, contentType: String, filename: String, data: String? = nil, url: String? = nil, expiresAt: String? = nil) {
            self.kind = kind
            self.contentType = contentType
            self.filename = filename
            self.data = data
            self.url = url
            self.expiresAt = expiresAt
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case contentType = "content_type"
            case filename, data, url
            case expiresAt = "expires_at"
        }
    }
}
