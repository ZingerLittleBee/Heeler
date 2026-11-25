import Foundation

/// The messages of a Rex server's control connection (ADR 0049), written by
/// hand from what Rex 0.1.0-preview.14 (API revision 12) was seen to send,
/// and checked unchanged at revision 19 against 0.1.0-preview.23.
///
/// Reading is tolerant: unknown fields are ignored, and a message of an
/// unknown type, an event this build does not know, or a field of the wrong
/// shape costs that one message, never the connection.
enum RexControlProtocol {
    static let path = "/api/control"
    static let subprotocol = "rex.control.v1"
    /// The newest API revision this build speaks, offered in each hello.
    static let apiRevision = 19
    /// The oldest API revision this build speaks. A server picks the newest
    /// revision both sides speak, so a server whose newest is older than this
    /// one, or whose oldest is newer than `apiRevision`, is refused.
    static let minimumAPIRevision = 12
    static let apiRevisions = minimumAPIRevision...apiRevision
    /// Rex drops a client whose hello is 512 bytes or more.
    static let helloByteLimit = 511
    /// Every Rex server accepts messages at least this large; used when a
    /// welcome names no limit.
    static let minimumMessageLimit = 65536
}

/// Who this client says it is in its hello. It never claims to be a Rex app
/// or the Rex command-line tool, and carries nothing personal: no account,
/// device, or host name.
struct RexClientIdentity: Sendable, Equatable {
    static let kind = "other"
    static let platform = "ios"
    /// Rex shows these to other clients, so each stays short.
    static let fieldByteLimit = 64

    var name: String
    var version: String
    var label: String

    static var heeler: RexClientIdentity {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return RexClientIdentity(name: "Heeler", version: version ?? "0", label: "Heeler")
    }
}

/// The token a welcome hands out for resuming this client after a dropped
/// connection. It is a credential: it never appears in a description, a
/// log, or an error, and only a hello carries it.
struct RexReconnectToken: Sendable, Equatable {
    fileprivate let value: String

    init?(_ value: String) {
        guard !value.isEmpty else { return nil }
        self.value = value
    }
}

extension RexReconnectToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "RexReconnectToken(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The first message: who this client is, and the token of the client it
/// resumes, if any.
struct RexHello {
    let identity: RexClientIdentity
    let reconnectToken: RexReconnectToken?

    /// The hello as one JSON text under `RexControlProtocol.helloByteLimit`,
    /// and whether the token is in it. Identity fields are cut to
    /// `RexClientIdentity.fieldByteLimit`; a token too long to fit is left
    /// out, so the server makes a new client instead of resuming one.
    func encoded() -> (text: String, carriesToken: Bool) {
        let client = Client(
            kind: RexClientIdentity.kind, platform: RexClientIdentity.platform,
            name: Self.cut(identity.name), version: Self.cut(identity.version), label: Self.cut(identity.label))
        if let reconnectToken {
            let text = Self.text(Message(reconnectToken: reconnectToken.value, client: client))
            if text.utf8.count <= RexControlProtocol.helloByteLimit { return (text, true) }
        }
        return (Self.text(Message(reconnectToken: nil, client: client)), false)
    }

    private struct Client: Encodable {
        let kind: String
        let platform: String
        let name: String
        let version: String
        let label: String
    }

    private struct Message: Encodable {
        let type = "hello"
        let reconnectToken: String?
        let client: Client
        let apiRevision = RexControlProtocol.apiRevision
        let apiMinRevision = RexControlProtocol.minimumAPIRevision

        private enum CodingKeys: String, CodingKey {
            case type
            case reconnectToken = "reconnect_token"
            case client
            case apiRevision = "api_revision"
            case apiMinRevision = "api_min_revision"
        }
    }

