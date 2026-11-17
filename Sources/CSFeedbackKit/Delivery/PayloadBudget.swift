import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fits a payload under a destination's `maxBodyBytes`.
/// Order: shrink the screenshot, drop logs, drop the screenshot. The note always goes.
enum PayloadBudget {
    private static let shrinkSteps: [CGFloat] = [800, 600, 400]
    private static let shrinkQuality: CGFloat = 0.5

    static func fit(
        _ payload: FeedbackPayload,
        for destination: DestinationConfig,
        formats: [String: Feedback.FormatHandler]
    ) throws -> FeedbackPayload {
        let maxBytes = destination.maxBodyBytes
        func size(of payload: FeedbackPayload) throws -> Int {
            try DestinationRequest.body(for: payload, destination: destination, formats: formats).data.count
        }
        var current = payload
        if try size(of: current) <= maxBytes { return current }

        for edge in shrinkSteps {
            guard let shrunk = shrinkingScreenshot(in: current, maxLongEdge: edge) else { break }
            current = shrunk
            if try size(of: current) <= maxBytes {
                Log.delivery.notice("\(payload.id, privacy: .public): screenshot shrunk to \(Int(edge))px to fit")
                return current
            }
        }

        if current.attachments.contains(where: { $0.kind == .logs }) {
            current.attachments.removeAll { $0.kind == .logs }
            Log.delivery.notice("\(payload.id, privacy: .public): logs dropped to fit")
            if try size(of: current) <= maxBytes { return current }
        }

        if current.attachments.contains(where: { $0.kind == .screenshot }) {
            current.attachments.removeAll { $0.kind == .screenshot }
            Log.delivery.notice("\(payload.id, privacy: .public): screenshot dropped to fit")
        }
        return current
    }

    private static func shrinkingScreenshot(in payload: FeedbackPayload, maxLongEdge: CGFloat) -> FeedbackPayload? {
        guard let index = payload.attachments.firstIndex(where: { $0.kind == .screenshot }),
              let encoded = payload.attachments[index].data,
              let original = Data(base64Encoded: encoded),
              let smaller = jpeg(original, maxLongEdge: maxLongEdge, quality: shrinkQuality),
              smaller.count < original.count else {
            return nil
        }
        var copy = payload
        copy.attachments[index].data = smaller.base64EncodedString()
        return copy
    }

    private static func jpeg(_ data: Data, maxLongEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
