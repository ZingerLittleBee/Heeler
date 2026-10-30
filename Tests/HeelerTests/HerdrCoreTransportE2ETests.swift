import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// The framed transport against a real core. The app never starts a core, so
/// each test starts its own through the fixture's explicit, isolated start.
@Suite("herdr-core real SSH", .enabled(if: RealSSHFixture.gate(CoreSSHFixture.isConfigured),
    "requires scripts/fixtures/herdr-core-ssh.py"), .serialized)
struct HerdrCoreTransportE2ETests {
    @Test("connecting never starts a core: unused, stopped and killed cores read not running")
    func neverStartsACoreAndReadsNotRunning() async throws {
        try await CoreSSHFixture.with { fixture in
            let processes = try await fixture.coreProcesses()

            // A session nobody has used.
            let unused = try await fixture.helloFailure()
            guard case TransportError.herdrCoreNotRunning(let socket, false) = unused else {
                Issue.record("An unused session read \(unused)")
                return
            }
            #expect(socket.hasSuffix("/\(fixture.session).sock"))
            #expect(try await !fixture.exists(fixture.lockPath))
            #expect(try await !fixture.exists(socket))
            #expect(try await fixture.coreProcesses() == processes)

            // A stale lock after `server stop`.
            try await fixture.startCore()
            try await fixture.stopCore()
            #expect(try await fixture.exists(fixture.lockPath))
            #expect(try await !fixture.exists(socket))
            #expect(try await fixture.helloFailure()
                == .herdrCoreNotRunning(socketPath: socket, socketFilePresent: false))
            #expect(try await fixture.coreProcesses() == processes)

            // A socket left behind by a core with no Terminals killed by SIGKILL.
            try await fixture.startCore()
            let status = try await fixture.rpc("server.status")
            let pid = try #require(HerdrCoreWire.integer(status["pid"]))
            try await fixture.kill(pid: pid)
            try await eventually { try await !fixture.isRunning(pid: pid) }
            #expect(try await fixture.exists(socket))
            #expect(try await fixture.helloFailure()
                == .herdrCoreNotRunning(socketPath: socket, socketFilePresent: true))
            #expect(try await fixture.coreProcesses() == processes)
        }
    }

    @Test("a framed hello reports the features and core id, and hc is never called")
    func helloFeaturesCoreIDAndNoHC() async throws {
        try await CoreSSHFixture.with { fixture in
            try await fixture.startCore()
            let viaHelper = try await fixture.rpc("server.status")
            let transport = try await fixture.connectCore()
            do {
                // The exec's PATH leaves out `~/.local/bin`, as many Hosts' do.
                let location = try await transport.locate()
                #expect(location.executablePath == fixture.configuration.coreExecutable)
                #expect(location.version == "0.1.13")
                #expect(location.socketSource == .lock)
                #expect(location.socketFilePresent)
                #expect(location.fitsSocketPathLimit)

                let info = try await transport.hello()
                #expect(info.generation == 1)
                #expect(info.version == location.version)
                #expect(HerdrCoreServerInfo.requiredFeatures.isSubset(of: info.features))
                #expect(info.coreID == viaHelper["core"]?["id"]?.stringValue)

                let status = try await transport.serverStatus()
                #expect(status.coreID == info.coreID)
                #expect(status.pid == HerdrCoreWire.integer(viaHelper["pid"]))
                #expect(status.live == 0)
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
            #expect(try await fixture.tripwireCalls().isEmpty)
        }
    }

    @Test("no outcome falls back to the legacy herdr on the same machine")
    func noLegacyFallback() async throws {
        try await CoreSSHFixture.with { fixture in
            // The session name hc refuses goes nowhere, not to another backend.
            let refused = try await SSHTransportConnector().connectCore(
                settings: fixture.settings(session: "../invalid-session"))
            do {
                _ = try await refused.hello()
                Issue.record("A session name hc refuses reached the Host")
            } catch TransportError.hostFeatureUnavailable {}
            try await refused.close()

            // Nor does a core that is not running, or not there at all.
            guard case TransportError.herdrCoreNotRunning = try await fixture.helloFailure() else {
                Issue.record("A stopped core must read not running")
                return
            }
            try await fixture.hidingCoreExecutable { () async throws in
                #expect(try await fixture.helloFailure() == .herdrCoreNotInstalled)
            }

            // The app's Herdr TUI transport refuses this Host outright.
            await #expect(throws: TransportError.self) {
                _ = try await SSHTransportConnector().connect(settings: fixture.settings())
            }
            #expect(try await !fixture.exists(fixture.configuration.legacyLog))
            #expect(try await fixture.tripwireCalls().isEmpty)
        }
    }
}

private enum CoreSSHFailure: Error { case timeout, fixture(String) }

private func eventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CoreSSHFailure.timeout
}

private struct CoreSSHFixture: Sendable {
    struct Configuration: Decodable, Sendable {
        let coreFixture: Bool
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let homePath: String
        let coreExecutable: String
        let startEnvironment: [String: String]
        let rpcHelper: String
        let tripwireLog: String
        let legacyLog: String
    }

