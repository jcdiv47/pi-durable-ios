import Foundation

/// Arbitrary JSON. Specs are validated as JSON first, so the model gets an error for every bad field, and
/// rendered from the same values, so a widget always draws something.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public init(json: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: json)
    }

    public init(json: String) throws {
        try self.init(json: Data(json.utf8))
    }

    public func data(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonText: String { String(decoding: data(), as: UTF8.self) }

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var number: Double? {
        switch self {
        case let .number(value): value
        // Models often quote numbers; a numeric string still renders as a number.
        case let .string(value): Double(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Short readable text: strings unquoted, whole numbers without a trailing `.0`.
    public var display: String {
        switch self {
        case .null: ""
        case let .bool(value): String(value)
        case let .number(value): Self.format(value)
        case let .string(value): value
        case let .array(values): values.map(\.display).joined(separator: ", ")
        case .object: jsonText
        }
    }

    /// The JSON type name, for error messages.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}
