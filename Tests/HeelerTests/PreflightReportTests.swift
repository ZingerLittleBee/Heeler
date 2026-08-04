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
        (.hostKeyRejected(
            presented: HostKeyFingerprint(publicKeyBlob: Data("blob-a".utf8))), .connection),
        (.timedOut, .connection),
        (.cancelled, .connection),
        (.channelFailed(detail: "boom"), .connection),
        (.eventsChannelAlreadyOpen, .connection),
        (.jumpHostFailed(.sshUnreachable(detail: "refused")), .connection),
        (.tcpForwardingUnavailable, .connection),
        (.socketNotFound(path: "/home/dev/.config/herdr/herdr.sock"), .herdrInstalled),
        (.homeDirectoryUnresolvable(detail: "no $HOME"), .remoteEnvironment),
        (.streamLocalOpenFailed(path: "/home/dev/.config/herdr/herdr.sock"), .serverRunning),
        (.protocolVersionMismatch(server: 18, supported: 17), .protocolCompatible),
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
        let passwordReport = PreflightReport.failure(.authenticationFailed, authMethod: .password)
        guard case .failed(let keyHint) = keyReport[.connection],
            case .failed(let passwordHint) = passwordReport[.connection]
        else {
            Issue.record("connection check should fail")
            return
        }
        #expect(keyHint.contains("authorized_keys"))
        #expect(passwordHint.contains("password"))
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
            .protocolVersionMismatch(server: 18, supported: 17), authMethod: .deviceKey)
        guard case .failed(let hint) = report[.protocolCompatible] else {
            Issue.record("protocol check should fail")
            return
        }
        #expect(hint.contains("18"))
        #expect(hint.contains("17"))
    }

    @Test func plainFailureAttachesTheGivenHintToTheGivenCheck() {
        let report = PreflightReport.failure(check: .connection, hint: "no password saved")
        #expect(report[.connection] == .failed(hint: "no password saved"))
        #expect(report[.herdrInstalled] == .blocked)
    }
}
