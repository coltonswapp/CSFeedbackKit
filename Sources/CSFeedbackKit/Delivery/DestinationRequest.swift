import Foundation

/// Turns a payload into an HTTP request for one destination.
enum DestinationRequest {
    struct Body {
        let data: Data
        let contentType: String
    }

    /// Header order: config `headers`, then the auth handler's (they win), then the package's own.
    static func make(
        destination: DestinationConfig,
        payload: FeedbackPayload,
        authHeaders: [String: String],
        userAgent: String,
        formats: [String: Feedback.FormatHandler]
    ) throws -> (URLRequest, Data) {
        guard let url = URL(string: destination.url) else {
            throw URLError(.badURL)
        }
        let body = try body(for: payload, destination: destination, formats: formats)

        var request = URLRequest(url: url, timeoutInterval: destination.timeoutSeconds)
        request.httpMethod = destination.method.uppercased()
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in destination.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(payload.id, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let signing = destination.signing {
            // Fresh timestamp per attempt; same id + body, so receivers dedupe retries.
            let headers = try RequestSigner.headers(for: signing, id: payload.id, body: body.data, date: Date())
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return (request, body.data)
    }

    static func body(
        for payload: FeedbackPayload,
        destination: DestinationConfig,
        formats: [String: Feedback.FormatHandler]
    ) throws -> Body {
        switch destination.format {
        case "csfeedbackkit":
            switch destination.encoding {
            case .json:
                return Body(data: try payload.jsonData(), contentType: "application/json")
            case .multipart:
                return try multipart(payload)
            }
        case "openbot":
            return Body(data: try openBotEnvelope(payload, eventType: destination.eventType), contentType: "application/json")
        default:
            guard let format = formats[destination.format] else {
                throw FormatError.notRegistered(destination.format)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return Body(data: try encoder.encode(try format(payload)), contentType: "application/json")
        }
    }

    enum FormatError: Error, LocalizedError {
        case notRegistered(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered(let name): return "format \"\(name)\" is not registered"
            }
        }
    }

    /// OpenBot's native body: the routine's agent receives `data`.
    private struct OpenBotEnvelope: Encodable {
        let type: String
        let occurredAt: String
        let data: FeedbackPayload
    }

    private static func openBotEnvelope(_ payload: FeedbackPayload, eventType: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(OpenBotEnvelope(type: eventType, occurredAt: payload.createdAt, data: payload))
    }

    /// `payload` part (JSON without attachment data) + one file part per attachment, named by filename.
    private static func multipart(_ payload: FeedbackPayload) throws -> Body {
        let boundary = "CSFeedbackKit-\(UUID().uuidString)"
        var stripped = payload
        stripped.attachments = payload.attachments.map { attachment in
            var copy = attachment
            copy.data = nil
            return copy
        }

        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"payload\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        data.append(try stripped.jsonData())
        append("\r\n")

        for attachment in payload.attachments {
            guard let encoded = attachment.data, let bytes = Data(base64Encoded: encoded) else { continue }
            let name = attachment.filename.replacingOccurrences(of: "\"", with: "")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name)\"\r\n")
            append("Content-Type: \(attachment.contentType)\r\n\r\n")
            data.append(bytes)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        return Body(data: data, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
