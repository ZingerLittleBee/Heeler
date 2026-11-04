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
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            "Heeler may not use the local network. Turn on Local Network for Heeler in Settings."
        case .noAddress:
            "The machine did not give an IP address. Type its address instead."
        case .timedOut:
            "The machine did not answer. Check that it is on and on this network."
        case .failed(let detail):
            "Could not search the local network: \(detail)"
        }
    }
}

/// The seam between the picker and the Network framework.
protocol LocalServiceBrowsing: Sendable {
    /// The machines found so far, sent again whenever the set changes.
    /// Ends with an error when the search cannot run.
    func machines() -> AsyncThrowingStream<[DiscoveredMachine], Error>
    /// Finds the numeric address and port of `machine`.
    func resolve(_ machine: DiscoveredMachine) async throws -> ResolvedMachine
}

/// Turns a resolved endpoint host into the address a Route saves.
enum DiscoveredAddress {
    /// An IPv4 address as is. An IPv6 address without its `%scope` suffix,
    /// except link-local (`fe80::/10`), which only works with its scope, so
    /// it keeps the suffix. A name (such as `box.local`) gives `nil`: the
    /// name would need mDNS on every later connection.
    static func string(for host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init)
        case .ipv6(let address):
            let text = "\(address)"
            let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
            return isLinkLocal(bare) ? text : bare
        case .name:
            return nil
        @unknown default:
            return nil
        }
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

    func machines() -> AsyncThrowingStream<[DiscoveredMachine], Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                let machines = results.compactMap { result -> DiscoveredMachine? in
                    guard case .service(let name, let type, let domain, _) = result.endpoint
                    else { return nil }
                    return DiscoveredMachine(name: name, type: type, domain: domain)
                }
                continuation.yield(machines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error), .waiting(let error):
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
        // IPv4 first, so the saved address is IPv4 when the machine has one.
        do {
            return try await Self.connect(
                endpoint, name: machine.name, version: .v4, timeout: .seconds(2))
        } catch LocalDiscoveryError.permissionDenied {
            throw LocalDiscoveryError.permissionDenied
        } catch {
            return try await Self.connect(
                endpoint, name: machine.name, version: nil, timeout: Self.resolveTimeout)
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
        return try await withThrowingTaskGroup(of: ResolvedMachine.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await Self.waitUntilReady(connection, name: name)
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LocalDiscoveryError.timedOut
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
        _ connection: NWConnection, name: String
    ) async throws -> ResolvedMachine {
        try await withCheckedThrowingContinuation { continuation in
            // `stateUpdateHandler` can fire more than once; resume only once.
            let gate = ResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                          let address = DiscoveredAddress.string(for: host)
                    else {
                        continuation.resume(throwing: LocalDiscoveryError.noAddress)
                        return
                    }
                    continuation.resume(
                        returning: ResolvedMachine(
                            name: name, address: address, port: Int(port.rawValue)))
                case .failed(let error), .waiting(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: Self.map(error))
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// `kDNSServiceErr_PolicyDenied`, which Local Network denial reports.
    private static let policyDenied: Int32 = -65_570

    private static func map(_ error: NWError) -> LocalDiscoveryError {
        if case .dns(let code) = error, code == policyDenied {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// State of the "Find on Local Network" sheet.
@MainActor
@Observable
final class LocalMachinePickerModel {
    private(set) var machines: [DiscoveredMachine] = []
    /// False once the search has failed.
    private(set) var isSearching = false
    private(set) var searchError: LocalDiscoveryError?
    /// The row being resolved.
    private(set) var resolvingID: String?
    private(set) var resolveError: LocalDiscoveryError?

    private let browser: any LocalServiceBrowsing
    private var searchTask: Task<Void, Never>?

    init(browser: any LocalServiceBrowsing = BonjourServiceBrowser()) {
        self.browser = browser
    }

    func start() {
        guard searchTask == nil else { return }
        isSearching = true
        searchError = nil
        searchTask = Task { [browser] in
            do {
                for try await found in browser.machines() {
                    machines = found
                }
            } catch let error as LocalDiscoveryError {
                searchError = error
            } catch {
                searchError = .failed(error.localizedDescription)
            }
            isSearching = false
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    /// Resolves `machine`; `nil` after setting `resolveError` on failure.
    func resolve(_ machine: DiscoveredMachine) async -> ResolvedMachine? {
        guard resolvingID == nil else { return nil }
        resolvingID = machine.id
        resolveError = nil
        defer { resolvingID = nil }
        do {
            return try await browser.resolve(machine)
        } catch let error as LocalDiscoveryError {
            resolveError = error
        } catch is CancellationError {
        } catch {
            resolveError = .failed(error.localizedDescription)
        }
        return nil
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
