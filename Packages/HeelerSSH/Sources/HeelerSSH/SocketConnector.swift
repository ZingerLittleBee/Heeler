import Darwin
import Dispatch
import Foundation

enum SocketConnector {
    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        let addresses = try await resolve(endpoint)
        var lastError: SSHError = .connectionFailed
        for address in addresses {
            do {
                return try await connect(to: address, until: deadline)
            } catch let error as SSHError {
                if error == .cancelled || error == .timedOut {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func resolve(_ endpoint: SSHEndpoint) async throws -> [SocketAddress] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_flags = AI_ADDRCONFIG
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(
                    endpoint.host,
                    String(endpoint.port),
                    &hints,
                    &result)
                guard status == 0, let first = result else {
                    continuation.resume(throwing: SSHError.connectionFailed)
                    return
                }
                defer { freeaddrinfo(first) }

                var addresses: [SocketAddress] = []
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let info = current?.pointee {
                    if let pointer = info.ai_addr, info.ai_addrlen > 0 {
                        addresses.append(
                            SocketAddress(
                                family: info.ai_family,
                                type: info.ai_socktype,
                                protocol: info.ai_protocol,
                                bytes: Data(
                                    bytes: pointer,
                                    count: Int(info.ai_addrlen))))
                    }
                    current = info.ai_next
                }
                guard !addresses.isEmpty else {
                    continuation.resume(throwing: SSHError.connectionFailed)
                    return
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        let descriptor = socket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHError.connectionFailed
        }

        let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.connect(
                descriptor,
                baseAddress.assumingMemoryBound(to: sockaddr.self),
                socklen_t(bytes.count))
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw SSHError.connectionFailed }
            try await SocketReadiness.wait(
                descriptor: descriptor,
                directions: .write,
                until: deadline)

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                socketError == 0
            else {
                throw SSHError.connectionFailed
            }
        }

        ownsDescriptor = false
        return descriptor
    }
}

private struct SocketAddress: Sendable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
