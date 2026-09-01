import CLibSSH2
import Darwin
import Foundation
import Testing

@testable import HeelerSSH

extension SessionDriverE2ETests {
    /// The server completes algorithm selection with production-supported
    /// methods, then drops the transport while Curve25519 key exchange is in
    /// flight. libssh2 reports that later phase with
    /// LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE, which must not be presented as the
    /// no-common-algorithm error from LIBSSH2_ERROR_KEX_FAILURE.
    @Test("post-negotiation transport loss is not an algorithm mismatch")
    func postNegotiationTransportLossIsNotAlgorithmMismatch() async throws {
        let server = try HandshakeCutoffServer.start()
        let failureCode = HandshakeFailureCodeRecorder()

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await HandshakeFailureObservation.$observer.withValue(
                failureCode.record
            ) {
                try await SSHConnection.connect(
                    to: SSHEndpoint(host: "127.0.0.1", port: server.port),
                    timeout: .seconds(5))
            }
        }
        #expect(failureCode.value == LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE)
        try await server.waitForCompletion()
    }
}

private final class HandshakeFailureCodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32?

    func record(_ code: Int32) {
        lock.withLock { storedValue = code }
    }

    var value: Int32? {
        lock.withLock { storedValue }
    }
}

/// A minimal loopback SSH peer that selects production-supported algorithms,
/// observes the client's key-exchange request, then closes before replying.
/// It intentionally implements no authentication or session behavior.
private struct HandshakeCutoffServer: Sendable {
    let port: UInt16
    private let task: Task<Void, any Error>

    static func start() throws -> HandshakeCutoffServer {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HandshakeCutoffServerError.socketFailed }

        do {
            var reuse: Int32 = 1
            guard setsockopt(
                listener,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout<Int32>.size)) == 0
            else { throw HandshakeCutoffServerError.socketFailed }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                throw HandshakeCutoffServerError.socketFailed
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                throw HandshakeCutoffServerError.socketFailed
            }

            var localAddress = sockaddr_in()
            var localAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listener, $0, &localAddressLength)
                }
            }
            guard named == 0 else { throw HandshakeCutoffServerError.socketFailed }
            let port = UInt16(bigEndian: localAddress.sin_port)

            let task = Task { try await serve(listener: listener) }
            return HandshakeCutoffServer(port: port, task: task)
        } catch {
            Darwin.close(listener)
            throw error
        }
    }

    func waitForCompletion() async throws {
        try await task.value
    }

    private static let queue = DispatchQueue(label: "heelerssh.handshake-cutoff-server")

    private static func serve(listener: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try serveBlocking(listener: listener) })
            }
        }
    }

    private static func serveBlocking(listener: Int32) throws {
        var ownsListener = true
        defer {
            if ownsListener { Darwin.close(listener) }
        }

        var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, 5_000) == 1 else {
            throw HandshakeCutoffServerError.acceptFailed
        }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else {
            throw HandshakeCutoffServerError.acceptFailed
        }
        Darwin.close(listener)
        ownsListener = false
        defer { Darwin.close(connection) }

        // Bound the blocking calls so a failed peer cannot strand the queue or
        // leave the checked continuation un-resumed.
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        let limitSize = socklen_t(MemoryLayout<timeval>.size)
        guard
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, limitSize) == 0,
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &limit, limitSize) == 0
        else { throw HandshakeCutoffServerError.socketFailed }

        try writeAll(Data("SSH-2.0-HeelerHandshakeCutoff\r\n".utf8), to: connection)
        try readIdentification(from: connection)
        _ = try readPacket(from: connection)
        try writeAll(kexInitPacket(), to: connection)
        _ = try readPacket(from: connection)
    }

    private static func readIdentification(from descriptor: Int32) throws {
        var byte: UInt8 = 0
        var bytesRead = 0
        while bytesRead < 255 {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { throw HandshakeCutoffServerError.readFailed }
            bytesRead += 1
            if byte == UInt8(ascii: "\n") { return }
        }
        throw HandshakeCutoffServerError.invalidIdentification
    }

    private static func readPacket(from descriptor: Int32) throws -> Data {
        let header = try readExactly(4, from: descriptor)
        let packetLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard packetLength >= 5, packetLength <= 64 * 1024 else {
            throw HandshakeCutoffServerError.invalidPacket
        }
        return try readExactly(Int(packetLength), from: descriptor)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < count {
                let read = Darwin.read(descriptor, base + offset, count - offset)
                guard read > 0 else { throw HandshakeCutoffServerError.readFailed }
                offset += read
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < bytes.count {
                let written = Darwin.send(
                    descriptor,
                    base + offset,
                    bytes.count - offset,
                    MSG_NOSIGNAL)
                guard written > 0 else { throw HandshakeCutoffServerError.writeFailed }
                offset += written
            }
        }
    }

    private static func kexInitPacket() -> Data {
        var payload = Data([20])
        payload.append(Data(repeating: 0xA5, count: 16))
        appendNameList("curve25519-sha256", to: &payload)
        appendNameList("ssh-ed25519", to: &payload)
        appendNameList("aes128-ctr", to: &payload)
        appendNameList("aes128-ctr", to: &payload)
        appendNameList("hmac-sha2-256", to: &payload)
        appendNameList("hmac-sha2-256", to: &payload)
        appendNameList("none", to: &payload)
        appendNameList("none", to: &payload)
        appendNameList("", to: &payload)
        appendNameList("", to: &payload)
        payload.append(0)
        appendUInt32(0, to: &payload)

        var paddingLength = 8 - ((5 + payload.count) % 8)
        if paddingLength < 4 { paddingLength += 8 }
        let packetLength = UInt32(1 + payload.count + paddingLength)
        var packet = Data()
        appendUInt32(packetLength, to: &packet)
        packet.append(UInt8(paddingLength))
        packet.append(payload)
        packet.append(Data(repeating: 0x5A, count: paddingLength))
        return packet
    }

    private static func appendNameList(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private enum HandshakeCutoffServerError: Error {
    case acceptFailed
    case invalidIdentification
    case invalidPacket
    case readFailed
    case socketFailed
    case writeFailed
}
