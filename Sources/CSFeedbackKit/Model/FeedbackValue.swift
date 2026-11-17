import Foundation

/// A custom field value. Flat on purpose: string, number, bool, or a list of strings.
public enum FeedbackValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Field values must be a string, number, bool, or array of strings"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }

    /// Whether this value fits a declared field type.
    public func matches(_ type: FieldConfig.ValueType) -> Bool {
        switch (self, type) {
        case (.string, .string), (.number, .number), (.bool, .bool), (.strings, .stringArray):
            return true
        default:
            return false
        }
    }

    /// Text for the composer's context section.
    public var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "Yes" : "No"
        case .strings(let value): return value.joined(separator: ", ")
        }
    }
}

extension FeedbackValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: String...) { self = .strings(elements) }
}

/// Values a screen or session provider hands to the package, keyed by declared field key.
public typealias FeedbackValues = [String: FeedbackValue]
