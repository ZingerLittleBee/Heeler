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
                    var one: Int32 = 1
                    _ = setsockopt(
                        descriptor,
                        IPPROTO_TCP,
                        TCP_NODELAY,
                        &one,
                        socklen_t(MemoryLayout<Int32>.size))
                    _ = setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &one,
                        socklen_t(MemoryLayout<Int32>.size))
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

    /// RFC 8305 Happy Eyeballs stagger between candidate addresses so a
    /// blackholed first address (e.g. unreachable IPv6) falls back to IPv4 in
    /// 250 ms instead of spending half the overall connect deadline waiting.
    static let happyEyeballsStagger: Duration = .milliseconds(250)

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        operations: Operations,
        stagger: Duration = happyEyeballsStagger
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline, now: operations.now())
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        guard !addresses.isEmpty else { throw SSHError.connectionFailed }
        if addresses.count == 1 {
            return try await connect(
                to: addresses[0],
                until: deadline,
                operations: operations)
        }
        return try await connectHappyEyeballs(
            addresses: addresses,
            until: deadline,
            operations: operations,
            stagger: stagger)
    }

    private enum RaceOutcome: Sendable {
        case won(Int32)
        case failed(SSHError)
        case cancelled
    }

    private actor HappyEyeballsCoordinator {
        private let addresses: [SocketAddress]
        private let deadline: ContinuousClock.Instant
        private let operations: Operations
        private let stagger: Duration
        private var nextIndex = 0
        private var inFlightCount = 0
        private var failureCount = 0
        private var lastError: SSHError = .connectionFailed
        private var isDecided = false
        private var tasks: [Task<Void, Never>] = []
        private var staggerTask: Task<Void, Never>?
        private var continuation: CheckedContinuation<RaceOutcome, Never>?

        init(
            addresses: [SocketAddress],
            deadline: ContinuousClock.Instant,
            operations: Operations,
            stagger: Duration
        ) {
            self.addresses = addresses
            self.deadline = deadline
            self.operations = operations
            self.stagger = stagger
        }

        func start(_ continuation: CheckedContinuation<RaceOutcome, Never>) {
            guard !isDecided else {
                continuation.resume(returning: .cancelled)
                return
            }
            self.continuation = continuation
            launchNext()
            scheduleStaggerIfNeeded()
        }

        func cancel() {
            decide(.cancelled)
        }

        private func launchNext() {
            guard !isDecided, nextIndex < addresses.count else { return }
            let address = addresses[nextIndex]
            nextIndex += 1
            inFlightCount += 1
            let deadline = deadline
            let operations = operations
            tasks.append(Task {
                do {
                    let fd = try await SocketConnector.connect(
                        to: address,
                        until: deadline,
                        operations: operations)
                    if !self.won(fd) {
                        operations.closeSocket(fd)
                    }
                } catch let error as SSHError {
                    self.failed(error)
                } catch {
                    self.failed(.connectionFailed)
                }
            })
        }

        private func scheduleStaggerIfNeeded() {
            staggerTask?.cancel()
            staggerTask = nil
            guard !isDecided, nextIndex < addresses.count else { return }
            let stagger = stagger
            staggerTask = Task {
                if stagger > .zero {
                    do { try await Task.sleep(for: stagger) } catch { return }
                }
                guard !Task.isCancelled else { return }
                self.staggerFired()
            }
        }

        private func staggerFired() {
            staggerTask = nil
            guard !isDecided, nextIndex < addresses.count else { return }
            launchNext()
            scheduleStaggerIfNeeded()
        }

        private func won(_ fd: Int32) -> Bool {
            guard !isDecided else { return false }
            decide(.won(fd))
            return true
        }

        private func failed(_ error: SSHError) {
            guard !isDecided else { return }
            inFlightCount -= 1
            failureCount += 1
            lastError = error
            if failureCount == addresses.count {
                decide(.failed(lastError))
            } else if inFlightCount == 0, nextIndex < addresses.count {
                // Every active candidate failed fast (e.g. ECONNREFUSED); start
                // the next address immediately instead of waiting out stagger.
                launchNext()
                scheduleStaggerIfNeeded()
            }
        }

        private func decide(_ outcome: RaceOutcome) {
            guard !isDecided else { return }
            isDecided = true
            staggerTask?.cancel()
            staggerTask = nil
            for task in tasks { task.cancel() }
            tasks.removeAll()
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private static func connectHappyEyeballs(
        addresses: [SocketAddress],
        until deadline: ContinuousClock.Instant,
        operations: Operations,
        stagger: Duration
    ) async throws -> Int32 {
        let coordinator = HappyEyeballsCoordinator(
            addresses: addresses,
            deadline: deadline,
            operations: operations,
            stagger: stagger)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await coordinator.start(continuation) }
            }
        } onCancel: {
            Task { await coordinator.cancel() }
        }
        switch outcome {
        case .won(let fd):
            return fd
        case .failed(let error):
            throw error
        case .cancelled:
            throw SSHError.cancelled
        }
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
