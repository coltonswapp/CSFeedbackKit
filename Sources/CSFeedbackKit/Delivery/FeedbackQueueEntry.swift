import Foundation

/// A note in the on-device queue, for a debug screen: waiting, failed, or recently sent.
public struct FeedbackQueueEntry: Sendable, Identifiable {
    public enum State: Sendable {
        /// At least one destination will be retried automatically.
        case waiting
        /// At least one destination gave up. Resend it by hand.
        case failed
        /// Every destination accepted it.
        case sent
    }

    public let payload: FeedbackPayload
    /// When it was saved on the device.
    public let savedAt: Date
    public let deliveries: [DeliveryStatus]

    public var id: String { payload.id }

    public var state: State {
        if deliveries.contains(where: { $0.state == .pending }) { return .waiting }
        if deliveries.contains(where: { $0.state == .failed }) { return .failed }
        return .sent
    }

    /// Pretty JSON of the payload with attachment data left out, for copying.
    public func jsonWithoutAttachmentData() -> String {
        var copy = payload
        copy.attachments = copy.attachments.map { attachment in
            var stripped = attachment
            if let data = stripped.data {
                stripped.data = "<\(data.count) base64 chars>"
            }
            return stripped
        }
        guard let data = try? copy.jsonData(pretty: true) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
