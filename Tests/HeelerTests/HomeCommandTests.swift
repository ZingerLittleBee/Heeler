import CryptoKit
import Foundation
import Testing

@testable import Heeler

// The home probe's answer becomes a component of every home-relative socket
// path, and it reaches the Host through the login shell, whose dialect is
// unknown. nushell does not expand `$HOME` inside double quotes, so a bare
// probe prints the marker literally and home resolution fails (#275). The
// default re-dispatches through /bin/sh, like the stage-directory and
// agent-discovery probes, so the wire always speaks one shell dialect.
@Suite("Home command")
struct HomeCommandTests {
    @Test func defaultHomeCommandRunsUnderPOSIXShell() {
        let settings = SSHTransportSettings(
            host: "example.invalid",
            port: 22,
            username: "u",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)

        #expect(
            settings.homeCommand
                == "/bin/sh -c 'printf \"__HEELER_HOME__=%s\\n\" \"$HOME\"'")
    }
}
