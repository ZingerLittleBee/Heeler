import Foundation
import Testing

@testable import Heeler

@Suite("Preflight report")
struct PreflightReportTests {
    private let fingerprintA = HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))
    private let fingerprintB = HostKeyFingerprint(publicKeyBlob: Data("blob-b".utf8))

    @Test func successPassesEveryCheck() {
        let report = PreflightReport.allPassed
        for check in PreflightCheck.allCases {
            #expect(report[check] == .passed)
        }
        #expect(report.isFullyPassed)
    }

    @Test func failurePassesEarlierChecksAndBlocksLaterOnes() {
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let report = PreflightReport.failure(
            .socketNotFound(path: socketPath), authMethod: .deviceKey)

        #expect(report[.connection] == .passed)
        #expect(report[.remoteEnvironment] == .passed)
        guard case .failed(let hint) = report[.herdrInstalled] else {
            Issue.record("herdr check should fail")
            return
        }
        #expect(hint.contains(socketPath))
        #expect(report[.serverRunning] == .blocked)
        #expect(report[.protocolCompatible] == .blocked)
        #expect(!report.isFullyPassed)
    }

    /// SSH access plus a running herdr are the whole Host contract now
    /// (ADR 0011): the checklist must not send anyone off to install a helper.
    @Test func theChecklistNeverAsksForSocat() {
        for check in PreflightCheck.allCases {
            #expect(!check.title.localizedCaseInsensitiveContains("socat"))
        }
    }

    @Test func streamLocalFailureGuidesTowardForwardingRatherThanInstallation() {
        let report = PreflightReport.failure(
            .streamLocalOpenFailed(path: "/home/dev/.config/herdr/herdr.sock"),
            authMethod: .deviceKey)
        guard case .failed(let hint) = report[.serverRunning] else {
            Issue.record("server check should fail")
            return
        }
        #expect(hint.localizedCaseInsensitiveContains("stream-local forwarding"))
        #expect(!hint.localizedCaseInsensitiveContains("socat"))
        #expect(!hint.localizedCaseInsensitiveContains("install"))
    }

    @Test(arguments: [
        (TransportError.sshUnreachable(detail: "refused"), PreflightCheck.connection),
        (.authenticationFailed, .connection),
        (.deviceKeyCorrupt, .connection),
        (.rsaKeyCorrupt, .connection),
        (.rsaSignatureUnsupported, .connection),
        (.hostKeyRejected(
            presented: HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))), .connection),
        (.timedOut, .connection),
        // Not reachable from connect+ping; keep the closed taxonomy total.
        (.gitTimedOut, .connection),
        (.cancelled, .connection),
        (.channelFailed(detail: "boom"), .connection),
        (.eventsChannelAlreadyOpen, .connection),
        (.herdrBinaryNotFound, .herdrInstalled),
        (.herdrLauncherNotFound(path: "/opt/example/bin/herdr"), .herdrInstalled),
        (.hostFeatureUnavailable(feature: "Windows requires remote-api-bridge"), .remoteEnvironment),
        (.jumpHostFailed(.sshUnreachable(detail: "refused")), .connection),
        (.tcpForwardingUnavailable, .connection),
        (.socketNotFound(path: "/home/dev/.config/herdr/herdr.sock"), .herdrInstalled),
        (.homeDirectoryUnresolvable(detail: "no $HOME"), .remoteEnvironment),
        (.streamLocalOpenFailed(path: "/home/dev/.config/herdr/herdr.sock"), .serverRunning),
        // Below the floor: the only direction that still produces this error
        // (#140 made a newer server usable rather than a mismatch).
        (.protocolVersionMismatch(server: 16, supported: 17), .protocolCompatible),
        (.malformedResponse("junk"), .protocolCompatible),
    ])
    func mapsEveryTransportErrorOntoItsCheck(error: TransportError, check: PreflightCheck) {
        let report = PreflightReport.failure(error, authMethod: .deviceKey)
        guard case .failed = report[check] else {
            Issue.record("\(error) should fail the \(check) check")
            return
        }
    }

    @Test func hostKeyMismatchHintNamesBothFingerprints() {
        let report = PreflightReport.failure(
            .hostKeyMismatch(known: fingerprintA, presented: fingerprintB), authMethod: .deviceKey)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains(fingerprintA.displayString))
        #expect(hint.contains(fingerprintB.displayString))
    }

    @Test func authenticationHintDependsOnTheAuthMethod() {
        let keyReport = PreflightReport.failure(.authenticationFailed, authMethod: .deviceKey)
        let rsaReport = PreflightReport.failure(.authenticationFailed, authMethod: .rsaKey)
        let passwordReport = PreflightReport.failure(.authenticationFailed, authMethod: .password)
        guard case .failed(let keyHint) = keyReport[.connection],
            case .failed(let rsaHint) = rsaReport[.connection],
            case .failed(let passwordHint) = passwordReport[.connection]
        else {
            Issue.record("connection check should fail")
            return
        }
        #expect(keyHint.contains("authorized_keys"))
        #expect(rsaHint.contains("RSA Key"))
        #expect(rsaHint.contains("SSH identities"))
        #expect(passwordHint.contains("password"))
    }

    @Test func unsupportedRSASignatureIsNotReportedAsARejectedKey() {
        let direct = PreflightReport.failure(.rsaSignatureUnsupported, authMethod: .rsaKey)
        let jump = PreflightReport.failure(
            .jumpHostFailed(.rsaSignatureUnsupported), authMethod: .rsaKey)
        guard case .failed(let directHint) = direct[.connection],
            case .failed(let jumpHint) = jump[.connection]
        else {
            Issue.record("connection check should fail")
            return
        }
        #expect(directHint.contains("rsa-sha2-512"))
        #expect(!directHint.contains("rejected"))
        #expect(jumpHint.contains("Jump Host"))
        #expect(jumpHint.contains("rsa-sha2-512"))
    }

    @Test func jumpHostFailureHintNamesTheFirstHop() {
        let report = PreflightReport.failure(
            .jumpHostFailed(.authenticationFailed), authMethod: .password)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("Jump Host"))
        #expect(hint.contains("same password"))
    }

    @Test func forwardingPolicyHintNamesTheRequiredServerSetting() {
        let report = PreflightReport.failure(
            .tcpForwardingUnavailable, authMethod: .deviceKey)
        guard case .failed(let hint) = report[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("Jump Host"))
        #expect(hint.contains("AllowTcpForwarding"))
    }

    @Test func protocolMismatchHintNamesBothVersions() {
        let report = PreflightReport.failure(
            .protocolVersionMismatch(server: 16, supported: 17), authMethod: .deviceKey)
        guard case .failed(let hint) = report[.protocolCompatible] else {
            Issue.record("protocol check should fail")
            return
        }
        #expect(hint.contains("16"))
        #expect(hint.contains("17"))
    }

    @Test func missingHerdrLauncherFailsHerdrInstalledNamingTheLauncher() {
        let report = PreflightReport.failure(
            .herdrLauncherNotFound(path: "/Users/ada/Library/Application Support/Example/bin/herdr"),
            authMethod: .deviceKey, usesHerdrEndpoint: true)
        #expect(report[.remoteEnvironment] == .passed)
        #expect(
            report[.herdrInstalled]
                == .failed(
                    hint: "The herdr launcher at "
                        + "/Users/ada/Library/Application Support/Example/bin/herdr could not run. "
                        + "Open the app that provides herdr on the Host, or pair the Host again."))
        #expect(report[.serverRunning] == .blocked)
    }

    /// Without an endpoint the socket and protocol hints stay byte for byte
    /// what they were before ADR 0021.
    @Test func hostsWithoutAnEndpointKeepTheirSocketAndProtocolHints() {
        let path = "/home/dev/.config/herdr/herdr.sock"
        let cases: [(TransportError, PreflightCheck, String)] = [
            (
                .socketNotFound(path: path), .herdrInstalled,
                "No herdr socket at \(path). Install and start herdr on the Host, "
                    + "or fix the session name."
            ),
            (
                .streamLocalOpenFailed(path: path), .serverRunning,
                "Could not open the herdr socket at \(path). Start herdr on the Host, "
                    + "or enable SSH stream-local forwarding and run the checks again."
            ),
            (
                .protocolVersionMismatch(server: 16, supported: 17), .protocolCompatible,
                "The Host speaks herdr protocol 16; this app needs at least 17. "
                    + "Update herdr on the Host."
            ),
        ]
        for (error, check, hint) in cases {
            let byDefault = PreflightReport.failure(error, authMethod: .deviceKey)
            let explicit = PreflightReport.failure(
                error, authMethod: .deviceKey, usesHerdrEndpoint: false)
            #expect(byDefault[check] == .failed(hint: hint))
            #expect(explicit[check] == .failed(hint: hint))
        }
    }

    /// An endpoint's socket comes from its Pairing Code, so no session name
    /// or herdr update on the Host can fix it: point at the providing app.
    @Test func endpointHostsPointSocketAndProtocolHintsAtTheProvidingApp() {
        let path = "/Users/ada/Library/Application Support/Example/herdr/herdr.sock"
        let cases: [(TransportError, PreflightCheck, String)] = [
            (
                .socketNotFound(path: path), .herdrInstalled,
                "No herdr socket at \(path). Open the app that provides herdr on the Host, "
                    + "then run the checks again."
            ),
            (
                .streamLocalOpenFailed(path: path), .serverRunning,
                "Could not open the herdr socket at \(path). Open the app that provides "
                    + "herdr on the Host, or enable SSH stream-local forwarding and run the "
                    + "checks again."
            ),
            (
                .protocolVersionMismatch(server: 16, supported: 17), .protocolCompatible,
                "The Host speaks herdr protocol 16; this app needs at least 17. "
                    + "Update the app that provides herdr on the Host."
            ),
        ]
        for (error, check, hint) in cases {
            let report = PreflightReport.failure(
                error, authMethod: .deviceKey, usesHerdrEndpoint: true)
            #expect(report[check] == .failed(hint: hint))
        }
    }

    @Test func plainFailureAttachesTheGivenHintToTheGivenCheck() {
        let report = PreflightReport.failure(check: .connection, hint: "no password saved")
        #expect(report[.connection] == .failed(hint: "no password saved"))
        #expect(report[.herdrInstalled] == .blocked)
    }
}
