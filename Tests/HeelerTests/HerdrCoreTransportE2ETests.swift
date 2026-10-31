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

    @Test("a core restarted under one SSH connection resets its event sequence and keeps its id")
    func coreRestartUnderOneConnection() async throws {
        try await CoreSSHFixture.with { fixture in
            try await fixture.startCore()
            // A kept Terminal, so its holder brings the core back; then enough
            // events that a restarted core's count starts below this one's.
            let terminal = try await fixture.runTerminal(["/bin/sleep", "600"], keep: true)
            for index in 0..<40 {
                _ = try await fixture.rpc(
                    "terminal.label",
                    params: .object([
                        "terminal": .string(terminal),
                        "labels": .object(["heeler-e2e": .string("\(index)")]),
                    ]))
            }

            let dials = CoreDialCount()
            let session = HerdrCoreHostSession(
                connect: {
                    dials.add()
                    return try await fixture.connectCore()
                },
                keepalive: nil)
            let watcher = CoreSessionWatcher(session)
            await session.resume()
            do {
                let before = try await watcher.nextSnapshot()
                #expect(before.snapshot.sequence >= 40)
                #expect(before.snapshot.terminals.map(\.address) == [terminal])

                let status = try await fixture.rpc("server.status")
                let pid = try #require(HerdrCoreWire.integer(status["pid"]))
                try await fixture.kill(pid: pid)

                let after = try await watcher.nextSnapshot()
                #expect(after.coreID == before.coreID)
                #expect(after.snapshot.sequence < before.snapshot.sequence)
                #expect(after.snapshot.terminals.map(\.address) == [terminal])
                #expect(dials.value == 1)
                // The Host stayed Connected through it.
                #expect(watcher.statusesSinceLastSnapshot.isEmpty)
                await session.end()
            } catch {
                await session.end()
                throw error
            }
            #expect(try await fixture.tripwireCalls().isEmpty)
        }
    }

    @Test("a recent read of a full-screen program is passive")
    func passiveRecentRead() async throws {
        try await CoreSSHFixture.with { fixture in
            try await fixture.startCore()
            // The alternate screen, then a marker, then a program that waits.
            let terminal = try await fixture.runTerminal(
                ["/bin/sh", "-c", #"printf '\033[?1049hheeler-passive-read\n'; exec cat"#], keep: false)
            let transport = try await fixture.connectCore()
            do {
                _ = try await transport.hello()
                try await eventually {
                    try await transport.readTerminal(terminal).text.contains("heeler-passive-read")
                }
                let first = try await transport.readTerminal(terminal)
                let second = try await transport.readTerminal(terminal)
                #expect(first.how == "screen")
                #expect(second.how == "screen")
                #expect(first.text == second.text)
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
            #expect(try await fixture.tripwireCalls().isEmpty)
        }
    }

    @Test("labels and a seeded herdr-app document place Terminals, and the app never writes it")
    func desktopPlacement() async throws {
        try await CoreSSHFixture.with { fixture in
            try await fixture.startCore()
            try await checkDesktopPlacement(fixture)
            #expect(try await fixture.tripwireCalls().isEmpty)
        }
    }

    @MainActor
    private func checkDesktopPlacement(_ fixture: CoreSSHFixture) async throws {
        let home = fixture.configuration.homePath
        let repository = "\(home)/placement/repo"
        let plain = "\(home)/placement/plain"
        try await fixture.makeCheckout(at: repository, subdirectory: "src")
        try await fixture.makeDirectory(plain)

        let program = ["/bin/sleep", "600"]
        let labeled = try await fixture.runTerminal(program, keep: false)
        let other = try await fixture.runTerminal(program, keep: false)
        let child = try await fixture.runTerminal(
            program, keep: false, cwd: plain, parent: labeled)
        let lonely = try await fixture.runTerminal(program, keep: false, cwd: "\(repository)/src")
        let headless = try await fixture.runTerminal(program, keep: false, cwd: plain)
        try await fixture.label(labeled, space: "s1", tab: "tb1")
        try await fixture.label(other, space: "s2", tab: "tb2")
        try await fixture.label(lonely, space: "lonely", tab: "tb7")
        try await fixture.setDesktopDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space(
                    "s2", name: "Zeta", tabs: [CoreDesktopJSON.tab("tb2", name: "logs")]),
                CoreDesktopJSON.space(
                    "s1", name: "Alpha",
                    tabs: [CoreDesktopJSON.tab("tb1", name: "main", terminals: [labeled])]),
            ]), version: 0)

        let host = Host(address: "fixture", username: "dev", serverKind: .herdrCore)
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(connect: { try await fixture.connectCore() }, keepalive: nil)
            },
            coreHostMemory: HerdrCoreHostMemory())
        let presentation = TerminalListPresentationStore(
            defaults: UserDefaults(suiteName: "core-\(UUID())") ?? .standard)
        func cards() -> [String] {
            presentation.projection(hosts: [host], console: store).workspaces()
                .map { "\($0.title): \($0.terminals.map(\.paneID).joined(separator: " "))" }
        }
        func waitForCards(_ expected: [String]) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while cards() != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(cards() == expected)
        }

        store.setHosts([host])
        await store.resume()
        defer { store.setHosts([]) }

        // The document's names and order, the checkout's folder for a space only
        // labels know, the child beside its parent, and the rest by directory.
        try await waitForCards([
            "Zeta: \(other)", "Alpha: \(labeled) \(child)", "repo: \(lonely)", "plain: \(headless)",
        ])
        let rows = Dictionary(store.terminals.map { ($0.paneID, $0) }) { first, _ in first }
        #expect(rows[child]?.tabID == rows[labeled]?.tabID)
        #expect(rows[labeled]?.displayTabTitle == "Tab \u{201C}main\u{201D}")

        // A `doc` event and a `labels` event re-place them with no re-list.
        try await fixture.setDesktopDocument(
            CoreDesktopJSON.document([
                CoreDesktopJSON.space(
                    "s1", name: "Alpha Two",
                    tabs: [CoreDesktopJSON.tab("tb1", name: "main", terminals: [labeled])]),
                CoreDesktopJSON.space(
                    "s2", name: "Zeta", tabs: [CoreDesktopJSON.tab("tb2", name: "logs")]),
            ]), version: 1)
        try await fixture.label(headless, space: "s2", tab: "tb2")
        try await waitForCards([
            "Alpha Two: \(labeled) \(child)", "Zeta: \(other) \(headless)", "repo: \(lonely)",
        ])

        // Only the fixture wrote the document: both of its writes, and no more.
        let document = try await fixture.rpc(
            "doc.get", params: .object(["name": .string("herdr-app")]))
        #expect(HerdrCoreWire.integer(document["version"]) == 2)

        try await checkCheckoutRoots(fixture, repository: repository, plain: plain)
    }

    /// The exec itself, with a directory no shell should read as anything else.
    private func checkCheckoutRoots(
        _ fixture: CoreSSHFixture, repository: String, plain: String
    ) async throws {
        let home = fixture.configuration.homePath
        let awkward = "\(home)/placement/it's $(touch \(home)/pwned) `id`\n; x"
        try await fixture.makeCheckout(at: awkward, subdirectory: "deep")

        let transport = try await fixture.connectCore()
        do {
            let services = transport.hostServices
            let roots = try await services.checkoutRoots(
                for: ["\(repository)/src", "\(awkward)/deep", plain, "\(home)/placement/missing"])
            #expect(roots == ["\(repository)/src": repository, "\(awkward)/deep": awkward])
            #expect(try await fixture.exists("\(home)/pwned") == false)

            let capped = (0..<40).map { "\(repository)/src/../src/\(String(repeating: "./", count: $0))" }
            let answers = try await services.checkoutRoots(for: capped)
            #expect(answers.count == GitProbe.checkoutRootsPerCall)
            try await transport.close()
        } catch {
            try? await transport.close()
            throw error
        }
    }
}

