import Foundation

/// Checks the decoder can't: typos, duplicates, dangling names, bad values.
enum ConfigValidator {

    // MARK: Unknown keys

    /// Allowed keys per object. Keep in sync with `FeedbackConfig` and the config schema.
    /// `nil` children mean "any keys" (free-form objects like headers and metadata).
    private static let topLevel: Set<String> = [
        "$schema", "version", "enabledIn", "enabledWhen", "tester", "fields", "tags",
        "destinations", "attachments", "triggers", "session", "copy", "storage",
    ]
    private static let objectKeys: [String: Set<String>] = [
        "tester": ["source", "field", "prompt"],
        "attachments": ["screenshot", "device", "logs"],
        "attachments.screenshot": ["enabled", "defaultOn", "maxLongEdge", "jpegQuality", "redactSecureFields", "environments"],
        "attachments.device": ["enabled", "environments"],
        "attachments.logs": ["enabled", "subsystems", "lastMinutes", "maxBytes", "environments"],
        "session": ["enabled", "maxItems"],
        "storage": ["type", "url", "headers", "auth", "timeoutSeconds"],
        "copy": ["composerTitle", "notePlaceholder", "sendButton", "sentToast", "queuedToast", "failedTitle", "promptAction", "promptCancel"],
    ]
    private static let arrayItemKeys: [String: Set<String>] = [
        "fields": ["key", "label", "type", "value", "sources", "required", "sensitive", "visible"],
        "tags": ["id", "label", "selected", "metadata"],
        "destinations": ["id", "type", "url", "method", "headers", "auth", "encoding", "timeoutSeconds", "maxAttempts", "maxBodyBytes", "eventType", "signing", "format", "attachments", "when", "environments"],
        "triggers": ["type", "prompt", "environments"],
    ]

    static func unknownKeyIssues(in config: JSONValue) -> [String] {
        guard case .object(let root) = config else { return [] }
        var issues = unknown(root.keys, allowed: topLevel, at: nil)

        for (path, allowed) in objectKeys {
            let parts = path.split(separator: ".").map(String.init)
            if case .object(let object)? = value(at: parts, in: root) {
                issues += unknown(object.keys, allowed: allowed, at: path)
            }
        }
        for (key, allowed) in arrayItemKeys {
            guard case .array(let items)? = root[key] else { continue }
            for (index, item) in items.enumerated() {
                if case .object(let object) = item {
                    issues += unknown(object.keys, allowed: allowed, at: "\(key)[\(index)]")
                    if key == "destinations", case .object(let signing)? = object["signing"] {
                        issues += unknown(signing.keys, allowed: ["scheme", "secret"], at: "destinations[\(index)].signing")
                    }
                    if key == "destinations", case .object(let when)? = object["when"] {
                        issues += unknown(when.keys, allowed: ["tags", "field", "is"], at: "destinations[\(index)].when")
                    }
                }
            }
        }
        return issues
    }

    private static func value(at path: [String], in root: [String: JSONValue]) -> JSONValue? {
        var current: JSONValue = .object(root)
        for part in path {
            guard case .object(let object) = current, let next = object[part] else { return nil }
            current = next
        }
        return current
    }

    private static func unknown(_ keys: Dictionary<String, JSONValue>.Keys, allowed: Set<String>, at path: String?) -> [String] {
        keys.filter { !allowed.contains($0) }.sorted().map { key in
            let suggestion = closest(to: key, in: allowed).map { ", did you mean \"\($0)\"?" } ?? ""
            return "\(path.map { "\($0): " } ?? "")unknown key \"\(key)\"\(suggestion)"
        }
    }

