extension TransportError {
    var connectionGuidance: String {
        switch self {
        case .sshUnreachable(let detail):
            "SSH unavailable: \(detail)"
        case .jumpHostFailed(let underlying):
            "Jump Host: \(underlying.connectionGuidance)"
        case .tcpForwardingUnavailable:
            "SSH TCP forwarding is disabled. Enable it on the Jump Host."
        case .authenticationFailed:
            "Authentication failed. Update this Host's credentials or authorized key."
        case .deviceKeyCorrupt:
            "The Device Key is corrupted. Replace it and install the new public key on the Host."
        case .hostKeyRejected:
            "The host key is not trusted. Verify it before reconnecting."
        case .hostKeyMismatch:
            "The host key changed. Verify the machine before updating trust."
        case .socketNotFound:
            "The herdr socket was not found. Check this Host's session."
        case .streamLocalOpenFailed:
            "herdr is not running on this Host. If it is running, check SSH stream-local forwarding."
        case .protocolVersionMismatch(let server, let supported):
            "herdr protocol \(server) is incompatible with app protocol \(supported)."
        case .homeDirectoryUnresolvable:
            "The remote home directory could not be resolved."
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            "The connection is busy. Close the other terminal before reconnecting."
        case .timedOut:
            "The connection timed out."
        case .cancelled:
            "The connection was cancelled."
        case .malformedResponse:
            "herdr returned an invalid response. Check its version."
        case .apiRejected(_, let message):
            "herdr rejected the request: \(message)"
        case .sftpUnavailable:
            "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem."
        case .channelFailed(let detail):
            "The connection failed: \(detail)"
        }
    }
}
