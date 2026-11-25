import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Dialing a Rex Host over a scripted SSH connection: which socket, how a
/// refused channel or a refusing server reads to the user, resuming the
/// control link, and data channels. Paths, ids and tokens are invented.
@Suite("Rex transport", .timeLimit(.minutes(1)))
struct RexTransportTests {
    static let path = "/Users/dev/Library/Application Support/rex/server.sock"
    private static var socket: RexSocket? { RexSocket(path: path) }

    private func connect(_ host: ScriptedRexHost, socket: RexSocket? = Self.socket) async throws -> RexSSHTransport {
        try await RexSSHTransport.connect(over: host, socket: socket, options: .testing)
    }

    private func failure(_ host: ScriptedRexHost, socket: RexSocket? = Self.socket) async -> (any Error)? {
        do {
            let transport = try await connect(host, socket: socket)
            await transport.close()
            return nil
        } catch {
            return error
        }
    }

    @Test func itReachesTheStoredSocketAndSaysHello() async throws {
        let server = FakeRexServer()
        let host = ScriptedRexHost(control: [.server(server)])

        let transport = try await connect(host)

        #expect(await host.log == ["control \(Self.path)"])
        #expect(transport.socket == Self.socket)
        #expect(transport.foundSocket == nil)
        #expect(await server.nextHello()["client"]?["kind"] == .string("other"))
        #expect(await transport.control.clientID == FakeRexServer.Welcome().clientID)
        #expect(await transport.isConnected)

        await transport.close()
        #expect(await server.clientClose?.code == .normalClosure)
        #expect(await host.log == ["control \(Self.path)", "close"])
    }

    /// A Host that stores no socket has it looked up first, on the same connection.
    @Test func aHostWithoutASocketLooksItUp() async throws {
        let found = "/run/user/1000/rex/server.sock"
        let host = ScriptedRexHost(
            probe: ScriptedRexHost.probeFinding(found, kernel: "Linux"), control: [.server(FakeRexServer())])

        let transport = try await connect(host, socket: nil)

        #expect(transport.foundSocket == RexSocket(path: found))
        #expect(transport.socket == RexSocket(path: found))
        #expect(await host.log == ["probe", "control \(found)"])
        await transport.close()
    }

    @Test(arguments: [
        (["kernel Darwin", "installed"], TransportError.rexServerNotRunning(socketPath: nil)),
        (["kernel Darwin"], .rexNotInstalled),
        (["kernel Linux", "socket 0 0 /run/rex/server.sock", "installed"], .rexAccountRefused(socketPath: "/run/rex/server.sock")),
        (["kernel FreeBSD"], .rexLookupFailed(reason: "Heeler finds Rex on macOS, Linux and Windows Hosts only.")),
    ])
    func aLookupThatFindsNoUsableSocketSaysWhy(probe: [String], expected: TransportError) async {
        let host = ScriptedRexHost(probe: probe)

        let error = await failure(host, socket: nil)

        #expect(error as? TransportError == expected)
        #expect(await host.log == ["probe", "close"])
    }

