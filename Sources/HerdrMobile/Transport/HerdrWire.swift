import Foundation

/// herdr's NDJSON wire format: request `{"id","method","params"}` + "\n",
/// success `{"id","result"}`, failure `{"id","error":{"code","message"}}`.
/// One request per connection; decoding is lenient (unknown fields ignored)
/// because herdr's API has no stability guarantee.
enum HerdrWire {
    /// Encodes a single request line, trailing newline included.
    static func requestLine(id: String, method: String) throws -> String {
        let request = Request(id: id, method: method)
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw TransportError.malformedResponse(
                "failed to encode request for \(method): \(error)")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Decodes one response line: unwraps the envelope, checks id correlation,
    /// and either returns the result or throws the server's error.
    static func decodeResult<R: Decodable>(
        _ type: R.Type, fromResponseLine data: Data, requestID: String
    ) throws -> R {
        let lineData = Data(data.prefix(while: { $0 != 0x0A }))
        let envelope: ResponseEnvelope<R>
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope<R>.self, from: lineData)
        } catch {
            let preview = String(decoding: lineData.prefix(200), as: UTF8.self)
            throw TransportError.malformedResponse("undecodable response line: \(preview)")
        }
        guard envelope.id == requestID else {
            throw TransportError.malformedResponse(
                "response id \(envelope.id ?? "<none>") does not match request id \(requestID)")
        }
        if let error = envelope.error {
            throw error
        }
        guard let result = envelope.result else {
            throw TransportError.malformedResponse("response has neither result nor error")
        }
        return result
    }

    private struct Request: Encodable {
        let id: String
        let method: String
        // All M0 methods take empty params; grows a payload when one needs it.
        let params = EmptyParams()

        struct EmptyParams: Encodable {}
    }

    private struct ResponseEnvelope<R: Decodable>: Decodable {
        let id: String?
        let result: R?
        let error: HerdrAPIError?
    }
}

extension HerdrAPIError: Decodable {
    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int.self, forKey: .code) {
            self.init(code: String(number), message: try container.decode(String.self, forKey: .message))
        } else {
            self.init(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message))
        }
    }
}

/// Result payload of `agent.list`.
struct AgentListResult: Decodable {
    let agents: [Agent]
}