    static var isConfigured: Bool {
        guard let raw = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: raw),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["coreFixture"] as? Bool == true
    }

    let configuration: Configuration
    let connection: SSHConnection
    /// Nine characters: the fixture root's path budget counts on it.
    let session = "h" + UUID().uuidString.prefix(8).lowercased()

    var lockPath: String { "\(configuration.homePath)/.local/state/herdr-core/\(session)/core.lock" }

    static func with(_ body: (CoreSSHFixture) async throws -> Void) async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"])
        let data = try #require(Data(base64Encoded: raw))
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: config.host, port: config.port), timeout: RealSSHFixture.setupTimeout)
        let key = DeviceKey(privateKey: try RealSSHFixture.deviceKey(seed: config.deviceKeySeed))
        try await connection.authenticate(
            username: config.username, publicKey: key.publicKeyBlob,
            signer: { try key.privateKey.signature(for: $0) }, timeout: RealSSHFixture.setupTimeout)
        let fixture = CoreSSHFixture(configuration: config, connection: connection)
        do {
            try await body(fixture)
            try await fixture.stopCore()
            try await connection.close(timeout: .seconds(3))
        } catch {
            try? await fixture.stopCore()
            try? await connection.close(timeout: .seconds(3))
            throw error
        }
    }

    func settings(session: String? = nil) throws -> SSHTransportSettings {
        var result = SSHTransportSettings(
            host: configuration.host, port: Int(configuration.port), username: configuration.username,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)
        result.serverKind = .herdrCore
        result.coreSessionName = session ?? self.session
        return result
    }

    func connectCore() async throws -> any HerdrCoreTransport {
        try await SSHTransportConnector().connectCore(settings: settings())
    }

    /// What the app reads for this session, over its own SSH connection.
    func helloFailure() async throws -> TransportError {
        let transport = try await connectCore()
        do {
            let info = try await transport.hello()
            try? await transport.close()
            throw CoreSSHFailure.fixture("hello unexpectedly reached core \(info.coreID)")
        } catch let error as TransportError {
            try await transport.close()
            return error
        }
    }

    // MARK: The core's side, never through `hc`

    private func run(_ command: String) async throws -> SSHExecResult {
        try await connection.execute(command, timeout: .seconds(20))
    }

    private func require(_ command: String) async throws -> Data {
        let response = try await run(command)
        guard response.exitStatus == 0 else {
            throw CoreSSHFailure.fixture("\(command): \(String(decoding: response.stderr, as: UTF8.self))")
        }
        return response.stdout
    }

    /// The explicit isolated start's command line: no rc file, no inherited
    /// environment, the program by its absolute path.
    private func coreCommand(_ words: [String]) -> String {
        let environment = configuration.startEnvironment.merging(["HC_SESSION": session]) { $1 }
            .sorted { $0.key < $1.key }
            .map { GitProbe.singleQuoted("\($0.key)=\($0.value)") }
        return (["env", "-i"] + environment + [GitProbe.singleQuoted(configuration.coreExecutable)]
            + words.map(GitProbe.singleQuoted)).joined(separator: " ") + " </dev/null >/dev/null 2>&1"
    }

    func startCore() async throws {
        _ = try await require(coreCommand(["server", "start"]))
        try await eventually {
            HerdrCoreWire.integer((try? await rpc("server.status"))?["pid"]) != nil
        }
    }

    /// `server stop` is the one subcommand that cannot start a core.
    func stopCore() async throws {
        _ = try await require(coreCommand(["server", "stop"]))
    }

    func rpc(_ method: String) async throws -> JSONValue {
        let stdout = try await require(
            [configuration.rpcHelper, "--session", session, method].map(GitProbe.singleQuoted)
                .joined(separator: " "))
        return try JSONDecoder().decode(JSONValue.self, from: stdout)
    }

    func exists(_ path: String) async throws -> Bool {
        try await run("test -e " + GitProbe.singleQuoted(path)).exitStatus == 0
    }

    func kill(pid: Int) async throws {
        _ = try await require("kill -KILL \(pid)")
    }

    func isRunning(pid: Int) async throws -> Bool {
        try await run("ps -p \(pid) -o pid=").exitStatus == 0
    }

    /// Every process running the fixture's core, which holders run too.
    func coreProcesses() async throws -> Set<Int> {
        let listing = String(decoding: try await require("ps -axo pid=,command="), as: UTF8.self)
        return Set(listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix(configuration.coreExecutable + " ") else { return nil }
            return Int(fields[0])
        })
    }

    func tripwireCalls() async throws -> String {
        let response = try await run("cat " + GitProbe.singleQuoted(configuration.tripwireLog))
        return String(decoding: response.stdout, as: UTF8.self)
    }

    func hidingCoreExecutable(_ body: () async throws -> Void) async throws {
        let program = GitProbe.singleQuoted(configuration.coreExecutable)
        let aside = GitProbe.singleQuoted(configuration.coreExecutable + ".aside")
        _ = try await require("mv \(program) \(aside)")
        do {
            try await body()
            _ = try await require("mv \(aside) \(program)")
        } catch {
            _ = try? await require("mv \(aside) \(program)")
            throw error
        }
    }
}
