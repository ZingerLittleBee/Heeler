import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Explicit opt-in only: a `RexHostSession` against a Rex server that already
/// runs on this Mac, over its local Unix socket. It never runs in the
/// HeelerTests target or in CI, and fails rather than skips when selected
/// without its configuration.
///
/// The session connects, attaches to every session, reads the inventory and
/// each terminal's title and process, then leaves with a close frame. It
/// creates nothing and changes nothing on the server: it only reads. It
/// prints counts only, never labels, titles, programs or directories.
///
/// Give the socket path that `rex server status` prints on its endpoint line
/// to the Simulator's launchd environment, run the suite, then unset it:
///
/// ```sh
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexInventoryLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@Suite("Rex inventory over a local socket", .serialized, .timeLimit(.minutes(1)))
struct RexInventoryLiveTests {
    @Test func aSessionReadsTheLocalServersTerminals() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let session = RexHostSession(storedSocket: RexSocket(path: socketPath)) { _, previous in
            try await LocalRexTransport.connect(path: socketPath, resuming: previous)
        }

        await session.resume()
        var inventory: RexInventory?
        var statuses: [EventsSessionStatus] = []
        let deadline = ContinuousClock.now + .seconds(20)
        for await update in session.updates {
            switch update {
            case .status(let status):
                statuses.append(status)
                if case .failed(let failure) = status { Issue.record("The session failed: \(failure)") }
            case .server:
                break
            case .inventory(let next):
                inventory = next
            }
            // The second inventory carries the terminals' details; a server
            // whose terminals all read empty may send only one.
            let withDetails = inventory?.sessions.flatMap(\.terminals).contains {
                $0.details.program != nil || $0.details.title != nil
            }
            if withDetails == true || ContinuousClock.now > deadline || statuses.last.map(Self.isFailure) == true {
                break
            }
        }
        await session.end()

        let read = try #require(inventory, "No inventory arrived")
        let terminals = read.sessions.flatMap(\.terminals)
        let windows = read.sessions.reduce(0) { $0 + $1.windows.count }
        let detached = read.sessions.reduce(0) { $0 + $1.detached.count }
        let titled = terminals.count(where: { $0.details.title != nil })
        let withProgram = terminals.count(where: { $0.details.program != nil })
        let withDirectory = terminals.count(where: { $0.details.directory != nil })
        print(
            "Rex inventory: \(read.sessions.count) sessions, \(windows) windows, \(terminals.count) terminals "
                + "(\(detached) detached); \(titled) titled, \(withProgram) with a program, "
                + "\(withDirectory) with a directory")
        #expect(read.sessions.contains { !$0.terminals.isEmpty })
        #expect(statuses.prefix(2) == [.connecting, .connected])
    }

    private static func isFailure(_ status: EventsSessionStatus) -> Bool {
        if case .failed = status { true } else { false }
    }
}

/// A Rex Host's transport over the local socket, in place of SSH: the control
/// link and each data link open on a Unix socket channel of their own.
actor LocalRexTransport: RexTransport {
    nonisolated let routeID: UUID? = nil
    nonisolated let socket: RexSocket
    nonisolated let foundSocket: RexSocket? = nil
    private let path: String
    private(set) var control: RexControlLink
    private var closed = false

    private init(path: String, socket: RexSocket, control: RexControlLink) {
        self.path = path
        self.socket = socket
        self.control = control
    }

    static func connect(path: String, resuming previous: RexControlLink?) async throws -> LocalRexTransport {
        guard let socket = RexSocket(path: path) else {
            throw TransportError.rexLookupFailed(reason: "The socket path does not read.")
        }
        let control = try await RexControlLink.open(over: try UnixDomainSocketChannel(path: path), resuming: previous)
        return LocalRexTransport(path: path, socket: socket, control: control)
    }

    var isConnected: Bool { !closed }

    func reconnectControl(resuming: Bool) async throws -> RexControlLink {
        let previous = control
        if resuming {
            await previous.disconnect()
        } else {
            await previous.close()
        }
        control = try await RexControlLink.open(
            over: try UnixDomainSocketChannel(path: path), resuming: resuming ? previous : nil)
        return control
    }

    func openDataChannel() async throws -> any HeelerSSHAPIChannel {
        try UnixDomainSocketChannel(path: path)
    }

    func close() async {
        closed = true
        await control.close()
    }
}
