import Darwin
import Dispatch
import Foundation
import dnssd

protocol SocketAddressResolving: Sendable {
    func resolve(
        _ endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> [SocketAddress]
}

struct DNSServiceAddressResolver: SocketAddressResolving {
    private let functions: DNSServiceFunctions

    init(functions: DNSServiceFunctions = .live) {
        self.functions = functions
    }

    func resolve(
        _ endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> [SocketAddress] {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
        if let numericAddress = SocketAddress.numeric(
            host: endpoint.host,
            port: endpoint.port)
        {
            return [numericAddress]
        }

        let query = DNSServiceQuery(functions: functions)
        return try await query.resolve(
            host: endpoint.host,
            port: endpoint.port,
            until: deadline)
    }
}

struct DNSServiceFunctions: @unchecked Sendable {
    typealias Start = @Sendable (
        UnsafeMutablePointer<DNSServiceRef?>,
        String,
        DNSServiceGetAddrInfoReply?,
        UnsafeMutableRawPointer?
    ) -> DNSServiceErrorType
    typealias Schedule = @Sendable (
        DNSServiceRef,
        DispatchQueue
    ) -> DNSServiceErrorType
    typealias Deallocate = @Sendable (DNSServiceRef) -> Void

    let start: Start
    let schedule: Schedule
    let deallocate: Deallocate

    static let live = DNSServiceFunctions(
        start: { reference, hostname, callback, context in
            hostname.withCString {
                DNSServiceGetAddrInfo(
                    reference,
                    0,
                    UInt32(kDNSServiceInterfaceIndexAny),
                    0,
                    $0,
                    callback,
                    context)
            }
        },
        schedule: { DNSServiceSetDispatchQueue($0, $1) },
        deallocate: { DNSServiceRefDeallocate($0) })
}

final class DNSServiceQuery: @unchecked Sendable {
    private let functions: DNSServiceFunctions
    private let queue = DispatchQueue(
        label: "dev.bybee.heeler.ssh.dns-resolution",
        qos: .userInitiated)

    private var reference: DNSServiceRef?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<[SocketAddress], any Error>?
    private var result: Result<[SocketAddress], any Error>?
    private var addresses: [SocketAddress] = []
    private var callbackContext: UnsafeMutableRawPointer?
    private var port: UInt16 = 0

    init(functions: DNSServiceFunctions) {
        self.functions = functions
    }

    func resolve(
        host: String,
        port: UInt16,
        until deadline: ContinuousClock.Instant
    ) async throws -> [SocketAddress] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    begin(
                        host: host,
                        port: port,
                        deadline: deadline,
                        continuation: continuation)
                }
            }
        } onCancel: {
            queue.async { [self] in
                finish(.failure(SSHError.cancelled))
            }
        }
    }

    private func begin(
        host: String,
        port: UInt16,
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<[SocketAddress], any Error>
    ) {
        precondition(self.continuation == nil)
        self.continuation = continuation
        if let result {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }
        guard ContinuousClock.now < deadline else {
            finish(.failure(SSHError.timedOut))
            return
        }

        self.port = port
        let callbackContext = Unmanaged.passRetained(self).toOpaque()
        self.callbackContext = callbackContext
        var reference: DNSServiceRef?
        let startResult = functions.start(
            &reference,
            host,
            dnsServiceAddressCallback,
            callbackContext)
        guard startResult == kDNSServiceErr_NoError, let reference else {
            if let reference { functions.deallocate(reference) }
            releaseCallbackContext()
            finish(.failure(SSHError.connectionFailed))
            return
        }
        self.reference = reference

        let scheduleResult = functions.schedule(reference, queue)
        guard scheduleResult == kDNSServiceErr_NoError else {
            finish(.failure(SSHError.connectionFailed))
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + dispatchInterval(until: deadline))
        timer.setEventHandler { [self] in
            finish(.failure(SSHError.timedOut))
        }
        self.timer = timer
        timer.activate()
    }

    fileprivate func receive(
        flags: DNSServiceFlags,
        error: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        guard result == nil else { return }
        guard error == kDNSServiceErr_NoError else {
            finish(.failure(
                error == kDNSServiceErr_Timeout
                    ? SSHError.timedOut
                    : SSHError.connectionFailed))
            return
        }
        if let address, let socketAddress = SocketAddress(address, port: port) {
            addresses.append(socketAddress)
        }
        guard flags & kDNSServiceFlagsMoreComing == 0 else { return }
        guard !addresses.isEmpty else {
            finish(.failure(SSHError.connectionFailed))
            return
        }
        finish(.success(addresses))
    }

    private func finish(_ result: Result<[SocketAddress], any Error>) {
        guard self.result == nil else { return }
        self.result = result

        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let reference {
            functions.deallocate(reference)
            self.reference = nil
        }
        releaseCallbackContext()

        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func releaseCallbackContext() {
        guard let callbackContext else { return }
        self.callbackContext = nil
        Unmanaged<DNSServiceQuery>.fromOpaque(callbackContext).release()
    }

    private func dispatchInterval(
        until deadline: ContinuousClock.Instant
    ) -> DispatchTimeInterval {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return .nanoseconds(0) }
        let components = remaining.components
        let seconds = max(components.seconds, 0)
        let nanosFromAttoseconds = max(components.attoseconds, 0) / 1_000_000_000
        let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return .seconds(Int.max) }
        let total = nanoseconds.partialValue.addingReportingOverflow(nanosFromAttoseconds)
        guard !total.overflow, total.partialValue <= Int64(Int.max) else {
            return .seconds(Int.max)
        }
        return .nanoseconds(Int(total.partialValue))
    }
}

private let dnsServiceAddressCallback: DNSServiceGetAddrInfoReply = {
    _, flags, _, error, _, address, _, context in
    guard let context else { return }
    Unmanaged<DNSServiceQuery>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(flags: flags, error: error, address: address)
}

private extension SocketAddress {
    init?(_ address: UnsafePointer<sockaddr>, port: UInt16) {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
            value.sin_port = port.bigEndian
            self.init(
                family: AF_INET,
                type: SOCK_STREAM,
                protocol: IPPROTO_TCP,
                bytes: Data(bytes: &value, count: MemoryLayout<sockaddr_in>.size))
        case AF_INET6:
            var value = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee
            value.sin6_port = port.bigEndian
            self.init(
                family: AF_INET6,
                type: SOCK_STREAM,
                protocol: IPPROTO_TCP,
                bytes: Data(bytes: &value, count: MemoryLayout<sockaddr_in6>.size))
        default:
            return nil
        }
    }

    static func numeric(host: String, port: UInt16) -> SocketAddress? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = ipv4
            return SocketAddress(
                family: AF_INET,
                type: SOCK_STREAM,
                protocol: IPPROTO_TCP,
                bytes: Data(bytes: &address, count: MemoryLayout<sockaddr_in>.size))
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = ipv6
            return SocketAddress(
                family: AF_INET6,
                type: SOCK_STREAM,
                protocol: IPPROTO_TCP,
                bytes: Data(bytes: &address, count: MemoryLayout<sockaddr_in6>.size))
        }
        return nil
    }
}