    private static func text(_ message: Message) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings and integers always encode.
        let data = (try? encoder.encode(message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Whole characters only, so the text stays valid UTF-8.
    private static func cut(_ field: String) -> String {
        var result = ""
        var bytes = 0
        for character in field {
            let size = character.utf8.count
            guard bytes + size <= RexClientIdentity.fieldByteLimit else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}

/// What a server answered a hello with.
struct RexWelcome: Sendable {
    let protocolName: String?
    let apiRevision: Int?
    let serverRevision: Int?
    let minimumRevision: Int?
    let maxMessageBytes: Int?
    let clientID: String?
    let reconnectToken: RexReconnectToken?
    /// The server kept the client the hello's token named. A welcome that
    /// leaves this out, or says null, made a new client.
    let resumed: Bool

    init(_ message: JSONValue) {
        protocolName = message["protocol"]?.stringValue
        apiRevision = message["api_revision"]?.rexInteger
        serverRevision = message["api_server_revision"]?.rexInteger
        minimumRevision = message["api_min_revision"]?.rexInteger
        maxMessageBytes = message["limits"]?["max_message_bytes"]?.rexInteger
        clientID = message["client"]?["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        reconnectToken = message["client"]?["reconnect_token"]?.stringValue.flatMap(RexReconnectToken.init)
        resumed = message["client"]?["resumed"] == .bool(true)
    }

    var offer: RexServerOffer {
        RexServerOffer(
            protocolName: protocolName, apiRevision: apiRevision, serverRevision: serverRevision,
            minimumRevision: minimumRevision)
    }
}

/// What a server offered that this build could not use. Every field is nil
/// when the server closed the connection before it welcomed this client.
struct RexServerOffer: Sendable, Equatable {
    var protocolName: String?
    var apiRevision: Int?
    var serverRevision: Int?
    var minimumRevision: Int?

    static let unknown = RexServerOffer()

    /// The newest revision the server said it speaks, for telling the user.
    var newestRevision: Int? { serverRevision ?? apiRevision }
}

/// An error a server answered a request with.
struct RexServerError: Error, Sendable, Equatable {
    /// The server's code, such as `session_not_found`. Kept as sent, so a
    /// code this build does not know still reaches the caller.
    let code: String
    let message: String
    /// The HTTP-style status the server paired with the code.
    let status: Int?

    enum Kind: Sendable, Equatable {
        case badRequest
        case notFound
        case conflict
        case notSupported
        case refused
        case tooLarge
        case revisionTooLow
        case timedOut
        case serverFailure
        case other
    }

    /// The code's meaning; a code this build does not know is read by its status.
    var kind: Kind {
        switch code {
        case "bad_request": .badRequest
        case "not_found", "method_not_found", "session_not_found": .notFound
        case "conflict", "client_unavailable": .conflict
        case "not_supported": .notSupported
        case "refused": .refused
        case "too_large": .tooLarge
        case "revision_too_low": .revisionTooLow
        case "timeout": .timedOut
        case "internal": .serverFailure
        default:
            switch status ?? 0 {
            case 400: .badRequest
            case 403: .refused
            case 404: .notFound
            case 409: .conflict
            case 413: .tooLarge
            case 504: .timedOut
            case 500...599: .serverFailure
            default: .other
            }
        }
    }
}

/// One answer to a request: its result and where it falls among events.
struct RexResponse: Sendable {
    let method: String
    /// The seq of the last event the server queued before it began this
    /// request; 0 when it had queued none, or the response named no seq. An
    /// event with this seq or a lower one is already part of the result.
    let seq: UInt64
    private let message: Data

    init(method: String, seq: UInt64, message: Data) {
        self.method = method
        self.seq = seq
        self.message = message
    }

    /// The result, decoded as `Result`. A response without one decodes as
    /// an empty object.
    func result<Result: Decodable>(_ type: Result.Type = Result.self) throws(RexControlError) -> Result {
        do {
            let envelope = try JSONDecoder().decode(ResultEnvelope<Result>.self, from: message)
            if let payload = envelope.payload { return payload }
            return try JSONDecoder().decode(Result.self, from: Data("{}".utf8))
        } catch {
            throw .unreadableResult(method: method)
        }
    }

    private struct ResultEnvelope<Payload: Decodable>: Decodable {
        let payload: Payload?
    }
}

/// One event a server pushed, with its place in the connection's sequence.
struct RexControlEvent: Sendable, Equatable {
    let seq: UInt64
    /// The session a session event came wrapped in; nil for server-wide events.
    let sessionID: String?
    let body: RexEventBody
}

/// The events this build reads. Others are skipped.
enum RexEventBody: Sendable, Equatable {
    case sessionCreated(sessionID: String, label: String?)
    case sessionDestroyed(sessionID: String)
    case sessionMoved(sessionID: String, beforeSessionID: String?)
    case sessionLabelChanged(label: String?)
    case sessionViewChanged(revision: Int?)
    case windowCreated(windowID: String, label: String?)
    case windowClosed(windowID: String)
    case windowLabelChanged(windowID: String, label: String?)
    case activeWindowChanged(windowID: String?)
    case blockCreated(blockID: String)
    case blockClosed(blockID: String)
    case blockOwnerChanged(blockID: String, owner: String?, previousOwner: String?, reason: String?)
    /// An event a block's creator raised, such as a terminal's process change.
    case blockEvent(blockID: String, creatorName: String?, name: String, payload: JSONValue?)
    /// An event this build knows whose fields it could not read. What it
    /// changed is unknown, so whatever was built from events needs a fresh read.
    case unreadable(name: String)
}

/// What one inbound text message is.
enum RexInbound: Sendable {
    case welcome(RexWelcome)
    case response(id: String, seq: UInt64?, outcome: Outcome)
    /// `seq` is nil when the event carried none readable; `event` is nil for
    /// an event this build does not know.
    case event(seq: UInt64?, event: (sessionID: String?, body: RexEventBody)?)
    /// Not JSON, of an unknown type, or missing what its type needs.
    case skipped

    enum Outcome: Sendable {
        case result(Data)
        case error(RexServerError)
    }

    init(text: String) {
        let data = Data(text.utf8)
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            self = .skipped
            return
        }
        switch message["type"]?.stringValue {
        case "welcome":
            self = .welcome(RexWelcome(message))
        case "response":
            guard let id = message["id"]?.stringValue else {
                self = .skipped
                return
            }
            let seq = message["seq"]?.rexSeq
            if let error = message["error"], error != .null {
                self = .response(id: id, seq: seq, outcome: .error(RexServerError(
                    code: error["code"]?.stringValue ?? "", message: error["message"]?.stringValue ?? "",
                    status: error["status"]?.rexInteger)))
            } else {
                self = .response(id: id, seq: seq, outcome: .result(data))
            }
        case "event":
            self = .event(seq: message["seq"]?.rexSeq, event: Self.event(message["payload"]))
        default:
            self = .skipped
        }
    }

    private static func event(_ envelope: JSONValue?) -> (sessionID: String?, body: RexEventBody)? {
        guard let name = envelope?["type"]?.stringValue else { return nil }
        let fields = envelope?["payload"]
        guard name == "session_event" else {
            return body(name: name, fields: fields, sessionID: nil).map { (nil, $0) }
        }
        let sessionID = fields?["session_id"]?.stringValue
        let inner = fields?["event"]
        guard let innerName = inner?["type"]?.stringValue else {
            return (sessionID, .unreadable(name: name))
        }
        return body(name: innerName, fields: inner?["payload"], sessionID: sessionID).map { (sessionID, $0) }
    }

    private static func body(name: String, fields: JSONValue?, sessionID: String?) -> RexEventBody? {
        func text(_ key: String) -> String? { fields?[key]?.stringValue }
        func required(_ key: String, _ make: (String) -> RexEventBody) -> RexEventBody {
            text(key).map(make) ?? .unreadable(name: name)
        }
        switch name {
        case "session_created":
            guard let session = fields?["session"], let id = session["session_id"]?.stringValue else {
                return .unreadable(name: name)
            }
            return .sessionCreated(sessionID: id, label: session["label"]?.stringValue)
        case "session_destroyed":
            guard let id = text("session_id") ?? sessionID else { return .unreadable(name: name) }
            return .sessionDestroyed(sessionID: id)
        case "session_moved":
            guard let id = text("session_id") ?? sessionID else { return .unreadable(name: name) }
            return .sessionMoved(sessionID: id, beforeSessionID: text("before_session_id"))
        case "session_label_changed":
            return .sessionLabelChanged(label: text("label"))
        case "session_view_changed":
            return .sessionViewChanged(revision: fields?["revision"]?.rexInteger)
        case "window_created":
            return required("window_id") { .windowCreated(windowID: $0, label: text("label")) }
        case "window_closed":
            return required("window_id") { .windowClosed(windowID: $0) }
        case "window_label_changed":
            return required("window_id") { .windowLabelChanged(windowID: $0, label: text("label")) }
        case "active_window_changed":
            return .activeWindowChanged(windowID: text("window_id"))
        case "block_created":
            return required("block_id") { .blockCreated(blockID: $0) }
        case "block_closed":
            return required("block_id") { .blockClosed(blockID: $0) }
        case "block_owner_changed":
            return required("block_id") {
                .blockOwnerChanged(blockID: $0, owner: text("owner"), previousOwner: text("previous"), reason: text("reason"))
            }
        case "block_event":
            guard let blockID = text("block_id"), let eventName = text("name") else { return .unreadable(name: name) }
            return .blockEvent(blockID: blockID, creatorName: text("creator_name"), name: eventName, payload: fields?["payload"])
        default:
            return nil
        }
    }
}

extension JSONValue {
    /// A whole number that fits an `Int`.
    fileprivate var rexInteger: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(value)
    }

    fileprivate var rexSeq: UInt64? {
        rexInteger.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }
}
