import Foundation

// A typed, Sendable boundary for untrusted JSON. No provider body is logged or persisted.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let flag): try value.encode(flag)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self, v.isFinite { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var isNull: Bool { self == .null }

    public static func parse(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
    }
}

func safeLabel(_ value: String?, fallback: String) -> String {
    guard let value else { return fallback }
    let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let label = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? fallback : String(label.prefix(160))
}
