/// What one `TransportError` is allowed to say: a Summary, an optional Detail
/// carrying the error's own words, and an optional Recovery Suggestion.
/// See Transport Error Presentation in `CONTEXT.md`.
struct TransportErrorPresentation: Equatable, Sendable {
    /// Short, stable, standalone. No trailing period. Safe on an ambient
    /// surface while automatic recovery is running.
    let summary: String
    /// The error's own interpolated text — a transport detail string, or
    /// herdr's code and message. Never authored instruction.
    let detail: String?
    /// Present only when the error itself supports a safe next step.
    let recoverySuggestion: String?

    /// `summary` [+ ": " + `detail`] + "." — what happened, no instruction.
    /// A detail that already ends its sentence, with a closing mark of its
    /// script or an ellipsis where it was cut short, gets no second one. The
    /// joining formats are catalog entries, so a locale closes the sentence
    /// with its own mark: Japanese ends it with "。".
    var explanation: String {
        if let detail {
            return detail.endsSentence
                ? String(localized: "\(summary): \(detail)")
                : String(localized: "\(summary): \(detail).")
        }
        return summary.asSentence
    }

    /// `explanation` [+ " " + `recoverySuggestion`] — the whole presentation.
    var message: String {
        if let recoverySuggestion {
            return "\(explanation) \(recoverySuggestion)"
        }
        return explanation
    }
}

extension TransportError {
    /// A core stopped or replaced with SSH still up, in the words every surface
    /// shares. Nil for any other error, whose surface keeps its own copy.
    static func herdrCoreLinkMessage(for error: any Error) -> String? {
        guard let transportError = error as? TransportError else { return nil }
        switch transportError {
        case .herdrCoreNotRunning, .herdrCoreInventoryStale, .herdrCoreTerminalGone:
            return transportError.presentation.message
        default: return nil
        }
    }

