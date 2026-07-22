import Foundation
import Testing

@testable import HerdrMobile

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
        let report = PreflightReport.failure(
            .socatMissing(path: "/usr/bin/socat"), authMethod: .deviceKey)

        #expect(report[.connection] == .passed)
        #expect(report[.remoteEnvironment] == .passed)
        guard case .failed(let hint) = report[.socat] else {
            Issue.record("socat check should fail")
            return
        }
        #expect(hint.contains("/usr/bin/socat"))
        #expect(report[.herdrInstalled] == .blocked)
        #expect(report[.serverRunning] == .blocked)
        #expect(report[.protocolCompatible] == .blocked)
        #expect(!report.isFullyPassed)
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
        (.socatMissing(path: "/usr/bin/socat"), .socat),
        (.socketNotFound(path: "/home/dev/.config/herdr/herdr.sock"), .herdrInstalled),
        (.homeDirectoryUnresolvable(detail: "no $HOME"), .remoteEnvironment),
        (.serverNotRunning(path: "/home/dev/.config/herdr/herdr.sock"), .serverRunning),
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
        #expect(report[.socat] == .blocked)
    }
}
