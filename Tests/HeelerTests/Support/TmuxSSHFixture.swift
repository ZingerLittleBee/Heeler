import Foundation
import HeelerSSH
import Testing

@testable import Heeler

enum TmuxSSHFailure: Error {
    case timeout
    case fixture(String)
}

/// The Swift side of `scripts/fixtures/tmux-ssh.py`, for every tmux Host suite
/// that runs over real SSH.
///
/// The fixture account has its own home and its own tmux directory, so no
/// socket here, `default` included, is ever the user's. The app never starts a
/// server: a test starts one over this fixture's own SSH connection, on a
/// socket in that directory, and `with` ends every server there by its `-S`
/// path before and after its body.
struct TmuxSSHFixture: Sendable {
    struct Configuration: Decodable, Sendable {
        let tmuxFixture: Bool
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let homePath: String
        /// Where the login shell finds tmux. The exec's own `PATH` has none.
        let tmuxExecutable: String
        /// That tmux's version, as it names itself.
        let tmuxVersion: String
        /// Before `tmuxExecutable` on the login shell's `PATH`, and empty.
        let firstDirectory: String
        /// Where the login shell's `TMUX_TMPDIR` puts a named socket.
        let socketDirectory: String
        /// Where the exec's own `TMUX_TMPDIR` would. Nothing listens there.
        let execSocketDirectory: String
    }

