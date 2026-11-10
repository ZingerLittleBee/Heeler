import Foundation

@testable import Heeler

/// A Host with a tmux on it, for tests of the tmux transport, detection and
/// everything above them. It answers the probe's script from what the script
/// asks: which executable, which socket, through the login shell or not.
actor ScriptedTmuxHost: TmuxHostConnection, ServerKindDetectionConnection {
    static let nonce = "scripted-tmux-host-nonce"
    static let executable = "/opt/homebrew/bin/tmux"
    static let directory = "/private/tmp/tmux-501"
    static let instance = TmuxServerInstance(pid: 4242, startTime: 1_794_326_988)

    static func socketPath(_ name: String = "default", in directory: String = directory) -> String {
        "\(directory)/\(name)"
    }

    static func paths(_ name: String = "default") -> TmuxPaths {
        guard let paths = TmuxPaths(executable: executable, socket: socketPath(name)) else {
            preconditionFailure("The scripted tmux paths are valid")
        }
        return paths
    }

    nonisolated let routeID: UUID? = nil
    private let kernel: String
    /// Every tmux on the Host, by path, with what its `-V` prints.
    private var executables: [String: String]
    /// The tmux the login shell's `PATH` finds.
    private var loginExecutable: String?
    /// The tmux directory the login shell's `TMUX_TMPDIR` names.
    private var loginDirectory: String
    /// The servers that answer, by socket path.
    private var servers: [String: TmuxServerInstance]
    private var failures: [TransportError] = []
    private var nextAnswers: [GitExecResult] = []
    private var connected = true

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []

    /// A Mac with Homebrew's tmux, and a server on each of `sockets`.
    init(
        executable: String? = ScriptedTmuxHost.executable, version: String = "tmux 3.7b",
        directory: String = ScriptedTmuxHost.directory, sockets: [String] = ["default"],
        kernel: String = "Darwin"
    ) {
        self.kernel = kernel
        executables = executable.map { [$0: version] } ?? [:]
        loginExecutable = executable
        loginDirectory = directory
        servers = Dictionary(
            uniqueKeysWithValues: sockets.enumerated().map { index, name in
                (
                    Self.socketPath(name, in: directory),
                    TmuxServerInstance(pid: Self.instance.pid + index, startTime: Self.instance.startTime)
                )
            })
    }

    // MARK: What the user does on the Host

    func startServer(
        _ name: String = "default", instance: TmuxServerInstance = ScriptedTmuxHost.instance
    ) {
        servers[Self.socketPath(name, in: loginDirectory)] = instance
    }

    /// Stopped or killed: a socket file left behind answers no better than none.
    func stopServer(_ name: String = "default") {
        servers[Self.socketPath(name, in: loginDirectory)] = nil
    }

    /// The tmux moves, as a package manager's upgrade can move it.
    func moveExecutable(to path: String, version: String = "tmux 3.7b") {
        executables = [path: version]
        loginExecutable = path
    }

    func uninstall() {
        executables = [:]
        loginExecutable = nil
    }

    /// The login shell's files name another tmux directory, and the servers are there.
    func moveDirectory(to directory: String) {
        let names = servers.map { (String($0.key.dropFirst(loginDirectory.count + 1)), $0.value) }
        loginDirectory = directory
        servers = Dictionary(uniqueKeysWithValues: names.map { (Self.socketPath($0.0, in: directory), $0.1) })
    }

    func failNextProbe(_ error: TransportError) {
        failures.append(error)
    }

    func answerNextProbe(stdout: String, exitStatus: Int32 = 0) {
        nextAnswers.append(GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: exitStatus))
    }

    func clearLog() {
        log = []
        scripts = []
    }

    // MARK: The connection

    var isConnected: Bool { connected }

    func close() async throws {
        log.append("close")
        connected = false
    }

    /// A new connection to the Host, which closes apart from any other.
    func transport(socketName: String, storedPaths: TmuxPaths?) -> TmuxSSHTransport {
        TmuxSSHTransport(
            connection: Dial(host: self), socketName: socketName, storedPaths: storedPaths,
            nonce: { Self.nonce })
    }

    private func noteClose() {
        log.append("close")
    }

    /// One SSH connection to the Host.
    private actor Dial: TmuxHostConnection {
        nonisolated let routeID: UUID? = nil
        private let host: ScriptedTmuxHost
        private var connected = true

        init(host: ScriptedTmuxHost) {
            self.host = host
        }

        var isConnected: Bool { connected }

        func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
            try await host.runTmuxProbe(script, throughLoginShell: throughLoginShell)
        }

        func close() async throws {
            connected = false
            await host.noteClose()
        }
    }

    func runTmuxProbe(_ script: Data, throughLoginShell: Bool) async throws -> GitExecResult {
        let body = String(decoding: script, as: UTF8.self)
        log.append(throughLoginShell ? "probe login" : "probe stored")
        scripts.append(body)
        if !failures.isEmpty { throw failures.removeFirst() }
        if !nextAnswers.isEmpty { return nextAnswers.removeFirst() }
        return GitExecResult(stdout: Data(answer(to: body).utf8), stderr: Data(), exitStatus: 0)
    }

    /// What the probe prints for the script's own request.
    private func answer(to script: String) -> String {
        // Through the login shell the body travels as one quoted word.
        let body = script.replacingOccurrences(of: "'\\''", with: "'")
            .replacingOccurrences(of: "__heeler_tmux_probe='", with: "")
        func assigned(_ name: String) -> String {
            guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("\(name)='") }) else { return "" }
            return String(line.dropFirst(name.count + 2).dropLast())
        }
        let nonce = Self.nonce(in: body)
        let asked = assigned("t")
        let socket = assigned("s")
        let name = assigned("n")
        let executable = asked.isEmpty ? loginExecutable : (executables[asked] == nil ? nil : asked)
        var lines = ["", "\(nonce) tmux begin", "kernel \(kernel)"]
        if let executable, let version = executables[executable] {
            lines += ["executable \(executable)", "version \(version)"]
        }
        if socket.isEmpty { lines.append("directory \(loginDirectory)") }
        let target = socket.isEmpty && !name.isEmpty ? Self.socketPath(name, in: loginDirectory) : socket
        if executable != nil, !target.isEmpty {
            if let instance = servers[target] { lines.append("instance \(instance.pid) \(instance.startTime)") }
        } else if executable != nil {
            let prefix = loginDirectory + "/"
            lines += servers.keys.filter { $0.hasPrefix(prefix) }.sorted().map { "socket \($0.dropFirst(prefix.count))" }
        }
        return (lines + ["", "\(nonce) tmux end", ""]).joined(separator: "\n")
    }

    private static func nonce(in script: String) -> String {
        guard let end = script.range(of: " tmux begin")?.lowerBound else { return "" }
        return String(script[..<end].reversed().prefix { $0 != "'" && $0 != "\n" }.reversed())
    }

    // MARK: Detection

    func corePlatform() async throws -> HostPlatform { .posix }

    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult {
        throw TransportError.hostFeatureUnavailable(feature: "native Windows")
    }

    /// A Host with neither herdr nor a core: only the tmux part finds anything.
    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        let body = String(decoding: script, as: UTF8.self)
        log.append("detection")
        scripts.append(body)
        if !failures.isEmpty { throw failures.removeFirst() }
        let marker = "herdr-tui begin\\n' '"
        let nonce = body.range(of: marker).map { String(body[$0.upperBound...].prefix { $0 != "'" }) } ?? ""
        var printed = "\n\(nonce) herdr-tui begin\n\n\(nonce) herdr-tui status 127\n"
        printed += answer(to: body)
        if body.contains("__session=") {
            printed += ["\(nonce) begin", "kernel \(kernel)", "default /home/dev/.herdr-core.sock", "socket-file 0", "\(nonce) end", ""]
                .joined(separator: "\n")
        }
        return GitExecResult(stdout: Data(printed.utf8), stderr: Data(), exitStatus: 0)
    }
}
