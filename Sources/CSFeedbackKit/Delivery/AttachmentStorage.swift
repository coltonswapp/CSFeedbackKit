import Foundation

/// One attachment to store, handed to an uploader.
public struct FeedbackUpload: Sendable {
    /// The note's id. Use it in the object key so retries overwrite instead of duplicating.
    public let noteId: String
    public let filename: String
    public let contentType: String
    public let data: Data
}

/// Where a stored attachment can be downloaded.
public struct FeedbackUploadResult: Sendable {
    /// A URL the receiver can fetch without credentials (presigned or public).
    public let url: URL
    /// When `url` stops working. `nil` means it doesn't expire.
    public let expiresAt: Date?

    public init(url: URL, expiresAt: Date? = nil) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

enum AttachmentStorageError: Error, LocalizedError {
    case notConfigured
    case noteMissing
    case signer(String)
    case upload(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "attachment storage is not configured"
        case .noteMissing: return "note is no longer in the outbox"
        case .signer(let detail): return "upload signer: \(detail)"
        case .upload(let detail): return "upload: \(detail)"
        }
    }
}

/// `"storage": { "type": "presigned", "url": … }`
///
/// 1. `POST url` `{ "id", "filename", "content_type", "size" }`
/// 2. The signer answers `{ "upload_url", "download_url", "headers"?, "expires_at"? }`
/// 3. `PUT upload_url` with the bytes, `Content-Type`, and any `headers` it returned
/// 4. `download_url` goes in the payload
///
/// Bucket credentials stay on the signer; the phone only sees short-lived URLs.
enum PresignedUploader {
    private struct SignRequest: Encodable {
        let id: String
        let filename: String
        let content_type: String
        let size: Int
    }

    private struct SignResponse: Decodable {
        let upload_url: String
        let download_url: String
        let headers: [String: String]?
        let expires_at: String?
    }

    static func upload(
        _ upload: FeedbackUpload,
        storage: StorageConfig,
        headers: [String: String],
        session: URLSession
    ) async throws -> FeedbackUploadResult {
        guard let signerString = storage.url, let signerURL = URL(string: signerString) else {
            throw AttachmentStorageError.notConfigured
        }

        var signRequest = URLRequest(url: signerURL, timeoutInterval: storage.timeoutSeconds)
        signRequest.httpMethod = "POST"
        for (name, value) in headers {
            signRequest.setValue(value, forHTTPHeaderField: name)
        }
        signRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        signRequest.httpBody = try JSONEncoder().encode(SignRequest(
            id: upload.noteId,
            filename: upload.filename,
            content_type: upload.contentType,
            size: upload.data.count
        ))

        let (signData, signResponse) = try await session.data(for: signRequest)
        guard let signHTTP = signResponse as? HTTPURLResponse, (200..<300).contains(signHTTP.statusCode) else {
            let status = (signResponse as? HTTPURLResponse)?.statusCode ?? 0
            let detail = String(decoding: signData.prefix(200), as: UTF8.self)
            throw AttachmentStorageError.signer("HTTP \(status) \(detail)")
        }
        let signed: SignResponse
        do {
            signed = try JSONDecoder().decode(SignResponse.self, from: signData)
        } catch {
            throw AttachmentStorageError.signer("response needs upload_url and download_url")
        }
        guard let uploadURL = URL(string: signed.upload_url), let downloadURL = URL(string: signed.download_url) else {
            throw AttachmentStorageError.signer("invalid upload_url or download_url")
        }

        var put = URLRequest(url: uploadURL, timeoutInterval: storage.timeoutSeconds)
        put.httpMethod = "PUT"
        put.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in signed.headers ?? [:] {
            put.setValue(value, forHTTPHeaderField: name)
        }
        let (putData, putResponse) = try await session.upload(for: put, from: upload.data)
        guard let putHTTP = putResponse as? HTTPURLResponse, (200..<300).contains(putHTTP.statusCode) else {
            let status = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw AttachmentStorageError.upload("HTTP \(status) \(String(decoding: putData.prefix(200), as: UTF8.self))")
        }

        return FeedbackUploadResult(url: downloadURL, expiresAt: signed.expires_at.flatMap(parseDate))
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
