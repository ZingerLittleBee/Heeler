import Foundation
import HeelerSSH

@testable import Heeler

/// A Rex server's control endpoint at the far end of a `FakeWebSocketServer`,
/// shaped after what Rex 0.1.0-preview.14 (API revision 12) was seen to do.
/// It reads what the client sends as JSON, and answers with a scripted
/// welcome, responses, pushed events, close frames, and dropped connections.
/// It answers a client's close frame as a server does. Time never passes on
/// its own. Ids, labels and tokens here are invented.
actor FakeRexServer {
    struct Welcome: Sendable {
        /// Nil leaves `client` out of the welcome, token and all.
        var clientID: String? = "client:00000000-0000-7000-8000-000000000001"
        var reconnectToken: String? = "fake-reconnect-token-0001"
        /// Nil leaves `resumed` out, as Rex does for a new client.
        var resumed: Bool?
        var protocolName = RexControlProtocol.subprotocol
        var apiRevision = 12
        var serverRevision = 12
        var minimumRevision = 12
        var maxMessageBytes: Int? = 1_048_576

        init() {}
    }

    struct Request: Sendable {
        let id: String
        let method: String
        let payload: JSONValue?
        /// The whole message as the client wrote it.
        let text: String
    }

    enum Answer: Sendable {
        case result(JSONValue)
        case error(code: String, message: String, status: Int?)
    }

    nonisolated let channel: FakeWebSocketServer
    private var answers: [String: Answer] = [:]
    private var responders: [String: @Sendable (Request) -> Answer] = [:]
    private var hello: (value: JSONValue, text: String)?
    private var unanswered: [Request] = []
    private var lastSeq: UInt64 = 0
    private var pumping = false
    private var sentClose = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Every request the client sent, answered or not, in order.
    private(set) var requests: [Request] = []
    /// The close frame the client sent, if it sent one.
    private(set) var clientClose: WebSocketClose?

    init(channel: FakeWebSocketServer = FakeWebSocketServer()) {
        self.channel = channel
    }

    // MARK: Handshake

    /// Answers the upgrade for the requested subprotocol and starts reading
    /// what the client sends.
    @discardableResult
    func acceptUpgrade() async -> FakeWebSocketServer.UpgradeRequest {
        let request = await channel.nextUpgradeRequest()
        await channel.acceptUpgrade()
        startPump()
        return request
    }

    /// Answers the upgrade with an HTTP error instead.
    func refuseUpgrade(status: Int) async {
        _ = await channel.nextUpgradeRequest()
        await channel.deliver(Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\n\r\n".utf8))
    }

    /// The client's hello, once it arrives.
    func nextHello() async -> JSONValue {
        await helloText().value
    }

    func helloText() async -> (value: JSONValue, text: String) {
        while true {
            if let hello { return hello }
            await waitForChange()
        }
    }

    func sendWelcome(_ welcome: Welcome = Welcome()) async {
        var limits: [String: JSONValue] = [:]
        if let maxMessageBytes = welcome.maxMessageBytes { limits["max_message_bytes"] = .number(Double(maxMessageBytes)) }
        var message: [String: JSONValue] = [
            "type": .string("welcome"), "protocol": .string(welcome.protocolName), "limits": .object(limits),
            "carriers": .array([]), "features": .object([:]),
            "api_revision": .number(Double(welcome.apiRevision)),
            "api_server_revision": .number(Double(welcome.serverRevision)),
            "api_min_revision": .number(Double(welcome.minimumRevision)),
        ]
        if let clientID = welcome.clientID {
            var client: [String: JSONValue] = ["id": .string(clientID)]
            if let token = welcome.reconnectToken { client["reconnect_token"] = .string(token) }
            if let resumed = welcome.resumed { client["resumed"] = .bool(resumed) }
            message["client"] = .object(client)
        }
        await send(message)
    }

    /// Accepts the upgrade, waits for the hello and welcomes the client.
    /// Returns the hello.
    @discardableResult
    func handshake(_ welcome: Welcome = Welcome()) async -> JSONValue {
        await acceptUpgrade()
        let hello = await nextHello()
        await sendWelcome(welcome)
        return hello
    }

    // MARK: Requests

    /// Each later request for `method` is answered as it arrives, with the
    /// seq of the last event pushed.
    func answer(_ method: String, with answer: Answer) {
        answers[method] = answer
    }

    /// Each later request for `method` is answered as it arrives with what
    /// `responder` makes of it, with the seq of the last event pushed. A
    /// responder takes precedence over a fixed answer.
    func answer(_ method: String, using responder: @escaping @Sendable (Request) -> Answer) {
        responders[method] = responder
    }

    /// Stops answering `method` by itself.
    func stopAnswering(_ method: String) {
        answers[method] = nil
        responders[method] = nil
    }

    /// The next request no scripted answer took, once it arrives.
    func nextRequest() async -> Request {
        while unanswered.isEmpty { await waitForChange() }
        return unanswered.removeFirst()
    }

    /// `seq` defaults to the last event pushed, as Rex numbers a response.
    func respond(to request: Request, with result: JSONValue = .object([:]), seq: UInt64? = nil) async {
        await send(Self.response(id: request.id, seq: seq ?? lastSeq, outcome: .result(result)))
    }

    func fail(_ request: Request, code: String, message: String, status: Int?, seq: UInt64? = nil) async {
        await send(Self.response(
            id: request.id, seq: seq ?? lastSeq, outcome: .error(code: code, message: message, status: status)))
    }

    // MARK: Events

    /// Pushes one event, numbered after the last one unless `seq` says
    /// otherwise. With `session`, it comes wrapped as that session's event.
    @discardableResult
    func push(_ name: String, _ payload: JSONValue = .object([:]), session: String? = nil, seq: UInt64? = nil) async
        -> UInt64
    {
        let number = seq ?? lastSeq + 1
        lastSeq = number
        let event: JSONValue =
            if let session {
                .object([
                    "type": .string("session_event"),
                    "payload": .object([
                        "session_id": .string(session),
                        "event": .object(["type": .string(name), "payload": payload]),
                    ]),
                ])
            } else {
                .object(["type": .string(name), "payload": payload])
            }
        await send(["type": .string("event"), "seq": .number(Double(number)), "payload": event])
        return number
    }

    /// Sends one text message exactly as given.
    func sendText(_ text: String) async {
        await channel.send(text: text)
    }

    // MARK: Endings

    func close(_ code: WebSocketCloseCode, reason: String = "") async {
        sentClose = true
        await channel.sendClose(code, reason: reason)
    }

    /// The connection ends with no close frame.
    func drop() async {
        await channel.deliverEndOfFile()
    }

    func waitUntilClosed() async {
        await channel.waitUntilClosed()
    }

    /// Whether the client wrote a close frame at any point.
    var clientSentCloseFrame: Bool {
        get async { await channel.frames.contains { $0.opcode == .close } }
    }

    // MARK: Reading the client

    private func startPump() {
        guard !pumping else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while let frame = await channel.nextFrameUnlessClosed() {
            switch frame.opcode {
            case .text:
                await received(String(decoding: frame.payload, as: UTF8.self))
            case .close:
                let close = (try? WebSocketClose(payload: frame.payload)) ?? WebSocketClose(code: .noStatusReceived)
                clientClose = close
                if !sentClose {
                    sentClose = true
                    await channel.sendClose(close.code.mayBeSent ? close.code : nil)
                }
            default:
                break
            }
            signalChange()
        }
        signalChange()
    }

    private func received(_ text: String) async {
        let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
        guard hello != nil else {
            hello = (value, text)
            return
        }
        guard value["type"]?.stringValue == "request", let id = value["id"]?.stringValue,
            let method = value["method"]?.stringValue
        else { return }
        let request = Request(id: id, method: method, payload: value["payload"], text: text)
        requests.append(request)
        guard let answer = responders[method]?(request) ?? answers[method] else {
            unanswered.append(request)
            return
        }
        await send(Self.response(id: id, seq: lastSeq, outcome: answer))
    }

    private static func response(id: String, seq: UInt64, outcome: Answer) -> [String: JSONValue] {
        var message: [String: JSONValue] = [
            "type": .string("response"), "id": .string(id), "seq": .number(Double(seq)),
        ]
        switch outcome {
        case .result(let result):
            message["payload"] = result
        case .error(let code, let text, let status):
            var error: [String: JSONValue] = ["code": .string(code), "message": .string(text)]
            if let status { error["status"] = .number(Double(status)) }
            message["error"] = .object(error)
        }
        return message
    }

    private func send(_ message: [String: JSONValue]) async {
        await channel.send(text: Self.text(.object(message)))
    }

    /// JSON as Rex writes it: whole numbers without a fraction.
    static func text(_ value: JSONValue) -> String {
        let object = foundation(value)
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .string(let value): value
        case .array(let values): values.map(foundation)
        case .object(let fields): fields.mapValues(foundation)
        }
    }

    private func waitForChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func signalChange() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

extension FakeRexServer {
    /// A control link that finished its hello with a fresh fake server.
    /// Deadlines run on `clock`, which only moves when the test says so.
    static func open(
        welcome: Welcome = Welcome(), options: RexControlLink.Options = .testing, clock: ManualClock = ManualClock(),
        resuming previous: RexControlLink? = nil
    ) async throws -> (server: FakeRexServer, link: RexControlLink) {
        let server = FakeRexServer()
        async let link = RexControlLink.open(
            over: server.channel, resuming: previous, options: options, sleep: clock.parkedSleep(for:))
        await server.handshake(welcome)
        return (server, try await link)
    }
}

extension RexControlLink.Options {
    /// No client pings, and an identity that never changes with the app's version.
    static var testing: RexControlLink.Options {
        var options = RexControlLink.Options()
        options.keepalive = nil
        options.identity = RexClientIdentity(name: "Heeler", version: "1.2.3", label: "Heeler")
        return options
    }
}

/// Literals for fixtures, so a test writes `["session_id": "session:a"]`.
extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByIntegerLiteral,
    @retroactive ExpressibleByBooleanLiteral, @retroactive ExpressibleByArrayLiteral,
    @retroactive ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
