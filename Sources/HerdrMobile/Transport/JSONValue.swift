import Foundation

/// A decoded JSON tree. Event payloads are schema-free — only 3 of herdr's
/// 26 subscription kinds have typed payloads — so events carry their data as
/// a JSONValue and consumers pick out the fields they know.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value under `key` if this is an object that holds one.
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

extension JSONValue: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Double: JSONDecoder refuses cross-type coercion, so
        // the order only disambiguates, it cannot misread.
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
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "value is not JSON")
        }
    }
}
