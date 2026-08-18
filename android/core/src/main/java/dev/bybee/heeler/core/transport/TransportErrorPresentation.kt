package dev.bybee.heeler.core.transport

/** User-facing connection guidance with no error-message matching at call sites. */
val TransportError.connectionGuidance: String
    get() = when (this) {
        is TransportError.SshUnreachable -> "SSH unavailable: $detail"
        is TransportError.JumpHostFailed -> "Jump Host: ${underlying.connectionGuidance}"
        TransportError.TcpForwardingUnavailable ->
            "SSH TCP forwarding is disabled. Enable it on the Jump Host."
        TransportError.AuthenticationFailed ->
            "Authentication failed. Update this Host's credentials or authorized key."
        TransportError.DeviceKeyCorrupt ->
            "The Device Key is corrupted. Replace it and install the new public key on the Host."
        is TransportError.HostKeyRejected ->
            "The host key is not trusted. Verify it before reconnecting."
        is TransportError.HostKeyMismatch ->
            "The host key changed. Verify the machine before updating trust."
        is TransportError.SocketNotFound ->
            "The herdr socket was not found. Check this Host's session."
        is TransportError.StreamLocalOpenFailed ->
            "herdr is not running on this Host. If it is running, check SSH stream-local forwarding."
        is TransportError.ProtocolVersionMismatch ->
            "herdr protocol $server is incompatible with app protocol $supported."
        is TransportError.HomeDirectoryUnresolvable ->
            "The remote home directory could not be resolved."
        TransportError.EventsChannelAlreadyOpen,
        TransportError.TerminalChannelAlreadyOpen ->
            "The connection is busy. Close the other terminal before reconnecting."
        TransportError.TimedOut -> "The connection timed out."
        TransportError.Cancelled -> "The connection was cancelled."
        is TransportError.MalformedResponse ->
            "herdr returned an invalid response. Check its version."
        is TransportError.ApiRejected -> "herdr rejected the request: $serverMessage"
        is TransportError.ChannelFailed -> "The connection failed: $detail"
    }
