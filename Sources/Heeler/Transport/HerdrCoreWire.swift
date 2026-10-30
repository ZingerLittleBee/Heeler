import Foundation

/// The generation-1 herdr-core API is JSON-RPC, not the legacy herdr wire
/// protocol. These are its envelope, for the link and the typed records.
enum HerdrCoreWire {
    static let generation = 1

    static func requestLine(
        id: String, method: String, params: JSONValue = .object([:])
    ) throws -> String {
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "method": .string(method), "params": params,
        ])
        return String(decoding: try JSONEncoder().encode(request), as: UTF8.self) + "\n"
    }

    static func result(from data: Data, id: String) throws -> JSONValue {
        let envelope = try decodeLine(data)
        guard envelope["jsonrpc"] == .string("2.0"), envelope["id"] == .string(id) else {
            throw malformed("The response is not JSON-RPC 2.0 for the requested id.")
        }
        if let error = envelope["error"], error != .null {
            guard let message = error["message"]?.stringValue else {
                throw malformed("The error response has no message.")
            }
            let kind = error["data"]?["kind"]?.stringValue
                ?? integer(error["code"]).map(String.init) ?? "herdr_core_error"
            let hint = nonEmpty(error["data"]?["hint"]?.stringValue)
            throw HerdrAPIError(code: kind, message: hint.map { "\(message) \($0)" } ?? message)
        }
        guard let result = envelope["result"] else {
            throw malformed("The response has neither a result nor an error.")
        }
        return result
    }

    /// The id of a channel-0 reply, or nil for anything that is not a reply
    /// to one of this client's string-id requests.
    static func responseID(from data: Data) -> String? {
        guard let envelope = try? decodeLine(data), envelope["method"] == nil else { return nil }
        return envelope["id"]?.stringValue
    }

    /// A typed view of a decoded JSON value. Unknown fields are ignored.
    static func typed<Value: Decodable>(_ value: JSONValue) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        } catch {
            throw malformed("Invalid \(Value.self).")
        }
    }

    /// A Terminal's address at the codec boundary. Addresses are opaque and
    /// travel inside JSON, so only the two that name no local Terminal are
    /// refused: an empty one, and a federated one, which contains "/".
    static func address(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("/") else {
            throw TransportError.hostFeatureUnavailable(
                feature: "Connect directly to the Host that owns this herdr-core Terminal")
        }
        return value
    }

    private static func decodeLine(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw malformed("Invalid JSON response.") }
    }

    static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number.isFinite,
            number.rounded(.towardZero) == number,
            number >= Double(Int.min), number < Double(Int.max)
        else { return nil }
        return Int(number)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func malformed(_ detail: String) -> TransportError {
        .malformedResponse("herdr-core: \(detail)")
    }
}
