import Foundation

/// Who sent the note. From a declared field, or a prompt answer remembered on device.
enum TesterIdentity {
    private static let storageKey = "CSFeedbackKit.testerIdentity"

    static var stored: String? {
        get {
            let value = UserDefaults.standard.string(forKey: storageKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
    }

    static func resolve(_ config: TesterConfig, values: FeedbackValues) -> String? {
        switch config.source {
        case .none:
            return nil
        case .prompt:
            return stored
        case .field:
            guard let key = config.field, case .string(let value)? = values[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
