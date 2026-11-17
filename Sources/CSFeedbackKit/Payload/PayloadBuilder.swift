import Foundation

enum PayloadBuilder {
    static func build(
        configuration: FeedbackConfig,
        capture: FeedbackCapture,
        draft: FeedbackDraft
    ) async throws -> FeedbackPayload {
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw FeedbackError.emptyNote }

        let environment = capture.environment
        let attachmentsConfig = configuration.attachments

        // Custom fields: captured values, plus what the tester typed (declared, typed, non-static only).
        var custom = capture.fields.values
        for (key, value) in draft.filledFields {
            if let accepted = FieldResolver.accept(typed: value, for: key, in: configuration.fields) {
                custom[key] = accepted
            }
        }
        let missing = configuration.fields.filter { $0.required && custom[$0.key] == nil }
        guard missing.isEmpty else {
            throw FeedbackError.missingRequiredFields(missing.map(\.label))
        }

        let tags = configuration.tags
            .filter { draft.tagIDs.contains($0.id) }
            .map { FeedbackPayload.Tag(id: $0.id, label: $0.label, metadata: $0.metadata) }

        let tester = (draft.testerIdentity.flatMap(nonEmpty) ?? capture.testerIdentity)
            .map(FeedbackPayload.Tester.init(identity:))

        let app = DeviceInfo.app(environment: environment)

        var device: FeedbackPayload.DeviceInfo?
        if let config = attachmentsConfig.device, config.enabled, config.environments.allows(environment) {
            device = DeviceInfo.device()
        }

        var attachments: [FeedbackPayload.Attachment] = []
        if let config = attachmentsConfig.screenshot, config.enabled, config.environments.allows(environment),
           let jpeg = draft.screenshotJPEG, !jpeg.isEmpty {
            attachments.append(.init(
                kind: .screenshot,
                contentType: "image/jpeg",
                filename: "screenshot.jpg",
                data: jpeg.base64EncodedString()
            ))
        }
        if let config = attachmentsConfig.logs, config.enabled, config.environments.allows(environment),
           draft.includeLogs,
           let logs = await LogCollector.collect(config, endingAt: capture.createdAt, bundleId: app.bundleId) {
            attachments.append(.init(
                kind: .logs,
                contentType: "text/plain; charset=utf-8",
                filename: "logs.txt",
                data: logs.base64EncodedString()
            ))
        }

        return FeedbackPayload(
            id: capture.id,
            sessionId: draft.sessionId,
            createdAt: capture.createdAt,
            note: note,
            tags: tags,
            source: capture.source,
            custom: custom,
            tester: tester,
            app: app,
            device: device,
            attachments: attachments
        )
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension FeedbackPayload {
    /// Encoded body. Sorted keys so identical payloads produce identical bytes.
    public func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
