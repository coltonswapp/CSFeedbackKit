import Foundation

/// Every problem found while loading a config, reported together.
public struct FeedbackConfigError: Error, CustomStringConvertible, Sendable {
    public let issues: [String]

    public var description: String {
        "CSFeedbackKit config is invalid:\n" + issues.map { "  • \($0)" }.joined(separator: "\n")
    }
}

/// Loads, layers, resolves, decodes, and validates a config.
enum ConfigLoader {
    /// Arrays merged by an identity key instead of replaced.
    private static let keyedArrays: [String: String] = [
        "fields": "key",
        "tags": "id",
        "destinations": "id",
        "triggers": "type",
    ]

    static func load(
        _ source: ConfigSource,
        variables: [String: String],
        authNames: Set<String>,
        checkNames: Set<String>,
        formatNames: Set<String>,
        uploaderNames: Set<String>
    ) -> Result<FeedbackConfig, FeedbackConfigError> {
        var issues: [String] = []

        // 1. Read every layer.
        var layers: [JSONValue] = []
        for layer in source.layers {
            switch read(layer) {
            case .success(let value): layers.append(value)
            case .failure(let message): issues.append(message)
            }
        }
        guard issues.isEmpty, var merged = layers.first else {
            if issues.isEmpty { issues.append("No config layers given") }
            return .failure(FeedbackConfigError(issues: issues))
        }

        // 2. Merge.
        for overlay in layers.dropFirst() {
            merged = merge(merged, overlay, key: nil)
        }

        // 3. Unknown keys (the decoder ignores them, so typos would pass silently).
        issues += ConfigValidator.unknownKeyIssues(in: merged)

        // 4. ${NAME} in destination URLs and headers.
        merged = resolvePlaceholders(in: merged, variables: variables, infoBundle: source.infoBundle, issues: &issues)

        // 5. Decode.
        let config: FeedbackConfig
        do {
            let data = try JSONEncoder().encode(merged)
            config = try JSONDecoder().decode(FeedbackConfig.self, from: data)
        } catch let error as DecodingError {
            issues.append(describe(error))
            return .failure(FeedbackConfigError(issues: issues))
        } catch {
            issues.append("Couldn’t decode config: \(error.localizedDescription)")
            return .failure(FeedbackConfigError(issues: issues))
        }

        // 6. Semantic checks.
        issues += ConfigValidator.issues(
            in: config,
            authNames: authNames,
            checkNames: checkNames,
            formatNames: formatNames,
            uploaderNames: uploaderNames
        )

        return issues.isEmpty ? .success(config) : .failure(FeedbackConfigError(issues: issues))
    }

    // MARK: Reading

    private enum ReadResult {
        case success(JSONValue)
        case failure(String)
    }

