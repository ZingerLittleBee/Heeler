import CLibSSH2
import CHeelerSSHSupport
import Darwin
import Foundation

actor SessionDriver {
    static let hostKeyAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp521",
        "rsa-sha2-512",
        "rsa-sha2-256",
    ]

    private static let hostKeyPreference = hostKeyAlgorithms.joined(separator: ",")

    private static let keyExchangePreference = [
        "curve25519-sha256",
        "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp384",
        "ecdh-sha2-nistp256",
        "ecdh-sha2-nistp521",
        "diffie-hellman-group18-sha512",
        "diffie-hellman-group16-sha512",
        "diffie-hellman-group14-sha256",
        "diffie-hellman-group-exchange-sha256",
    ].joined(separator: ",")

    private static let cipherPreference = [
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com",
        "aes128-gcm@openssh.com",
        "aes256-ctr",
        "aes192-ctr",
        "aes128-ctr",
    ].joined(separator: ",")

    private static let macPreference = [
        "hmac-sha2-512-etm@openssh.com",
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512",
        "hmac-sha2-256",
    ].joined(separator: ",")

    private var session: OpaquePointer?
    private var descriptor: Int32 = -1
    private var authenticated = false
    private var valid = true
    private var forwarding = false

    // Actor reentrancy would otherwise allow a second task to call libssh2
    // while the first one is suspended on socket readiness.
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    func handshake(endpoint: SSHEndpoint, timeout: Duration) async throws -> SSHHostKey {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, session == nil, descriptor < 0 else {
            throw SSHError.connectionInvalidated
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        do {
            descriptor = try await SocketConnector.connect(to: endpoint, until: deadline)
            return try await performHandshake(deadline: deadline)
        } catch {
            invalidateResources()
            throw normalize(error)
        }
    }

    func handshake(
        transport: any SSHByteTransport,
        timeout: Duration
    ) async throws -> SSHHostKey {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, session == nil, descriptor < 0 else {
            throw SSHError.connectionInvalidated
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        do {
            descriptor = try transport.takeDescriptor()
            return try await performHandshake(deadline: deadline)
        } catch {
            invalidateResources()
            throw normalize(error)
        }
    }

    func authenticate(username: String, password: String, timeout: Duration) async throws {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, !authenticated, let session else {
            throw SSHError.connectionInvalidated
        }
        guard !username.isEmpty else { throw SSHError.authenticationFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        do {
            let result = try await repeatUntilComplete(deadline: deadline) {
                username.withCString { usernamePointer in
                    password.withCString { passwordPointer in
                        libssh2_userauth_password_ex(
                            session,
                            usernamePointer,
                            UInt32(username.utf8.count),
                            passwordPointer,
                            UInt32(password.utf8.count),
                            nil)
                    }
                }
            }
            guard result == 0 else { throw mapAuthenticationError(result) }
            authenticated = true
        } catch {
            let normalized = normalize(error)
            if normalized != .authenticationFailed {
                invalidateResources()
            }
            throw normalized
        }
    }

    func authenticate(
        username: String,
        publicKey: Data,
        signer: @escaping SSHSigningClosure,
        timeout: Duration
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, !authenticated, let session else {
            throw SSHError.connectionInvalidated
        }
        guard !username.isEmpty, !publicKey.isEmpty else {
            throw SSHError.authenticationFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let retainedContext = Unmanaged.passRetained(SigningContext(signer: signer))
        defer { retainedContext.release() }
        var abstract: UnsafeMutableRawPointer? = retainedContext.toOpaque()

        do {
            let result = try await repeatUntilComplete(deadline: deadline) {
                username.withCString { usernamePointer in
                    publicKey.withUnsafeBytes { publicKeyBytes in
                        withUnsafeMutablePointer(to: &abstract) { abstractPointer in
                            libssh2_userauth_publickey(
                                session,
                                usernamePointer,
                                publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                                publicKeyBytes.count,
                                signPublicKey,
                                abstractPointer)
                        }
                    }
                }
            }
            guard result == 0 else { throw mapAuthenticationError(result) }
            authenticated = true
        } catch {
            let normalized = normalize(error)
            if normalized != .authenticationFailed {
                invalidateResources()
            }
            throw normalized
        }
    }

    func execute(command: String, input: Data, timeout: Duration) async throws -> SSHExecResult {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, let session else {
            throw SSHError.connectionInvalidated
        }
        guard !command.isEmpty else { throw SSHError.channelFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var channel: OpaquePointer?

        do {
            channel = try await openSessionChannel(session: session, deadline: deadline)
            guard let channel else { throw SSHError.channelFailed }
            try await startExec(
                channel: channel,
                command: command,
                session: session,
                deadline: deadline)

            let result = try await exchange(
                channel: channel,
                input: input,
                session: session,
                deadline: deadline)
            try await cleanChannel(
                channel,
                session: session,
                deadline: deadline,
                cancellable: true)
            return result
        } catch {
            let normalized = normalize(error)
            if let channel {
                do {
                    try await cleanChannel(
                        channel,
                        session: session,
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                } catch {
                    invalidateResources()
                }
            } else {
                // A channel-open outcome is uncertain, so the session must not
                // admit later work even if the underlying TCP socket survives.
                invalidateResources()
            }
            throw normalized
        }
    }

    func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, let session else {
            throw SSHError.connectionInvalidated
        }
        guard
            socketPath.hasPrefix("/"),
            !socketPath.utf8.contains(0),
            !request.isEmpty,
            request.last == 0x0A,
            maximumResponseBytes > 0
        else {
            throw SSHError.channelFailed
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var channel: OpaquePointer?

        do {
            channel = try await openStreamLocalChannel(
                socketPath: socketPath,
                session: session,
                deadline: deadline)
            guard let channel else { throw SSHError.streamLocalOpenFailed }
            let response = try await exchangeResponseLine(
                channel: channel,
                request: request,
                maximumResponseBytes: maximumResponseBytes,
                session: session,
                deadline: deadline)
            try await cleanChannel(
                channel,
                session: session,
                deadline: deadline,
                cancellable: true)
            return response
        } catch {
            let normalized = normalize(error)
            if let channel {
                do {
                    try await cleanChannel(
                        channel,
                        session: session,
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                } catch {
                    invalidateResources()
                }
            } else if normalized != .streamLocalOpenFailed {
                // A timeout or cancellation while opening has an uncertain
                // channel outcome. Do not admit later work on this session.
                invalidateResources()
            }
            throw normalized
        }
    }

    func close(timeout: Duration) async throws {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding else {
            if forwarding { throw SSHError.channelFailed }
            invalidateResources()
            return
        }
        guard let session else {
            invalidateResources()
            return
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        do {
            let disconnectResult = try await repeatUntilComplete(deadline: deadline) {
                libssh2_session_disconnect_ex(
                    session,
                    SSH_DISCONNECT_BY_APPLICATION,
                    "Heeler closed the connection",
                    "")
            }
            guard disconnectResult == 0 else {
                throw mapSessionError(disconnectResult)
            }
            try await freeSession(session, deadline: deadline, cancellable: true)
            self.session = nil
            closeDescriptor()
            valid = false
        } catch {
            invalidateResources()
            throw normalize(error)
        }
    }

    func invalidate() {
        invalidateResources()
    }

#if DEBUG
    func resourceStateForTesting() -> SessionDriverResourceState {
        SessionDriverResourceState(
            hasSession: session != nil,
            descriptorIsOpen: descriptor >= 0,
            isValid: valid)
    }
#endif

    private func configureAlgorithms(_ session: OpaquePointer) throws {
        let preferences: [(Int32, String)] = [
            (LIBSSH2_METHOD_HOSTKEY, Self.hostKeyPreference),
            (LIBSSH2_METHOD_KEX, Self.keyExchangePreference),
            (LIBSSH2_METHOD_CRYPT_CS, Self.cipherPreference),
            (LIBSSH2_METHOD_CRYPT_SC, Self.cipherPreference),
            (LIBSSH2_METHOD_MAC_CS, Self.macPreference),
            (LIBSSH2_METHOD_MAC_SC, Self.macPreference),
        ]
        for (method, preference) in preferences {
            let result = preference.withCString {
                libssh2_session_method_pref(session, method, $0)
            }
            guard result == 0 else { throw SSHError.algorithmNegotiationFailed }
        }
    }

    private func performHandshake(
        deadline: ContinuousClock.Instant
    ) async throws -> SSHHostKey {
        guard NativeLibrary.initializationResult == 0 else {
            throw SSHError.connectionFailed
        }
        guard let createdSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.connectionFailed
        }
        session = createdSession
        libssh2_session_set_blocking(createdSession, 0)
        try configureAlgorithms(createdSession)

        let handshakeResult = try await repeatUntilComplete(deadline: deadline) {
            libssh2_session_handshake(createdSession, descriptor)
        }
        guard handshakeResult == 0 else {
            throw mapSessionError(handshakeResult)
        }
        return try extractHostKey(createdSession)
    }

    func openDirectTCPIP(
        endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> DirectTCPIPByteTransport {
        await acquireOperation()
        defer { releaseOperation() }

        guard
            valid,
            !forwarding,
            authenticated,
            let session,
            !endpoint.host.isEmpty,
            endpoint.port > 0
        else {
            throw SSHError.connectionInvalidated
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var channel: OpaquePointer?

        do {
            channel = try await openDirectTCPIPChannel(
                endpoint: endpoint,
                session: session,
                deadline: deadline)
            guard let channel else { throw SSHError.channelFailed }
            let transport = try DirectTCPIPByteTransport()
            let pumpDescriptor = try transport.takePumpDescriptor()
            forwarding = true
            let task = Task { [self] in
                await pumpDirectTCPIP(
                    channel: channel,
                    bridgeDescriptor: pumpDescriptor,
                    session: session)
            }
            transport.start(task)
            return transport
        } catch {
            let normalized = normalize(error)
            if let channel {
                do {
                    try await cleanChannel(
                        channel,
                        session: session,
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                } catch {
                    invalidateResources()
                }
            } else if normalized == .timedOut || normalized == .cancelled {
                invalidateResources()
            }
            throw normalized
        }
    }

    private func openDirectTCPIPChannel(
        endpoint: SSHEndpoint,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        while true {
            try checkProgress(deadline: deadline)
            let channel = endpoint.host.withCString { hostPointer in
                libssh2_channel_direct_tcpip_ex(
                    session,
                    hostPointer,
                    Int32(endpoint.port),
                    "127.0.0.1",
                    0)
            }
            if let channel { return channel }

            let error = libssh2_session_last_errno(session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
            } else {
                throw classifyDirectTCPIPOpenFailure(session)
            }
        }
    }

    private func classifyDirectTCPIPOpenFailure(_ session: OpaquePointer) -> SSHError {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        _ = libssh2_session_last_error(session, &messagePointer, &messageLength, 0)
        guard let messagePointer, messageLength > 0 else { return .channelFailed }
        let message = String(
            decoding: Data(bytes: messagePointer, count: Int(messageLength)),
            as: UTF8.self)
            .lowercased()
        if message.contains("administratively prohibited")
            || message.contains("forwarding disabled")
            || message.contains("not allowed")
        {
            return .forwardingDenied
        }
        if message.contains("connect failed") || message.contains("connection refused") {
            return .targetUnreachable
        }
        return .channelFailed
    }

    private func pumpDirectTCPIP(
        channel: OpaquePointer,
        bridgeDescriptor: Int32,
        session: OpaquePointer
    ) async -> Result<Void, SSHError> {
        defer {
            Darwin.close(bridgeDescriptor)
            forwarding = false
        }

        do {
            try await runDirectTCPIPPump(
                channel: channel,
                bridgeDescriptor: bridgeDescriptor,
                session: session)
            try await cleanChannel(
                channel,
                session: session,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                cancellable: false)
            return .success(())
        } catch {
            let normalized = normalize(error)
            do {
                try await cleanChannel(
                    channel,
                    session: session,
                    deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                    cancellable: false)
            } catch {
                invalidateResources()
            }
            return .failure(normalized)
        }
    }

    private func runDirectTCPIPPump(
        channel: OpaquePointer,
        bridgeDescriptor: Int32,
        session: OpaquePointer
    ) async throws {
        let bufferLimit = 1_048_576
        var toOuter = Data()
        var toInner = Data()
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        var innerEOF = false
        var outerEOF = false

        while true {
            if Task.isCancelled { throw SSHError.cancelled }
            guard valid else { throw SSHError.connectionInvalidated }
            var madeProgress = false

            if !innerEOF, toOuter.count < bufferLimit {
                let readCount = scratch.withUnsafeMutableBytes { bytes in
                    Darwin.read(bridgeDescriptor, bytes.baseAddress, bytes.count)
                }
                if readCount > 0 {
                    toOuter.append(contentsOf: scratch.prefix(readCount))
                    madeProgress = true
                } else if readCount == 0 {
                    innerEOF = true
                    madeProgress = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    throw SSHError.connectionFailed
                }
            }

            if !toOuter.isEmpty {
                let written = toOuter.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_write_ex(
                        channel,
                        0,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
                if written > 0 {
                    toOuter.removeFirst(written)
                    madeProgress = true
                } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw SSHError.connectionFailed
                }
            }

            if !outerEOF, toInner.count < bufferLimit {
                let readCount = scratch.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_read_ex(
                        channel,
                        0,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
                if readCount > 0 {
                    toInner.append(contentsOf: scratch.prefix(readCount))
                    madeProgress = true
                } else if readCount != 0 && readCount != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw SSHError.connectionFailed
                }
                if libssh2_channel_eof(channel) == 1 {
                    outerEOF = true
                    madeProgress = true
                }
            }

            if !toInner.isEmpty {
                let written = toInner.withUnsafeBytes { bytes in
                    Darwin.write(bridgeDescriptor, bytes.baseAddress, bytes.count)
                }
                if written > 0 {
                    toInner.removeFirst(written)
                    madeProgress = true
                } else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                    throw SSHError.connectionFailed
                }
            }

            if outerEOF, toInner.isEmpty {
                _ = Darwin.shutdown(bridgeDescriptor, SHUT_WR)
            }
            if innerEOF, toOuter.isEmpty { return }

            if !madeProgress {
                var innerDirections: SocketDirections = []
                if !innerEOF, toOuter.count < bufferLimit { innerDirections.insert(.read) }
                if !toInner.isEmpty { innerDirections.insert(.write) }
                let pumpDeadline = ContinuousClock.now.advanced(by: .seconds(60))
                do {
                    try await SocketReadiness.wait(
                        for: [
                            .init(
                                descriptor: descriptor,
                                directions: sessionDirections(session)),
                            .init(
                                descriptor: bridgeDescriptor,
                                directions: innerDirections),
                        ],
                        until: pumpDeadline)
                } catch SSHError.timedOut {
                    continue
                }
            }
        }
    }

    private func sessionDirections(_ session: OpaquePointer) -> SocketDirections {
        let rawDirections = libssh2_session_block_directions(session)
        var directions: SocketDirections = []
        if rawDirections & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            directions.insert(.read)
        }
        if rawDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            directions.insert(.write)
        }
        if directions.isEmpty { directions = [.read, .write] }
        return directions
    }

    private func extractHostKey(_ session: OpaquePointer) throws -> SSHHostKey {
        var length = 0
        var type: Int32 = 0
        guard
            let keyPointer = libssh2_session_hostkey(session, &length, &type),
            length > 0,
            let methodPointer = libssh2_session_methods(session, LIBSSH2_METHOD_HOSTKEY)
        else {
            throw SSHError.algorithmNegotiationFailed
        }
        return SSHHostKey(
            algorithm: String(cString: methodPointer),
            key: Data(bytes: keyPointer, count: length))
    }

    private func openSessionChannel(
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        while true {
            try checkProgress(deadline: deadline)
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32 * 1024,
                nil,
                0)
            {
                return channel
            }
            let error = libssh2_session_last_errno(session)
            guard error == LIBSSH2_ERROR_EAGAIN else { throw SSHError.channelFailed }
            try await waitForSession(session, deadline: deadline)
        }
    }

    private func openStreamLocalChannel(
        socketPath: String,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        while true {
            try checkProgress(deadline: deadline)
            let channel = socketPath.withCString { socketPathPointer in
                libssh2_channel_direct_streamlocal_ex(
                    session,
                    socketPathPointer,
                    "127.0.0.1",
                    0)
            }
            if let channel { return channel }

            let error = libssh2_session_last_errno(session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
            } else {
                throw SSHError.streamLocalOpenFailed
            }
        }
    }

    private func startExec(
        channel: OpaquePointer,
        command: String,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws {
        let result = try await repeatUntilComplete(deadline: deadline) {
            command.withCString { commandPointer in
                libssh2_channel_process_startup(
                    channel,
                    "exec",
                    UInt32("exec".utf8.count),
                    commandPointer,
                    UInt32(command.utf8.count))
            }
        }
        guard result == 0 else { throw SSHError.channelFailed }
    }

    private func exchange(
        channel: OpaquePointer,
        input: Data,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws -> SSHExecResult {
        var inputOffset = 0
        var sentEOF = false
        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            try checkProgress(deadline: deadline)
            var madeProgress = false

            if inputOffset < input.count {
                let written = input.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    let pointer = baseAddress.advanced(by: inputOffset)
                        .assumingMemoryBound(to: CChar.self)
                    return libssh2_channel_write_ex(
                        channel,
                        0,
                        pointer,
                        input.count - inputOffset)
                }
                if written > 0 {
                    inputOffset += written
                    madeProgress = true
                } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw SSHError.channelFailed
                }
            } else if !sentEOF {
                let result = libssh2_channel_send_eof(channel)
                if result == 0 {
                    sentEOF = true
                    madeProgress = true
                } else if result != LIBSSH2_ERROR_EAGAIN {
                    throw SSHError.channelFailed
                }
            }

            let stdoutRead = try readAvailable(channel: channel, stream: 0, buffer: &buffer)
            if stdoutRead.count > 0 {
                stdout.append(stdoutRead)
                madeProgress = true
            }
            let stderrRead = try readAvailable(
                channel: channel,
                stream: Int32(SSH_EXTENDED_DATA_STDERR),
                buffer: &buffer)
            if stderrRead.count > 0 {
                stderr.append(stderrRead)
                madeProgress = true
            }

            if libssh2_channel_eof(channel) == 1 {
                return SSHExecResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitStatus: Int32(libssh2_channel_get_exit_status(channel)),
                    reachedEOF: true)
            }
            if !madeProgress {
                try await waitForSession(session, deadline: deadline)
            }
        }
    }

    private func exchangeResponseLine(
        channel: OpaquePointer,
        request: Data,
        maximumResponseBytes: Int,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws -> Data {
        var requestOffset = 0
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            try checkProgress(deadline: deadline)
            var madeProgress = false

            if requestOffset < request.count {
                let written = request.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_write_ex(
                        channel,
                        0,
                        baseAddress.advanced(by: requestOffset)
                            .assumingMemoryBound(to: CChar.self),
                        request.count - requestOffset)
                }
                if written > 0 {
                    requestOffset += written
                    madeProgress = true
                } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw SSHError.channelFailed
                }
            }

            let received = try readAvailable(channel: channel, stream: 0, buffer: &buffer)
            if !received.isEmpty {
                response.append(received)
                madeProgress = true
                if let newline = response.firstIndex(of: 0x0A) {
                    let lineLength = response.distance(from: response.startIndex, to: newline) + 1
                    guard lineLength <= maximumResponseBytes else {
                        throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                    }
                    return Data(response.prefix(lineLength))
                }
                guard response.count <= maximumResponseBytes else {
                    throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                }
            }

            if libssh2_channel_eof(channel) == 1 {
                throw SSHError.unexpectedEOF
            }
            if !madeProgress {
                try await waitForSession(session, deadline: deadline)
            }
        }
    }

    private func readAvailable(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) throws -> Data {
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_channel_read_ex(
                channel,
                stream,
                baseAddress.assumingMemoryBound(to: CChar.self),
                bytes.count)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
        throw SSHError.channelFailed
    }

    private func cleanChannel(
        _ channel: OpaquePointer,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        let eofResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_send_eof(channel)
        }
        guard eofResult == 0 || eofResult == LIBSSH2_ERROR_CHANNEL_EOF_SENT else {
            throw SSHError.channelFailed
        }

        let closeResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_close(channel)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }

        let freeResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_free(channel)
        }
        guard freeResult == 0 else { throw SSHError.channelFailed }
    }

    @discardableResult
    private func repeatUntilComplete(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        guard let session else { throw SSHError.connectionInvalidated }
        while true {
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN { return result }
            try await waitForSession(
                session,
                deadline: deadline,
                cancellable: cancellable)
        }
    }

    private func waitForSession(
        _ session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true
    ) async throws {
        let rawDirections = libssh2_session_block_directions(session)
        var directions: SocketDirections = []
        if rawDirections & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            directions.insert(.read)
        }
        if rawDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            directions.insert(.write)
        }
        if directions.isEmpty { directions = [.read, .write] }
        try await SocketReadiness.wait(
            descriptor: descriptor,
            directions: directions,
            until: deadline,
            cancellable: cancellable)
    }

    private func freeSession(
        _ session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        let result = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_session_free(session)
        }
        guard result == 0 else { throw mapSessionError(result) }
    }

    private func checkProgress(deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
    }

    private func mapAuthenticationError(_ code: Int32) -> SSHError {
        switch code {
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED,
            LIBSSH2_ERROR_PASSWORD_EXPIRED,
            LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED,
            LIBSSH2_ERROR_KEYFILE_AUTH_FAILED:
            return .authenticationFailed
        default:
            return mapSessionError(code)
        }
    }

    private func mapSessionError(_ code: Int32) -> SSHError {
        switch code {
        case LIBSSH2_ERROR_KEX_FAILURE,
            LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE,
            LIBSSH2_ERROR_METHOD_NONE,
            LIBSSH2_ERROR_METHOD_NOT_SUPPORTED,
            LIBSSH2_ERROR_ALGO_UNSUPPORTED,
            LIBSSH2_ERROR_HOSTKEY_INIT:
            return .algorithmNegotiationFailed
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED,
            LIBSSH2_ERROR_PASSWORD_EXPIRED:
            return .authenticationFailed
        default:
            return .connectionFailed
        }
    }

    private func normalize(_ error: any Error) -> SSHError {
        if let error = error as? SSHError { return error }
        return .connectionFailed
    }

    private func invalidateResources() {
        valid = false
        authenticated = false
        InvalidatedSessionTeardown.reclaim(&session)
        closeDescriptor()
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func acquireOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}

