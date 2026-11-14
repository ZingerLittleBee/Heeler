import Foundation
import Testing

@testable import Heeler

@Suite struct WebSocketHandshakeTests {
    /// The nonce behind the RFC 6455 section 1.3 example key.
    private static let sampleNonce = Data("the sample nonce".utf8)
    private static let sampleAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    private static func handshake() throws -> WebSocketHandshake {
        try WebSocketHandshake(path: "/api/test", host: "localhost", subprotocol: "heeler.test.v1", nonce: sampleNonce)
    }

    private static func answer(_ lines: [String], trailing: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + trailing).utf8)
    }

    private static let goodLines = [
        "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
        "Sec-WebSocket-Accept: \(sampleAccept)", "Sec-WebSocket-Protocol: heeler.test.v1",
    ]

    private static func problem(_ lines: [String]) -> WebSocketError? {
        do {
            _ = try handshake().response(from: answer(lines))
            return nil
        } catch {
            return error as? WebSocketError
        }
    }

    @Test func computesTheRFCExampleAcceptValue() throws {
        #expect(try Self.handshake().key == "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(WebSocketHandshake.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == Self.sampleAccept)
    }

    @Test func requestsOneSubprotocolAndNoExtension() throws {
        let request = String(decoding: try Self.handshake().request, as: UTF8.self)
        #expect(
            request
                == [
                    "GET /api/test HTTP/1.1", "Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13",
                    "Sec-WebSocket-Protocol: heeler.test.v1", "", "",
                ].joined(separator: "\r\n"))
    }

    @Test func refusesARequestThatCouldInjectHeaders() {
        for (path, subprotocol) in [("/a\r\nX: y", "p"), ("relative", "p"), ("/a", "p, q"), ("/a b", "p")] {
            #expect(throws: WebSocketError.self) {
                try WebSocketHandshake(path: path, host: "localhost", subprotocol: subprotocol, nonce: Self.sampleNonce)
            }
        }
    }

    @Test func returnsTheBytesAfterTheHeader() throws {
        let rest = try Self.handshake().response(from: Self.answer(Self.goodLines, trailing: "first frame"))
        #expect(rest == Data("first frame".utf8))
    }

    @Test func waitsForTheWholeHeaderHoweverItArrives() throws {
        let handshake = try Self.handshake()
        let answer = Self.answer(Self.goodLines)
        for count in 0..<answer.count {
            #expect(try handshake.response(from: answer.prefix(count)) == nil, "prefix \(count)")
        }
        #expect(try handshake.response(from: answer) == Data())
    }

    @Test func readsFieldNamesAndTokensWithoutCase() throws {
        let lines = [
            "HTTP/1.1 101 Switching Protocols", "upgrade: WebSocket", "connection: keep-alive, Upgrade",
            "sec-websocket-accept:\(Self.sampleAccept)", "SEC-WEBSOCKET-PROTOCOL:  heeler.test.v1 ",
        ]
        #expect(try Self.handshake().response(from: Self.answer(lines)) == Data())
    }

    @Test func surfacesANon101Status() throws {
        let lines = ["HTTP/1.1 403 Forbidden", "Content-Type: application/json", "Content-Length: 17"]
        guard case .upgradeRefused(let status) = Self.problem(lines) else {
            Issue.record("A 403 answer read as \(String(describing: Self.problem(lines)))")
            return
        }
        #expect(status == 403)
    }

    @Test func failsAWrongAcceptKey() {
        var lines = Self.goodLines
        lines[3] = "Sec-WebSocket-Accept: \(WebSocketHandshake.acceptValue(forKey: "AAAAAAAAAAAAAAAAAAAAAA=="))"
        guard case .upgradeInvalid(.wrongAccept) = Self.problem(lines) else {
            Issue.record("A wrong accept read as \(String(describing: Self.problem(lines)))")
            return
        }
    }

    @Test func failsAMissingOrOtherSubprotocol() {
        for replacement in ["Sec-WebSocket-Protocol: other.v1", "X-Nothing: here"] {
            var lines = Self.goodLines
            lines[4] = replacement
            guard case .upgradeInvalid(.wrongSubprotocol) = Self.problem(lines) else {
                Issue.record("\(replacement) read as \(String(describing: Self.problem(lines)))")
                continue
            }
        }
    }

    @Test func failsAnExtensionThatWasNotOffered() {
        let lines = Self.goodLines + ["Sec-WebSocket-Extensions: permessage-deflate"]
        guard case .upgradeInvalid(.unexpectedExtension) = Self.problem(lines) else {
            Issue.record("An extension read as \(String(describing: Self.problem(lines)))")
            return
        }
    }

    @Test func failsAMissingUpgrade() {
        for index in [1, 2] {
            var lines = Self.goodLines
            lines.remove(at: index)
            guard case .upgradeInvalid(.missingUpgrade) = Self.problem(lines) else {
                Issue.record("Without line \(index) read as \(String(describing: Self.problem(lines)))")
                continue
            }
        }
    }

    @Test func failsAMalformedAnswer() {
        for lines in [["SSH-2.0-OpenSSH_9.9"], ["HTTP/1.1 101 Switching Protocols", "no colon here"]] {
            guard case .upgradeInvalid(.malformedResponse) = Self.problem(lines) else {
                Issue.record("\(lines) read as \(String(describing: Self.problem(lines)))")
                continue
            }
        }
    }

    @Test func capsTheAnswerHeader() throws {
        let handshake = try Self.handshake()
        let endless = Data(repeating: 0x61, count: WebSocketHandshake.maximumResponseHeaderBytes + 1)
        #expect(throws: WebSocketError.self) { try handshake.response(from: endless) }
        let padded = Self.goodLines + ["X-Pad: " + String(repeating: "a", count: WebSocketHandshake.maximumResponseHeaderBytes)]
        guard case .upgradeInvalid(.responseHeaderTooLarge) = Self.problem(padded) else {
            Issue.record("A long header read as \(String(describing: Self.problem(padded)))")
            return
        }
    }
}
