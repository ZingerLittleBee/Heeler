import Foundation
import HeelerSSH

@testable import Heeler

/// A Rex Host's SSH connection, scripted for `RexSSHTransport`: what the Rex
/// probe and the socket check print, and whether SSH opens each channel to the
/// socket, with the fake server behind it when it does.
final actor ScriptedRexHost: RexHostConnection {
    enum Channel: Sendable {
        /// SSH opens it to this server. With a welcome, the server answers the
        /// upgrade and the hello by itself; without one, the test drives it.
        case server(FakeRexServer, welcome: FakeRexServer.Welcome? = FakeRexServer.Welcome())
        /// SSH refuses it, as libssh2 reports any refused socket.
        case refused
        case fails(TransportError)
    }

    nonisolated let routeID: UUID? = nil
    private let platform: HostPlatform
    /// What the Rex probe prints between its markers; nil makes it exit 1.
    private let probe: [String]?
    /// The socket check's one line, such as `listening`; nil prints none.
    private let socketCheck: String?
    private var controlChannels: [Channel]
    private var dataChannels: [Channel]
    private(set) var isConnected = true
    /// What was asked of the connection, in order.
    private(set) var log: [String] = []
    /// Every server a channel opened to, in order.
    private(set) var servers: [FakeRexServer] = []

    init(
        probe: [String]? = nil, socketCheck: String? = nil, control: [Channel] = [], data: [Channel] = [],
        platform: HostPlatform = .posix
    ) {
        self.probe = probe
        self.socketCheck = socketCheck
        controlChannels = control
        dataChannels = data
        self.platform = platform
    }

    /// What a Rex probe prints for one socket this account owns and may use.
    static func probeFinding(_ path: String, kernel: String = "Darwin") -> [String] {
        ["kernel \(kernel)", "socket 1 1 \(path)", "installed"]
    }

    func corePlatform() async throws -> HostPlatform {
        platform
    }

    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        log.append("probe")
        let body = String(decoding: script, as: UTF8.self)
        guard let probe, let nonce = Self.nonce(in: body, before: " rex begin'") else {
            return GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 1)
        }
        let printed = (["", "\(nonce) rex begin"] + probe + ["", "\(nonce) rex end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(printed.utf8), stderr: Data(), exitStatus: 0)
    }

    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult {
        log.append("windows")
        throw TransportError.hostFeatureUnavailable(feature: "Windows commands")
    }

    func openRexControlChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("control \(socketPath)")
        return try open(socketPath, from: &controlChannels)
    }

    func openRexDataChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("data \(socketPath)")
        return try open(socketPath, from: &dataChannels)
    }

    func runRexSocketCheck(_ script: Data) async throws -> GitExecResult {
        log.append("check")
        let body = String(decoding: script, as: UTF8.self)
        guard let nonce = Self.nonce(in: body, before: " rex-socket begin'") else {
            return GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 1)
        }
        let lines = ["", "\(nonce) rex-socket begin"] + (socketCheck.map { [$0] } ?? []) + ["", "\(nonce) rex-socket end"]
        return GitExecResult(stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data(), exitStatus: 0)
    }

    func close() async throws {
        log.append("close")
        isConnected = false
    }

    private func open(_ socketPath: String, from queue: inout [Channel]) throws -> any HeelerSSHAPIChannel {
        guard !queue.isEmpty else { throw TransportError.channelFailed(detail: "No channel scripted") }
        switch queue.removeFirst() {
        case .server(let server, let welcome):
            servers.append(server)
            if let welcome { Task { await server.handshake(welcome) } }
            return server.channel
        case .refused:
            throw TransportError.streamLocalOpenFailed(path: socketPath)
        case .fails(let error):
            throw error
        }
    }

    /// The nonce a script's begin marker carries.
    private static func nonce(in script: String, before marker: String) -> String? {
        guard let marker = script.range(of: marker) else { return nil }
        let head = script[..<marker.lowerBound]
        guard let quote = head.lastIndex(of: "'") else { return nil }
        return String(head[head.index(after: quote)...])
    }
}