    var presentation: TransportErrorPresentation {
        switch self {
        case .hostFeatureUnavailable(let feature):
            TransportErrorPresentation(
                summary: String(localized: "This feature is unavailable on the Host"), detail: feature,
                recoverySuggestion: nil)
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: String(localized: "SSH unavailable"),
                detail: detail,
                recoverySuggestion:
                    String(localized: "Check that the Host is awake and reachable, then verify its address and port."))
        case .jumpHostFailed(let underlying):
            Self.jumpHostPresentation(underlying)
        case .overlayFailed(let network, let reason):
            Self.overlayPresentation(network: network, reason: reason)
        case .noRouteReached(let failures):
            Self.noRouteReachedPresentation(failures)
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: String(localized: "SSH TCP forwarding is disabled"),
                detail: nil,
                recoverySuggestion: String(localized: "Enable it on the Jump Host."))
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: String(localized: "Authentication failed"),
                detail: nil,
                recoverySuggestion: String(localized: "Update this Host's credentials or authorized key."))
        case .deviceKeyCorrupt:
            TransportErrorPresentation(
                summary: String(localized: "The Device Key is corrupted"),
                detail: nil,
                recoverySuggestion:
                    String(localized: "Replace it and install the new public key on the Host."))
        case .rsaKeyCorrupt:
            TransportErrorPresentation(
                summary: String(localized: "The RSA Key is corrupted"),
                detail: nil,
                recoverySuggestion:
                    String(localized: "Replace it and register the new public key on every Host that uses it."))
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: String(localized: "The Host does not accept RSA-SHA2-512"),
                detail: nil,
                recoverySuggestion:
                    String(localized:
                        "Enable rsa-sha2-512 signatures on the Host, or choose another authentication method."))
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: String(localized: "The host key is not trusted"),
                detail: nil,
                recoverySuggestion: String(localized: "Verify it before reconnecting."))
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: String(localized: "The host key changed"),
                detail: nil,
                recoverySuggestion: String(localized: "Verify the machine before updating trust."))
        case .socketNotFound(let path):
            TransportErrorPresentation(
                summary: String(localized: "The herdr socket was not found"),
                detail: path,
                recoverySuggestion: String(localized: "Check this Host's session."))
        case .herdrBinaryNotFound:
            TransportErrorPresentation(
                summary: String(localized: "herdr is not on this Host's SSH PATH"),
                detail: nil,
                recoverySuggestion:
                    String(localized:
                        "Put herdr's install directory on the account's non-interactive SSH PATH."))
        case .herdrLauncherNotFound(let path):
            TransportErrorPresentation(
                summary: String(localized: "The herdr launcher could not run"),
                detail: path,
                recoverySuggestion:
                    String(localized:
                        "Check that this launcher exists, is executable, and can start herdr. Pair the Host again if its path changed."))
        case .streamLocalOpenFailed:
            TransportErrorPresentation(
                summary: String(localized: "herdr is not running on this Host"),
                detail: nil,
                recoverySuggestion: String(localized: "If it is running, check SSH stream-local forwarding."))
        case .protocolVersionMismatch(let server, let supported):
            TransportErrorPresentation(
                summary: String(localized: "Incompatible herdr protocol"),
                detail: String(localized:
                    "herdr speaks protocol \(server); this app needs at least \(supported)"),
                recoverySuggestion: String(localized: "Update herdr on the Host."))
        case .homeDirectoryUnresolvable(let detail):
            TransportErrorPresentation(
                summary: String(localized: "The remote home directory could not be resolved"),
                detail: detail,
                recoverySuggestion: nil)
        case .invalidDirectoryPath(let path):
            TransportErrorPresentation(
                summary: String(localized: "That folder path cannot be opened"),
                detail: path,
                recoverySuggestion:
                    String(localized: "Pick a folder from the list instead of typing a path."))
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            TransportErrorPresentation(
                summary: String(localized: "The connection is busy"),
                detail: nil,
                recoverySuggestion:
                    String(localized: "Close the other terminal before reconnecting."))
        case .timedOut:
            TransportErrorPresentation(
                summary: String(localized: "Connection timed out"),
                detail: nil,
                recoverySuggestion: nil)
        case .coreMutationOutcomeUnknown:
            TransportErrorPresentation(
                summary: String(localized: "The Host did not confirm the action"),
                detail: String(localized: "It may still complete. Check the Terminal before trying again."),
                recoverySuggestion: nil)
        case .herdrCoreInventoryStale:
            TransportErrorPresentation(
                summary: String(localized: "The Host's Terminals are being read again"),
                detail: String(localized: "Nothing was sent"),
                recoverySuggestion: String(localized: "Try again once they are back."))
        case .herdrCoreTerminalGone:
            TransportErrorPresentation(
                summary: String(localized: "This Terminal belongs to a core that is gone"),
                detail: String(localized: "Nothing was sent"),
                recoverySuggestion: String(localized: "Open it again from the list."))
        case .herdrCoreNotInstalled:
            TransportErrorPresentation(
                summary: String(localized: "herdr-core is not installed"),
                detail: String(localized:
                    "It is not on the SSH PATH or at ~/.local/bin/herdr-core, or where its installer puts it on native Windows"),
                recoverySuggestion: String(localized: "Install herdr-core on the Host, then check again."))
        case .herdrCoreNotRunning(let socketPath, _) where HerdrCoreLocator.isWindowsPipe(socketPath):
            TransportErrorPresentation(
                summary: String(localized: "herdr-core is not running"),
                detail: String(localized: "The named pipe \(socketPath) does not exist"),
                recoverySuggestion:
                    String(localized:
                        "Start the core on that machine in your desktop session, in a PowerShell window not run as administrator. Heeler keeps checking."))
        case .herdrCoreNotRunning(let socketPath, let socketFilePresent):
            socketFilePresent
                ? TransportErrorPresentation(
                    summary: String(localized: "herdr-core is not running"),
                    detail: String(localized:
                        "A socket file is left at \(socketPath): a core stopped or crashed, or the SSH server refuses socket forwarding"),
                    recoverySuggestion:
                        String(localized:
                            "Start the core on the Host, or allow stream-local forwarding in its SSH server, then check again."))
                : TransportErrorPresentation(
                    summary: String(localized: "herdr-core is not running"),
                    detail: String(localized: "Nothing is listening at \(socketPath)"),
                    recoverySuggestion: String(localized: "Start the core on the Host, then check again."))
        case .herdrCoreForwardingRefused(let socketPath):
            TransportErrorPresentation(
                summary: String(localized: "The SSH server refuses socket forwarding"),
                detail: String(localized: "herdr-core is running, but SSH will not open \(socketPath)"),
                recoverySuggestion:
                    String(localized:
                        "Allow stream-local forwarding in the Host's SSH server, then check again."))
        case .herdrCoreUpdateRequired(let command):
            TransportErrorPresentation(
                summary: String(localized: "herdr-core needs an update"),
                detail: String(localized: "This core lacks what the app needs"),
                recoverySuggestion: String(localized: "Run \(command) on the Host, then check again."))
        case .herdrCoreSocketPathTooLong(let path, let limit):
            TransportErrorPresentation(
                summary: String(localized: "The herdr-core socket path is too long"),
                detail: String(localized: "\(path) is over this Host's limit of \(limit) bytes"),
                recoverySuggestion:
                    String(localized:
                        "Use a shorter core session name, or set a shorter socket in the core's config."))
        case .herdrCoreSessionNameRefused(let reason):
            TransportErrorPresentation(
                summary: String(localized: "This session name can't be used"),
                detail: Self.droppingTrailingPeriods(reason),
                recoverySuggestion: String(localized: "Edit the Host's session name."))
        case .gitTimedOut:
            TransportErrorPresentation(
                summary: String(localized: "Reading Changes timed out"),
                detail: nil,
                recoverySuggestion: nil)
        case .hostFileTimedOut:
            TransportErrorPresentation(
                summary: String(localized: "Reading the conversation timed out"),
                detail: nil,
                recoverySuggestion: nil)
        case .hostFileUnreadable(let status):
            TransportErrorPresentation(
                summary: String(localized: "The conversation file cannot be read"),
                detail: String(localized: "SFTP status \(status)"),
                recoverySuggestion: String(localized: "Check the file's permissions on the Host."))
        case .hostStoreUnreadable(let detail):
            // A whole sentence explains itself. A reader's own line cut
            // short keeps its ellipsis rather than gaining a period.
            detail.hasSuffix("…")
                ? TransportErrorPresentation(
                    summary: String(localized: "OpenCode's database couldn't be read"), detail: detail,
                    recoverySuggestion: nil)
                : TransportErrorPresentation(
                    summary: Self.droppingTrailingPeriods(detail), detail: nil,
                    recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: String(localized: "Connection cancelled"),
                detail: nil,
                recoverySuggestion: nil)
        case .malformedResponse(let payload):
            TransportErrorPresentation(
                summary: String(localized: "herdr returned an invalid response"),
                detail: payload,
                recoverySuggestion: String(localized: "Check its version."))
        case .apiRejected(let code, let message):
            TransportErrorPresentation(
                summary: String(localized: "herdr rejected the request"),
                detail: "\(message) (\(code))",
                recoverySuggestion: nil)
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Connection dropped"),
                detail: Self.displayedChannelDetail(detail),
                recoverySuggestion: nil)
        case .attachExited(let status, let output):
            TransportErrorPresentation(
                summary: String(localized: "herdr exited with status \(status)"),
                detail: output.map(Self.droppingTrailingPeriods).flatMap {
                    $0.isEmpty ? nil : $0
                },
                recoverySuggestion: nil)
        }
    }

    /// `presentation` for a Host. An endpoint Host's socket comes from its
    /// Pairing Code (ADR 0023): no session setting can bring a missing one
    /// back; recovery targets the configured instance.
    func presentation(usesHerdrEndpoint: Bool) -> TransportErrorPresentation {
        let shared: TransportErrorPresentation = presentation
        guard usesHerdrEndpoint, case .socketNotFound = self else { return shared }
        return TransportErrorPresentation(
            summary: shared.summary, detail: shared.detail,
            recoverySuggestion:
                String(localized: "Start the herdr instance configured for this Host and verify its socket path."))
    }

    /// A `channelFailed` detail as the user reads it.
    /// ``HerdrCoreLink/closedDetail`` stays a plain token because
    /// `HerdrCoreSSHTransport` matches on it, so it is localized here, where
    /// it is shown, rather than where it is thrown.
    static func displayedChannelDetail(_ detail: String) -> String {
        detail == HerdrCoreLink.closedDetail
            ? String(localized: "The herdr-core link closed.") : detail
    }

    /// herdr's own sentence, or a localized detail, may already end in a
    /// full stop of its script; `explanation` supplies the closing one. A
    /// question or exclamation mark stays, since it says something.
    private static func droppingTrailingPeriods(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.unicodeScalars.last, isFullStop(last) { text = text.dropLast() }
        return String(text)
    }

    private static func isFullStop(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isSentenceTerminal, let name = scalar.properties.name else { return false }
        return !name.contains("QUESTION") && !name.contains("EXCLAMATION") && name != "INTERROBANG"
    }

    /// A changed host key is a security refusal, not an ordinary outage.
    /// Nested first-hop failures keep that classification: a Jump Host key
    /// change is still a host-key refusal.
    var isHostKeySecurityFailure: Bool {
        switch self {
        case .hostKeyMismatch: true
        case .jumpHostFailed(let underlying): underlying.isHostKeySecurityFailure
        // A LAN address answered by another machine away from home is
        // expected while another route is down, so its changed key counts
        // only when every route failed on its key. Any other route's changed
        // key counts on its own.
        case .noRouteReached(let failures):
            (!failures.isEmpty && failures.allSatisfy(\.error.isHostKeySecurityFailure))
                || failures.contains(where: \.isHostKeySecurityFailure)
        default: false
        }
    }

    /// Every route's own failure, in order. A changed key that counts as a
    /// security failure leads, as it would for a Host with one route, so it
    /// does not read as an ordinary outage.
    private static func noRouteReachedPresentation(
        _ failures: [RouteFailure]
    ) -> TransportErrorPresentation {
        let detail = failures.map { "\($0.route): \($0.error.presentation.summary)" }
            .joined(separator: "; ")
        if let changed = failures.first(where: \.isHostKeySecurityFailure) {
            let presentation = changed.error.presentation
            return TransportErrorPresentation(
                summary: presentation.summary,
                detail: detail,
                recoverySuggestion: presentation.recoverySuggestion)
        }
        return TransportErrorPresentation(
            summary: String(localized: "No route reached the Host"),
            detail: detail,
            recoverySuggestion:
                String(localized: "Check that the Host is awake, then review its routes."))
    }

    /// Overlay failures name the network, not the Host: the Host was never
    /// contacted, and the fix lives in Settings › Overlay Networks.
    private static func overlayPresentation(
        network: String, reason: OverlayFailure
    ) -> TransportErrorPresentation {
        switch reason {
        case .notConfigured:
            TransportErrorPresentation(
                summary: String(localized: "This Host's overlay network no longer exists"),
                detail: nil,
                recoverySuggestion: String(localized: "Choose another network in Edit Host."))
        case .catalogUnreadable:
            TransportErrorPresentation(
                summary: String(localized: "The saved overlay networks could not be read"),
                detail: nil,
                recoverySuggestion: String(localized: "Update Heeler, then reconnect."))
        case .notReady(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Overlay network “\(network)” is not ready yet"),
                detail: detail,
                recoverySuggestion:
                    String(localized:
                        "If it is waiting for approval, authorize this device in the network's admin console."))
        case .misconfigured(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Overlay network “\(network)” is misconfigured"),
                detail: detail,
                recoverySuggestion: String(localized: "Fix it in Settings › Overlay Networks."))
        case .loginRequired:
            TransportErrorPresentation(
                summary: String(localized: "Overlay network “\(network)” needs sign-in"),
                detail: nil,
                recoverySuggestion: String(localized: "Sign in from Settings › Overlay Networks."))
        case .signedOut:
            TransportErrorPresentation(
                summary: String(localized: "This device is signed out of overlay network “\(network)”"),
                detail: nil,
                recoverySuggestion: String(localized: "Connect it again in Settings › Overlay Networks."))
        case .startFailed(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Overlay network “\(network)” could not start"),
                detail: detail,
                recoverySuggestion:
                    String(localized: "Check its settings in Settings › Overlay Networks."))
        case .unreachable(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Unreachable over overlay network “\(network)”"),
                detail: detail,
                recoverySuggestion:
                    String(localized:
                        "Check that the machine has joined the network, then verify its overlay address and port."))
        case .timedOut:
            TransportErrorPresentation(
                summary: String(localized: "Overlay network “\(network)” did not answer in time"),
                detail: nil,
                recoverySuggestion: nil)
        }
    }

    private static func jumpHostPresentation(
        _ underlying: TransportError
    ) -> TransportErrorPresentation {
        switch underlying {
        case .hostFeatureUnavailable:
            underlying.presentation
        case .jumpHostFailed:
            underlying.presentation
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: String(localized: "Jump Host unavailable"),
                detail: detail,
                recoverySuggestion:
                    String(localized:
                        "Check that the Jump Host is awake and reachable, then verify its address and port."))
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host rejected authentication"),
                detail: nil,
                recoverySuggestion:
                    String(localized: "Update the Jump Host's credentials or authorized key."))
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host's key is not trusted"),
                detail: nil,
                recoverySuggestion: String(localized: "Verify it before reconnecting."))
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host's key changed"),
                detail: nil,
                recoverySuggestion: String(localized: "Verify the machine before updating trust."))
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: String(localized: "SSH TCP forwarding is disabled on the Jump Host"),
                detail: nil,
                recoverySuggestion: String(localized: "Enable it on the Jump Host."))
        case .timedOut:
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host did not answer in time"),
                detail: nil,
                recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: String(localized: "Jump Host connection cancelled"),
                detail: nil,
                recoverySuggestion: nil)
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host connection dropped"),
                detail: Self.displayedChannelDetail(detail),
                recoverySuggestion: nil)
        case .deviceKeyCorrupt, .rsaKeyCorrupt:
            underlying.presentation
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: String(localized: "The Jump Host does not accept RSA-SHA2-512"),
                detail: nil,
                recoverySuggestion:
                    String(localized:
                        "Enable rsa-sha2-512 signatures on the Jump Host, or choose another authentication method."))
        default:
            TransportErrorPresentation(
                summary: String(localized: "Jump Host: \(underlying.presentation.summary)"),
                detail: underlying.presentation.detail,
                recoverySuggestion: nil)
        }
    }
}
