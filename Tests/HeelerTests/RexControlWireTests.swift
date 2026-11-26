import Foundation
import Testing

@testable import Heeler

/// The control connection's messages as written and read, against shapes Rex
/// 0.1.0-preview.14 (API revision 12) was seen to use. Ids, labels and tokens
/// are invented.
@Suite("Rex control messages")
struct RexControlWireTests {
    private static let token = "fake-token-7f3a"

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Hello

    @Test func aHelloSaysWhoThisClientIsAndAsksForRevisions12To19() throws {
        let identity = RexClientIdentity(name: "Heeler", version: "1.2.3", label: "Heeler")
        let (text, carriesToken) = RexHello(identity: identity, reconnectToken: nil).encoded()
        let hello = try json(text)

        #expect(!carriesToken)
        #expect(hello["type"] == .string("hello"))
        #expect(hello["api_revision"] == .number(19))
        #expect(hello["api_min_revision"] == .number(12))
        #expect(hello["reconnect_token"] == nil)
        #expect(
            hello["client"]
                == .object([
                    "kind": .string("other"), "platform": .string("ios"), "name": .string("Heeler"),
                    "version": .string("1.2.3"), "label": .string("Heeler"),
                ]))
        #expect(text.utf8.count < 512)
    }

    @Test func theAppsOwnIdentityNamesNoAccountDeviceOrHost() {
        let identity = RexClientIdentity.heeler
        #expect(identity.name == "Heeler")
        #expect(identity.label == "Heeler")
        #expect(!identity.version.isEmpty)
    }

    @Test func aResumingHelloCarriesTheToken() throws {
        let token = try #require(RexReconnectToken(Self.token))
        let (text, carriesToken) = RexHello(identity: .heeler, reconnectToken: token).encoded()

        #expect(carriesToken)
        #expect(try json(text)["reconnect_token"] == .string(Self.token))
    }

    /// Rex drops a hello of 512 bytes or more, so long fields are cut, by
    /// whole characters, and a token that cannot fit is left out.
    @Test func aHelloStaysUnder512BytesAndValidUTF8() throws {
        let long = String(repeating: "界", count: 200)
        let identity = RexClientIdentity(name: long, version: long, label: long)
        let token = try #require(RexReconnectToken(String(repeating: "t", count: 100)))
        let (text, carriesToken) = RexHello(identity: identity, reconnectToken: token).encoded()
        let client = try json(text)["client"]

        #expect(text.utf8.count < 512)
        #expect(carriesToken)
        #expect(client?["name"]?.stringValue?.utf8.count ?? 99 <= 64)
        #expect(client?["name"]?.stringValue?.allSatisfy { $0 == "界" } == true)

        let huge = try #require(RexReconnectToken(String(repeating: "t", count: 400)))
        let (withoutToken, carriesHuge) = RexHello(identity: identity, reconnectToken: huge).encoded()
        #expect(!carriesHuge)
        #expect(withoutToken.utf8.count < 512)
        #expect(try json(withoutToken)["reconnect_token"] == nil)
    }

    // MARK: Welcome

    @Test func aWelcomeIsReadWhateverElseItCarries() throws {
        let welcome = RexWelcome(
            try json(
                #"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576,"later":1},"# +
                    #""carriers":[],"client":{"id":"client:0001","reconnect_token":"\#(Self.token)"},"# +
                    #""features":{"x":true},"api_revision":12,"api_server_revision":12,"api_min_revision":12,"# +
                    #""something_new":{"a":[1,2]}}"#))

        #expect(welcome.protocolName == "rex.control.v1")
        #expect(welcome.apiRevision == 12)
        #expect(welcome.serverRevision == 12)
        #expect(welcome.minimumRevision == 12)
        #expect(welcome.maxMessageBytes == 1_048_576)
        #expect(welcome.clientID == "client:0001")
        #expect(welcome.reconnectToken == RexReconnectToken(Self.token))
        #expect(!welcome.resumed)
    }

    @Test(arguments: [
        (#""resumed":true"#, true), (#""resumed":false"#, false), (#""resumed":null"#, false),
        (#""resumed":"yes""#, false),
    ])
    func aWelcomeResumesOnlyWhenItSaysTrue(field: String, resumed: Bool) throws {
        let welcome = RexWelcome(try json(#"{"type":"welcome","client":{"id":"client:0001",\#(field)}}"#))
        #expect(welcome.resumed == resumed)
    }

    @Test func aWelcomeFieldOfTheWrongShapeReadsAsMissing() throws {
        let welcome = RexWelcome(
            try json(#"{"type":"welcome","protocol":7,"api_revision":"12","limits":[],"client":"client:0001"}"#))

        #expect(welcome.protocolName == nil)
        #expect(welcome.apiRevision == nil)
        #expect(welcome.maxMessageBytes == nil)
        #expect(welcome.clientID == nil)
        #expect(welcome.offer == RexServerOffer())
    }

    // MARK: Responses and events

    @Test func aResponseCarriesItsSeqAndResult() throws {
        guard case .response(let id, let seq, .result(let message)) = RexInbound(
            text: #"{"type":"response","id":"h3","seq":41,"payload":{"sessions":[]},"extra":1}"#)
        else {
            Issue.record("not read as a response")
            return
        }
        #expect(id == "h3")
        #expect(seq == 41)
        struct Sessions: Decodable { let sessions: [String] }
        let response = RexResponse(method: "session.list", seq: seq ?? 0, message: message)
        #expect(try response.result(Sessions.self).sessions.isEmpty)
        #expect(throws: RexControlError.self) { try response.result([Int].self) }
    }

    @Test func anErrorResponseKeepsTheServersCodeAndReadsAnUnknownOneByStatus() {
        guard case .response(_, _, .error(let known)) = RexInbound(
            text: #"{"type":"response","id":"h1","seq":0,"error":{"code":"session_not_found","message":"no such session","status":404}}"#),
            case .response(_, _, .error(let unknown)) = RexInbound(
                text: #"{"type":"response","id":"h2","error":{"code":"brand_new","message":"","status":409}}"#)
        else {
            Issue.record("not read as error responses")
            return
        }
        #expect(known == RexServerError(code: "session_not_found", message: "no such session", status: 404))
        #expect(known.kind == .notFound)
        #expect(unknown.kind == .conflict)
        #expect(RexServerError(code: "", message: "", status: nil).kind == .other)
    }

    @Test func eventsAreReadAtTopLevelAndInsideTheirSession() {
        let created = RexInbound(
            text: #"{"type":"event","seq":1,"payload":{"type":"session_created","payload":{"session":{"session_id":"session:a","label":"lab-a"}}}}"#)
        let window = RexInbound(
            text: #"{"type":"event","seq":2,"payload":{"type":"session_event","payload":{"session_id":"session:a","event":{"type":"window_label_changed","payload":{"window_id":"window:w","label":"w2"}}}}}"#)
        let block = RexInbound(
            text: #"{"type":"event","seq":3,"payload":{"type":"session_event","payload":{"session_id":"session:a","event":{"type":"block_event","payload":{"block_id":"block:b","creator_name":"term","name":"process_changed","payload":{"generation":2}}}}}}"#)

        guard case .event(1, let createdEvent?) = created, case .event(2, let windowEvent?) = window,
            case .event(3, let blockEvent?) = block
        else {
            Issue.record("events not read")
            return
        }
        #expect(createdEvent.sessionID == nil)
        #expect(createdEvent.body == .sessionCreated(sessionID: "session:a", label: "lab-a"))
        #expect(windowEvent.sessionID == "session:a")
        #expect(windowEvent.body == .windowLabelChanged(windowID: "window:w", label: "w2"))
        #expect(
            blockEvent.body
                == .blockEvent(
                    blockID: "block:b", creatorName: "term", name: "process_changed",
                    payload: .object(["generation": .number(2)])))
    }

    @Test func anUnknownEventKeepsItsSeqAndAKnownOneWithBadFieldsSaysSo() {
        let unknown = RexInbound(text: #"{"type":"event","seq":4,"payload":{"type":"client_connected","payload":{}}}"#)
        let bad = RexInbound(
            text: #"{"type":"event","seq":5,"payload":{"type":"session_event","payload":{"session_id":"session:a","event":{"type":"block_closed","payload":{"block_id":9}}}}}"#)
        let noSeq = RexInbound(text: #"{"type":"event","payload":{"type":"session_destroyed","payload":{"session_id":"session:a"}}}"#)

        guard case .event(4, nil) = unknown, case .event(5, let badEvent?) = bad, case .event(nil, let lone?) = noSeq
        else {
            Issue.record("events not read")
            return
        }
        #expect(badEvent.body == .unreadable(name: "block_closed"))
        #expect(lone.body == .sessionDestroyed(sessionID: "session:a"))
    }

    @Test(arguments: ["not json", "[1,2]", #"{"type":"mystery"}"#, #"{"type":"response"}"#, #"{"seq":1}"#])
    func aMessageOfAnUnknownShapeIsSkipped(text: String) {
        guard case .skipped = RexInbound(text: text) else {
            Issue.record("\(text) was not skipped")
            return
        }
    }

    // MARK: The token stays private

    @Test func aReconnectTokenNeverAppearsInADescription() throws {
        let token = try #require(RexReconnectToken(Self.token))
        let welcome = RexWelcome(try json(#"{"type":"welcome","client":{"id":"c","reconnect_token":"\#(Self.token)"}}"#))
        var dumped = ""
        dump(welcome, to: &dumped)
        dump(token, to: &dumped)

        for text in [
            String(describing: token), String(reflecting: token), "\(token)", String(describing: welcome),
            String(reflecting: welcome), dumped,
        ] {
            #expect(!text.contains(Self.token), "\(text)")
        }
        #expect(Mirror(reflecting: token).children.isEmpty)
    }
}