    static var isConfigured: Bool {
        guard let raw = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: raw),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["tmuxFixture"] as? Bool == true
    }

    let configuration: Configuration
    let connection: SSHConnection
    /// A socket name of this test's own.
    let socketName: String

    init(configuration: Configuration, connection: SSHConnection) {
        self.configuration = configuration
        self.connection = connection
        socketName = "h" + UUID().uuidString.lowercased().prefix(8)
    }

    static func with(_ body: (TmuxSSHFixture) async throws -> Void) async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"])
        let data = try #require(Data(base64Encoded: raw))
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        // The fixture script refuses to start on anything else. Nothing below
        // runs a tmux command unless every socket is the fixture's own.
        let root = URL(fileURLWithPath: config.homePath).deletingLastPathComponent().path
        for directory in [config.socketDirectory, config.execSocketDirectory] {
            guard directory.hasPrefix(root + "/"), !directory.hasPrefix("/tmp/tmux-"),
                !directory.hasPrefix("/private/tmp/tmux-")
            else { throw TmuxSSHFailure.fixture("\(directory) is not a directory of the fixture's own") }
        }
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: config.host, port: config.port), timeout: RealSSHFixture.setupTimeout)
        let key = DeviceKey(privateKey: try RealSSHFixture.deviceKey(seed: config.deviceKeySeed))
        try await connection.authenticate(
            username: config.username, publicKey: key.publicKeyBlob,
            signer: { try key.privateKey.signature(for: $0) }, timeout: RealSSHFixture.setupTimeout)
        let fixture = TmuxSSHFixture(configuration: config, connection: connection)
        do {
            try await fixture.reset()
            try await body(fixture)
            try await fixture.reset()
            try await connection.close(timeout: .seconds(3))
        } catch {
            try? await fixture.reset()
            try? await connection.close(timeout: .seconds(3))
            throw error
        }
    }

    // MARK: The app's side

    func settings(socketName: String? = nil, storedPaths: TmuxPaths? = nil) throws -> SSHTransportSettings {
        var result = SSHTransportSettings(
            host: configuration.host, port: Int(configuration.port), username: configuration.username,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)
        result.serverKind = .tmux
        result.tmuxSocketName = socketName ?? self.socketName
        result.tmuxPaths = storedPaths
        return result
    }

    func connectTmux(socketName: String? = nil, storedPaths: TmuxPaths? = nil) async throws -> any TmuxTransport {
        try await SSHTransportConnector().connectTmux(
            settings: settings(socketName: socketName, storedPaths: storedPaths))
    }

    /// What one fresh connection reads of the Host, and the paths it resolved.
    func read(
        socketName: String? = nil, storedPaths: TmuxPaths? = nil
    ) async throws -> (status: Result<TmuxServerStatus, TransportError>, resolved: TmuxPaths?) {
        let transport = try await connectTmux(socketName: socketName, storedPaths: storedPaths)
        do {
            let status: Result<TmuxServerStatus, TransportError>
            do {
                status = .success(try await transport.status())
            } catch let error as TransportError {
                status = .failure(error)
            }
            let resolved = await transport.resolvedPaths()
            try await transport.close()
            return (status, resolved)
        } catch {
            try? await transport.close()
            throw error
        }
    }

    /// What an unconfirmed Host's one detection exec finds here.
    func detect(typedSocket: String = "") async throws -> ServerKindDetection {
        var settings = try settings()
        settings.serverKind = .unconfirmed
        let connection = try await SSHTransportConnector().connectForDetection(settings: settings)
        do {
            let found = try await ServerKindDetection.run(over: connection, session: typedSocket)
            try await connection.close()
            return found
        } catch {
            try? await connection.close()
            throw error
        }
    }

    // MARK: The Host's side, always by a socket path of the fixture's own

    func socketPath(_ name: String? = nil) -> String {
        "\(configuration.socketDirectory)/\(name ?? socketName)"
    }

    /// What a Host confirmed on this socket stores.
    func paths(_ name: String? = nil) throws -> TmuxPaths {
        try #require(TmuxPaths(executable: configuration.tmuxExecutable, socket: socketPath(name)))
    }

    func run(_ command: String) async throws -> SSHExecResult {
        try await connection.execute(command, timeout: .seconds(20))
    }

    @discardableResult
    func require(_ command: String) async throws -> String {
        let response = try await run(command)
        guard response.exitStatus == 0 else {
            throw TmuxSSHFailure.fixture("\(command): \(String(decoding: response.stderr, as: UTF8.self))")
        }
        return String(decoding: response.stdout, as: UTF8.self)
    }

    private func tmuxCommand(_ name: String?, _ words: [String], startsServer: Bool = false) -> String {
        ([configuration.tmuxExecutable] + (startsServer ? [] : ["-N"]) + ["-S", socketPath(name)] + words)
            .map(GitProbe.singleQuoted).joined(separator: " ")
    }

    /// Asks the server on a fixture socket. `-N`: asking never starts one.
    @discardableResult
    func tmux(_ name: String? = nil, _ words: String...) async throws -> String {
        try await require(tmuxLine(words, on: name))
    }

    /// The command line of one ask, for words kept in a list.
    func tmuxLine(_ words: [String], on name: String? = nil) -> String {
        tmuxCommand(name, words) + " </dev/null"
    }

    /// Starts a server with one session, the only way one starts here. It reads
    /// no configuration unless asked to, where `~/.tmux.conf` is the test's own.
    func startServer(_ name: String? = nil, readingConfiguration: Bool = false) async throws {
        let words =
            (readingConfiguration ? [] : ["-f", "/dev/null"])
            + ["new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/cat"]
        try await require(tmuxCommand(name, words, startsServer: true) + " </dev/null >/dev/null 2>&1")
        try await eventually { try await answers(name) }
    }

    func answers(_ name: String? = nil) async throws -> Bool {
        try await run(tmuxCommand(name, ["display-message", "-p", "x"]) + " </dev/null >/dev/null 2>&1")
            .exitStatus == 0
    }

    func stopServer(_ name: String? = nil) async throws {
        try await tmux(name, "kill-server")
        try await eventually { try await !answers(name) }
    }

    /// Kills the server outright, which leaves its socket file behind.
    func killServer(_ name: String? = nil) async throws {
        let pid = try await serverInstance(name).pid
        try await require("kill -KILL \(pid)")
        try await eventually { try await !answers(name) }
    }

    func serverInstance(_ name: String? = nil) async throws -> TmuxServerInstance {
        let fields = try await tmux(name, "display-message", "-p", "#{pid} #{start_time}")
            .split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = Int(fields[0]), let startTime = Int(fields[1]) else {
            throw TmuxSSHFailure.fixture("The server on \(socketPath(name)) did not name itself")
        }
        return TmuxServerInstance(pid: pid, startTime: startTime)
    }

    func sessionNames(_ name: String? = nil) async throws -> [String] {
        try await tmux(name, "list-sessions", "-F", "#{session_name}")
            .split(separator: "\n").map(String.init).sorted()
    }

    /// Every process running the fixture's tmux or naming one of its sockets.
    func tmuxProcesses() async throws -> Set<Int> {
        let listing = try await require("ps -axo pid=,command=")
        return Set(
            listing.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { return nil }
                let command = fields[1]
                guard
                    command.hasPrefix(configuration.tmuxExecutable + " ")
                        || command.contains(configuration.socketDirectory + "/")
                        || command.contains(configuration.execSocketDirectory + "/")
                else { return nil }
                return Int(fields[0])
            })
    }

    /// The socket files in both of the fixture's tmux directories.
    func socketFiles() async throws -> [String] {
        let directories = [configuration.socketDirectory, configuration.execSocketDirectory]
            .map(GitProbe.singleQuoted).joined(separator: " ")
        return try await require("for d in \(directories); do for f in \"$d\"/*; do [ -S \"$f\" ] && echo \"$f\"; done; done; true")
            .split(separator: "\n").map(String.init).sorted()
    }

    /// An executable at `path`, in a directory made for it.
    func writeProgram(at path: String, _ body: String) async throws {
        let quoted = GitProbe.singleQuoted(path)
        try await require(
            "mkdir -p \"$(dirname \(quoted))\" && printf '%s\\n' \(GitProbe.singleQuoted(body)) > \(quoted) && chmod +x \(quoted)")
    }

    func writeFile(at path: String, _ contents: String) async throws {
        try await require("printf '%s\\n' \(GitProbe.singleQuoted(contents)) > \(GitProbe.singleQuoted(path))")
    }

    func exists(_ path: String) async throws -> Bool {
        try await run("test -e " + GitProbe.singleQuoted(path)).exitStatus == 0
    }

    /// A program named tmux that comes first on the login shell's `PATH` and
    /// only says which version it is, for a Host whose tmux is too old.
    func withStandInTmux(versionLine: String, _ body: () async throws -> Void) async throws {
        try await writeProgram(
            at: "\(configuration.firstDirectory)/tmux",
            "#!/bin/sh\nif [ \"$1\" = -V ]; then echo \(GitProbe.singleQuoted(versionLine)); exit 0; fi\nexit 1")
        do {
            try await body()
            try await reset()
        } catch {
            try? await reset()
            throw error
        }
    }

    /// A Host with no tmux anywhere a login shell looks.
    func hidingTmux(_ body: () async throws -> Void) async throws {
        let program = GitProbe.singleQuoted(configuration.tmuxExecutable)
        let aside = GitProbe.singleQuoted(Self.aside(configuration.tmuxExecutable))
        try await require("mv \(program) \(aside)")
        do {
            try await body()
            try await require("mv \(aside) \(program)")
        } catch {
            _ = try? await require("mv \(aside) \(program)")
            throw error
        }
    }

    private static func aside(_ path: String) -> String { path + ".aside" }

    /// Puts the fixture back as its script made it: tmux where it was, no
    /// stand-in, no configuration, and no server on any of its sockets.
    func reset() async throws {
        let program = GitProbe.singleQuoted(configuration.tmuxExecutable)
        let aside = GitProbe.singleQuoted(Self.aside(configuration.tmuxExecutable))
        let directories = [configuration.socketDirectory, configuration.execSocketDirectory]
            .map(GitProbe.singleQuoted).joined(separator: " ")
        try await require(
            """
            [ ! -e \(aside) ] || mv \(aside) \(program)
            rm -f \(GitProbe.singleQuoted(configuration.firstDirectory))/*
            rm -f \(GitProbe.singleQuoted(configuration.homePath + "/.tmux.conf"))
            for d in \(directories); do
                for f in "$d"/*; do
                    [ -S "$f" ] || continue
                    \(program) -N -S "$f" kill-server </dev/null >/dev/null 2>&1
                    rm -f "$f"
                done
            done
            true
            """)
        try await eventually { try await tmuxProcesses().isEmpty }
    }

    func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TmuxSSHFailure.timeout
    }
}