    private static func closest(to key: String, in candidates: Set<String>) -> String? {
        let scored = candidates.map { ($0, distance(key.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, key.count / 3) else { return nil }
        return best.0
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Semantics

    static func issues(
        in config: FeedbackConfig,
        authNames: Set<String>,
        checkNames: Set<String>,
        formatNames: Set<String>,
        uploaderNames: Set<String>
    ) -> [String] {
        var issues: [String] = []

        if config.version != FeedbackConfig.supportedVersion {
            issues.append("version \(config.version) is not supported (expected \(FeedbackConfig.supportedVersion))")
        }
        if config.enabledIn.isEmpty {
            issues.append("enabledIn is empty, so the package never runs")
        }
        if let check = config.enabledWhen, !checkNames.contains(check) {
            issues.append("enabledWhen \"\(check)\" has no check registered. Pass it in `checks:` to Feedback.start.")
        }

        issues += duplicates(config.fields.map(\.key), label: "fields key")
        issues += duplicates(config.tags.map(\.id), label: "tags id")
        issues += duplicates(config.destinations.map(\.id), label: "destinations id")
        issues += duplicates(config.triggers.map(\.type.rawValue), label: "triggers type")

        let fieldsByKey = Dictionary(config.fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for field in config.fields {
            if let value = field.value, !value.matches(field.type) {
                issues.append("fields[\(field.key)]: value doesn’t match type \(field.type.rawValue)")
            }
            if !field.isStatic, field.sources.isEmpty {
                issues.append("fields[\(field.key)]: needs a value or at least one source")
            }
            if field.key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                issues.append("fields[\(field.key)]: key must start with a letter and use letters, digits, or _")
            }
        }

        switch config.tester.source {
        case .field:
            if let key = config.tester.field {
                if let field = fieldsByKey[key] {
                    if field.type != .string {
                        issues.append("tester.field \"\(key)\" must be a string field")
                    }
                } else {
                    issues.append("tester.field \"\(key)\" is not a declared field")
                }
            } else {
                issues.append("tester.source is \"field\" but tester.field is missing")
            }
        case .none, .prompt:
            break
        }

        if config.destinations.isEmpty {
            issues.append("destinations is empty")
        }
        for destination in config.destinations {
            let label = "destinations[\(destination.id)]"
            if let url = URL(string: destination.url), let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http", url.host != nil {
                // ok
            } else if !destination.url.contains("${") {
                issues.append("\(label).url \"\(destination.url)\" is not an http(s) URL")
            }
            if let auth = destination.auth, !authNames.contains(auth) {
                issues.append("\(label).auth \"\(auth)\" has no handler registered. Pass it in `auth:` to Feedback.start.")
            }
            if !["POST", "PUT"].contains(destination.method.uppercased()) {
                issues.append("\(label).method must be POST or PUT")
            }
            if destination.timeoutSeconds <= 0 {
                issues.append("\(label).timeoutSeconds must be greater than 0")
            }
            if destination.maxAttempts < 1 {
                issues.append("\(label).maxAttempts must be at least 1")
            }
            if destination.maxBodyBytes < 1024 {
                issues.append("\(label).maxBodyBytes must be at least 1024")
            }
            if destination.eventType.trimmingCharacters(in: .whitespaces).isEmpty || destination.eventType.count > 256 {
                issues.append("\(label).eventType must be 1–256 characters")
            }
            if let signing = destination.signing, !signing.secret.contains("${") {
                switch signing.scheme {
                case .standardWebhooks:
                    if RequestSigner.standardWebhooksKey(from: signing.secret) == nil {
                        issues.append("\(label).signing.secret must be whsec_ followed by base64")
                    }
                case .openbot:
                    if signing.secret.trimmingCharacters(in: .whitespaces).isEmpty {
                        issues.append("\(label).signing.secret is empty")
                    }
                }
            }
            let formatIsBuiltIn = DestinationConfig.builtInFormats.contains(destination.format)
            if !formatIsBuiltIn, !formatNames.contains(destination.format) {
                issues.append("\(label).format \"\(destination.format)\" is not built in and has no format registered. Pass it in `formats:` to Feedback.start.")
            }
            if destination.format != "csfeedbackkit", destination.encoding == .multipart {
                issues.append("\(label): multipart encoding only works with format csfeedbackkit")
            }
            if let when = destination.when {
                for tag in when.tags ?? [] where !config.tags.contains(where: { $0.id == tag }) {
                    issues.append("\(label).when.tags \"\(tag)\" is not a declared tag")
                }
                if let field = when.field {
                    if let declared = config.fields.first(where: { $0.key == field }) {
                        if let equals = when.equals, !equals.matches(declared.type),
                           !(declared.type == .stringArray && { if case .string = equals { return true } else { return false } }()) {
                            issues.append("\(label).when.is doesn’t match the type of field \"\(field)\"")
                        }
                    } else {
                        issues.append("\(label).when.field \"\(field)\" is not a declared field")
                    }
                } else if when.equals != nil {
                    issues.append("\(label).when.is needs when.field")
                }
            }
            if destination.signing?.scheme == .openbot {
                if destination.maxBodyBytes > 65_536 {
                    issues.append("\(label).maxBodyBytes must be at most 65536 for openbot (its body limit)")
                }
            }
            issues += disabledEverywhere(destination.environments, enabledIn: config.enabledIn, label: label)
        }

        if let screenshot = config.attachments.screenshot {
            if !(0...1).contains(screenshot.jpegQuality) {
                issues.append("attachments.screenshot.jpegQuality must be between 0 and 1")
            }
            if screenshot.maxLongEdge <= 0 {
                issues.append("attachments.screenshot.maxLongEdge must be greater than 0")
            }
        }
        if let logs = config.attachments.logs {
            if logs.lastMinutes <= 0 { issues.append("attachments.logs.lastMinutes must be greater than 0") }
            if logs.maxBytes <= 0 { issues.append("attachments.logs.maxBytes must be greater than 0") }
        }
        for trigger in config.triggers {
            issues += disabledEverywhere(trigger.environments, enabledIn: config.enabledIn, label: "triggers[\(trigger.type.rawValue)]")
        }
        let linkDestinations = config.destinations.filter { $0.attachments == .link }.map(\.id)
        if let storage = config.storage {
            if storage.type == "presigned" {
                if let url = storage.url {
                    if !url.contains("${"), URL(string: url).flatMap({ $0.scheme?.lowercased() }).map({ $0 == "https" || $0 == "http" }) != true {
                        issues.append("storage.url \"\(url)\" is not an http(s) URL")
                    }
                } else {
                    issues.append("storage.url is required for type presigned")
                }
            } else if !uploaderNames.contains(storage.type) {
                issues.append("storage.type \"\(storage.type)\" is not presigned and has no uploader registered. Pass it in `uploaders:` to Feedback.start.")
            }
            if let auth = storage.auth, !authNames.contains(auth) {
                issues.append("storage.auth \"\(auth)\" has no handler registered. Pass it in `auth:` to Feedback.start.")
            }
            if storage.timeoutSeconds <= 0 {
                issues.append("storage.timeoutSeconds must be greater than 0")
            }
        } else if !linkDestinations.isEmpty {
            issues.append("destinations \(linkDestinations.joined(separator: ", ")) use \"attachments\": \"link\" but there's no storage section")
        }

        if config.session.maxItems < 1 {
            issues.append("session.maxItems must be at least 1")
        }

        return issues
    }

    // MARK: Warnings

    /// Valid but almost certainly not what was meant. Logged at start; the config still loads.
    static func warnings(in config: FeedbackConfig) -> [String] {
        var warnings: [String] = []
        let sendsScreenshots = config.attachments.screenshot?.enabled == true
        for destination in config.destinations where sendsScreenshots && destination.attachments == .inline {
            let isOpenBot = destination.format == "openbot" || destination.signing?.scheme == .openbot
            if isOpenBot {
                warnings.append(
                    "destinations[\(destination.id)] sends screenshots inline to OpenBot. The bot's model sees base64 as text, "
                        + "not an image, and the 64 KiB body limit shrinks or drops the screenshot. "
                        + "Use \"attachments\": \"link\" with a storage section so the bot gets a URL it can fetch."
                )
            }
        }
        return warnings
    }

    private static func duplicates(_ values: [String], label: String) -> [String] {
        var seen = Set<String>()
        var reported = Set<String>()
        var issues: [String] = []
        for value in values where !seen.insert(value).inserted && reported.insert(value).inserted {
            issues.append("duplicate \(label) \"\(value)\"")
        }
        return issues
    }

    /// An `environments` list that shares nothing with `enabledIn` is almost always a mistake.
    private static func disabledEverywhere(
        _ environments: [FeedbackEnvironment]?,
        enabledIn: [FeedbackEnvironment],
        label: String
    ) -> [String] {
        guard let environments else { return [] }
        if environments.isEmpty || Set(environments).isDisjoint(with: enabledIn) {
            return ["\(label).environments never overlaps enabledIn, so it never runs"]
        }
        return []
    }
}
