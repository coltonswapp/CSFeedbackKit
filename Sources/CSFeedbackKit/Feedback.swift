import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Entry point.
///
/// ```swift
/// Feedback.start(
///     config: .bundled("Feedback"),
///     auth: ["staff": { ["Authorization": "Bearer \(try await StaffAccess.token())"] }],
///     checks: ["staffAccess": { StaffAccess.canUseStudioClientAPI }]
/// )
/// Feedback.session.provide("userEmail") { AuthStore.shared.currentUser?.email }
/// ```
@MainActor
public enum Feedback {
    /// Returns headers for a request. Runs before every delivery attempt, so it can refresh tokens.
    public typealias AuthHandler = @Sendable () async throws -> [String: String]
    /// Re-evaluated on every use, so it can follow login or claim changes.
    public typealias Check = @MainActor () -> Bool
    /// Turns the payload into a destination's JSON body, for `"format": "<name>"`.
    /// Runs off the main actor before every attempt; keep it pure.
    public typealias FormatHandler = @Sendable (FeedbackPayload) throws -> any Encodable
    /// Stores one attachment and returns where it can be downloaded, for `"storage": { "type": "<name>" }`.
    public typealias UploadHandler = @Sendable (FeedbackUpload) async throws -> FeedbackUploadResult

    /// The loaded config. `nil` before `start` or when the config was invalid.
    public private(set) static var configuration: FeedbackConfig?
    /// Where this build came from. `nil` until detection finishes, shortly after `start`.
    public private(set) static var environment: FeedbackEnvironment?
    /// App-wide field values (session source).
    public static let session = SessionValues()

    static private(set) var authHandlers: [String: AuthHandler] = [:]
    private static var checks: [String: Check] = [:]
    private static var environmentTask: Task<FeedbackEnvironment, Never>?

    // MARK: Setup

    /// Loads and validates the config and starts environment detection.
    ///
    /// An invalid config stops in DEBUG with every problem listed. In Release it's logged
    /// and the package stays off. Returns whether the config loaded.
    ///
    /// - Parameter variables: Values for `${NAME}`, checked before the scheme environment
    ///   and Info.plist. Use for secrets kept outside the repo (e.g. a gitignored plist).
    @discardableResult
    public static func start(
        config source: ConfigSource,
        variables: [String: String] = [:],
        auth: [String: AuthHandler] = [:],
        checks: [String: Check] = [:],
        formats: [String: FormatHandler] = [:],
        uploaders: [String: UploadHandler] = [:]
    ) -> Bool {
        authHandlers = auth
        self.checks = checks

        switch ConfigLoader.load(
            source,
            variables: variables,
            authNames: Set(auth.keys),
            checkNames: Set(checks.keys),
            formatNames: Set(formats.keys),
            uploaderNames: Set(uploaders.keys)
        ) {
        case .success(let config):
            configuration = config
            for warning in ConfigValidator.warnings(in: config) {
                Log.general.error("\(warning, privacy: .public)")
            }
        case .failure(let error):
            configuration = nil
            Log.general.fault("\(error.description, privacy: .public)")
            #if DEBUG
            assertionFailure(error.description)
            #endif
            return false
        }

        if environmentTask == nil {
            environmentTask = Task {
                let detected = await BuildEnvironment.detect()
                environment = detected
                return detected
            }
        }

        // Delivery: configure the outbox and send anything left from earlier launches.
        let destinations = configuration?.destinations ?? []
        let storage = configuration?.storage
        let userAgent = makeUserAgent()
        Task {
            await Outbox.shared.configure(
                destinations: destinations,
                auth: auth,
                formats: formats,
                storage: storage,
                uploaders: uploaders,
                userAgent: userAgent
            )
            await Outbox.shared.flush()
        }
        observeForeground()
        observeScreenshots()

        for key in session.registeredKeys {
            warnIfUndeclared(key, source: .session)
        }
        return true
    }

    /// Waits for environment detection. Usually done within milliseconds of `start`.
    public static func resolvedEnvironment() async -> FeedbackEnvironment? {
        await environmentTask?.value
    }

    // MARK: State

