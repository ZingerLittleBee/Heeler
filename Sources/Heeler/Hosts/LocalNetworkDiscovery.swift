import Foundation
import Network
import Observation

/// A machine found on the local network by Bonjour. It names the service,
/// not an address: the address is resolved only when the user picks it.
struct DiscoveredMachine: Identifiable, Hashable, Sendable {
    let name: String
    let type: String
    let domain: String

    var id: String { "\(name)|\(type)|\(domain)" }
}

/// A picked machine, resolved to what a Route stores.
struct ResolvedMachine: Equatable, Sendable {
    /// The machine's service name, for an unnamed Host.
    let name: String
    /// A numeric IP address; never a `.local` name.
    let address: String
    let port: Int
}

enum LocalDiscoveryError: Error, Equatable, Sendable {
    /// The user declined Local Network access.
    case permissionDenied
    /// The machine answered with a name only, which Heeler does not save.
    case noAddress
    /// The only address was link-local IPv6, which the SSH layer cannot dial.
    case linkLocalOnly
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            "Heeler may not use the local network. Turn on Local Network for Heeler in Settings."
        case .noAddress:
            "The machine did not give an IP address. Type its address instead."
        case .linkLocalOnly:
            "This machine only gave a link-local IPv6 address. Enter its IPv4 address by hand."
        case .timedOut:
            "The machine did not answer. Check that it is on and on this network."
        case .failed(let detail):
            "Could not search the local network: \(detail)"
        }
    }
}

enum LocalBrowseUpdate: Equatable, Sendable {
    /// The machines found so far, sent again whenever the set changes.
    case machines([DiscoveredMachine])
    /// The browser cannot search yet. `permissionDenied` is the Local
    /// Network prompt or a denial; the search resumes by itself.
    case waiting(permissionDenied: Bool)
    case ready
}

/// The seam between the picker and the Network framework.
protocol LocalServiceBrowsing: Sendable {
    /// Updates of the search. It ends with an error only when the search
    /// has failed for good; a waiting search (no network, first-run prompt)
    /// is a `.waiting` update and goes on.
    func updates() -> AsyncThrowingStream<LocalBrowseUpdate, Error>
    /// Finds the numeric address and port of `machine`.
    func resolve(_ machine: DiscoveredMachine) async throws -> ResolvedMachine
}

/// Turns a resolved endpoint host into the address a Route saves.
enum DiscoveredAddress {
    /// IPv4 as is; IPv6 without its `%scope`. Link-local IPv6 (`fe80::/10`)
    /// is refused: the SSH layer's numeric address parser cannot carry a
    /// scope, so the Route would not connect. A name (`box.local`) is
    /// refused: it would need mDNS on every later connection.
    static func address(for host: NWEndpoint.Host) -> Result<String, LocalDiscoveryError> {
        switch host {
        case .ipv4(let address):
            return .success(bare("\(address)"))
        case .ipv6(let address):
            let text = bare("\(address)")
            return isLinkLocal(text) ? .failure(.linkLocalOnly) : .success(text)
        case .name:
            return .failure(.noAddress)
        @unknown default:
            return .failure(.noAddress)
        }
    }

    private static func bare(_ text: String) -> String {
        text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    /// `fe80::/10`: first group from fe80 to febf.
    static func isLinkLocal(_ ipv6: String) -> Bool {
        let first = ipv6.lowercased().split(separator: ":", omittingEmptySubsequences: false).first
        guard let first, let group = UInt16(first, radix: 16) else { return false }
        return group & 0xFFC0 == 0xFE80
    }
}

/// Bonjour search for `_ssh._tcp`, using `NWBrowser` and `NWConnection`.
struct BonjourServiceBrowser: LocalServiceBrowsing {
    static let serviceType = "_ssh._tcp"
    /// How long a pick waits for an address.
    static let resolveTimeout: Duration = .seconds(5)

