import Foundation

/// The part of SOCKS5 (RFC 1928) and its username and password method
/// (RFC 1929) that a web view speaks to the preview's proxy.
enum SOCKS5 {
    /// What the bytes received so far amount to.
    enum Step<Value: Sendable & Equatable>: Sendable, Equatable {
        /// More bytes are needed before the message is whole.
        case incomplete
        /// The bytes are not this message.
        case malformed
        /// The message, and how many bytes it took.
        case parsed(Value, consumed: Int)
    }

    struct Credentials: Sendable, Equatable {
        let username: [UInt8]
        let password: [UInt8]
    }

    enum Address: Sendable, Equatable {
        case domain(String)
        case ipv4([UInt8])
        case ipv6([UInt8])
    }

    struct Request: Sendable, Equatable {
        let command: UInt8
        let address: Address
        let port: UInt16
    }

    /// RFC 1928 section 6 reply codes the proxy sends.
    enum Reply: UInt8, Sendable {
        case succeeded = 0
        case generalFailure = 1
        case notAllowed = 2
        case hostUnreachable = 4
        case connectionRefused = 5
        case commandNotSupported = 7
        case addressTypeNotSupported = 8
    }

    static let version: UInt8 = 5
    static let connect: UInt8 = 1
    static let usernamePasswordMethod: UInt8 = 2
    static let noAcceptableMethod: UInt8 = 0xFF

    /// The methods a client offers in its greeting.
    static func greeting(in bytes: [UInt8]) -> Step<[UInt8]> {
        guard bytes.count >= 2 else { return bytes.first.map { $0 == version } ?? true ? .incomplete : .malformed }
        guard bytes[0] == version else { return .malformed }
        let end = 2 + Int(bytes[1])
        guard bytes.count >= end else { return .incomplete }
        return .parsed(Array(bytes[2..<end]), consumed: end)
    }

    /// The username and password of an RFC 1929 request.
    static func credentials(in bytes: [UInt8]) -> Step<Credentials> {
        guard let first = bytes.first else { return .incomplete }
        guard first == 1 else { return .malformed }
        guard bytes.count >= 2 else { return .incomplete }
        let usernameEnd = 2 + Int(bytes[1])
        guard bytes.count > usernameEnd else { return .incomplete }
        let end = usernameEnd + 1 + Int(bytes[usernameEnd])
        guard bytes.count >= end else { return .incomplete }
        return .parsed(
            Credentials(
                username: Array(bytes[2..<usernameEnd]),
                password: Array(bytes[(usernameEnd + 1)..<end])),
            consumed: end)
    }

    /// A connection request.
    static func request(in bytes: [UInt8]) -> Step<Request> {
        guard let first = bytes.first else { return .incomplete }
        guard first == version else { return .malformed }
        guard bytes.count >= 4 else { return .incomplete }
        let addressEnd: Int
        let address: Address
        switch bytes[3] {
        case 1:
            addressEnd = 8
            guard bytes.count >= addressEnd else { return .incomplete }
            address = .ipv4(Array(bytes[4..<addressEnd]))
        case 3:
            guard bytes.count >= 5 else { return .incomplete }
            addressEnd = 5 + Int(bytes[4])
            guard bytes.count >= addressEnd else { return .incomplete }
            address = .domain(String(decoding: bytes[5..<addressEnd], as: UTF8.self))
        case 4:
            addressEnd = 20
            guard bytes.count >= addressEnd else { return .incomplete }
            address = .ipv6(Array(bytes[4..<addressEnd]))
        default:
            return .malformed
        }
        let end = addressEnd + 2
        guard bytes.count >= end else { return .incomplete }
        let port = UInt16(bytes[addressEnd]) << 8 | UInt16(bytes[addressEnd + 1])
        return .parsed(Request(command: bytes[1], address: address, port: port), consumed: end)
    }

    static func methodSelection(_ method: UInt8) -> Data {
        Data([version, method])
    }

    static func authenticationStatus(accepted: Bool) -> Data {
        Data([1, accepted ? 0 : 1])
    }

    /// A reply whose bound address is unspecified, which is all a client
    /// that asked to connect reads from it.
    static func reply(_ reply: Reply) -> Data {
        Data([version, reply.rawValue, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}

extension SOCKS5.Request {
    /// The Host loopback port this request asks for, or the reply that
    /// refuses it. The proxy carries one name to one place: anything else a
    /// client asks for is not forwarded anywhere.
    var loopbackPort: Result<UInt16, SOCKS5.Refusal> {
        guard command == SOCKS5.connect else { return .failure(.init(reply: .commandNotSupported)) }
        guard port != 0 else { return .failure(.init(reply: .notAllowed)) }
        switch address {
        case .domain(let name):
            return name.lowercased() == "localhost" ? .success(port) : .failure(.init(reply: .notAllowed))
        case .ipv4(let bytes):
            return bytes == [127, 0, 0, 1] ? .success(port) : .failure(.init(reply: .notAllowed))
        case .ipv6(let bytes):
            return bytes == [UInt8](repeating: 0, count: 15) + [1]
                ? .success(port) : .failure(.init(reply: .notAllowed))
        }
    }
}

extension SOCKS5 {
    struct Refusal: Error, Sendable, Equatable {
        let reply: Reply
    }
}

extension SOCKS5.Credentials {
    /// Whether these are the expected credentials, compared without stopping
    /// at the first byte that differs.
    func matches(username: [UInt8], password: [UInt8]) -> Bool {
        Self.same(self.username, username) && Self.same(self.password, password)
    }

    private static func same(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
