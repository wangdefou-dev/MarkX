import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func value(at path: [String]) -> JSONValue? {
        path.reduce(Optional(self)) { partial, key in partial?[key] }
    }

    public func firstString(forKeys keys: Set<String>) -> String? {
        switch self {
        case .object(let object):
            for key in keys {
                if let value = object[key]?.stringValue, !value.isEmpty {
                    return value
                }
            }
            for key in object.keys.sorted() {
                if let value = object[key]?.firstString(forKeys: keys) {
                    return value
                }
            }
        case .array(let array):
            for value in array {
                if let found = value.firstString(forKeys: keys) { return found }
            }
        default:
            break
        }
        return nil
    }

    public func collectStrings(forKeys keys: Set<String>) -> [String] {
        var output: [String] = []
        collectStrings(forKeys: keys, into: &output)
        return output
    }

    private func collectStrings(forKeys keys: Set<String>, into output: inout [String]) {
        switch self {
        case .object(let object):
            for key in object.keys.sorted() {
                let value = object[key]!
                if keys.contains(key), let string = value.stringValue {
                    output.append(string)
                }
                value.collectStrings(forKeys: keys, into: &output)
            }
        case .array(let array):
            for value in array { value.collectStrings(forKeys: keys, into: &output) }
        default:
            break
        }
    }
}
