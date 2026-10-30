import Foundation

@testable import Heeler

/// An SSH connection to a herdr-core Host, without SSH: the locator's exec
/// prints scripted lines, and the forwarded channel is either refused or a
/// `FakeCoreSocket` that answers `hello` with a scripted line. What is under
/// test above it is the real `HerdrCoreSSHTransport` and `HerdrCoreLink`.
actor ScriptedCoreHost: HerdrCoreHostConnection, ServerKindDetectionConnection {
    enum Channel: Sendable {
        case refused
        /// Answers the plain `hello` line with these bytes.
        case answersHello(Data)
    }

    /// What `herdr session list --json` does in the detection exec.
    enum HerdrRead: Sendable, CustomStringConvertible {
        /// The shell cannot find it: status 127, nothing on stdout.
        case notInstalled
        case answers(String)
        case fails(status: Int32, output: String)

        var description: String {
            switch self {
            case .notInstalled: "not installed"
            case .answers(let output): "answers \(output)"
            case .fails(let status, let output): "fails \(status) \(output)"
            }
        }
    }

    static let nonce = "scripted-core-host-nonce"
    static let installedPath = "/home/me/.local/bin/herdr-core"
    static let socketPath = "/run/user/1000/herdr-core/work.sock"

    static let helloResult: JSONValue = .object([
        "generation": .number(1), "version": .string("0.1.13"),
        "core": .object(["id": .string("c1"), "name": .string("lab")]),
        "framed": .bool(true), "methods": .array([]),
        "features": .array(["framed", "attach", "events", "status", "shell"].map(JSONValue.string)),
    ])

    static func helloReply(result: JSONValue = helloResult) -> Data {
        let reply = try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("hello"), "result": result,
        ]))
        return (reply ?? Data()) + Data([0x0A])
    }

    static func helloReply(errorKind: String) -> Data {
        let reply = try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("hello"),
            "error": .object([
                "code": .number(-32601), "message": .string(errorKind),
                "data": .object(["kind": .string(errorKind)]),
            ]),
        ]))
        return (reply ?? Data()) + Data([0x0A])
    }

    static func helloReply(features: [String]) -> Data {
        helloReply(result: .object([
            "generation": .number(1), "version": .string("0.0.9"),
            "core": .object(["id": .string("c1"), "name": .string("lab")]),
            "framed": .bool(true), "methods": .array([]),
            "features": .array(features.map(JSONValue.string)),
        ]))
    }

    /// What the locator prints for a typical Linux Host.
    static func locatorLines(
        executable: String? = installedPath, version: String = "0.1.13", lock: String? = nil,
        defaultPath: String = socketPath, socketFile: Bool = false, kernel: String = "Linux",
        shell: String? = "/bin/bash"
    ) -> [String] {
        var lines = ["kernel \(kernel)"]
        if let executable { lines += ["executable \(executable)", "version \(version)"] }
        lines.append("default \(defaultPath)")
        if let lock { lines.append("lock \(lock)") }
        lines.append("socket-file \(socketFile ? 1 : 0)")
        if let shell { lines.append("shell \(shell)") }
        return lines
    }

    nonisolated let routeID: UUID? = nil
    private let locator: [String]
    private let locatorStatus: Int32
    private let shellBanner: Data
    private let channel: Channel
    private let herdrRead: HerdrRead
    private let detectionFailure: TransportError?

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []
    private(set) var socket: FakeCoreSocket?

    /// `shellBanner` is what the user's shell prints before it runs the script.
    init(
        locator: [String] = locatorLines(), locatorStatus: Int32 = 0, shellBanner: Data = Data(),
        herdrRead: HerdrRead = .notInstalled, detectionFailure: TransportError? = nil,
        channel: Channel
    ) {
        self.herdrRead = herdrRead
        self.detectionFailure = detectionFailure
        self.locator = locator
        self.locatorStatus = locatorStatus
        self.shellBanner = shellBanner
        self.channel = channel
    }

    func runCoreLocator(_ script: Data) async throws -> GitExecResult {
        log.append("locator")
        scripts.append(String(decoding: script, as: UTF8.self))
        let output = (["\(Self.nonce) begin"] + locator + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: shellBanner + Data(output.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    /// Prints what the script asked for, framed by the nonce the script carries.
    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        log.append("detection")
        let body = String(decoding: script, as: UTF8.self)
        scripts.append(body)
        if let detectionFailure { throw detectionFailure }
        let nonce = Self.nonce(in: body)
        let (status, output): (Int32, String) =
            switch herdrRead {
            case .notInstalled: (127, "")
            case .answers(let output): (0, output)
            case .fails(let status, let output): (status, output)
            }
        var printed = "\n\(nonce) herdr-tui begin\n\(output)\n\(nonce) herdr-tui status \(status)\n"
        if body.contains("__session=") {
            printed += (["\(nonce) begin"] + locator + ["\(nonce) end"]).joined(separator: "\n") + "\n"
        }
        return GitExecResult(stdout: shellBanner + Data(printed.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    private static func nonce(in script: String) -> String {
        let marker = "herdr-tui begin\\n' '"
        guard let start = script.range(of: marker)?.upperBound,
            let end = script[start...].firstIndex(of: "'")
        else { return "" }
        return String(script[start..<end])
    }

    func openCoreLinkChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("open \(socketPath)")
        switch channel {
        case .refused:
            throw TransportError.streamLocalOpenFailed(path: socketPath)
        case .answersHello(let reply):
            let socket = FakeCoreSocket()
            self.socket = socket
            Task {
                _ = await socket.nextWrittenLine()
                await socket.deliver(reply)
            }
            return socket
        }
    }

    func close() async throws {
        log.append("close")
    }

    /// The transport the app gets for this Host, with a nonce the script knows.
    nonisolated func transport(session: String = "work") -> HerdrCoreSSHTransport {
        HerdrCoreSSHTransport(connection: self, session: session, nonce: { Self.nonce })
    }
}