    func updates() -> AsyncThrowingStream<LocalBrowseUpdate, Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                let machines = results.compactMap { result -> DiscoveredMachine? in
                    guard case .service(let name, let type, let domain, _) = result.endpoint
                    else { return nil }
                    return DiscoveredMachine(name: name, type: type, domain: domain)
                }
                let sorted = machines.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                continuation.yield(.machines(sorted))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.ready)
                case .waiting(let error):
                    // Not fatal: the first-run prompt and a missing network
                    // both wait here and recover by themselves.
                    continuation.yield(.waiting(permissionDenied: Self.isDenied(error)))
                case .failed(let error):
                    continuation.finish(throwing: Self.map(error))
                default:
                    break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .main)
        }
    }

    func resolve(_ machine: DiscoveredMachine) async throws -> ResolvedMachine {
        let endpoint = NWEndpoint.service(
            name: machine.name, type: machine.type, domain: machine.domain, interface: nil)
        return try await Self.resolveIPv4First { version in
            try await Self.connect(
                endpoint, name: machine.name, version: version,
                timeout: version == nil ? Self.resolveTimeout : .seconds(2))
        }
    }

    /// IPv4 first, so the saved address is IPv4 when the machine has one;
    /// then any family. Cancellation and a denied permission end it at once.
    static func resolveIPv4First(
        _ attempt: (NWProtocolIP.Options.Version?) async throws -> ResolvedMachine
    ) async throws -> ResolvedMachine {
        do {
            return try await attempt(.v4)
        } catch is CancellationError {
            throw CancellationError()
        } catch LocalDiscoveryError.permissionDenied {
            throw LocalDiscoveryError.permissionDenied
        } catch {
            try Task.checkCancellation()
            return try await attempt(nil)
        }
    }

    private static func connect(
        _ endpoint: NWEndpoint, name: String, version: NWProtocolIP.Options.Version?,
        timeout: Duration
    ) async throws -> ResolvedMachine {
        let parameters = NWParameters.tcp
        if let version,
           let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        {
            ip.version = version
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let gate = ResumeGate()
        return try await withThrowingTaskGroup(of: ResolvedMachine.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await Self.waitUntilReady(connection, name: name, gate: gate)
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Mark the timeout before cancelling, so the connection's
                // own cancel reads as a timeout (which falls back), not as
                // the caller's cancellation.
                let error = gate.markTimedOut()
                connection.cancel()
                throw error
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            guard let first = try await group.next() else { throw LocalDiscoveryError.timedOut }
            return first
        }
    }

    private static func waitUntilReady(
        _ connection: NWConnection, name: String, gate: ResumeGate
    ) async throws -> ResolvedMachine {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already finished (cancelled before this body): resumed
                // by `install`, and the connection is never started.
                guard gate.install(continuation) else { return }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard case .hostPort(let host, let port)? =
                            connection.currentPath?.remoteEndpoint
                        else {
                            gate.resume(.failure(LocalDiscoveryError.noAddress))
                            return
                        }
                        switch DiscoveredAddress.address(for: host) {
                        case .success(let address):
                            gate.resume(
                                .success(
                                    ResolvedMachine(
                                        name: name, address: address, port: Int(port.rawValue))))
                        case .failure(let error):
                            gate.resume(.failure(error))
                        }
                    case .waiting(let error):
                        // Keep waiting until ready or the timeout.
                        if Self.isDenied(error) { gate.noteDenied() }
                    case .failed(let error):
                        gate.resume(.failure(Self.map(error)))
                    case .cancelled:
                        gate.resume(.failure(gate.cancellationError))
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
            connection.cancel()
        }
    }

    /// `kDNSServiceErr_PolicyDenied`, which Local Network denial reports.
    private static let policyDenied: Int32 = -65_570

    private static func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == policyDenied { return true }
        return false
    }

    private static func map(_ error: NWError) -> LocalDiscoveryError {
        isDenied(error) ? .permissionDenied : .failed(error.localizedDescription)
    }
}