private final class CoreDialCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// The session's next snapshot, within a deadline that covers the holder's
/// restart. While nothing comes, its retries' statuses bring the deadline up.
private final class CoreSessionWatcher: @unchecked Sendable {
    private var iterator: AsyncStream<HerdrCoreHostSessionUpdate>.Iterator
    private(set) var statusesSinceLastSnapshot: [EventsSessionStatus] = []

    init(_ session: HerdrCoreHostSession) {
        iterator = session.updates.makeAsyncIterator()
    }

    func nextSnapshot() async throws -> (snapshot: HerdrCoreSnapshot, coreID: String) {
        statusesSinceLastSnapshot = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, let next = await iterator.next() {
            switch next {
            case .snapshot(let snapshot, let coreID): return (snapshot, coreID)
            case .status(.failed(let failure)): throw failure
            case .status(let status): statusesSinceLastSnapshot.append(status)
            default: continue
            }
        }
        throw CoreSSHFailure.timeout
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

    func rpc(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        var words = [configuration.rpcHelper, "--session", session, method]
        if let params {
            words += ["--params", String(decoding: try JSONEncoder().encode(params), as: UTF8.self)]
        }
        let stdout = try await require(words.map(GitProbe.singleQuoted).joined(separator: " "))
        return try JSONDecoder().decode(JSONValue.self, from: stdout)
    }

    /// Starts a Terminal and returns its address.
    func runTerminal(
        _ argv: [String], keep: Bool, cwd: String? = nil, parent: String? = nil
    ) async throws -> String {
        var params: [String: JSONValue] = [
            "argv": .array(argv.map(JSONValue.string)),
            "cwd": .string(cwd ?? configuration.homePath), "keep": .bool(keep),
        ]
        if let parent { params["parent"] = .string(parent) }
        let result = try await rpc("terminal.run", params: .object(params))
        return try #require(result["address"]?.stringValue)
    }

    /// The desktop app's labels, written as a test client would.
    func label(_ terminal: String, space: String, tab: String) async throws {
        _ = try await rpc(
            "terminal.label",
            params: .object([
                "terminal": .string(terminal),
                "labels": .object(["herdr.space": .string(space), "herdr.tab": .string(tab)]),
            ]))
    }

    func setDesktopDocument(_ value: JSONValue, version: Int) async throws {
        _ = try await rpc(
            "doc.set",
            params: .object([
                "name": .string("herdr-app"), "value": value, "version": .number(Double(version)),
            ]))
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await require("mkdir -p " + GitProbe.singleQuoted(path))
    }

    func makeCheckout(at path: String, subdirectory: String) async throws {
        try await makeDirectory("\(path)/\(subdirectory)")
        _ = try await require("git init -q " + GitProbe.singleQuoted(path))
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