    /// Config loaded, environment allowed, and the `enabledWhen` check passes.
    public static var isActive: Bool {
        guard let configuration, let environment, configuration.enabledIn.contains(environment) else {
            return false
        }
        guard let name = configuration.enabledWhen else { return true }
        return checks[name]?() ?? false
    }

    /// Remembered prompt answer. Settable so an app can prefill it.
    public static var testerIdentity: String? {
        get { TesterIdentity.stored }
        set { TesterIdentity.stored = newValue }
    }

    // MARK: Capture

    /// Freezes context for one note: fields from screens and session, tester identity, time.
    /// Returns `nil` when the package isn't active.
    ///
    /// - Parameters:
    ///   - source: The screen the note is about.
    ///   - contextProviders: Nearest screen first.
    public static func capture(
        source: FeedbackPayload.Source?,
        contextProviders: [any FeedbackContextProvider] = []
    ) -> FeedbackCapture? {
        guard isActive, let configuration, let environment else { return nil }
        let fields = FieldResolver.resolve(
            fields: configuration.fields,
            screen: contextProviders.map { $0.feedbackValues() },
            session: session.snapshot()
        )
        return FeedbackCapture(
            id: makeID(prefix: "fb"),
            createdAt: Date(),
            environment: environment,
            source: source,
            fields: fields,
            testerIdentity: TesterIdentity.resolve(configuration.tester, values: fields.values)
        )
    }

    /// Builds the payload for a capture and the tester's draft. Collects logs if configured.
    public static func makePayload(_ capture: FeedbackCapture, draft: FeedbackDraft) async throws -> FeedbackPayload {
        guard let configuration else { throw FeedbackError.notStarted }
        if configuration.tester.source == .prompt, let typed = draft.testerIdentity {
            TesterIdentity.stored = typed
        }
        return try await PayloadBuilder.build(configuration: configuration, capture: capture, draft: draft)
    }

    /// Shared id for items submitted together from the tray.
    public static func makeSessionID() -> String {
        makeID(prefix: "ses")
    }

    // MARK: Delivery

    /// Builds the payload, saves it on device, and tries each chosen or matching destination once right away.
    ///
    /// - Returns: `.delivered` when every destination accepted it, `.queued` when some will
    ///   be retried later.
    /// - Throws: `FeedbackError` for problems the tester can fix (empty note, missing fields),
    ///   or `.rejected` when every destination refused it for good.
    public static func submit(_ capture: FeedbackCapture, draft: FeedbackDraft) async throws -> FeedbackSubmitResult {
        let saved = try await save(capture, draft: draft)
        return try await deliver(saved)
    }

    /// Destinations available for the draft's environment, tags, and custom fields, in config order.
    public static func availableDestinations(for capture: FeedbackCapture, draft: FeedbackDraft) -> [DestinationConfig] {
        guard let configuration else { return [] }
        let tags = Set(configuration.tags.map(\.id)).intersection(draft.tagIDs)
        let custom = PayloadBuilder.customFields(configuration: configuration, capture: capture, draft: draft)
        return configuration.destinations.filter {
            $0.environments.allows(capture.environment) && ($0.when?.matches(tagIDs: tags, custom: custom) ?? true)
        }
    }

    /// Builds the payload and saves it in the outbox. Once this returns, the note can't be
    /// lost, so UI can dismiss and call `deliver` without making the tester wait.
    public static func save(_ capture: FeedbackCapture, draft: FeedbackDraft) async throws -> SavedFeedback {
        guard let configuration else { throw FeedbackError.notStarted }
        let payload = try await makePayload(capture, draft: draft)
        let destinationIDs = configuration.destinations
            .filter {
                (draft.destinationID == nil || $0.id == draft.destinationID)
                    && $0.environments.allows(capture.environment)
                    && ($0.when?.matches(payload) ?? true)
            }
            .map(\.id)
        guard !destinationIDs.isEmpty else { throw FeedbackError.noDestinations }

        do {
            try await Outbox.shared.add(payload, destinationIDs: destinationIDs)
        } catch {
            throw FeedbackError.storageFailed(error.localizedDescription)
        }
        return SavedFeedback(id: payload.id)
    }

