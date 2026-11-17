import Foundation

/// Field values for one capture: screen beats session beats static. Declared keys only.
public struct ResolvedFields: Sendable, Equatable {
    /// What will be sent under `custom` (before the tester fills anything in).
    public var values: FeedbackValues
    /// Required fields no provider supplied. The composer asks for these.
    public var missingRequired: [FieldConfig]

    public init(values: FeedbackValues, missingRequired: [FieldConfig]) {
        self.values = values
        self.missingRequired = missingRequired
    }
}

enum FieldResolver {
    /// - Parameters:
    ///   - screen: Values from context providers, nearest screen first.
    ///   - session: Values from `Feedback.session`.
    static func resolve(
        fields: [FieldConfig],
        screen: [FeedbackValues],
        session: FeedbackValues
    ) -> ResolvedFields {
        let declared = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        warnAboutUndeclared(screen.flatMap(\.keys), source: .screen, declared: declared)
        warnAboutUndeclared(Array(session.keys), source: .session, declared: declared)

        var values: FeedbackValues = [:]
        var missing: [FieldConfig] = []

        for field in fields {
            if let fixed = field.value {
                values[field.key] = fixed
                continue
            }
            var resolved: FeedbackValue?
            if field.sources.contains(.screen) {
                resolved = screen.compactMap { $0[field.key] }.first(where: { accept($0, for: field, source: .screen) })
            }
            if resolved == nil, field.sources.contains(.session), let value = session[field.key],
               accept(value, for: field, source: .session) {
                resolved = value
            }
            if let resolved {
                values[field.key] = resolved
            } else if field.required {
                missing.append(field)
            }
        }
        return ResolvedFields(values: values, missingRequired: missing)
    }

    /// Validates a value the tester typed for a field. Returns nil when it doesn't fit.
    static func accept(typed value: FeedbackValue, for key: String, in fields: [FieldConfig]) -> FeedbackValue? {
        guard let field = fields.first(where: { $0.key == key }), !field.isStatic else { return nil }
        return value.matches(field.type) ? value : nil
    }

    private static func accept(_ value: FeedbackValue, for field: FieldConfig, source: FieldConfig.Source) -> Bool {
        if value.matches(field.type) { return true }
        Log.fields.fault("""
            \(source.rawValue, privacy: .public) value for "\(field.key, privacy: .public)" \
            doesn’t match type \(field.type.rawValue, privacy: .public); dropped
            """)
        return false
    }

    private static func warnAboutUndeclared(
        _ keys: [String],
        source: FieldConfig.Source,
        declared: [String: FieldConfig]
    ) {
        for key in Set(keys) {
            if let field = declared[key] {
                if !field.isStatic, !field.sources.contains(source) {
                    Log.fields.fault("""
                        "\(key, privacy: .public)" came from \(source.rawValue, privacy: .public) \
                        but its sources don’t allow it; ignored
                        """)
                }
            } else {
                Log.fields.fault("""
                    "\(key, privacy: .public)" from \(source.rawValue, privacy: .public) \
                    is not declared in fields; dropped
                    """)
            }
        }
    }
}