    private static func read(_ layer: ConfigSource.Layer) -> ReadResult {
        let data: Data
        let label: String
        switch layer {
        case .resource(let name, let bundle):
            label = "\(name).json"
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                return .failure("\(label) not found in bundle \(bundle.bundleIdentifier ?? bundle.bundlePath). Check target membership.")
            }
            do {
                data = try Data(contentsOf: url)
            } catch {
                return .failure("\(label) couldn’t be read: \(error.localizedDescription)")
            }
        case .data(let raw, let rawLabel):
            label = rawLabel
            data = raw
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object = value else { return .failure("\(label) must be a JSON object") }
            return .success(value)
        } catch {
            return .failure("\(label) is not valid JSON")
        }
    }

    // MARK: Merging

    private static func merge(_ base: JSONValue, _ overlay: JSONValue, key: String?) -> JSONValue {
        switch (base, overlay) {
        case (.object(let a), .object(let b)):
            var result = a
            for (k, v) in b {
                result[k] = a[k].map { merge($0, v, key: k) } ?? v
            }
            return .object(result)
        case (.array(let a), .array(let b)):
            guard let key, let identity = keyedArrays[key] else { return overlay }
            return .array(mergeKeyed(a, b, identity: identity))
        default:
            return overlay
        }
    }

    private static func mergeKeyed(_ base: [JSONValue], _ overlay: [JSONValue], identity: String) -> [JSONValue] {
        func id(_ value: JSONValue) -> String? {
            if case .object(let o) = value, case .string(let s)? = o[identity] { return s }
            return nil
        }
        var result = base
        for item in overlay {
            if let itemID = id(item), let index = result.firstIndex(where: { id($0) == itemID }) {
                result[index] = merge(result[index], item, key: nil)
            } else {
                result.append(item)
            }
        }
        return result
    }

    // MARK: ${NAME}

    private static func resolvePlaceholders(
        in config: JSONValue,
        variables: [String: String],
        infoBundle: Bundle,
        issues: inout [String]
    ) -> JSONValue {
        guard case .object(var root) = config, case .array(var destinations)? = root["destinations"] else {
            return config
        }
        for index in destinations.indices {
            guard case .object(var destination) = destinations[index] else { continue }
            let label: String
            if case .string(let id)? = destination["id"] { label = "destinations[\(id)]" } else { label = "destinations[\(index)]" }
            if case .string(let url)? = destination["url"] {
                destination["url"] = .string(resolve(url, at: "\(label).url", variables: variables, infoBundle: infoBundle, issues: &issues))
            }
            if case .object(var headers)? = destination["headers"] {
                for (name, value) in headers {
                    if case .string(let raw) = value {
                        headers[name] = .string(resolve(raw, at: "\(label).headers.\(name)", variables: variables, infoBundle: infoBundle, issues: &issues))
                    }
                }
                destination["headers"] = .object(headers)
            }
            if case .object(var signing)? = destination["signing"], case .string(let secret)? = signing["secret"] {
                signing["secret"] = .string(resolve(secret, at: "\(label).signing.secret", variables: variables, infoBundle: infoBundle, issues: &issues))
                destination["signing"] = .object(signing)
            }
            destinations[index] = .object(destination)
        }
        root["destinations"] = .array(destinations)

        if case .object(var storage)? = root["storage"] {
            if case .string(let url)? = storage["url"] {
                storage["url"] = .string(resolve(url, at: "storage.url", variables: variables, infoBundle: infoBundle, issues: &issues))
            }
            if case .object(var headers)? = storage["headers"] {
                for (name, value) in headers {
                    if case .string(let raw) = value {
                        headers[name] = .string(resolve(raw, at: "storage.headers.\(name)", variables: variables, infoBundle: infoBundle, issues: &issues))
                    }
                }
                storage["headers"] = .object(headers)
            }
            root["storage"] = .object(storage)
        }
        return .object(root)
    }

    private static func resolve(
        _ text: String,
        at path: String,
        variables: [String: String],
        infoBundle: Bundle,
        issues: inout [String]
    ) -> String {
        guard text.contains("${") else { return text }
        let placeholder = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        let ns = text as NSString
        var result = text
        for match in placeholder.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1))
            guard let value = lookup(name, variables: variables, infoBundle: infoBundle) else {
                issues.append("\(path): ${\(name)} is not set (variables:, scheme environment, or Info.plist)")
                continue
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: value)
        }
        return result
    }

    /// Order: `variables:` passed to `Feedback.start`, scheme environment (DEBUG), Info.plist.
    private static func lookup(_ name: String, variables: [String: String], infoBundle: Bundle) -> String? {
        if let value = variables[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
        #if DEBUG
        // Scheme environment variables, handy for local URLs.
        if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
        #endif
        // Unset build settings expand to "" in Info.plist; treat that as missing.
        guard let value = (infoBundle.object(forInfoDictionaryKey: name) as? String)?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    // MARK: Errors

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return joined.isEmpty ? "(root)" : String(joined.drop(while: { $0 == "." }))
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context.codingPath)
            return "\(parent == "(root)" ? "" : parent + ": ")missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "Couldn’t decode config"
        }
    }
}
