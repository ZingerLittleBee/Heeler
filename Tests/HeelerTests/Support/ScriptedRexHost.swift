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
        /// SSH opens it to this data endpoint, which serves it as Rex would.
        case endpoint(FakeRexDataEndpoint)
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
    /// Where data channels take their attach slots, as `HeelerSSHTransport`'s do.
    nonisolated let admission: SSHChannelAdmission?
    private(set) var isConnected = true
    /// What was asked of the connection, in order.
    private(set) var log: [String] = []
    /// Every server a channel opened to, in order.
    private(set) var servers: [FakeRexServer] = []
    /// Closing closes every channel opened on the connection, as SSH does,
    /// so nothing written on one afterwards reaches its server.
    private let closingClosesChannels: Bool
    private var opened: [any HeelerSSHAPIChannel] = []

    init(
        probe: [String]? = nil, socketCheck: String? = nil, control: [Channel] = [], data: [Channel] = [],
        admission: SSHChannelAdmission? = nil, platform: HostPlatform = .posix, closingClosesChannels: Bool = false
    ) {
        self.probe = probe
        self.socketCheck = socketCheck
        controlChannels = control
        dataChannels = data
        self.admission = admission
        self.platform = platform
        self.closingClosesChannels = closingClosesChannels
    }

    /// Serves `endpoint` for every data channel from now on.
    func serveData(from endpoint: FakeRexDataEndpoint, count: Int = 64) {
        dataChannels += Array(repeating: .endpoint(endpoint), count: count)
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
        return try await serve(try next(from: &controlChannels), at: socketPath)
    }

    func openRexDataChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("data \(socketPath)")
        let channel = try next(from: &dataChannels)
        guard let admission else { return try await serve(channel, at: socketPath) }
        return try await admission.admitAttachLink { try await self.serve(channel, at: socketPath) }
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
        guard closingClosesChannels else { return }
        for channel in opened { try? await channel.close(timeout: .zero) }
    }

    private func next(from queue: inout [Channel]) throws -> Channel {
        guard !queue.isEmpty else { throw TransportError.channelFailed(detail: "No channel scripted") }
        return queue.removeFirst()
    }

    private func serve(_ channel: Channel, at socketPath: String) async throws -> any HeelerSSHAPIChannel {
        switch channel {
        case .server(let server, let welcome):
            servers.append(server)
            if let welcome { Task { await server.handshake(welcome) } }
            opened.append(server.channel)
            return server.channel
        case .endpoint(let endpoint):
            let channel = await endpoint.connect()
            opened.append(channel)
            return channel
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
