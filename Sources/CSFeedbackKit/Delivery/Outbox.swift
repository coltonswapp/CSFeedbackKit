import Foundation
import Network

/// Per-destination delivery state for one note.
public struct DeliveryStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case pending
        case delivered
        /// Gave up: a non-retryable response, or out of attempts.
        case failed
    }

    public let destinationId: String
    public internal(set) var state: State
    public internal(set) var attempts: Int
    public internal(set) var nextAttemptAt: Date
    public internal(set) var lastError: String?
    /// `id` from the receiver's JSON response, when it sent one.
    public internal(set) var responseId: String?
}

/// Notes waiting to be delivered, one file each, so nothing is lost to a bad network,
/// a crash, or the app being killed.
actor Outbox {
    static let shared = Outbox()

    /// Notes still waiting or failed are kept this long for manual resend.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Fully delivered notes are kept this long, so they can be resent if a receiver lost them.
    private static let sentMaxAge: TimeInterval = 3 * 24 * 60 * 60
    /// Oldest notes are dropped past this, sent ones first.
    private static let maxItems = 100
    private static let maxBackoff: TimeInterval = 10 * 60
    private static let maxRetryAfter: TimeInterval = 60 * 60

    private struct Item: Codable {
        var payload: FeedbackPayload
        var enqueuedAt: Date
        var deliveries: [DeliveryStatus]
        /// Set when no destination is pending any more (delivered or failed).
        var completedAt: Date?
        /// Attachments already uploaded for `link` destinations, by filename. Reused by
        /// every destination and retry until they near expiry.
        var uploads: [String: StoredUpload]?
    }

    private struct StoredUpload: Codable {
        var url: String
        var expiresAt: Date?
    }

    private enum Outcome {
        case delivered(responseId: String?)
        case retry(String, after: TimeInterval?)
        case permanent(String)
    }

    private var destinations: [String: DestinationConfig] = [:]
    private var auth: [String: Feedback.AuthHandler] = [:]
    private var formats: [String: Feedback.FormatHandler] = [:]
    private var storage: StorageConfig?
    private var uploaders: [String: Feedback.UploadHandler] = [:]
    private var userAgent = "CSFeedbackKit/1"
    private var isConfigured = false

    private var inFlight: Set<String> = []
    private var isFlushing = false
    private var needsAnotherPass = false
    private var wakeTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Setup

    func configure(
        destinations: [DestinationConfig],
        auth: [String: Feedback.AuthHandler],
        formats: [String: Feedback.FormatHandler],
        storage: StorageConfig?,
        uploaders: [String: Feedback.UploadHandler],
        userAgent: String
    ) {
        self.formats = formats
        self.storage = storage
        self.uploaders = uploaders
        self.destinations = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.auth = auth
        self.userAgent = userAgent
        isConfigured = true
        startPathMonitor()
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { await Outbox.shared.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "CSFeedbackKit.outbox.path"))
        pathMonitor = monitor
    }

    // MARK: Public operations

    /// Persists a note for the given destinations.
    func add(_ payload: FeedbackPayload, destinationIDs: [String]) throws {
        let now = Date()
        let item = Item(
            payload: payload,
            enqueuedAt: now,
            deliveries: destinationIDs.map {
                DeliveryStatus(destinationId: $0, state: .pending, attempts: 0, nextAttemptAt: now, lastError: nil, responseId: nil)
            }
        )
        try write(item)
        enforceItemLimit()
    }

    /// Tries every pending destination of one note right away. Used right after submit.
    func attemptNow(id: String) async -> [DeliveryStatus] {
        guard isConfigured, let item = read(id) else { return [] }
        for status in item.deliveries where status.state == .pending {
            await attempt(itemID: id, destinationID: status.destinationId)
        }
        return read(id)?.deliveries ?? []
    }

    /// Tries everything that's due. Safe to call often.
    func flush() async {
        guard isConfigured else { return }
        if isFlushing {
            needsAnotherPass = true
            return
        }
        isFlushing = true
        repeat {
            needsAnotherPass = false
            let now = Date()
            for item in allItems().sorted(by: { $0.enqueuedAt < $1.enqueuedAt }) {
                for status in item.deliveries where status.state == .pending && status.nextAttemptAt <= now {
                    await attempt(itemID: item.payload.id, destinationID: status.destinationId)
                }
            }
        } while needsAnotherPass
        isFlushing = false
        scheduleWake()
    }

    func pendingCount() -> Int {
        allItems().filter { $0.deliveries.contains { $0.state == .pending } }.count
    }

    // MARK: Queue (debug screen)

    /// Every stored note, newest first.
    func entries() -> [FeedbackQueueEntry] {
        allItems()
            .sorted { $0.enqueuedAt > $1.enqueuedAt }
            .map { FeedbackQueueEntry(payload: $0.payload, savedAt: $0.enqueuedAt, deliveries: $0.deliveries) }
    }

    /// Sends a stored note again, now. Failed destinations always; delivered ones too when
    /// `includingDelivered` (e.g. a receiver accepted it but lost it downstream).
    func resend(id: String, includingDelivered: Bool) async -> [DeliveryStatus] {
        guard var item = read(id) else { return [] }
        let now = Date()
        for index in item.deliveries.indices {
            let state = item.deliveries[index].state
            guard state == .failed || state == .pending || (includingDelivered && state == .delivered) else { continue }
            item.deliveries[index].state = .pending
            item.deliveries[index].attempts = 0
            item.deliveries[index].nextAttemptAt = now
            item.deliveries[index].lastError = nil
            item.deliveries[index].responseId = nil
        }
        item.completedAt = nil
        try? write(item)
        Log.delivery.notice("\(id, privacy: .public): resend requested")
        return await attemptNow(id: id)
    }

    func discard(id: String) {
        delete(id)
    }

    // MARK: Attempts

    private func attempt(itemID: String, destinationID: String) async {
        let key = "\(itemID)/\(destinationID)"
        guard !inFlight.contains(key), let item = read(itemID) else { return }
        guard item.deliveries.contains(where: { $0.destinationId == destinationID && $0.state == .pending }) else { return }
        inFlight.insert(key)
        let outcome = await send(item.payload, itemID: itemID, to: destinationID)
        inFlight.remove(key)
        record(outcome, itemID: itemID, destinationID: destinationID)
    }

    private func send(_ payload: FeedbackPayload, itemID: String, to destinationID: String) async -> Outcome {
        guard let destination = destinations[destinationID] else {
            return .permanent("destination \"\(destinationID)\" is no longer in the config")
        }

        var authHeaders: [String: String] = [:]
        if let name = destination.auth {
            guard let handler = auth[name] else {
                return .permanent("auth handler \"\(name)\" is not registered")
            }
            do {
                authHeaders = try await handler()
            } catch {
                return .retry("auth \"\(name)\" failed: \(error.localizedDescription)", after: nil)
            }
        }

        var linked: [String: StoredUpload] = [:]
        if destination.attachments == .link, payload.attachments.contains(where: { $0.data != nil }) {
            do {
                linked = try await ensureUploads(itemID: itemID)
            } catch {
                return .retry("attachment upload failed: \(error.localizedDescription)", after: nil)
            }
        }

        let request: URLRequest
        let body: Data
        do {
            var typed = payload
            typed.type = destination.eventType
            switch destination.attachments {
            case .inline:
                break
            case .none:
                typed.attachments = []
            case .link:
                typed.attachments = typed.attachments.compactMap { attachment in
                    guard let upload = linked[attachment.filename] else { return nil }
                    var copy = attachment
                    copy.data = nil
                    copy.url = upload.url
                    copy.expiresAt = upload.expiresAt.map(FeedbackPayload.timestamp)
                    return copy
                }
            }
            let fitted = try PayloadBudget.fit(typed, for: destination, formats: formats)
            (request, body) = try DestinationRequest.make(
                destination: destination,
                payload: fitted,
                authHeaders: authHeaders,
                userAgent: userAgent,
                formats: formats
            )
        } catch {
            return .permanent("couldn’t build request: \(error.localizedDescription)")
        }

        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                return .retry("no HTTP response", after: nil)
            }
            return classify(http, data: data)
        } catch let error as URLError {
            return .retry(error.localizedDescription, after: nil)
        } catch {
            return .retry(error.localizedDescription, after: nil)
        }
    }

    // MARK: Uploads

    /// Uploads this note's attachments that aren't stored yet (or expire within the hour),
    /// saves the links on the item, and returns them by filename.
    private func ensureUploads(itemID: String) async throws -> [String: StoredUpload] {
        guard let item = read(itemID) else { throw AttachmentStorageError.noteMissing }
        var uploads = item.uploads ?? [:]
        let freshUntil = Date().addingTimeInterval(60 * 60)
        for attachment in item.payload.attachments {
            if let existing = uploads[attachment.filename], (existing.expiresAt ?? .distantFuture) > freshUntil {
                continue
            }
            guard let encoded = attachment.data, let bytes = Data(base64Encoded: encoded) else { continue }
            let result = try await upload(FeedbackUpload(
                noteId: item.payload.id,
                filename: attachment.filename,
                contentType: attachment.contentType,
                data: bytes
            ))
            uploads[attachment.filename] = StoredUpload(url: result.url.absoluteString, expiresAt: result.expiresAt)
            Log.delivery.info("\(itemID, privacy: .public): uploaded \(attachment.filename, privacy: .public)")
        }
        if var latest = read(itemID) {
            latest.uploads = uploads
            try? write(latest)
        }
        return uploads
    }

    private func upload(_ upload: FeedbackUpload) async throws -> FeedbackUploadResult {
        guard let storage else { throw AttachmentStorageError.notConfigured }
        if storage.type == "presigned" {
            var headers = storage.headers
            if let name = storage.auth {
                guard let handler = auth[name] else { throw AttachmentStorageError.notConfigured }
                let authHeaders = try await handler()
                headers.merge(authHeaders) { _, new in new }
            }
            return try await PresignedUploader.upload(upload, storage: storage, headers: headers, session: session)
        }
        guard let uploader = uploaders[storage.type] else { throw AttachmentStorageError.notConfigured }
        return try await uploader(upload)
    }

    private func classify(_ response: HTTPURLResponse, data: Data) -> Outcome {
        let status = response.statusCode
        if (200..<300).contains(status) {
            return .delivered(responseId: responseID(from: data))
        }
        let detail = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "HTTP \(status)" + (detail.isEmpty ? "" : ": \(detail)")
        switch status {
        // Auth may refresh; timeouts, rate limits, and server errors are transient.
        case 401, 403, 408, 425, 429, 500...599:
            return .retry(message, after: retryAfter(response))
        default:
            return .permanent(message)
        }
    }

    private func responseID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = object["id"] as? String { return id }
        if let id = object["id"] as? NSNumber { return id.stringValue }
        return nil
    }

    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else {
            return nil
        }
        return min(seconds, Self.maxRetryAfter)
    }

    private func record(_ outcome: Outcome, itemID: String, destinationID: String) {
        guard var item = read(itemID),
              let index = item.deliveries.firstIndex(where: { $0.destinationId == destinationID }) else {
            return
        }
        guard let destination = destinations[destinationID] else {
            item.deliveries[index].state = .failed
            item.deliveries[index].lastError = "destination removed from config"
            finish(item)
            return
        }

        var status = item.deliveries[index]
        status.attempts += 1
        switch outcome {
        case .delivered(let responseId):
            status.state = .delivered
            status.lastError = nil
            status.responseId = responseId
            Log.delivery.info("\(itemID, privacy: .public) → \(destinationID, privacy: .public): delivered")
        case .permanent(let message):
            status.state = .failed
            status.lastError = message
            Log.delivery.error("\(itemID, privacy: .public) → \(destinationID, privacy: .public): failed, \(message, privacy: .public)")
        case .retry(let message, let after):
            status.lastError = message
            if status.attempts >= destination.maxAttempts {
                status.state = .failed
                Log.delivery.error("\(itemID, privacy: .public) → \(destinationID, privacy: .public): gave up after \(status.attempts) attempts, \(message, privacy: .public)")
            } else {
                let delay = max(after ?? 0, backoff(attempts: status.attempts))
                status.nextAttemptAt = Date().addingTimeInterval(delay)
                Log.delivery.notice("\(itemID, privacy: .public) → \(destinationID, privacy: .public): retry in \(Int(delay))s, \(message, privacy: .public)")
            }
        }
        item.deliveries[index] = status
        finish(item)
    }

    /// Writes the item back, or removes it once every destination is delivered or failed.
    /// Writes the item back. Finished notes (delivered or failed everywhere) are kept for the
    /// queue screen; failed ones wait there for a manual resend.
    private func finish(_ item: Item) {
        var item = item
        if item.deliveries.allSatisfy({ $0.state != .pending }) {
            item.completedAt = item.completedAt ?? Date()
            if item.deliveries.contains(where: { $0.state == .failed }) {
                Log.delivery.error("\(item.payload.id, privacy: .public): kept in the queue for manual resend")
            }
        }
        try? write(item)
    }

    /// 5s, 10s, 20s, … up to 10 minutes, with jitter.
    private func backoff(attempts: Int) -> TimeInterval {
        let base = min(Self.maxBackoff, 5 * pow(2, Double(max(attempts - 1, 0))))
        return base * Double.random(in: 0.8...1.2)
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        let pending = allItems().flatMap(\.deliveries).filter { $0.state == .pending }
        guard let next = pending.map(\.nextAttemptAt).min() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        wakeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // A fresh task, so cancelling this wake can't cancel the flush's requests.
            Task { await Outbox.shared.flush() }
        }
    }

    // MARK: Storage

    private var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        var url = base.appendingPathComponent("CSFeedbackKit/Outbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    private func fileURL(_ id: String) -> URL? {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return directory?.appendingPathComponent("\(safe).json")
    }

    private func read(_ id: String) -> Item? {
        guard let url = fileURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    private func write(_ item: Item) throws {
        guard let url = fileURL(item.payload.id) else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(item)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func delete(_ id: String) {
        guard let url = fileURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every stored item. Drops unreadable files and items past `maxAge`.
    private func allItems() -> [Item] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let sentCutoff = Date().addingTimeInterval(-Self.sentMaxAge)
        var items: [Item] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(Item.self, from: data) else {
                Log.delivery.error("Dropping unreadable outbox file \(url.lastPathComponent, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if item.enqueuedAt < cutoff {
                Log.delivery.error("\(item.payload.id, privacy: .public): dropped after 7 days")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let completedAt = item.completedAt, completedAt < sentCutoff,
               item.deliveries.allSatisfy({ $0.state == .delivered }) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            items.append(item)
        }
        return items
    }

    private func enforceItemLimit() {
        // Sent notes go first, then the oldest.
        let items = allItems().sorted { lhs, rhs in
            let lhsSent = lhs.deliveries.allSatisfy { $0.state == .delivered }
            let rhsSent = rhs.deliveries.allSatisfy { $0.state == .delivered }
            if lhsSent != rhsSent { return lhsSent }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        guard items.count > Self.maxItems else { return }
        for item in items.prefix(items.count - Self.maxItems) {
            Log.delivery.error("\(item.payload.id, privacy: .public): dropped, outbox over \(Self.maxItems) notes")
            delete(item.payload.id)
        }
    }
}
