import Darwin
import Dispatch
import Foundation

enum SocketConnector {
    enum ConnectionState: Sendable {
        case connected
        case inProgress
        case failed
    }

    struct Operations: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let makeSocket: @Sendable (Int32, Int32, Int32) -> Int32
        let setNonBlocking: @Sendable (Int32) -> Bool
        let beginConnection: @Sendable (Int32, SocketAddress) -> ConnectionState
        let waitUntilWritable:
            @Sendable (Int32, ContinuousClock.Instant) async throws -> Void
        let connectionSucceeded: @Sendable (Int32) -> Bool
        let closeSocket: @Sendable (Int32) -> Void

        static func live(
            makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32 = {
                socket($0, $1, $2)
            }
        ) -> Self {
            Operations(
                now: { ContinuousClock.now },
                makeSocket: makeSocket,
                setNonBlocking: { descriptor in
                    let flags = fcntl(descriptor, F_GETFL, 0)
                    return flags >= 0
                        && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
                },
                beginConnection: { descriptor, address in
                    let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return Darwin.connect(
                            descriptor,
                            baseAddress.assumingMemoryBound(to: sockaddr.self),
                            socklen_t(bytes.count))
                    }
                    if result == 0 { return .connected }
                    return errno == EINPROGRESS ? .inProgress : .failed
                },
                waitUntilWritable: { descriptor, deadline in
                    try await SocketReadiness.wait(
                        descriptor: descriptor,
                        directions: .write,
                        until: deadline)
                },
                connectionSucceeded: { descriptor in
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    return getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &length) == 0 && socketError == 0
                },
                closeSocket: { descriptor in
                    _ = Darwin.close(descriptor)
                })
        }
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: DNSServiceAddressResolver(),
            operations: .live())
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: resolver,
            operations: .live(makeSocket: makeSocket))
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        operations: Operations
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline, now: operations.now())
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        var lastError: SSHError = .connectionFailed
        for (index, address) in addresses.enumerated() {
            do {
                let candidateStart = operations.now()
                try checkProgress(until: deadline, now: candidateStart)
                let remainingCandidates = addresses.count - index
                // Split the time still owned by the caller evenly across the
                // candidates that have not yet had a chance to connect.
                let candidateDeadline = min(
                    candidateStart.advanced(
                        by: candidateStart.duration(to: deadline) / remainingCandidates),
                    deadline)
                return try await connect(
                    to: address,
                    until: candidateDeadline,
                    operations: operations)
            } catch let error as SSHError {
                if error == .cancelled { throw error }
                if error == .timedOut {
                    lastError = error
                    try checkProgress(until: deadline, now: operations.now())
                    continue
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant,
        operations: Operations
    ) async throws -> Int32 {
        let descriptor = operations.makeSocket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { operations.closeSocket(descriptor) }
        }

        guard operations.setNonBlocking(descriptor) else {
            throw SSHError.connectionFailed
        }

        switch operations.beginConnection(descriptor, address) {
        case .connected:
            break
        case .inProgress:
            try await operations.waitUntilWritable(descriptor, deadline)
            guard operations.connectionSucceeded(descriptor) else {
                throw SSHError.connectionFailed
            }
        case .failed:
            throw SSHError.connectionFailed
        }

        ownsDescriptor = false
        return descriptor
    }

    private static func checkProgress(
        until deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