private final class SigningContext: Sendable {
    let signer: SSHSigningClosure

    init(signer: @escaping SSHSigningClosure) {
        self.signer = signer
    }
}

private func signPublicKey(
    _ session: OpaquePointer?,
    _ signaturePointer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ signatureLength: UnsafeMutablePointer<Int>?,
    _ dataPointer: UnsafePointer<UInt8>?,
    _ dataLength: Int,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
    guard
        session != nil,
        let signaturePointer,
        let signatureLength,
        let dataPointer,
        dataLength >= 0,
        let contextPointer = abstract?.pointee
    else {
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }

    signaturePointer.pointee = nil
    signatureLength.pointee = 0
    let context = Unmanaged<SigningContext>
        .fromOpaque(contextPointer)
        .takeUnretainedValue()

    do {
        let signature = try context.signer(Data(bytes: dataPointer, count: dataLength))
        // SessionDriver initializes libssh2 with its default malloc/free
        // allocator. libssh2 takes ownership here and frees this buffer after
        // copying it into the authentication packet.
        guard !signature.isEmpty, let allocation = malloc(signature.count) else {
            return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
        }
        signature.copyBytes(
            to: allocation.assumingMemoryBound(to: UInt8.self),
            count: signature.count)
        signaturePointer.pointee = allocation.assumingMemoryBound(to: UInt8.self)
        signatureLength.pointee = signature.count
        return 0
    } catch {
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }
}

enum InvalidatedSessionTeardown {
    typealias FreeSession = (OpaquePointer) -> Int32

    @discardableResult
    static func reclaim(
        _ session: inout OpaquePointer?,
        using freeSession: FreeSession = heeler_libssh2_abandon_session
    ) -> Int32 {
        guard let ownedSession = session else { return 0 }
        let result = freeSession(ownedSession)
        if result == 0 {
            session = nil
        }
        return result
    }
}

#if DEBUG
struct SessionDriverResourceState: Sendable, Equatable {
    let hasSession: Bool
    let descriptorIsOpen: Bool
    let isValid: Bool
}
#endif

enum NativeLibrary {
    static let initializationResult = libssh2_init(0)
}
