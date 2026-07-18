import Foundation

/// herdr's NDJSON wire format: request `{"id","method","params"}` + "\n",
/// success `{"id","result"}`, failure `{"id","error":{"code","message"}}`.
/// One request per connection; decoding is lenient (unknown fields ignored)
/// because herdr's API has no stability guarantee.
enum HerdrWire {
    /// Encodes a single request line, trailing newline included.
    static func requestLine(id: String, method: String) throws -> String {
        try requestLine(id: id, method: method, params: EmptyParams())
    }

    /// Encodes a single request line with a params payload.
    static func requestLine<P: Encodable>(id: String, method: String, params: P) throws -> String {
        let request = Request(id: id, method: method, params: params)
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw TransportError.malformedResponse(
                "failed to encode request for \(method): \(error)")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Encodes an `events.subscribe` request line. Subscription kinds go out
    /// in their canonical dotted spelling; pane-scoped entries carry the
    /// pane id the server requires.
    static func subscribeRequestLine(id: String, subscriptions: [EventSubscription]) throws
        -> String
    {
        try requestLine(
            id: id, method: "events.subscribe",
            params: SubscribeParams(subscriptions: subscriptions.map(WireSubscription.init)))
    }

    /// Decodes one events-channel line. Returns nil for anything that is not
    /// an event line — lenient by design: junk on the stream is dropped,
    /// never fatal.
    static func decodeEvent(fromLine data: Data) -> HerdrEvent? {
        guard let line = try? JSONDecoder().decode(EventLine.self, from: data) else { return nil }
        return HerdrEvent(kind: HerdrEventKind(wireName: line.event), data: line.data ?? .null)
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
        // Server-reported errors win even when id correlation is off: herdr
        // answers a request it could not parse with id "" (live-captured
        // shape), and the error is the actionable part.
        if let error = envelope.error {
            throw error
        }
        guard envelope.id == requestID else {
            throw TransportError.malformedResponse(
                "response id \(envelope.id ?? "<none>") does not match request id \(requestID)")
        }
        guard let result = envelope.result else {
            throw TransportError.malformedResponse("response has neither result nor error")
        }
        return result
    }

    private struct Request<P: Encodable>: Encodable {
        let id: String
        let method: String
        let params: P
    }

    private struct EmptyParams: Encodable {}

    private struct SubscribeParams: Encodable {
        let subscriptions: [WireSubscription]
    }

    private struct WireSubscription: Encodable {
        let type: String
        let paneID: String?

        init(_ subscription: EventSubscription) {
            switch subscription {
            case .global(let kind):
                type = kind.rawValue
                paneID = nil
            case .pane(let kind, let paneID):
                type = kind.rawValue
                self.paneID = paneID
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case paneID = "pane_id"
        }
    }

    private struct EventLine: Decodable {
        let event: String
        let data: JSONValue?
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

/// Result payload of the `events.subscribe` ack line
/// (`{"type":"subscription_started"}`). Shape intentionally unchecked: the
/// envelope carrying a result at all is the acknowledgement.
struct SubscriptionStartedResult: Decodable {}
