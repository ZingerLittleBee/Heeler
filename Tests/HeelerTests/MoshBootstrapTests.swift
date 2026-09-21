import Foundation
import Testing

@testable import Heeler

@Suite("Mosh bootstrap")
struct MoshBootstrapTests {
    /// mosh-server's real banner shape, verified live: the CONNECT line
    /// among startup chatter.
    private static let connectLine = "MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg"
    // 22-char key: "MDEyMzQ1Njc4OWFiY2RlZg"

    @Test func parsesTheConnectBanner() {
        let bootstrap = MoshBootstrap.parse(
            Data("\(Self.connectLine)\n".utf8), host: "host.example")
        #expect(bootstrap == MoshBootstrap(
            host: "host.example", udpPort: "60001",
            key: "MDEyMzQ1Njc4OWFiY2RlZg"))
    }

    @Test func toleratesChatterBeforeAndAfterTheBanner() {
        let output = """
            mosh-server (mosh 1.4.0) [build mosh 1.4.0]
            Copyright 2012 Keith Winstein
            mosh-server: creating PTY...
            \(Self.connectLine)
            mosh-server: started
            """
        let bootstrap = MoshBootstrap.parse(Data(output.utf8))
        #expect(bootstrap?.udpPort == "60001")
        #expect(bootstrap?.key == "MDEyMzQ1Njc4OWFiY2RlZg")
    }

    @Test func toleratesLeadingWhitespaceOnTheBannerLine() {
        let bootstrap = MoshBootstrap.parse(
            Data("\r\n  \(Self.connectLine)\r\n".utf8))
        #expect(bootstrap?.udpPort == "60001")
    }

    @Test func rejectsAMalformedKeyLength() {
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZ".utf8)) == nil)
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg=".utf8)) == nil)
    }

    @Test func rejectsAMissingPort() {
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT  MDEyMzQ1Njc4OWFiY2RlZg".utf8)) == nil)
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001X MDEyMzQ1Njc4OWFiY2RlZg".utf8)) == nil)
    }

    @Test func rejectsOutputWithoutABanner() {
        #expect(MoshBootstrap.parse(Data("mosh-server: not found\n".utf8)) == nil)
        #expect(MoshBootstrap.parse(Data()) == nil)
    }

    // MARK: transport choice

    @Test func agentTargetsChooseMoshWhenProbedAvailable() {
        #expect(
            MoshTransportChoice.select(availability: true, target: .agentPane("w1:p1"))
                == .mosh)
    }

    @Test func shellTargetsKeepSSH() {
        #expect(
            MoshTransportChoice.select(availability: true, target: .terminal("t1"))
                == .ssh)
    }

    @Test func anUnavailableOrMissingProbeKeepsSSH() {
        #expect(
            MoshTransportChoice.select(availability: false, target: .agentPane("w1:p1"))
                == .ssh)
        #expect(
            MoshTransportChoice.select(availability: false, target: .terminal("t1"))
                == .ssh)
    }

    // MARK: bootstrap command

    @Test func bootstrapCommandWrapsTheAttachWithMoshServer() throws {
        let command = try HeelerSSHTransport.moshBootstrapCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .agentPane("w1:p1"), takeover: true, cols: 100, rows: 40),
            socketPath: "/home/user/.herdr/herdr.sock")

        // The herdr attach runs under mosh-server's PTY with the UTF-8
        // locale; the socket path reaches it through HERDR_SOCKET_PATH.
        #expect(
            command
                .contains(
                    "exec mosh-server new -c 100 -l LANG=en_US.UTF-8 -- herdr agent attach \"$1\" --takeover"))
        #expect(command.contains("HERDR_SOCKET_PATH=\"$2\""))
        #expect(command.contains("'/home/user/.herdr/herdr.sock'"))
        #expect(command.contains("attach \"$1\" --takeover' mosh 'w1:p1'"))
    }

    @Test func bootstrapCommandOmitsTakeoverWhenNotRequested() throws {
        let command = try HeelerSSHTransport.moshBootstrapCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .agentPane("w1:p1"), takeover: false, cols: 80, rows: 24),
            socketPath: "/home/user/.herdr/herdr.sock")
        #expect(!command.contains("--takeover"))
    }

    @Test func bootstrapCommandRefusesAnUnquotableTarget() {
        #expect(throws: TransportError.self) {
            try HeelerSSHTransport.moshBootstrapCommand(
                agentAttachCommand: "herdr agent attach",
                terminalAttachCommand: "herdr terminal attach",
                request: TerminalAttachRequest(
                    target: .agentPane("w1:p'1"), takeover: false, cols: 80, rows: 24),
                socketPath: "/home/user/.herdr/herdr.sock")
        }
    }

    // MARK: typed mosh failure and transport choice

    @Test func moshSessionFailedCarriesItsDetailAndIsRetryable() {
        let error = TransportError.moshSessionFailed(
            detail: "mosh session failed (exit status 1)")
        #expect(error == .moshSessionFailed(detail: "mosh session failed (exit status 1)"))
        #expect(error.isRetryable)
        #expect(error.presentation.summary == "The mosh session failed")
        #expect(!error.isHostKeySecurityFailure)
    }

    @Test func probeBootstrapCommandWrapsAKeepAliveNotAHerdrAttach() throws {
        let command = try HeelerSSHTransport.moshProbeBootstrapCommand(
            socketPath: "/home/user/.herdr/herdr.sock")
        // A bare command: mosh-server flattens inner quoting when it joins
        // its arguments through the login shell, so anything that needs
        // quotes dies on connect. `sleep 120` survives the join verbatim.
        #expect(command.contains("-- sleep 120"))
        #expect(command.contains("mosh-probe"))
        // The keep-alive must be a bare command, but the OUTER wrapper is
        // itself a `/bin/sh -c '…'` — that occurrence is the wrapper, not
        // the keep-alive.
        #expect(!command.contains("-- sh -c"))
    }

    @Test func invalidationMakesTheTransportChoiceReadSSH() {
        // The runner consults MoshTransportChoice with the Console's
        // availability read; an invalidated probe must read unavailable even
        // though mosh-server exists on the Host.
        #expect(
            MoshTransportChoice.select(availability: true, target: .agentPane("w1:p1"))
                == .mosh)
        #expect(
            MoshTransportChoice.select(availability: false, target: .agentPane("w1:p1"))
                == .ssh)
        #expect(
            MoshTransportChoice.select(availability: true, target: .terminal("t1"))
                == .ssh)
    }
}
