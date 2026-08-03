import Darwin
import Dispatch
import Foundation

enum SocketConnector {
    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: DNSServiceAddressResolver(),
            makeSocket: { socket($0, $1, $2) })
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline)
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        var lastError: SSHError = .connectionFailed
        for address in addresses {
            do {
                try checkProgress(until: deadline)
                return try await connect(
                    to: address,
                    until: deadline,
                    makeSocket: makeSocket)
            } catch let error as SSHError {
                if error == .cancelled || error == .timedOut {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        let descriptor = makeSocket(address.family, address.type, address.protocol)
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

    private static func checkProgress(
        until deadline: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
