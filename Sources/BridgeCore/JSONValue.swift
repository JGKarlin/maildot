import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let object) = self { object[key] ?? .null } else { .null } }
    public var string: String? { if case .string(let text) = self { text } else { nil } }
    public var integer: Int? { if case .number(let value) = self, value.isFinite, value.rounded() == value { Int(exactly: value) } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    public func text() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
extension JSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .number(Double(value)) } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSONValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension JSONValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: JSONValue...) { self = .array(elements) } }
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}