    /// A probe whose exec fails is a lookup that could not read the Host, not
    /// a server's malformed answer.
    @Test func aLookupWhoseProbeFailsSaysItCouldNotLook() async {
        let host = ScriptedRexHost(probe: nil)

        let error = await failure(host, socket: nil)

        #expect(
            error as? TransportError
                == .rexLookupFailed(reason: "Heeler could not read whether Rex is on this Host."))
        #expect(await host.log == ["probe", "close"])
    }

    /// SSH reports a refused socket one way whatever the cause, so the Host is
    /// asked whether anything listens there.
    @Test(arguments: [
        ("missing" as String?, TransportError.rexServerNotRunning(socketPath: RexTransportTests.path)),
        ("idle", .rexServerNotRunning(socketPath: RexTransportTests.path)),
        ("listening", .rexForwardingRefused(socketPath: RexTransportTests.path)),
        (nil, .rexSocketUnreachable(socketPath: RexTransportTests.path)),
    ])
    func aRefusedChannelIsExplainedByTheSocketCheck(answer: String?, expected: TransportError) async {
        let host = ScriptedRexHost(socketCheck: answer, control: [.refused])

        let error = await failure(host)

        #expect(error as? TransportError == expected)
        #expect(await host.log == ["control \(Self.path)", "check", "close"])
    }

    @Test func aRefusingServerIsTheAccountsProblem() async {
        let server = FakeRexServer()
        let host = ScriptedRexHost(control: [.server(server, welcome: nil)])
        async let error = failure(host)
        await server.refuseUpgrade(status: 403)

        #expect(await error as? TransportError == .rexAccountRefused(socketPath: nil))
        #expect(await host.log == ["control \(Self.path)", "close"])
    }

    @Test func anotherRevisionNamesWhatTheServerOffered() async {
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = 20
        welcome.serverRevision = 21
        let server = FakeRexServer()
        let host = ScriptedRexHost(control: [.server(server, welcome: welcome)])

        let error = await failure(host)

        #expect(error as? TransportError == .rexUnsupportedRevision(offered: 21))
        #expect(await server.clientClose?.code == .normalClosure)
    }

    @Test func anSSHFailureOpeningTheChannelPassesThrough() async {
        let host = ScriptedRexHost(control: [.fails(.sshUnreachable(detail: "gone"))])

        #expect(await failure(host) as? TransportError == .sshUnreachable(detail: "gone"))
        #expect(await host.log == ["control \(Self.path)", "close"])
    }

    // MARK: Resuming and data channels

    @Test func reconnectingDropsTheOldLinkAndResumesWithItsToken() async throws {
        var first = FakeRexServer.Welcome()
        first.reconnectToken = "fake-token-old"
        var again = FakeRexServer.Welcome()
        again.resumed = true
        again.reconnectToken = "fake-token-new"
        let oldServer = FakeRexServer()
        let newServer = FakeRexServer()
        let host = ScriptedRexHost(control: [.server(oldServer, welcome: first), .server(newServer, welcome: again)])
        let transport = try await connect(host)
        let old = await transport.control

        let link = try await transport.reconnectControl()

        #expect(link.resumed)
        #expect(link.clientID == old.clientID)
        #expect(await transport.control === link)
        #expect(await newServer.nextHello()["reconnect_token"] == .string("fake-token-old"))
        #expect(await oldServer.channel.isClosed)
        #expect(await !oldServer.clientSentCloseFrame)
        #expect(await host.log == ["control \(Self.path)", "control \(Self.path)"])
        await transport.close()
    }

    // MARK: Native Windows

    static let pipe = "npipe:////./pipe/rex-S-1-5-21-1111111111-2222222222-3333333333-1001"
    static let dial = "cmd /d /c \"echo __HEELER_STREAM_READY__&& cd /d %USERPROFILE%&& rex.exe -S \(pipe) __internal dial-stdio --autostart=false\""

    /// SSH forwards no named pipe: the control and data links are execs of
    /// Rex's stdio bridge, carrying the same WebSocket.
    @Test func aWindowsPipeIsReachedThroughRexsStdioBridge() async throws {
        let server = FakeRexServer()
        let endpoint = FakeRexDataEndpoint()
        let host = ScriptedRexHost(control: [.server(server)], data: [.endpoint(endpoint)], platform: .nativeWindows)

        let transport = try await connect(host, socket: RexSocket(path: Self.pipe))
        #expect(await server.nextHello()["api_revision"] == .number(19))
        _ = try await transport.openDataChannel()

        #expect(await host.log == ["control exec \(Self.dial)", "data exec \(Self.dial)"])
        await transport.close()
    }

    /// A Windows Host that stores no pipe looks for it with the Windows probe.
    @Test func aWindowsHostWithoutAPipeLooksItUp() async throws {
        let host = ScriptedRexHost(
            probe: ScriptedRexHost.probeFinding(Self.pipe, kernel: "Windows"), control: [.server(FakeRexServer())],
            platform: .nativeWindows)

        let transport = try await connect(host, socket: nil)

        #expect(transport.foundSocket == RexSocket(path: Self.pipe))
        #expect(await host.log == ["windows", "control exec \(Self.dial)"])
        await transport.close()
    }

    /// The bridge ends before the upgrade when no server listens (it starts
    /// none) or `rex` is not on PATH; a fresh look says which.
    @Test(arguments: [
        (["kernel Windows", "installed"], TransportError.rexServerNotRunning(socketPath: pipe)),
        (["kernel Windows"], .rexNotInstalled),
        (["kernel Windows", "socket 1 0 \(pipe)", "installed"],
         .rexLookupFailed(reason: "Rex is running, but rex.exe is not on the PATH of this account's SSH sessions.")),
    ])
    func aWindowsBridgeThatEndsSaysWhy(probe: [String], expected: TransportError) async {
        let host = ScriptedRexHost(probe: probe, control: [.endsAtOnce], platform: .nativeWindows)

        let error = await failure(host, socket: RexSocket(path: Self.pipe))

        #expect(error as? TransportError == expected)
        #expect(await host.log == ["control exec \(Self.dial)", "windows", "close"])
    }

    /// A pipe found while `rex.exe` is not on the exec's PATH is no server
    /// the bridge can reach, and the lookup says so.
    @Test func aWindowsPipeWithoutRexOnPathSaysSo() async {
        let host = ScriptedRexHost(
            probe: ["kernel Windows", "socket 1 0 \(Self.pipe)", "installed"], platform: .nativeWindows)

        let error = await failure(host, socket: nil)

        #expect(
            error as? TransportError
                == .rexLookupFailed(reason: "Rex is running, but rex.exe is not on the PATH of this account's SSH sessions."))
        #expect(await host.log == ["windows", "close"])
    }

    @Test func aWindowsServersPlatformNamesItsKernel() {
        #expect(RexServerPlatform.kernel(reading: ["platform": "windows_amd64"]) == HerdrCoreLocator.windowsKernel)
        #expect(RexServerPlatform.kernel(reading: ["platform": "darwin_arm64"]) == HerdrCoreLocator.macOSKernel)
    }

    @Test func aDataChannelGoesToTheSameSocket() async throws {
        let data = FakeRexServer()
        let host = ScriptedRexHost(control: [.server(FakeRexServer())], data: [.server(data, welcome: nil), .refused])
        let transport = try await connect(host)

        let channel = try await transport.openDataChannel()
        #expect(channel as? FakeWebSocketServer === data.channel)
        await #expect(throws: TransportError.rexSocketUnreachable(socketPath: Self.path)) {
            try await transport.openDataChannel()
        }
        #expect(await host.log == ["control \(Self.path)", "data \(Self.path)", "data \(Self.path)", "check"])
        await transport.close()
    }

    /// A data link holds an attach slot, never the events slot the control link holds.
    @Test func aDataLinkTakesAnAttachSlotUntilItCloses() async throws {
        let admission = SSHChannelAdmission()
        let channel = try await admission.admitAttachLink { FakeWebSocketServer() }
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().events == 0)

        try await channel.close(timeout: .seconds(1))
        #expect(await admission.snapshot().attach == 0)
    }

    // MARK: What the user reads

    @Test func eachFailureSaysWhatToDo() {
        let notRunning = TransportError.rexServerNotRunning(socketPath: Self.path).presentation
        #expect(notRunning.message.contains("Heeler does not start it"))
        #expect(notRunning.message.contains(Self.path))
        #expect(TransportError.rexServerNotRunning(socketPath: nil).presentation.message.contains("No Rex server socket"))

        let forwarding = TransportError.rexForwardingRefused(socketPath: Self.path).presentation
        let herdr = TransportError.herdrCoreForwardingRefused(socketPath: Self.path).presentation
        #expect(forwarding.summary == herdr.summary)
        #expect(forwarding.recoverySuggestion == herdr.recoverySuggestion)
        #expect(forwarding.detail?.contains("Rex is running") == true)

        #expect(TransportError.rexAccountRefused(socketPath: nil).presentation.summary == "Rex did not let this account in")
        let newer = TransportError.rexUnsupportedRevision(offered: 21).presentation.message
        #expect(newer.contains("21") && newer.contains("revisions 12 to 19") && newer.contains("Update Heeler"))
        #expect(TransportError.rexUnsupportedRevision(offered: 11).presentation.message.contains("Update Rex"))
        #expect(TransportError.rexUnsupportedRevision(offered: nil).presentation.message.contains("12 to 19"))

        #expect(TransportError.rexServerNotRunning(socketPath: nil).isRetryable)
        #expect(TransportError.rexSocketUnreachable(socketPath: Self.path).isRetryable)
        #expect(!TransportError.rexForwardingRefused(socketPath: Self.path).isRetryable)
        #expect(!TransportError.rexUnsupportedRevision(offered: 13).isRetryable)
        #expect(!TransportError.rexAccountRefused(socketPath: nil).isRetryable)
    }

    @Test func aControlLinkFailureMapsToTheTransportTaxonomy() {
        #expect(TransportError(rexControl: .upgradeRefused(status: 403)) == .rexAccountRefused(socketPath: nil))
        #expect(TransportError(rexControl: .unsupportedVersion(.unknown)) == .rexUnsupportedRevision(offered: nil))
        #expect(TransportError(rexControl: .welcomeTimedOut) == .timedOut)
        #expect(TransportError(rexControl: .deadlineExceeded(method: "session.list")) == .timedOut)
        #expect(
            TransportError(rexControl: .server(RexServerError(code: "refused", message: "no", status: 403)))
                == .rexRejected(code: "refused", message: "no"))
        guard case .rexAnswerUnreadable = TransportError(rexControl: .unreadableResult(method: "session.view")) else {
            Issue.record("An unreadable result is not Rex's unreadable answer")
            return
        }
        guard case .channelFailed = TransportError(rexControl: .linkEnded(.linkLost)) else {
            Issue.record("A lost link is not a channel failure")
            return
        }
    }

    /// Endings only a misbehaving or overloaded server brings each say what
    /// happened, and every one is retried.
    @Test(arguments: [
        (RexControlEnding.droppedByServer, "too many events were waiting"),
        (.messageTooBig, "too large"),
        (.protocolFailure, "did not agree on the connection's protocol"),
        (.linkLost, "The connection to Rex ended."),
        (.serverWentAway(code: 1001), "The connection to Rex ended."),
    ])
    func aLinkEndingSaysWhichItWas(reason: RexControlEnding, says: String) {
        let failure = TransportError(rexControl: .linkEnded(reason))
        #expect(failure.presentation.message.contains(says))
        #expect(failure.isRetryable)
    }

    /// Rex's own refusals and answers it cannot read name Rex, not herdr, and
    /// keep the retry behavior of herdr's counterparts.
    @Test func rexsOwnAnswersNameRex() {
        let rejected = TransportError.rexRejected(code: "internal", message: "something broke").presentation
        #expect(rejected.summary == "Rex rejected the request")
        #expect(rejected.detail == "something broke (internal)")
        #expect(TransportError.rexRejected(code: "internal", message: "x").isRetryable)

        let unreadable = TransportError.rexAnswerUnreadable("Rex's status named no server instance.").presentation
        #expect(unreadable.summary == "Rex sent an answer Heeler cannot read")
        #expect(unreadable.detail == "Rex's status named no server instance")
        #expect(unreadable.recoverySuggestion == "Check the Rex version on the Host.")
        #expect(!TransportError.rexAnswerUnreadable("x").isRetryable)
        for error in [TransportError.rexRejected(code: "internal", message: "x"), .rexAnswerUnreadable("x")] {
            #expect(!error.presentation.message.contains("herdr"))
        }
    }
}