    /// Tries every destination of a saved note once, now. Retries continue in the background.
    ///
    /// - Throws: `.rejected` when every destination refused it for good.
    public static func deliver(_ saved: SavedFeedback) async throws -> FeedbackSubmitResult {
        let statuses = await Outbox.shared.attemptNow(id: saved.id)
        guard !statuses.isEmpty else { return .queued(lastError: nil) }

        if statuses.allSatisfy({ $0.state == .delivered }) {
            var ids: [String: String] = [:]
            for status in statuses {
                if let responseId = status.responseId { ids[status.destinationId] = responseId }
            }
            return .delivered(responseIds: ids)
        }
        if statuses.allSatisfy({ $0.state == .failed }) {
            throw FeedbackError.rejected(statuses.compactMap(\.lastError).joined(separator: "; "))
        }
        if statuses.contains(where: { $0.state == .pending }) {
            return .queued(lastError: statuses.compactMap(\.lastError).first)
        }
        // Some delivered, the rest failed for good: the note reached someone.
        return .delivered(responseIds: [:])
    }

    /// Retries everything that's due. Called on launch, foreground, and reconnect already.
    public static func flushOutbox() async {
        await Outbox.shared.flush()
    }

    /// Notes saved on device and still being retried automatically.
    public static func pendingCount() async -> Int {
        await Outbox.shared.pendingCount()
    }

    // MARK: Queue

    /// Every note on the device, newest first: waiting, failed (kept for manual resend for
    /// 7 days), and sent (kept 3 days in case a receiver lost it).
    public static func queue() async -> [FeedbackQueueEntry] {
        await Outbox.shared.entries()
    }

    /// Sends a stored note again, now. Failed destinations always; delivered ones too when
    /// `includingDelivered`. Receivers dedupe on the note `id` where they support it.
    @discardableResult
    public static func resend(_ id: String, includingDelivered: Bool = false) async -> [DeliveryStatus] {
        await Outbox.shared.resend(id: id, includingDelivered: includingDelivered)
    }

    /// Removes a note from the device.
    public static func discard(_ id: String) async {
        await Outbox.shared.discard(id: id)
    }

    private static var foregroundObserver: NSObjectProtocol?

    private static func observeForeground() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await Outbox.shared.flush() }
        }
        #endif
    }

    // MARK: Triggers

    /// The configured trigger of this kind, if it applies right now
    /// (feedback is active and the trigger's `environments` include this build).
    public static func activeTrigger(_ kind: TriggerConfig.Kind) -> TriggerConfig? {
        guard isActive, let configuration, let environment else { return nil }
        return configuration.triggers.first {
            $0.type == kind && ($0.environments?.contains(environment) ?? true)
        }
    }

    /// Opens the composer for a trigger. Set by CSFeedbackKitUI's `Feedback.installTriggers()`.
    package static var triggerHandler: (@MainActor (TriggerConfig) -> Void)?

    private static var screenshotObserver: NSObjectProtocol?

    private static func observeScreenshots() {
        #if canImport(UIKit)
        guard screenshotObserver == nil,
              configuration?.triggers.contains(where: { $0.type == .screenshot }) == true else { return }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in screenshotTaken() }
        }
        #endif
    }

    private static func screenshotTaken() {
        guard let trigger = activeTrigger(.screenshot) else { return }
        guard let triggerHandler else {
            Log.general.fault("A screenshot trigger is configured, but nothing opens the composer. Call Feedback.installTriggers() (CSFeedbackKitUI) after Feedback.start.")
            return
        }
        triggerHandler(trigger)
    }

    private static func makeUserAgent() -> String {
        let bundle = Bundle.main
        let id = bundle.bundleIdentifier ?? "app"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "CSFeedbackKit/1 \(id)/\(version) (\(build))"
    }

    // MARK: Internals

    static func warnIfUndeclared(_ key: String, source: FieldConfig.Source) {
        guard let configuration else { return }
        guard let field = configuration.fields.first(where: { $0.key == key }) else {
            Log.fields.fault("\(source.rawValue, privacy: .public) provider \"\(key, privacy: .public)\" is not declared in fields; it will be dropped")
            return
        }
        if !field.isStatic, !field.sources.contains(source) {
            Log.fields.fault("\"\(key, privacy: .public)\" doesn’t allow source \(source.rawValue, privacy: .public); it will be ignored")
        }
    }

    private static func makeID(prefix: String) -> String {
        "\(prefix)_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
