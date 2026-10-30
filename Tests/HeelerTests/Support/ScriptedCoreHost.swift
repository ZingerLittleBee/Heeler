import Foundation

@testable import Heeler

/// An SSH connection to a herdr-core Host, without SSH: the locator's exec
/// prints scripted lines, and the forwarded channel is either refused or a
/// `FakeCoreSocket` that answers `hello` with a scripted line. What is under
/// test above it is the real `HerdrCoreSSHTransport` and `HerdrCoreLink`.
actor ScriptedCoreHost: HerdrCoreHostConnection {
    enum Channel: Sendable {
        case refused
        /// Answers the plain `hello` line with these bytes.
        case answersHello(Data)
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
    private let channel: Channel

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []
    private(set) var socket: FakeCoreSocket?

    init(locator: [String] = locatorLines(), locatorStatus: Int32 = 0, channel: Channel) {
        self.locator = locator
        self.locatorStatus = locatorStatus
        self.channel = channel
    }

    func runCoreLocator(_ script: Data) async throws -> GitExecResult {
        log.append("locator")
        scripts.append(String(decoding: script, as: UTF8.self))
        let output = (["\(Self.nonce) begin"] + locator + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(output.utf8), stderr: Data(), exitStatus: locatorStatus)
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
