import CryptoKit
import Foundation

/// The client's half of the opening handshake (RFC 6455 section 4): one
/// HTTP/1.1 upgrade request for one subprotocol and no extensions, and the
/// checks its answer must pass. Neither the request nor the answer is ever
/// logged: a path or header can carry what a server treats as a secret.
struct WebSocketHandshake: Sendable {
    /// More than any answer to an upgrade needs; a longer one is not a WebSocket server.
    static let maximumResponseHeaderBytes = 16 * 1024
    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let headerEnd = Data("\r\n\r\n".utf8)

    let key: String
    let subprotocol: String
    let request: Data

    /// `nonce` is the 16 random bytes behind `Sec-WebSocket-Key`.
    init(path: String, host: String, subprotocol: String, nonce: Data) throws(WebSocketError) {
        guard path.hasPrefix("/"), Self.isVisibleASCII(path), Self.isVisibleASCII(host),
            Self.isVisibleASCII(subprotocol), !subprotocol.contains(","), nonce.count == 16
        else { throw .upgradeInvalid(.invalidRequest) }
        key = nonce.base64EncodedString()
        self.subprotocol = subprotocol
        request = Data(
            [
                "GET \(path) HTTP/1.1",
                "Host: \(host)",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: \(key)",
                "Sec-WebSocket-Version: 13",
                "Sec-WebSocket-Protocol: \(subprotocol)",
                "", "",
            ].joined(separator: "\r\n").utf8)
    }

    /// The `Sec-WebSocket-Accept` a server must answer `key` with.
    static func acceptValue(forKey key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
    }

    /// Checks the server's answer once its header has arrived. Nil while the
    /// header is still incomplete; otherwise the bytes that followed it,
    /// which begin the first frame.
    func response(from received: Data) throws(WebSocketError) -> Data? {
        guard let end = received.range(of: Self.headerEnd) else {
            if received.count > Self.maximumResponseHeaderBytes { throw .upgradeInvalid(.responseHeaderTooLarge) }
            return nil
        }
        guard end.upperBound - received.startIndex <= Self.maximumResponseHeaderBytes else {
            throw .upgradeInvalid(.responseHeaderTooLarge)
        }
        // Latin-1 maps every byte, so a header that is not ASCII still parses and fails the checks.
        guard let header = String(data: received[received.startIndex..<end.lowerBound], encoding: .isoLatin1)
        else { throw .upgradeInvalid(.malformedResponse) }
        var lines = header.components(separatedBy: "\r\n")
        let status = try Self.status(of: lines.removeFirst())
        guard status == 101 else { throw .upgradeRefused(status: status) }
        let fields = try Self.fields(lines)
        guard fields["upgrade"]?.count == 1,
            fields["upgrade"]?.first?.caseInsensitiveCompare("websocket") == .orderedSame,
            Self.tokens(fields["connection"]).contains("upgrade")
        else { throw .upgradeInvalid(.missingUpgrade) }
        guard fields["sec-websocket-accept"] == [Self.acceptValue(forKey: key)] else {
            throw .upgradeInvalid(.wrongAccept)
        }
        guard Self.tokens(fields["sec-websocket-extensions"]).isEmpty else {
            throw .upgradeInvalid(.unexpectedExtension)
        }
        guard fields["sec-websocket-protocol"] == [subprotocol] else { throw .upgradeInvalid(.wrongSubprotocol) }
        return Data(received[end.upperBound...])
    }

    private static func status(of line: String) throws(WebSocketError) -> Int {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3,
            let status = Int(parts[1])
        else { throw .upgradeInvalid(.malformedResponse) }
        return status
    }

    /// Values by lowercased field name, in the order they came.
    private static func fields(_ lines: [String]) throws(WebSocketError) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw .upgradeInvalid(.malformedResponse)
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            fields[name, default: []].append(value)
        }
        return fields
    }

    /// The comma-separated tokens of every value of one field, lowercased.
    private static func tokens(_ values: [String]?) -> [String] {
        (values ?? []).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func isVisibleASCII(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

/// How an upgrade answer failed RFC 6455 or asked for something not offered.
enum WebSocketUpgradeProblem: Sendable, Equatable {
    /// This side's own path, host or subprotocol cannot go in a request.
    case invalidRequest
    case malformedResponse
    case responseHeaderTooLarge
    /// No `Upgrade: websocket`, or no `upgrade` in `Connection`.
    case missingUpgrade
    case wrongAccept
    /// The server picked no subprotocol or another one.
    case wrongSubprotocol
    /// The server picked an extension, though none was offered.
    case unexpectedExtension
}
