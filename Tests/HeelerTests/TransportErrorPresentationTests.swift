import Foundation
import Testing

@testable import Heeler

struct TransportErrorPresentationTests {
    private static let homebrewPATH =
        "Homebrew installs are often at /opt/homebrew/bin or /home/linuxbrew/.linuxbrew/bin — "
        + "put that directory on the account's non-interactive PATH, "
        + "or symlink herdr into ~/.local/bin."

    private static let socketGuidance =
        "herdr is not running on this Host. If it is running, check SSH stream-local forwarding."

    private static let knownKey = HostKeyFingerprint(
        digest: Data(repeating: 0x11, count: 32), algorithm: "ssh-ed25519")
    private static let presentedKey = HostKeyFingerprint(
        digest: Data(repeating: 0x22, count: 32), algorithm: "ssh-ed25519")

    // MARK: Byte-identical messages

    @Test func streamLocalOpenFailureRecomposesByteIdentically() {
        let presentation = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
            .presentation
        #expect(presentation.message == Self.socketGuidance)
        #expect(presentation.summary == "herdr is not running on this Host")
        #expect(presentation.detail == nil)
        #expect(
            presentation.recoverySuggestion
                == "If it is running, check SSH stream-local forwarding.")
    }

    @Test func theEightUnchangedMessagesRecomposeByteForByte() {
        let cases: [(TransportError, String)] = [
            (
                .streamLocalOpenFailed(path: "/tmp/herdr.sock"),
                Self.socketGuidance
            ),
            (
                .authenticationFailed,
                "Authentication failed. Update this Host's credentials or authorized key."
            ),
            (
                .herdrBinaryNotFound,
                "herdr is not on this Host's SSH PATH. \(Self.homebrewPATH)"
            ),
            (
                .tcpForwardingUnavailable,
                "SSH TCP forwarding is disabled. Enable it on the Jump Host."
            ),
            (
                .deviceKeyCorrupt,
                "The Device Key is corrupted. Replace it and install the new public key on the Host."
            ),
            (
                .hostKeyRejected(presented: Self.presentedKey),
                "The host key is not trusted. Verify it before reconnecting."
            ),
            (
                .hostKeyMismatch(known: Self.knownKey, presented: Self.presentedKey),
                "The host key changed. Verify the machine before updating trust."
            ),
            (
                .eventsChannelAlreadyOpen,
                "The connection is busy. Close the other terminal before reconnecting."
            ),
            (
                .terminalChannelAlreadyOpen,
                "The connection is busy. Close the other terminal before reconnecting."
            ),
        ]
        for (error, expected) in cases {
            #expect(error.presentation.message == expected)
        }
    }

    // MARK: Retryable set

    @Test func retryableSummariesAndSuggestions() {
        let unreachable = TransportError.sshUnreachable(detail: "connection refused")
        #expect(unreachable.presentation.summary == "SSH unavailable")
        #expect(unreachable.presentation.detail == "connection refused")
        #expect(
            unreachable.presentation.recoverySuggestion
                == "Check that the Host is awake and reachable, then verify its address and port.")

        #expect(TransportError.timedOut.presentation.summary == "Connection timed out")
        #expect(TransportError.timedOut.presentation.detail == nil)
        #expect(TransportError.timedOut.presentation.recoverySuggestion == nil)

        #expect(TransportError.cancelled.presentation.summary == "Connection cancelled")
        #expect(TransportError.cancelled.presentation.recoverySuggestion == nil)

        let dropped = TransportError.channelFailed(detail: "connection reset")
        #expect(dropped.presentation.summary == "Connection dropped")
        #expect(dropped.presentation.detail == "connection reset")
        #expect(dropped.presentation.recoverySuggestion == nil)

        let rejected = TransportError.apiRejected(
            code: "pane_not_found", message: "pane w11:p9 not found")
        #expect(rejected.presentation.summary == "herdr rejected the request")
        #expect(rejected.presentation.detail == "pane w11:p9 not found (pane_not_found)")
        #expect(rejected.presentation.recoverySuggestion == nil)
    }

    @Test func onlyUnreachableAmongRetryableCasesNamesAnAction() {
        let retryable: [TransportError] = [
            .sshUnreachable(detail: "down"),
            .timedOut,
            .cancelled,
            .channelFailed(detail: "reset"),
            .apiRejected(code: "busy", message: "try later"),
            .jumpHostFailed(.sshUnreachable(detail: "down")),
            .jumpHostFailed(.timedOut),
            .jumpHostFailed(.cancelled),
            .jumpHostFailed(.channelFailed(detail: "reset")),
            .jumpHostFailed(.apiRejected(code: "busy", message: "try later")),
        ]
        for error in retryable {
            let hasSuggestion = error.presentation.recoverySuggestion != nil
            let shouldSuggest: Bool
            switch error {
            case .sshUnreachable, .jumpHostFailed(.sshUnreachable):
                shouldSuggest = true
            default:
                shouldSuggest = false
            }
            #expect(hasSuggestion == shouldSuggest)
        }
    }

    // MARK: Jump Host

    @Test func jumpHostMappingIsTargetAware() {
        let cases: [(TransportError, String, String?, String?)] = [
            (
                .jumpHostFailed(.sshUnreachable(detail: "refused")),
                "Jump Host unavailable",
                "refused",
                "Check that the Jump Host is awake and reachable, then verify its address and port."
            ),
            (
                .jumpHostFailed(.authenticationFailed),
                "The Jump Host rejected authentication",
                nil,
                "Update the Jump Host's credentials or authorized key."
            ),
            (
                .jumpHostFailed(.hostKeyRejected(presented: Self.presentedKey)),
                "The Jump Host's key is not trusted",
                nil,
                "Verify it before reconnecting."
            ),
            (
                .jumpHostFailed(
                    .hostKeyMismatch(known: Self.knownKey, presented: Self.presentedKey)),
                "The Jump Host's key changed",
                nil,
                "Verify the machine before updating trust."
            ),
            (
                .jumpHostFailed(.tcpForwardingUnavailable),
                "SSH TCP forwarding is disabled on the Jump Host",
                nil,
                "Enable it on the Jump Host."
            ),
            (
                .jumpHostFailed(.timedOut),
                "The Jump Host did not answer in time",
                nil,
                nil
            ),
            (
                .jumpHostFailed(.cancelled),
                "Jump Host connection cancelled",
                nil,
                nil
            ),
            (
                .jumpHostFailed(.channelFailed(detail: "reset")),
                "The Jump Host connection dropped",
                "reset",
                nil
            ),
            (
                .jumpHostFailed(.deviceKeyCorrupt),
                "The Device Key is corrupted",
                nil,
                "Replace it and install the new public key on the Host."
            ),
        ]
        for (error, summary, detail, suggestion) in cases {
            #expect(error.presentation.summary == summary)
            #expect(error.presentation.detail == detail)
            #expect(error.presentation.recoverySuggestion == suggestion)
        }
    }

    @Test func jumpHostAuthenticationDoesNotTellTheUserToFixTheHost() {
        let presentation = TransportError.jumpHostFailed(.authenticationFailed).presentation
        #expect(!presentation.message.contains("this Host's credentials"))
        #expect(presentation.message.contains("Jump Host"))
    }

    @Test func jumpHostFallbackDropsAnUnretargetedSuggestion() {
        let fallbacks: [TransportError] = [
            .socketNotFound(path: "/tmp/herdr.sock"),
            .streamLocalOpenFailed(path: "/tmp/herdr.sock"),
            .herdrBinaryNotFound,
            .protocolVersionMismatch(server: 18, supported: 19),
            .homeDirectoryUnresolvable(detail: "echo $HOME failed"),
            .malformedResponse("{"),
            .apiRejected(code: "busy", message: "try later"),
            .eventsChannelAlreadyOpen,
            .terminalChannelAlreadyOpen,
        ]
        for underlying in fallbacks {
            let presentation = TransportError.jumpHostFailed(underlying).presentation
            #expect(presentation.summary == "Jump Host: \(underlying.presentation.summary)")
            #expect(presentation.detail == underlying.presentation.detail)
            #expect(presentation.recoverySuggestion == nil)
        }
    }

    @Test func nestedJumpHostFailureCollapsesRatherThanStackingPrefixes() {
        let inner = TransportError.jumpHostFailed(.authenticationFailed)
        let presentation = TransportError.jumpHostFailed(inner).presentation
        #expect(presentation.summary == "The Jump Host rejected authentication")
        #expect(!presentation.summary.contains("Jump Host: Jump Host"))
    }

    // MARK: Non-retryable copy that gained detail

    @Test func socketNotFoundIncludesThePath() {
        let presentation = TransportError.socketNotFound(path: "/tmp/herdr.sock").presentation
        #expect(presentation.summary == "The herdr socket was not found")
        #expect(presentation.detail == "/tmp/herdr.sock")
        #expect(presentation.recoverySuggestion == "Check this Host's session.")
        #expect(
            presentation.message
                == "The herdr socket was not found: /tmp/herdr.sock. Check this Host's session.")
    }

    @Test func protocolVersionMismatchNamesTheUpdate() {
        let presentation = TransportError.protocolVersionMismatch(server: 18, supported: 19)
            .presentation
        #expect(presentation.summary == "Incompatible herdr protocol")
        #expect(presentation.detail == "herdr speaks protocol 18; this app needs at least 19")
        #expect(presentation.recoverySuggestion == "Update herdr on the Host.")
        #expect(
            presentation.message
                == "Incompatible herdr protocol: herdr speaks protocol 18; this app needs at least 19. "
                + "Update herdr on the Host.")
    }

    @Test func homeDirectoryAndMalformedResponsePreserveDetail() {
        let home = TransportError.homeDirectoryUnresolvable(detail: "echo $HOME failed")
            .presentation
        #expect(home.summary == "The remote home directory could not be resolved")
        #expect(home.detail == "echo $HOME failed")
        #expect(home.recoverySuggestion == nil)
        #expect(
            home.message
                == "The remote home directory could not be resolved: echo $HOME failed.")

        let malformed = TransportError.malformedResponse("{not-json}").presentation
        #expect(malformed.summary == "herdr returned an invalid response")
        #expect(malformed.detail == "{not-json}")
        #expect(malformed.recoverySuggestion == "Check its version.")
        #expect(
            malformed.message
                == "herdr returned an invalid response: {not-json}. Check its version.")
    }

    // MARK: Composed views

    @Test func explanationNeverContainsARecoverySuggestion() {
        let errors: [TransportError] = [
            .sshUnreachable(detail: "down"),
            .timedOut,
            .cancelled,
            .channelFailed(detail: "reset"),
            .apiRejected(code: "busy", message: "later"),
            .jumpHostFailed(.sshUnreachable(detail: "down")),
            .jumpHostFailed(.authenticationFailed),
            .authenticationFailed,
            .streamLocalOpenFailed(path: "/s"),
            .protocolVersionMismatch(server: 18, supported: 19),
            .herdrBinaryNotFound,
            .socketNotFound(path: "/s"),
        ]
        for error in errors {
            let presentation = error.presentation
            #expect(presentation.explanation.hasSuffix("."))
            if let suggestion = presentation.recoverySuggestion {
                #expect(!presentation.explanation.contains(suggestion))
                #expect(presentation.message == "\(presentation.explanation) \(suggestion)")
            } else {
                #expect(presentation.message == presentation.explanation)
            }
        }
    }

    @Test func changedRetryableMessagesMatchTheApprovedWording() {
        #expect(
            TransportError.sshUnreachable(detail: "down").presentation.message
                == "SSH unavailable: down. Check that the Host is awake and reachable, then verify its address and port.")
        #expect(TransportError.timedOut.presentation.message == "Connection timed out.")
        #expect(TransportError.cancelled.presentation.message == "Connection cancelled.")
        #expect(
            TransportError.channelFailed(detail: "reset").presentation.message
                == "Connection dropped: reset.")
        #expect(
            TransportError.apiRejected(code: "pane_not_found", message: "gone").presentation.message
                == "herdr rejected the request: gone (pane_not_found).")
    }
}