/// Resumes the connection's continuation once, whichever of ready, failure,
/// timeout and cancellation comes first, even before the continuation exists.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedMachine, Error>?
    private var pending: Result<ResolvedMachine, Error>?
    private var finished = false
    private var denied = false
    private var timedOut = false

    func noteDenied() {
        lock.lock()
        defer { lock.unlock() }
        denied = true
    }

    /// Records the timeout and returns its error: a denied permission seen
    /// while waiting is the better explanation.
    func markTimedOut() -> LocalDiscoveryError {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
        return denied ? .permissionDenied : .timedOut
    }

    /// What a connection cancel means: a timeout when one was marked,
    /// else the caller's cancellation.
    var cancellationError: Error {
        lock.lock()
        defer { lock.unlock() }
        guard timedOut else { return CancellationError() }
        return denied ? LocalDiscoveryError.permissionDenied : LocalDiscoveryError.timedOut
    }

    /// Stores the continuation; false (after resuming it) when the gate
    /// already finished.
    func install(_ continuation: CheckedContinuation<ResolvedMachine, Error>) -> Bool {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resume(_ result: Result<ResolvedMachine, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// State of the "Find on Local Network" sheet.
@MainActor
@Observable
final class LocalMachinePickerModel {
    private(set) var machines: [DiscoveredMachine] = []
    /// False once the search has failed or stopped.
    private(set) var isSearching = false
    private(set) var searchError: LocalDiscoveryError?
    /// Set while the browser waits (no network, Local Network prompt);
    /// the search goes on and clears it.
    private(set) var waitingHint: LocalDiscoveryError?
    /// The row being resolved.
    private(set) var resolvingID: String?
    private(set) var resolveError: LocalDiscoveryError?

    private let browser: any LocalServiceBrowsing
    private var searchTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    /// Bumped by `stop()`, so a task that outlives it cannot write state.
    private var generation = 0

    init(browser: any LocalServiceBrowsing = BonjourServiceBrowser()) {
        self.browser = browser
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let searchTask { return searchTask }
        generation += 1
        let token = generation
        isSearching = true
        searchError = nil
        let task = Task { [browser] in
            do {
                for try await update in browser.updates() {
                    guard token == generation else { return }
                    apply(update)
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                searchError = (error as? LocalDiscoveryError)
                    ?? .failed(error.localizedDescription)
            }
            guard token == generation else { return }
            isSearching = false
            searchTask = nil
        }
        searchTask = task
        return task
    }

    func apply(_ update: LocalBrowseUpdate) {
        switch update {
        case .machines(let found):
            machines = found
            waitingHint = nil
        case .waiting(let permissionDenied):
            waitingHint = permissionDenied ? .permissionDenied : .failed("waiting for the network")
        case .ready:
            waitingHint = nil
        }
    }

    /// Stops the search and any pick in progress.
    func stop() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        resolveTask?.cancel()
        resolveTask = nil
        resolvingID = nil
        isSearching = false
    }

    /// Search again after a failure.
    func retry() {
        stop()
        machines = []
        waitingHint = nil
        start()
    }

    /// Resolves `machine`, then calls `onPicked` unless `stop()` came first.
    @discardableResult
    func pick(
        _ machine: DiscoveredMachine, onPicked: @escaping @MainActor (ResolvedMachine) -> Void
    ) -> Task<Void, Never>? {
        guard resolvingID == nil else { return nil }
        let token = generation
        resolvingID = machine.id
        resolveError = nil
        let task = Task { [browser] in
            let outcome: Result<ResolvedMachine, Error>
            do {
                outcome = .success(try await browser.resolve(machine))
            } catch {
                outcome = .failure(error)
            }
            guard token == generation, !Task.isCancelled else { return }
            resolvingID = nil
            resolveTask = nil
            switch outcome {
            case .success(let resolved):
                onPicked(resolved)
            case .failure(let error):
                if error is CancellationError { return }
                resolveError = (error as? LocalDiscoveryError)
                    ?? .failed(error.localizedDescription)
            }
        }
        resolveTask = task
        return task
    }
}

extension HostDraft {
    /// Fills route `routeID` with a resolved machine's address and port,
    /// and a blank Host name with the machine's name.
    mutating func applyDiscoveredMachine(
        _ machine: ResolvedMachine, toRoute routeID: HostRouteDraft.ID
    ) {
        guard let index = routes.firstIndex(where: { $0.id == routeID }) else { return }
        routes[index].address = machine.address
        routes[index].port = String(machine.port)
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = machine.name
        }
    }
}
