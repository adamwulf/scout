import Foundation

/// Retains the API's optional fields for JSON output without modeling the entire Help Scout API.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        guard case .object(let object) = self else { return .null }
        return object[key] ?? .null
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int? { if case .integer(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    public func requiredID(_ key: String = "id") throws -> Int {
        guard let value = self[key].int, value > 0 else {
            throw ScoutError.decoding("Help Scout response is missing a positive \(key).")
        }
        return value
    }
}

public struct ResourcePage: Codable, Sendable, Equatable {
    public var items: [JSONValue]
    public var nextCursor: String?
    public var nextPage: Int?

    public init(items: [JSONValue], nextCursor: String? = nil, nextPage: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.nextPage = nextPage
    }
}
