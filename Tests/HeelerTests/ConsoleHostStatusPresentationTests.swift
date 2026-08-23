import Foundation
import Testing

@testable import Heeler

@Suite("Console host status presentation")
struct ConsoleHostStatusPresentationTests {
    private let host = Host.fixture(name: "studio")

    @Test func reconnectingRowsUseTheStandaloneSummary() throws {
        let cases: [(TransportError, String)] = [
            (.sshUnreachable(detail: "down"), "SSH unavailable"),
            (.timedOut, "Connection timed out"),
            (.cancelled, "Connection cancelled"),
            (.channelFailed(detail: "reset"), "Connection dropped"),
            (.apiRejected(code: "busy", message: "later"), "herdr rejected the request"),
        ]
        for (failure, summary) in cases {
            let presentation = try #require(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: .reconnecting(attempt: 1, delay: .seconds(1), failure: failure),
                    syncError: nil))
            #expect(presentation.message == "Reconnecting to studio: \(summary)")
            #expect(presentation.systemImage == "wifi.exclamationmark")
            #expect(presentation.severity == .warning)
            #expect(presentation.navigates)
            #expect(presentation.hostName == "studio")
        }
    }

    @Test func aJumpHostOutageNamesTheJumpHostRatherThanConnectionFailed() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .reconnecting(
                    attempt: 2, delay: .seconds(2),
                    failure: .jumpHostFailed(.timedOut)),
                syncError: nil))
        #expect(presentation.message == "Reconnecting to studio: The Jump Host did not answer in time")
        #expect(!presentation.message.contains("connection failed"))
        #expect(presentation.navigates)
        #expect(presentation.severity == .warning)
    }

    @Test func aFailedHostRendersTheWholePresentation() throws {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.systemImage == "exclamationmark.triangle.fill")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func aHostKeyMismatchIsCritical() throws {
        let failure = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
            presented: HostKeyFingerprint(publicKeyBlob: Data("presented".utf8)))
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.systemImage == "exclamationmark.shield.fill")
        #expect(presentation.severity == .critical)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithASyncErrorKeepsTheSnapshotRow() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                syncError: "Could not sync this Host's Agents. Retrying…"))
        #expect(presentation.message == "studio: Could not sync this Host's Agents. Retrying…")
        #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func endedOrUnknownStatusesWithoutASyncErrorProduceNoRow() {
        let quiet: [EventsSessionStatus?] = [.ended, nil]
        for status in quiet {
            #expect(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: status,
                    syncError: nil) == nil)
        }
    }

    @Test func quietConditionRowsAreInformationalAndDoNotNavigate() throws {
        let paused = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .suspended, syncError: nil))
        #expect(paused.message == "Connection to studio is paused.")
        #expect(paused.severity == .informational)
        #expect(!paused.navigates)

        let connecting = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, syncError: nil))
        #expect(connecting.message == "Connecting to studio…")
        #expect(connecting.severity == .informational)
        #expect(!connecting.navigates)

        let loading = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: true,
                syncError: nil))
        #expect(loading.message == "Loading Agents from studio…")
        #expect(loading.severity == .informational)
        #expect(!loading.navigates)
    }

    @Test func connectingWithAStandingFailureLooksLikeFailure() throws {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connecting,
                standingFailure: failure,
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithKnownInventoryAndNoSyncErrorProducesNoRow() {
        #expect(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: false,
                syncError: nil) == nil)
    }
}
