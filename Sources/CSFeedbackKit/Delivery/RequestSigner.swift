import CryptoKit
import Foundation

/// Signs request bodies for receivers that verify them.
enum RequestSigner {
    enum SigningError: Error, LocalizedError {
        case invalidSecret

        var errorDescription: String? { "signing secret is missing or malformed" }
    }

    static func headers(for config: SigningConfig, id: String, body: Data, date: Date) throws -> [String: String] {
        switch config.scheme {
        case .standardWebhooks:
            guard let key = standardWebhooksKey(from: config.secret) else { throw SigningError.invalidSecret }
            let timestamp = String(Int(date.timeIntervalSince1970))
            var signed = Data("\(id).\(timestamp).".utf8)
            signed.append(body)
            let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: key))
            return [
                "webhook-id": id,
                "webhook-timestamp": timestamp,
                "webhook-signature": "v1," + Data(mac).base64EncodedString(),
            ]
        case .openbot:
            let secret = config.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw SigningError.invalidSecret }
            let timestamp = String(Int(date.timeIntervalSince1970))
            var signed = Data("\(timestamp).\(id).".utf8)
            signed.append(body)
            let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(secret.utf8)))
            return [
                "X-OpenBot-Timestamp": timestamp,
                "X-OpenBot-Delivery-Id": id,
                "X-OpenBot-Signature": "sha256=" + Data(mac).map { String(format: "%02x", $0) }.joined(),
            ]
        }
    }

    /// The HMAC key: base64-decoded bytes after `whsec_`.
    static func standardWebhooksKey(from secret: String) -> Data? {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("whsec_") else { return nil }
        guard let key = Data(base64Encoded: String(trimmed.dropFirst("whsec_".count))), !key.isEmpty else { return nil }
        return key
    }
}
