import CLibSSH2
import CHeelerSSHSupport
import Darwin
import Foundation

#if DEBUG
enum HandshakeFailureObservation {
    @TaskLocal static var observer: (@Sendable (Int32) -> Void)? = nil
}
#endif

actor SessionDriver {
    enum BridgeWriteResult: Equatable {
        case blocked
        case peerClosed
        case wrote(Int)
    }

    enum TransportSendOwnerDisposition: Equatable {
        case unchanged
        case clear
        case invalidate
    }

    private struct PacketOperationResult {
        let code: Int32
        let disposition: TransportSendOwnerDisposition
    }

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
        "mlkem768x25519-sha256",
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
    private var nextStreamLocalChannelID: UInt64 = 0
    private struct StreamLocalChannelState {
        let channel: OpaquePointer
        var acceptsIO = true
        var teardownInProgress = false
    }
    private var streamLocalChannels: [UInt64: StreamLocalChannelState] = [:]
    private struct PTYChannelState {
        let channel: OpaquePointer
        var reachedEOF = false
        var closed = false
        var acceptsIO = true
        var teardownInProgress = false
    }
    private var nextPTYChannelID: UInt64 = 0
    private var ptyChannels: [UInt64: PTYChannelState] = [:]
    private struct SFTPState {
        let handle: OpaquePointer
        var files: [UInt64: OpaquePointer] = [:]
    }
    private enum SFTPCompensationPhase {
        case unlink
        case stat
    }
    private var nextSFTPID: UInt64 = 0
    private var nextSFTPFileID: UInt64 = 0
    private var sftpClients: [UInt64: SFTPState] = [:]

    private struct ChannelOpenAdmissionError: Error, Sendable {
        let underlying: SSHError
    }

    private struct OneShotChannel {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    private enum ChannelIdentity: Equatable {
        case oneShot(UInt64)
        case pty(UInt64)
        case streamLocal(UInt64)
    }

    private var nextOneShotID: UInt64 = 0
    private var oneShotChannels: [UInt64: OneShotChannel] = [:]
    private var nextTransportSendIdentity: UInt64 = 0
    /// The logical libssh2 call that last returned `EAGAIN` with an outbound
    /// block. Cleared only by that same call returning non-`EAGAIN`, or by
    /// completed whole-session invalidation. Cancellation does not clear it.
    private var transportSendOwner: UInt64?
    /// Session-owned channel opens must not interleave, even when the opener
    /// releases the operation mutex to wait for a foreign send owner.
    private var channelOpenInProgress = false
    private var nextChannelOpenWaiterID: UInt64 = 0
    private struct DriverWaiter {
        let continuation: CheckedContinuation<Void, any Error>
        let deadlineTask: Task<Void, Never>
    }
    private struct PTYTeardownWaiter {
        let ptyID: UInt64
        let waiter: DriverWaiter
    }
    private var channelOpenWaiters: [UInt64: DriverWaiter] = [:]
    private var nextPTYTeardownWaiterID: UInt64 = 0
    private var ptyTeardownWaiters: [UInt64: PTYTeardownWaiter] = [:]
    private var sftpUses: [UInt64: Int] = [:]
    private var nextSFTPIdleWaiterID: UInt64 = 0
    private var sftpIdleWaiters: [UInt64: DriverWaiter] = [:]

#if DEBUG
    private var directTCPIPInboundBufferHighWaterMark = 0
    private var nextDirectTCPIPInboundBufferFullHoldForTesting: (@Sendable () async -> Void)?
    private var nextSFTPWriteDelayForTesting: Duration?
    private var sftpWriteDelayIsActiveForTesting = false
    private var nextSessionWaitHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecChannelAllocatedHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecCleanupHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationUnlinkPhaseHookForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationStatPhaseHookForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationShutdownHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOutboundWriteParkHoldForTesting: (@Sendable () async -> Void)?
    private var nextOneShotEstablishedHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOwnedLoopTopHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOwnedDrainHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextChannelOpenSlotHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextChannelTeardownHoldForTesting: (@Sendable () async -> Void)?
    private var nextResumedChannelOpenWaiterErrorForTesting: SSHError?
    private var nextChannelOpenWaiterRegistrationHoldForTesting: (@Sendable () async -> Void)?
    private var ownerSamplesForTesting: [TransportSendOwnerSample]?
    private var shouldFailNextSFTPInitBeforeEAGAINForTesting = false
#endif

    // Actor reentrancy would otherwise allow a second task to call libssh2
    // while the first one is suspended on socket readiness.
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    // Whoever holds the session may consume the bytes the operations waiting
    // for it are blocked on, which leaves them nothing to see on the socket.
    private let activity = SessionActivity()

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

        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        guard !command.isEmpty else { throw SSHError.channelFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var oneShotID: UInt64?

        do {
            let channel = try await openSessionChannel(deadline: deadline)
            let session = try requireSession()
            let id = registerOneShot(channel: channel, session: session)
            oneShotID = id
#if DEBUG
            try await holdExecChannelAllocationForTestingIfNeeded()
            try await holdOneShotEstablishedForTestingIfNeeded()
#endif
            try await startExec(
                identity: .oneShot(id),
                command: command,
                deadline: deadline)

            let result = try await exchange(
                identity: .oneShot(id),
                input: input,
                deadline: deadline)
            let freeResult = try await repeatUntilCompleteYielding(
                deadline: deadline,
                identity: .oneShot(id)
            ) {
                libssh2_channel_free($0)
            }
            guard freeResult == 0 else { throw SSHError.channelFailed }
            removeOneShot(id)
            return result
        } catch {
            let normalized = normalize(error)
            if let id = oneShotID {
                do {
                    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
#if DEBUG
                    try await holdExecCleanupForTestingIfNeeded()
#endif
                    try await cleanChannel(
                        identity: .oneShot(id),
                        deadline: cleanupDeadline,
                        cancellable: false)
                    removeOneShot(id)
                } catch {
                    // This is the last owner of the allocated exec channel.
                    // If cleanup cannot finish, only session teardown can
                    // reclaim its native channel and server session slot.
                    invalidateResources()
                }
            } else if !(error is ChannelOpenAdmissionError) {
                // A channel-open outcome is uncertain, so the session must not
                // admit later work even if the underlying TCP socket survives.
                invalidateResources()
            }
            throw normalized
        }
    }

    func executeResponseLine(
        command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        guard
            !command.isEmpty,
            !input.isEmpty,
            input.last == 0x0A,
            !input.dropLast().contains(0x0A),
            maximumResponseBytes > 0
        else {
            throw SSHError.channelFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var oneShotID: UInt64?

        do {
            let channel = try await openSessionChannel(deadline: deadline)
            let session = try requireSession()
            let id = registerOneShot(channel: channel, session: session)
            oneShotID = id
#if DEBUG
            try await holdExecChannelAllocationForTestingIfNeeded()
            try await holdOneShotEstablishedForTestingIfNeeded()
#endif
            try await startExec(
                identity: .oneShot(id),
                command: command,
                deadline: deadline)
            let response = try await exchangeResponseLine(
                identity: .oneShot(id),
                request: input,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline)
            try await cleanChannel(
                identity: .oneShot(id),
                deadline: deadline,
                cancellable: true)
            removeOneShot(id)
            return response
        } catch {
            let normalized = normalize(error)
            if let id = oneShotID {
                do {
                    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
#if DEBUG
                    try await holdExecCleanupForTestingIfNeeded()
#endif
                    try await cleanChannel(
                        identity: .oneShot(id),
                        deadline: cleanupDeadline,
                        cancellable: false)
                    removeOneShot(id)
                } catch {
                    // The response-line channel has no owner after this scope.
                    // A failed cleanup therefore requires session teardown to
                    // reclaim the native channel and its server session slot.
                    invalidateResources()
                }
            } else if !(error is ChannelOpenAdmissionError) {
                invalidateResources()
            }
            throw normalized
        }
    }

    func openPTY(
        command: String,
        terminal: String,
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws -> SSHPTYChannel {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        guard
            !command.isEmpty,
            !command.utf8.contains(0),
            command.utf8.count <= Int(UInt32.max),
            !terminal.isEmpty,
            !terminal.utf8.contains(0),
            terminal.utf8.count <= Int(UInt32.max),
            columns > 0,
            columns <= Int(Int32.max),
            rows > 0,
            rows <= Int(Int32.max)
        else {
            throw SSHError.channelFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var registeredID: UInt64?

        do {
            let channel = try await openSessionChannel(deadline: deadline)
            nextPTYChannelID &+= 1
            let id = nextPTYChannelID
            ptyChannels[id] = PTYChannelState(channel: channel)
            registeredID = id
            try await configurePTY(
                identity: .pty(id),
                terminal: terminal,
                columns: columns,
                rows: rows,
                deadline: deadline)
            try await startExec(
                identity: .pty(id),
                command: command,
                deadline: deadline)
            return SSHPTYChannel(id: id, driver: self)
        } catch {
            let normalized = normalize(error)
            if let id = registeredID {
                do {
                    try await cleanChannel(
                        identity: .pty(id),
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                    ptyChannels.removeValue(forKey: id)
                } catch {
                    invalidateResources()
                }
            } else if !(error is ChannelOpenAdmissionError) {
                invalidateResources()
            }
            throw normalized
        }
    }

    func writePTY(id: UInt64, data: Data, timeout: Duration) async throws {
        guard !data.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var offset = 0
        let owner = allocateTransportSendOwner()

        while offset < data.count {
            await acquireOperation()
            let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
            do {
                try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                let session = try requireSession()
                let channel = try resolveChannel(.pty(id))
                let written = writeChannel(channel, data: data, offset: offset)
                let disposition = notePacketProducingWrite(
                    written,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                guard written >= 0 || written == Int(LIBSSH2_ERROR_EAGAIN) else {
                    throw SSHError.channelFailed
                }
                progress = (
                    written,
                    sessionWaitPlan(session),
                    written == Int(LIBSSH2_ERROR_EAGAIN) && transportSendOwner == owner)
                releaseOperation()
            } catch {
                await finishOwnedSendIfNeeded(owner: owner) {
                    writeChannelOnce(identity: .pty(id), data: data, offset: offset)
                }
                releaseOperation()
                throw normalize(error)
            }

            if progress.written > 0 {
                offset += progress.written
                await Task.yield()
            } else {
#if DEBUG
                if progress.parkedOutbound {
                    await holdOutboundWriteParkForTestingIfNeeded()
                }
#endif
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedSendIfNeeded(owner: owner) {
                        writeChannelOnce(identity: .pty(id), data: data, offset: offset)
                    }
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    func readPTY(
        id: UInt64,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data? {
        guard maximumBytes > 0 else { throw SSHError.channelFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        let owner = allocateTransportSendOwner()
        while true {
            await acquireOperation()
            let progress: (data: Data, eof: Bool, wait: SessionWaitPlan)
            do {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                let session = try requireSession()
                let channel = try resolveChannel(.pty(id))
                var buffer = [UInt8](repeating: 0, count: maximumBytes)
                let data = try readAvailableNoting(
                    channel: channel,
                    stream: 0,
                    buffer: &buffer,
                    owner: owner,
                    session: session)
                let eof = libssh2_channel_eof(channel) == 1
                if eof { ptyChannels[id]?.reachedEOF = true }
                progress = (data, eof, sessionWaitPlan(session))
                releaseOperation()
            } catch {
                await finishOwnedSendIfNeeded(owner: owner) {
                    guard let channel = try? resolveChannel(.pty(id)) else { return nil }
                    var scratch = [UInt8](repeating: 0, count: maximumBytes)
                    return readOnce(channel: channel, stream: 0, buffer: &scratch)
                }
                releaseOperation()
                throw normalize(error)
            }

            if !progress.data.isEmpty { return progress.data }
            if progress.eof { return nil }
            do {
                try await awaitSessionProgress(progress.wait, until: deadline)
            } catch {
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner) {
                    guard let channel = try? resolveChannel(.pty(id)) else { return nil }
                    var scratch = [UInt8](repeating: 0, count: maximumBytes)
                    return readOnce(channel: channel, stream: 0, buffer: &scratch)
                }
                releaseOperation()
                throw normalize(error)
            }
        }
    }

    func resizePTY(
        id: UInt64,
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws {
        guard
            columns > 0,
            columns <= Int(Int32.max),
            rows > 0,
            rows <= Int(Int32.max)
        else {
            throw SSHError.channelFailed
        }
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, session != nil else { throw SSHError.connectionInvalidated }
        guard ptyChannels[id] != nil else { throw SSHError.channelFailed }
        let result = try await repeatUntilCompleteYielding(
            deadline: ContinuousClock.now.advanced(by: timeout),
            identity: .pty(id)
        ) {
            libssh2_channel_request_pty_size_ex($0, Int32(columns), Int32(rows), 0, 0)
        }
        guard result == 0 else { throw SSHError.channelFailed }
    }

    func ptyExitStatus(id: UInt64, timeout: Duration) async throws -> Int32 {
        await acquireOperation()
        defer { releaseOperation() }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        try checkProgress(deadline: deadline)
        guard valid, session != nil else { throw SSHError.connectionInvalidated }
        guard var state = ptyChannels[id], state.reachedEOF else {
            throw SSHError.channelFailed
        }
        guard !state.teardownInProgress else { throw SSHError.channelFailed }
        state.acceptsIO = false
        state.teardownInProgress = true
        ptyChannels[id] = state
#if DEBUG
        await holdChannelTeardownForTestingIfNeeded()
#endif

        do {
            let exitStatus = try await exitStatusAfterChannelClose(
                identity: .pty(id),
                deadline: deadline,
                allowClosing: true)
            ptyChannels[id]?.closed = true
            ptyChannels[id]?.teardownInProgress = false
            wakePTYTeardownWaiters(for: id)
            return exitStatus
        } catch {
            ptyChannels[id]?.acceptsIO = true
            ptyChannels[id]?.teardownInProgress = false
            wakePTYTeardownWaiters(for: id)
            throw error
        }
    }

    func closePTY(id: UInt64, timeout: Duration) async throws {
        await acquireOperation()
        defer { releaseOperation() }

        guard ptyChannels[id] != nil else { return }
        guard valid, session != nil else {
            ptyChannels.removeValue(forKey: id)
            wakePTYTeardownWaiters(for: id)
            return
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            try await waitUntilPTYTeardownCompletes(id: id, deadline: deadline)
        } catch {
            throw normalize(error)
        }
        guard var state = ptyChannels[id] else { return }
        guard valid, session != nil else {
            ptyChannels.removeValue(forKey: id)
            wakePTYTeardownWaiters(for: id)
            return
        }
        state.acceptsIO = false
        state.teardownInProgress = true
        ptyChannels[id] = state
#if DEBUG
        await holdChannelTeardownForTestingIfNeeded()
#endif
        do {
            if ptyChannels[id]?.closed == true {
                let freeResult = try await repeatUntilCompleteYielding(
                    deadline: deadline,
                    cancellable: false,
                    identity: .pty(id),
                    allowClosing: true
                ) {
                    libssh2_channel_free($0)
                }
                guard freeResult == 0 else { throw SSHError.channelFailed }
            } else {
                try await cleanChannel(
                    identity: .pty(id),
                    deadline: deadline,
                    cancellable: false,
                    allowClosing: true)
            }
            ptyChannels.removeValue(forKey: id)
            wakePTYTeardownWaiters(for: id)
        } catch {
            ptyChannels.removeValue(forKey: id)
            wakePTYTeardownWaiters(for: id)
            throw teardownFailure(error)
        }
    }

    func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        beforeRequestWrite: (@Sendable () async throws -> Void)? = nil,
        onRequestWritten: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, session != nil else {
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
        var oneShotID: UInt64?

        do {
            let channel = try await openStreamLocalChannel(
                socketPath: socketPath,
                deadline: deadline)
            let session = try requireSession()
            let id = registerOneShot(
                channel: channel,
                session: session)
            oneShotID = id
#if DEBUG
            try await holdOneShotEstablishedForTestingIfNeeded()
#endif
            let response = try await exchangeResponseLine(
                identity: .oneShot(id),
                request: request,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline,
                beforeRequestWrite: beforeRequestWrite,
                onRequestWritten: onRequestWritten)
            try await cleanChannel(
                identity: .oneShot(id),
                deadline: deadline,
                cancellable: true)
            removeOneShot(id)
            return response
        } catch {
            let normalized: SSHError?
            if error is ChannelOpenAdmissionError {
                normalized = normalize(error)
            } else {
                normalized = (error as? SSHError).map(normalize)
            }
            if let id = oneShotID {
                do {
                    try await cleanChannel(
                        identity: .oneShot(id),
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                    removeOneShot(id)
                } catch {
                    invalidateResources()
                }
            } else if !(error is ChannelOpenAdmissionError),
                normalized != .streamLocalOpenFailed
            {
                // `.streamLocalOpenFailed` now means only what it says: the
                // server refused this one channel and the session is intact.
                // Everything else — a timeout or cancellation with an uncertain
                // channel outcome, or the socket loss
                // `mappedStreamLocalOpenError` reports as `.connectionInvalidated`
                // — must not admit later work on this session.
                invalidateResources()
            }
            if let normalized {
                throw normalized
            }
            throw error
        }
    }

    func openStreamLocal(
        socketPath: String,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0) else {
            throw SSHError.channelFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var channel: OpaquePointer?

        do {
            channel = try await openStreamLocalChannel(
                socketPath: socketPath,
                deadline: deadline)
            guard let channel else { throw SSHError.streamLocalOpenFailed }
            nextStreamLocalChannelID &+= 1
            let id = nextStreamLocalChannelID
            streamLocalChannels[id] = StreamLocalChannelState(channel: channel)
            return SSHStreamLocalChannel(id: id, driver: self)
        } catch {
            let normalized = normalize(error)
            if let channel {
                do {
                    try await cleanChannel(
                        channel,
                        session: try requireSession(),
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                } catch {
                    invalidateResources()
                }
            } else if !(error is ChannelOpenAdmissionError),
                normalized != .streamLocalOpenFailed
            {
                // The same rule `exchangeStreamLocal` states above: only a
                // refusal of this one channel leaves the session usable.
                invalidateResources()
            }
            throw normalized
        }
    }

    func writeStreamLocal(
        id: UInt64,
        data: Data,
        timeout: Duration
    ) async throws {
        guard !data.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var offset = 0
        let owner = allocateTransportSendOwner()

        while offset < data.count {
            await acquireOperation()
            let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
            do {
                try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                let session = try requireSession()
                let channel = try resolveChannel(.streamLocal(id))
                let written = writeChannel(channel, data: data, offset: offset)
                let disposition = notePacketProducingWrite(
                    written,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                guard written >= 0 || written == Int(LIBSSH2_ERROR_EAGAIN) else {
                    throw SSHError.channelFailed
                }
                progress = (
                    written,
                    sessionWaitPlan(session),
                    written == Int(LIBSSH2_ERROR_EAGAIN) && transportSendOwner == owner)
                releaseOperation()
            } catch {
                await finishOwnedSendIfNeeded(owner: owner) {
                    writeChannelOnce(identity: .streamLocal(id), data: data, offset: offset)
                }
                releaseOperation()
                throw normalize(error)
            }

            if progress.written > 0 {
                offset += progress.written
                await Task.yield()
            } else {
#if DEBUG
                if progress.parkedOutbound {
                    await holdOutboundWriteParkForTestingIfNeeded()
                }
#endif
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedSendIfNeeded(owner: owner) {
                        writeChannelOnce(identity: .streamLocal(id), data: data, offset: offset)
                    }
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    func readStreamLocal(
        id: UInt64,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data? {
        guard maximumBytes > 0 else { throw SSHError.channelFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let owner = allocateTransportSendOwner()

        while true {
            await acquireOperation()
            let progress: (data: Data, eof: Bool, wait: SessionWaitPlan)
            do {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                let session = try requireSession()
                let channel = try resolveChannel(.streamLocal(id))
                var buffer = [UInt8](repeating: 0, count: maximumBytes)
                let data = try readAvailableNoting(
                    channel: channel,
                    stream: 0,
                    buffer: &buffer,
                    owner: owner,
                    session: session)
                progress = (
                    data,
                    libssh2_channel_eof(channel) == 1,
                    sessionWaitPlan(session))
                releaseOperation()
            } catch {
                await finishOwnedSendIfNeeded(owner: owner) {
                    guard let channel = try? resolveChannel(.streamLocal(id)) else { return nil }
                    var scratch = [UInt8](repeating: 0, count: maximumBytes)
                    return readOnce(channel: channel, stream: 0, buffer: &scratch)
                }
                releaseOperation()
                throw normalize(error)
            }

            if !progress.data.isEmpty { return progress.data }
            if progress.eof { return nil }
            do {
                try await awaitSessionProgress(progress.wait, until: deadline)
            } catch {
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner) {
                    guard let channel = try? resolveChannel(.streamLocal(id)) else { return nil }
                    var scratch = [UInt8](repeating: 0, count: maximumBytes)
                    return readOnce(channel: channel, stream: 0, buffer: &scratch)
                }
                releaseOperation()
                throw normalize(error)
            }
        }
    }

    func closeStreamLocal(id: UInt64, timeout: Duration) async throws {
        await acquireOperation()
        defer { releaseOperation() }

        guard var state = streamLocalChannels[id] else { return }
        guard valid, session != nil else {
            streamLocalChannels.removeValue(forKey: id)
            return
        }
        guard !state.teardownInProgress else { return }
        state.acceptsIO = false
        state.teardownInProgress = true
        streamLocalChannels[id] = state
#if DEBUG
        await holdChannelTeardownForTestingIfNeeded()
#endif
        do {
            try await cleanChannel(
                identity: .streamLocal(id),
                deadline: ContinuousClock.now.advanced(by: timeout),
                cancellable: false,
                allowClosing: true)
            streamLocalChannels.removeValue(forKey: id)
        } catch {
            streamLocalChannels.removeValue(forKey: id)
            throw teardownFailure(error)
        }
    }

    func openSFTP(timeout: Duration) async throws -> SSHSFTPClient {
        await acquireOperation()
        defer { releaseOperation() }

        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var initWasPending = false
        let owner = allocateTransportSendOwner()

        do {
            while true {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
#if DEBUG
                if shouldFailNextSFTPInitBeforeEAGAINForTesting {
                    shouldFailNextSFTPInitBeforeEAGAINForTesting = false
                    throw SSHError.sftpUnavailable
                }
#endif
                let session = try requireSession()
                if let sftp = libssh2_sftp_init(session) {
                    let disposition = notePacketProducingResult(
                        0,
                        owner: owner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    nextSFTPID &+= 1
                    let id = nextSFTPID
                    sftpClients[id] = SFTPState(handle: sftp)
                    return SSHSFTPClient(id: id, driver: self)
                }
                let error = libssh2_session_last_errno(session)
                let disposition = notePacketProducingResult(
                    error,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                if error == LIBSSH2_ERROR_EAGAIN {
                    initWasPending = true
                    try await waitForSession(session, deadline: deadline)
                } else if Self.isConnectionLoss(error) {
                    throw SSHError.connectionInvalidated
                } else {
                    throw SSHError.sftpUnavailable
                }
            }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            let normalized = normalize(error)
            // libssh2 1.11.1 keeps one in-progress SFTP-init state per session,
            // including its channel and allocation. Any failure after EAGAIN
            // may abandon that state, and a later init would resume it; only
            // session teardown can safely discard it. Before the first init
            // call (or after an ordinary non-EAGAIN failure), there is no
            // native init state to reclaim and the session remains reusable.
            if initWasPending || normalized == .connectionInvalidated {
                invalidateResources()
            }
            throw normalized
        }
    }

    func createSFTPDirectory(
        id: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
            throw SSHError.channelFailed
        }
        await acquireOperation()
        defer { releaseOperation() }
        let result = try await repeatUntilCompleteHoldingSFTP(
            id: id,
            deadline: ContinuousClock.now.advanced(by: timeout)
        ) { sftp in
            path.withCString { pathPointer in
                libssh2_sftp_mkdir_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int(permissions))
            }
        }
        try checkSFTPResult(result, sftpID: id)
    }

    func sftpAttributes(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> SSHSFTPAttributes {
        guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
        await acquireOperation()
        defer { releaseOperation() }
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let result = try await repeatUntilCompleteHoldingSFTP(
            id: id,
            deadline: ContinuousClock.now.advanced(by: timeout)
        ) { sftp in
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_STAT),
                    &attributes)
            }
        }
        try checkSFTPResult(result, sftpID: id)
        let hasSize = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0
        let hasPermissions = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
        return SSHSFTPAttributes(
            size: hasSize ? attributes.filesize : nil,
            permissions: hasPermissions
                ? UInt32(truncatingIfNeeded: attributes.permissions) & 0o777
                : nil)
    }

    func setSFTPPermissions(
        id: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
            throw SSHError.channelFailed
        }
        await acquireOperation()
        defer { releaseOperation() }
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attributes.permissions = UInt(permissions)
        let result = try await repeatUntilCompleteHoldingSFTP(
            id: id,
            deadline: ContinuousClock.now.advanced(by: timeout)
        ) { sftp in
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_SETSTAT),
                    &attributes)
            }
        }
        try checkSFTPResult(result, sftpID: id)
    }

    func readSFTPFileIfPresent(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> Data? {
        guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        return try await withSFTPUse(id: id, deadline: deadline) {
            guard let fileID = try await openSFTPFileForReadingIfPresent(
                sftpID: id,
                path: path,
                deadline: deadline)
            else { return nil }

            do {
                var contents = Data()
                while let chunk = try await readSFTPFileChunk(
                    sftpID: id,
                    fileID: fileID,
                    deadline: deadline)
                {
                    contents.append(chunk)
                }
                try await closeSFTPFileWithinUse(
                    sftpID: id,
                    fileID: fileID,
                    timeout: timeout)
                return contents
            } catch {
                try? await closeSFTPFileWithinUse(
                    sftpID: id,
                    fileID: fileID,
                    timeout: .seconds(2))
                throw normalize(error)
            }
        }
    }

    private func openSFTPFileForReadingIfPresent(
        sftpID: UInt64,
        path: String,
        deadline: ContinuousClock.Instant
    ) async throws -> UInt64? {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, session != nil, sftpClients[sftpID]?.handle != nil else {
            throw SSHError.connectionInvalidated
        }
        let owner = allocateTransportSendOwner()

        do {
        while true {
            try checkProgress(deadline: deadline)
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: true)
            let session = try requireSession()
            guard let sftp = sftpClients[sftpID]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let file = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    UInt(LIBSSH2_FXF_READ),
                    0,
                    Int32(LIBSSH2_SFTP_OPENFILE))
            }
            if let file {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                nextSFTPFileID &+= 1
                let fileID = nextSFTPFileID
                sftpClients[sftpID]?.files[fileID] = file
                return fileID
            }

            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
                continue
            }
            if Self.isConnectionLoss(error) {
                invalidateResources()
                throw SSHError.connectionInvalidated
            }
            let status = UInt64(libssh2_sftp_last_error(sftp))
            applyTransportSendOwnerDisposition(disposition)
            if disposition == .invalidate { throw SSHError.connectionInvalidated }
            if status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) { return nil }
            throw SSHError.sftpFailure(status: status)
        }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            throw error
        }
    }

    private func readSFTPFileChunk(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws -> Data? {
        let maximumChunkBytes = 64 * 1_024
        let owner = allocateTransportSendOwner()

        while true {
            await acquireOperation()
            let progress: (data: Data, reachedEOF: Bool, wait: SessionWaitPlan)
            do {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                guard
                    valid,
                    let session,
                    let state = sftpClients[sftpID],
                    let file = state.files[fileID]
                else {
                    throw SSHError.connectionInvalidated
                }
                var buffer = [UInt8](repeating: 0, count: maximumChunkBytes)
                let read = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_sftp_read(
                        file,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
                let disposition = notePacketProducingWrite(
                    read,
                    owner: owner,
                    session: session)
                if read < 0, read != Int(LIBSSH2_ERROR_EAGAIN) {
                    let mappedError = mappedSFTPError(
                        sftp: state.handle,
                        code: Int32(read))
                    applyTransportSendOwnerDisposition(disposition)
                    throw mappedError
                }
                applyTransportSendOwnerDisposition(disposition)
                progress = (
                    read > 0 ? Data(buffer.prefix(read)) : Data(),
                    read == 0,
                    sessionWaitPlan(session))
                releaseOperation()
            } catch {
                let normalized = normalize(error)
                if normalized == .connectionInvalidated { invalidateResources() }
                await finishOwnedSendIfNeeded(owner: owner) {
                    readSFTPOnce(sftpID: sftpID, fileID: fileID)
                }
                releaseOperation()
                throw normalized
            }

            if !progress.data.isEmpty { return progress.data }
            if progress.reachedEOF { return nil }
            do {
                try await awaitSessionProgress(progress.wait, until: deadline)
            } catch {
                let normalized = normalize(error)
                if normalized == .connectionInvalidated { invalidateResources() }
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner) {
                    readSFTPOnce(sftpID: sftpID, fileID: fileID)
                }
                releaseOperation()
                throw normalized
            }
        }
    }

    func openSFTPFileForWriting(
        sftpID: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws -> SSHSFTPFile {
        guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
            throw SSHError.channelFailed
        }
        await acquireOperation()
        defer { releaseOperation() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard valid, session != nil, sftpClients[sftpID]?.handle != nil else {
            throw SSHError.connectionInvalidated
        }
        try await waitUntilSFTPIdle(
            id: sftpID,
            deadline: deadline,
            cancellable: true)
        try beginSFTPUse(sftpID)
        defer { endSFTPUse(sftpID) }
        let flags = UInt(
            LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_EXCL)
        let owner = allocateTransportSendOwner()

        do {
        while true {
            try checkProgress(deadline: deadline)
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: true)
            let session = try requireSession()
            guard let sftp = sftpClients[sftpID]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let file = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    flags,
                    Int(permissions),
                    Int32(LIBSSH2_SFTP_OPENFILE))
            }
            if let file {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                nextSFTPFileID &+= 1
                let fileID = nextSFTPFileID
                sftpClients[sftpID]?.files[fileID] = file
                return SSHSFTPFile(sftpID: sftpID, fileID: fileID, driver: self)
            }
            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
            } else {
                let mappedError = mappedSFTPError(sftp: sftp, code: error)
                applyTransportSendOwnerDisposition(disposition)
                throw mappedError
            }
        }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            throw error
        }
    }

    func writeSFTPFile(
        sftpID: UInt64,
        fileID: UInt64,
        data: Data,
        timeout: Duration
    ) async throws {
        guard !data.isEmpty else { return }
#if DEBUG
        if let delay = nextSFTPWriteDelayForTesting {
            nextSFTPWriteDelayForTesting = nil
            sftpWriteDelayIsActiveForTesting = true
            do {
                try await Task.sleep(for: delay)
                sftpWriteDelayIsActiveForTesting = false
            } catch {
                sftpWriteDelayIsActiveForTesting = false
                throw error
            }
        }
#endif
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try await withSFTPUse(id: sftpID, deadline: deadline) {
            var offset = 0
            let owner = allocateTransportSendOwner()

            while offset < data.count {
                await acquireOperation()
                let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
                do {
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    guard
                        valid,
                        let session,
                        let state = sftpClients[sftpID],
                        let file = state.files[fileID]
                    else {
                        throw SSHError.connectionInvalidated
                    }
                    let written = data.withUnsafeBytes { bytes -> Int in
                        guard let baseAddress = bytes.baseAddress else { return 0 }
                        return libssh2_sftp_write(
                            file,
                            baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                            data.count - offset)
                    }
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: owner,
                        session: session)
                    if written < 0, written != Int(LIBSSH2_ERROR_EAGAIN) {
                        let mappedError = mappedSFTPError(
                            sftp: state.handle,
                            code: Int32(written))
                        applyTransportSendOwnerDisposition(disposition)
                        throw mappedError
                    }
                    applyTransportSendOwnerDisposition(disposition)
                    progress = (
                        written,
                        sessionWaitPlan(session),
                        written == Int(LIBSSH2_ERROR_EAGAIN))
                    releaseOperation()
                } catch {
                    let normalized = normalize(error)
                    if normalized == .connectionInvalidated { invalidateResources() }
                    await finishOwnedSendIfNeeded(owner: owner) {
                        writeSFTPOnce(sftpID: sftpID, fileID: fileID, data: data, offset: offset)
                    }
                    releaseOperation()
                    throw normalized
                }

                if progress.written > 0 {
                    offset += progress.written
                    await Task.yield()
                } else {
#if DEBUG
                    if progress.parkedOutbound {
                        await holdOutboundWriteParkForTestingIfNeeded()
                    }
#endif
                    do {
                        try await awaitSessionProgress(progress.wait, until: deadline)
                    } catch {
                        let normalized = normalize(error)
                        if normalized == .connectionInvalidated { invalidateResources() }
                        await acquireOperation()
                        await finishOwnedSendIfNeeded(owner: owner) {
                            writeSFTPOnce(sftpID: sftpID, fileID: fileID, data: data, offset: offset)
                        }
                        releaseOperation()
                        throw normalized
                    }
                }
            }
        }
    }

    func closeSFTPFile(
        sftpID: UInt64,
        fileID: UInt64,
        timeout: Duration
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard sftpClients[sftpID]?.files[fileID] != nil else { return }
        guard valid, session != nil else { return }
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            try await waitUntilSFTPIdle(
                id: sftpID,
                deadline: deadline,
                cancellable: false)
            try beginSFTPUse(sftpID)
            defer { endSFTPUse(sftpID) }
            try await closeSFTPFileHoldingOperation(
                sftpID: sftpID,
                fileID: fileID,
                deadline: deadline)
        } catch {
            throw teardownFailure(error)
        }
    }

    private func closeSFTPFileWithinUse(
        sftpID: UInt64,
        fileID: UInt64,
        timeout: Duration
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard sftpClients[sftpID]?.files[fileID] != nil else { return }
        guard valid, session != nil else { return }
        do {
            try await closeSFTPFileHoldingOperation(
                sftpID: sftpID,
                fileID: fileID,
                deadline: ContinuousClock.now.advanced(by: timeout))
        } catch {
            throw teardownFailure(error)
        }
    }

    private func closeSFTPFileHoldingOperation(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: false)
        guard let file = sftpClients[sftpID]?.files[fileID] else { return }
        let result = try await repeatUntilCompleteHolding(
            deadline: deadline,
            cancellable: false
        ) {
            libssh2_sftp_close_handle(file)
        }
        guard result == 0 else { throw SSHError.channelFailed }
        sftpClients[sftpID]?.files[fileID] = nil
    }

    func removeSFTPFile(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws {
        guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
        await acquireOperation()
        defer { releaseOperation() }
        try await removeSFTPFileHoldingOperation(
            id: id,
            path: path,
            timeout: timeout,
            cancellable: true,
            verifyAbsence: false)
    }

    func removeSFTPFileForCompensation(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws {
        guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
        await acquireOperation()
        defer { releaseOperation() }

        // Keep this permit through failure reclamation. If caller close ran
        // between the failed unlink/stat and shutdown, it could remove the
        // only SFTP state and leave this code unable to reclaim the handle.
        do {
            try await removeSFTPFileHoldingOperation(
                id: id,
                path: path,
                timeout: timeout,
                cancellable: false,
                verifyAbsence: true)
        } catch {
            let normalized = normalize(error)
            var shutdownFailed = false
            do {
                try await reclaimSFTPAfterCompensationFailureHoldingOperation(id: id)
            } catch {
                shutdownFailed = true
            }
            // libssh2 1.11.1 shutdown frees pending unlink/stat packets and the
            // subsystem channel. That bounds an abandoned request to this SFTP
            // client; only a failed shutdown or a lost transport poisons the
            // owning SSH session.
            if shutdownFailed || normalized == .connectionInvalidated {
                invalidateResources()
            }
            throw normalized
        }
    }

    private func reclaimSFTPAfterCompensationFailureHoldingOperation(
        id: UInt64
    ) async throws {
        // The caller owns the operation permit until this handle is either
        // shut down here or reclaimed by whole-session invalidation.
        guard let state = sftpClients.removeValue(forKey: id) else { return }
        guard valid, session != nil else { throw SSHError.connectionInvalidated }

        // Compensation has already exhausted its operation budget. Reclamation
        // gets a separate bounded chance because the caller cannot safely reuse
        // this subsystem until libssh2 has freed its pending packet state.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
#if DEBUG
        if let hold = nextCompensationShutdownHoldForTesting {
            nextCompensationShutdownHoldForTesting = nil
            try await hold()
        }
#endif
        let result = try await repeatUntilCompleteHolding(
            deadline: deadline,
            cancellable: false
        ) {
            libssh2_sftp_shutdown(state.handle)
        }
        guard result == 0 else {
            if Self.isConnectionLoss(result) { throw SSHError.connectionInvalidated }
            throw SSHError.channelFailed
        }
    }

    private func removeSFTPFileHoldingOperation(
        id: UInt64,
        path: String,
        timeout: Duration,
        cancellable: Bool,
        verifyAbsence: Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try await waitUntilSFTPIdle(
            id: id,
            deadline: deadline,
            cancellable: cancellable)
        try beginSFTPUse(id)
        defer { endSFTPUse(id) }
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: cancellable)
        guard valid, let session, let sftp = sftpClients[id]?.handle else {
            throw SSHError.connectionInvalidated
        }
        let result = try await repeatCompensationOperation(
            phase: .unlink,
            deadline: deadline,
            cancellable: cancellable
        ) {
            path.withCString { pathPointer in
                libssh2_sftp_unlink_ex(sftp, pathPointer, UInt32(path.utf8.count))
            }
        }
        if result.code != 0 {
            if Self.isConnectionLoss(result.code) {
                applyTransportSendOwnerDisposition(result.disposition)
                throw SSHError.connectionInvalidated
            }
            let status = UInt64(libssh2_sftp_last_error(sftp))
            applyTransportSendOwnerDisposition(result.disposition)
            if result.disposition == .invalidate { throw SSHError.connectionInvalidated }
            guard verifyAbsence, status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) else {
                throw SSHError.sftpFailure(status: status)
            }
        } else {
            applyTransportSendOwnerDisposition(result.disposition)
        }
        guard verifyAbsence else {
            return
        }

        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let statResult = try await repeatCompensationOperation(
            phase: .stat,
            deadline: deadline,
            cancellable: false
        ) {
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_STAT),
                    &attributes)
            }
        }
        if statResult.code == 0 {
            applyTransportSendOwnerDisposition(statResult.disposition)
            throw SSHError.channelFailed
        }
        if Self.isConnectionLoss(statResult.code) {
            applyTransportSendOwnerDisposition(statResult.disposition)
            throw SSHError.connectionInvalidated
        }
        let status = UInt64(libssh2_sftp_last_error(sftp))
        applyTransportSendOwnerDisposition(statResult.disposition)
        if statResult.disposition == .invalidate { throw SSHError.connectionInvalidated }
        guard status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) else {
            throw SSHError.sftpFailure(status: status)
        }
        guard valid, self.session == session else {
            throw SSHError.connectionInvalidated
        }
    }

    func renameSFTPFileAtomically(
        id: UInt64,
        sourcePath: String,
        destinationPath: String,
        timeout: Duration
    ) async throws {
        guard
            Self.isValidSFTPPath(sourcePath),
            Self.isValidSFTPPath(destinationPath)
        else {
            throw SSHError.channelFailed
        }
        await acquireOperation()
        defer { releaseOperation() }
        let result = try await repeatUntilCompleteHoldingSFTP(
            id: id,
            deadline: ContinuousClock.now.advanced(by: timeout)
        ) { sftp in
            sourcePath.withCString { sourcePointer in
                destinationPath.withCString { destinationPointer in
                    libssh2_sftp_posix_rename_ex(
                        sftp,
                        sourcePointer,
                        sourcePath.utf8.count,
                        destinationPointer,
                        destinationPath.utf8.count)
                }
            }
        }
        try checkSFTPResult(result, sftpID: id)
    }

    func closeSFTP(id: UInt64, timeout: Duration) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard sftpClients[id] != nil else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            try await waitUntilSFTPIdle(
                id: id,
                deadline: deadline,
                cancellable: false)
            guard let state = sftpClients.removeValue(forKey: id) else { return }
            guard valid, session != nil else { return }
            try await waitForTransportSendAdmission(
                owner: allocateTransportSendOwner(),
                deadline: deadline,
                cancellable: false)
            let result = try await repeatUntilCompleteHolding(
                deadline: deadline,
                cancellable: false
            ) {
                libssh2_sftp_shutdown(state.handle)
            }
            guard result == 0 else { throw SSHError.channelFailed }
        } catch {
            throw teardownFailure(error)
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
            valid = false
            oneShotChannels.removeAll()
            streamLocalChannels.removeAll()
            ptyChannels.removeAll()
            sftpClients.removeAll()
            transportSendOwner = nil
            activity.releaseAllWaiters()
            closeDescriptor()
        } catch {
            invalidateResources()
            throw normalize(error)
        }
    }

    func invalidate() {
        invalidateResources()
    }

    var isReusable: Bool {
        valid && session != nil && descriptor >= 0 && authenticated
    }

#if DEBUG
    func directTCPIPInboundBufferHighWaterMarkForTesting() -> Int {
        directTCPIPInboundBufferHighWaterMark
    }

    func holdNextDirectTCPIPInboundBufferFullForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextDirectTCPIPInboundBufferFullHoldForTesting = hold
    }

    func delayNextSFTPWriteForTesting(_ delay: Duration) {
        nextSFTPWriteDelayForTesting = delay
    }

    var isSFTPWriteDelayedForTesting: Bool {
        sftpWriteDelayIsActiveForTesting
    }

    /// Holds the next operation that blocks on the session in the window it
    /// naturally passes through: released to the next operation, not yet
    /// watching the socket. Widening that window turns the race this driver
    /// has to survive into something a test can drive.
    func holdNextSessionWaitForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextSessionWaitHoldForTesting = hold
    }

    func holdNextExecChannelAllocationForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecChannelAllocatedHoldForTesting = hold
    }

    func holdNextExecCleanupForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecCleanupHoldForTesting = hold
    }

    func holdNextOutboundWriteParkForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextOutboundWriteParkHoldForTesting = hold
    }

    func holdNextOneShotEstablishedForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOneShotEstablishedHoldForTesting = hold
    }

    func holdNextOwnedLoopTopForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOwnedLoopTopHoldForTesting = hold
    }

    func holdNextOwnedDrainForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOwnedDrainHoldForTesting = hold
    }

    func holdNextChannelOpenSlotForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextChannelOpenSlotHoldForTesting = hold
    }

    func holdNextChannelTeardownForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextChannelTeardownHoldForTesting = hold
    }

    func failNextResumedChannelOpenWaiterForTesting(_ error: SSHError) {
        nextResumedChannelOpenWaiterErrorForTesting = error
    }

    func holdNextChannelOpenWaiterRegistrationForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextChannelOpenWaiterRegistrationHoldForTesting = hold
    }

    func sftpUseCountForTesting() -> Int {
        sftpUses.values.reduce(0, +)
    }

    func sftpIdleWaiterCountForTesting() -> Int {
        sftpIdleWaiters.count
    }

    func channelOpenWaiterCountForTesting() -> Int {
        channelOpenWaiters.count
    }

    func ptyTeardownWaiterCountForTesting() -> Int {
        ptyTeardownWaiters.count
    }

    func ptyChannelCountForTesting() -> Int {
        ptyChannels.count
    }

    func ptyAcceptsIOForTesting(id: UInt64) -> Bool {
        ptyChannels[id]?.acceptsIO == true
    }

    func startSamplingTransportSendOwnerForTesting() {
        ownerSamplesForTesting = []
    }

    func transportSendOwnerSamplesForTesting() -> [TransportSendOwnerSample] {
        ownerSamplesForTesting ?? []
    }

    func oneShotRegistryCountForTesting() -> Int {
        oneShotChannels.count
    }

    func shrinkSendBufferForTesting(bytes: Int) throws {
        guard descriptor >= 0 else { throw SSHError.connectionInvalidated }
        var size = Int32(clamping: bytes)
        let result = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDBUF,
            &size,
            socklen_t(MemoryLayout<Int32>.size))
        guard result == 0 else { throw SSHError.connectionInvalidated }
    }

    func runNextCompensationUnlinkPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationUnlinkPhaseHookForTesting = hook
    }

    func runNextCompensationStatPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationStatPhaseHookForTesting = hook
    }

    func runNextCompensationShutdownHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationShutdownHoldForTesting = hook
    }

    func failNextSFTPInitBeforeEAGAINForTesting() {
        shouldFailNextSFTPInitBeforeEAGAINForTesting = true
    }

    var operationWaiterCountForTesting: Int {
        operationWaiters.count
    }

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
        activity.install(on: createdSession)
        try configureAlgorithms(createdSession)

        let handshakeResult = try await repeatUntilComplete(deadline: deadline) {
            libssh2_session_handshake(createdSession, descriptor)
        }
        guard handshakeResult == 0 else {
#if DEBUG
            HandshakeFailureObservation.observer?(handshakeResult)
#endif
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
                deadline: deadline)
            guard let channel else { throw SSHError.channelFailed }
            let transport = try DirectTCPIPByteTransport()
            let pumpDescriptor = try transport.takePumpDescriptor()
#if DEBUG
            directTCPIPInboundBufferHighWaterMark = 0
#endif
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
            } else if !(error is ChannelOpenAdmissionError),
                normalized == .timedOut || normalized == .cancelled
            {
                invalidateResources()
            }
            throw normalized
        }
    }

    private func openDirectTCPIPChannel(
        endpoint: SSHEndpoint,
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        do {
            try await claimChannelOpenSlot(deadline: deadline, cancellable: true)
        } catch {
            throw ChannelOpenAdmissionError(underlying: normalize(error))
        }
        defer { releaseChannelOpenSlot() }
        let owner = allocateTransportSendOwner()
        while true {
            try checkProgress(deadline: deadline)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                throw error
            }
            let session = try requireSession()
            let channel = endpoint.host.withCString { hostPointer in
                libssh2_channel_direct_tcpip_ex(
                    session,
                    hostPointer,
                    Int32(endpoint.port),
                    "127.0.0.1",
                    0)
            }
            if let channel {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                return channel
            }

            let error = libssh2_session_last_errno(session)
            let openFailure = error == LIBSSH2_ERROR_EAGAIN
                ? nil
                : classifyDirectTCPIPOpenFailure(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await waitForSession(session, deadline: deadline)
                } catch {
                    if transportSendOwner == owner { invalidateResources() }
                    throw error
                }
            } else {
                applyTransportSendOwnerDisposition(disposition)
                throw openFailure ?? SSHError.channelFailed
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
                let maximumReadCount = min(scratch.count, bufferLimit - toInner.count)
                let readCount = scratch.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_read_ex(
                        channel,
                        0,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        maximumReadCount)
                }
                if readCount > 0 {
                    toInner.append(contentsOf: scratch.prefix(readCount))
#if DEBUG
                    directTCPIPInboundBufferHighWaterMark = max(
                        directTCPIPInboundBufferHighWaterMark,
                        toInner.count)
                    if toInner.count >= bufferLimit,
                        let hold = nextDirectTCPIPInboundBufferFullHoldForTesting
                    {
                        nextDirectTCPIPInboundBufferFullHoldForTesting = nil
                        await hold()
                        if Task.isCancelled { throw SSHError.cancelled }
                        guard valid else { throw SSHError.connectionInvalidated }
                    }
#endif
                    madeProgress = true
                } else if readCount != 0 && readCount != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw SSHError.connectionFailed
                }
                if libssh2_channel_eof(channel) == 1 {
                    outerEOF = true
                    madeProgress = true
                }
            }

            let shouldHoldBridgeWrites: Bool
#if DEBUG
            shouldHoldBridgeWrites = nextDirectTCPIPInboundBufferFullHoldForTesting != nil
#else
            shouldHoldBridgeWrites = false
#endif
            if !toInner.isEmpty, !shouldHoldBridgeWrites {
                switch try Self.writeBridge(toInner, descriptor: bridgeDescriptor) {
                case .wrote(let written):
                    toInner.removeFirst(written)
                    madeProgress = true
                case .blocked:
                    break
                case .peerClosed:
                    // The nested session closes its socket before the pump has
                    // necessarily delivered the last bytes already read from
                    // the outer channel. No consumer remains for this
                    // direction, and that full-descriptor close also ends the
                    // opposite one.
                    toInner.removeAll(keepingCapacity: true)
                    innerEOF = true
                    madeProgress = true
                }
            }

            if outerEOF, toInner.isEmpty {
                // `toInner` only grows while `outerEOF` is false, so no later
                // bridge write can misread this local shutdown as peer close.
                _ = Darwin.shutdown(bridgeDescriptor, SHUT_WR)
            }
            if innerEOF, toOuter.isEmpty { return }

            if !madeProgress {
                var innerDirections: SocketDirections = []
                if !innerEOF, toOuter.count < bufferLimit { innerDirections.insert(.read) }
                if !toInner.isEmpty { innerDirections.insert(.write) }
                let pumpDeadline = ContinuousClock.now.advanced(by: .seconds(60))
                // The one wait in the driver that needs no SessionActivity
                // watch. `forwarding` is a hard mutual-exclusion gate: every
                // other entry point refuses while it is set, and `close`
                // throws rather than run. Once this pump is up, the outer
                // session has no other operation that could drain the socket
                // out from under it, so the socket edge is the only edge
                // there is. Do not copy this to a site that shares a session.
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

    static func writeBridge(_ data: Data, descriptor: Int32) throws -> BridgeWriteResult {
        let (written, writeErrno) = data.withUnsafeBytes { bytes -> (Int, Int32) in
            guard let baseAddress = bytes.baseAddress else { return (0, 0) }
            let result = Darwin.write(descriptor, baseAddress, bytes.count)
            return (result, result < 0 ? errno : 0)
        }
        if written > 0 { return .wrote(written) }
        if written == 0 || writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
            return .blocked
        }
        if writeErrno == EPIPE { return .peerClosed }
        throw SSHError.connectionFailed
    }

    /// Everything a blocked operation needs to wait on the session, captured
    /// while it still holds the session. Another operation may drain the
    /// socket between that capture and the wait actually arming, so the plan
    /// carries the receive count that makes such a drain detectable.
    private struct SessionWaitPlan {
        let descriptor: Int32
        let directions: SocketDirections
        let watch: SessionActivityWatch
    }

    private func sessionWaitPlan(_ session: OpaquePointer) -> SessionWaitPlan {
        SessionWaitPlan(
            descriptor: descriptor,
            directions: sessionDirections(session),
            watch: activity.watch())
    }

    private func awaitSessionProgress(
        _ plan: SessionWaitPlan,
        until deadline: ContinuousClock.Instant,
        cancellable: Bool = true
    ) async throws {
#if DEBUG
        if let hold = nextSessionWaitHoldForTesting {
            nextSessionWaitHoldForTesting = nil
            try await hold()
        }
#endif
        try await SocketReadiness.wait(
            descriptor: plan.descriptor,
            directions: plan.directions,
            until: deadline,
            cancellable: cancellable,
            watching: plan.watch)
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

    private func sessionReportsOutbound(_ session: OpaquePointer) -> Bool {
        libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
    }

    private func requireSession() throws -> OpaquePointer {
        guard valid, let session else { throw SSHError.connectionInvalidated }
        return session
    }

    private func allocateTransportSendOwner() -> UInt64 {
        nextTransportSendIdentity &+= 1
        return nextTransportSendIdentity
    }

    private func notePacketProducingResult(
        _ result: Int32,
        owner: UInt64,
        session: OpaquePointer
    ) -> TransportSendOwnerDisposition {
        if result == LIBSSH2_ERROR_EAGAIN {
            if sessionReportsOutbound(session), transportSendOwner == nil {
                transportSendOwner = owner
            }
            return .unchanged
        }
        guard transportSendOwner == owner else { return .unchanged }
        let disposition = Self.transportSendOwnerDisposition(
            result: result,
            isCurrentOwner: true,
            hasOutbound: sessionReportsOutbound(session))
        if disposition == .clear { transportSendOwner = nil }
        return disposition
    }

    static func transportSendOwnerDisposition(
        result: Int32,
        isCurrentOwner: Bool,
        hasOutbound: Bool
    ) -> TransportSendOwnerDisposition {
        guard isCurrentOwner else { return .unchanged }
        if result < 0, hasOutbound { return .invalidate }
        return .clear
    }

    private func applyTransportSendOwnerDisposition(
        _ disposition: TransportSendOwnerDisposition
    ) {
        if disposition == .invalidate { invalidateResources() }
    }

    private func notePacketProducingWrite(
        _ written: Int,
        owner: UInt64,
        session: OpaquePointer
    ) -> TransportSendOwnerDisposition {
        if written == Int(LIBSSH2_ERROR_EAGAIN) {
            return notePacketProducingResult(
                LIBSSH2_ERROR_EAGAIN,
                owner: owner,
                session: session)
        } else if written >= 0 {
            return notePacketProducingResult(0, owner: owner, session: session)
        } else {
            return notePacketProducingResult(
                Int32(clamping: written),
                owner: owner,
                session: session)
        }
    }

    /// Caller holds the operation mutex. Releases it while a foreign owner
    /// occupies the send, then re-acquires before returning or throwing so a
    /// matching `releaseOperation()` stays balanced.
    private func waitForTransportSendAdmission(
        owner: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        while let existing = transportSendOwner, existing != owner {
            let session = try requireSession()
            let plan = sessionWaitPlan(session)
            releaseOperation()
            do {
                try await awaitSessionProgress(
                    plan,
                    until: deadline,
                    cancellable: cancellable)
            } catch {
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
        }
    }

    /// Drives the exact owning libssh2 call to a non-`EAGAIN` result, or
    /// invalidates. Cancellation and timeout never clear ownership by themselves.
    private func finishOwnedSendIfNeeded(
        owner: UInt64,
        drive: () -> Int32
    ) async {
        await finishOwnedSendIfNeeded(owner: owner, drive: { drive() as Int32? })
    }

    private func finishOwnedSendIfNeeded(
        owner: UInt64,
        drive: () -> Int32?
    ) async {
        guard transportSendOwner == owner else { return }
#if DEBUG
        if let hold = nextOwnedDrainHoldForTesting {
            nextOwnedDrainHoldForTesting = nil
            do {
                try await hold()
            } catch {
                abandonOwnedSend(owner: owner, drive: drive)
                return
            }
        }
#endif
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        do {
            while transportSendOwner == owner {
                if ContinuousClock.now >= deadline {
                    abandonOwnedSend(owner: owner, drive: drive)
                    return
                }
                guard valid else { return }
                guard let result = drive() else {
                    invalidateResources()
                    return
                }
                let session = try requireSession()
                let disposition = notePacketProducingResult(
                    result,
                    owner: owner,
                    session: session)
                if disposition == .invalidate {
                    abandonOwnedSend(owner: owner, drive: drive)
                    return
                }
                applyTransportSendOwnerDisposition(disposition)
                if result != LIBSSH2_ERROR_EAGAIN { return }
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: false)
            }
        } catch {
            abandonOwnedSend(owner: owner, drive: drive)
        }
    }

    /// Completes the one pending packet through its exact owning call while
    /// native I/O is redirected locally, then synchronously frees the session.
    private func abandonOwnedSend(
        owner: UInt64,
        drive: () -> Int32?
    ) {
        guard transportSendOwner == owner, let session else {
            invalidateResources()
            return
        }
        heeler_libssh2_prepare_session_abandonment(session)
        _ = drive()
        invalidateResources()
    }

    private func claimChannelOpenSlot(
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        while channelOpenInProgress {
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
            nextChannelOpenWaiterID &+= 1
            let waiterID = nextChannelOpenWaiterID
            do {
                try await waitForChannelOpenSlot(
                    id: waiterID,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await acquireOperation()
                throw error
            }
            await acquireOperation()
#if DEBUG
            if let error = nextResumedChannelOpenWaiterErrorForTesting {
                nextResumedChannelOpenWaiterErrorForTesting = nil
                throw error
            }
#endif
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
            guard valid else { throw SSHError.connectionInvalidated }
        }
        channelOpenInProgress = true
#if DEBUG
        if let hold = nextChannelOpenSlotHoldForTesting {
            nextChannelOpenSlotHoldForTesting = nil
            // Keep the native-open slot claimed while allowing later callers
            // to reach and observe its waiter queue.
            releaseOperation()
            do {
                try await hold()
            } catch {
                await acquireOperation()
                releaseChannelOpenSlot()
                throw error
            }
            await acquireOperation()
        }
#endif
    }

    private func waitForChannelOpenSlot(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        if cancellable {
            try await withTaskCancellationHandler {
#if DEBUG
                await holdChannelOpenWaiterRegistrationForTestingIfNeeded()
#endif
                try await parkChannelOpenWaiterUntilDeadline(
                    id: id,
                    deadline: deadline,
                    cancellable: true)
            } onCancel: {
                Task { await self.resumeChannelOpenWaiter(id: id, .failure(SSHError.cancelled)) }
            }
        } else {
            try await parkChannelOpenWaiterUntilDeadline(
                id: id,
                deadline: deadline,
                cancellable: false)
        }
    }

    private func parkChannelOpenWaiterUntilDeadline(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard !cancellable || !Task.isCancelled else {
                releaseOperation()
                continuation.resume(throwing: SSHError.cancelled)
                return
            }
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumeChannelOpenWaiter(id: id, .failure(SSHError.timedOut))
            }
            channelOpenWaiters[id] = DriverWaiter(
                continuation: continuation,
                deadlineTask: deadlineTask)
            releaseOperation()
        }
    }

    private func resumeChannelOpenWaiter(id: UInt64, _ result: Result<Void, any Error>) {
        guard let waiter = channelOpenWaiters.removeValue(forKey: id) else { return }
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(with: result)
    }

    private func releaseChannelOpenSlot() {
        channelOpenInProgress = false
        resumeAllChannelOpenWaiters()
    }

    private func resumeAllChannelOpenWaiters() {
        let ids = Array(channelOpenWaiters.keys)
        for id in ids {
            resumeChannelOpenWaiter(id: id, .success(()))
        }
    }

    private func waitUntilPTYTeardownCompletes(
        id: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws {
        while ptyChannels[id]?.teardownInProgress == true {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            nextPTYTeardownWaiterID &+= 1
            let waiterID = nextPTYTeardownWaiterID
            do {
                try await parkPTYTeardownWaiter(
                    id: waiterID,
                    ptyID: id,
                    deadline: deadline)
            } catch {
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            guard valid else { throw SSHError.connectionInvalidated }
        }
    }

    private func parkPTYTeardownWaiter(
        id: UInt64,
        ptyID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumePTYTeardownWaiter(
                    id: id,
                    .failure(SSHError.timedOut))
            }
            ptyTeardownWaiters[id] = PTYTeardownWaiter(
                ptyID: ptyID,
                waiter: DriverWaiter(
                    continuation: continuation,
                    deadlineTask: deadlineTask))
            releaseOperation()
        }
    }

    private func resumePTYTeardownWaiter(
        id: UInt64,
        _ result: Result<Void, any Error>
    ) {
        guard let entry = ptyTeardownWaiters.removeValue(forKey: id) else { return }
        entry.waiter.deadlineTask.cancel()
        entry.waiter.continuation.resume(with: result)
    }

    private func wakePTYTeardownWaiters(for ptyID: UInt64) {
        let ids = ptyTeardownWaiters.compactMap { id, entry in
            entry.ptyID == ptyID ? id : nil
        }
        for id in ids { resumePTYTeardownWaiter(id: id, .success(())) }
    }

    private func resumeAllPTYTeardownWaiters() {
        let ids = Array(ptyTeardownWaiters.keys)
        for id in ids { resumePTYTeardownWaiter(id: id, .success(())) }
    }

    private func registerOneShot(
        channel: OpaquePointer,
        session: OpaquePointer
    ) -> UInt64 {
        nextOneShotID &+= 1
        let id = nextOneShotID
        oneShotChannels[id] = OneShotChannel(
            channel: channel,
            session: session)
        return id
    }

    private func removeOneShot(_ id: UInt64) {
        oneShotChannels.removeValue(forKey: id)
    }

    private func resolveChannel(
        _ identity: ChannelIdentity,
        allowClosing: Bool = false
    ) throws -> OpaquePointer {
        let session = try requireSession()
        switch identity {
        case .oneShot(let id):
            guard let entry = oneShotChannels[id], entry.session == session else {
                throw SSHError.channelFailed
            }
            return entry.channel
        case .pty(let id):
            guard let state = ptyChannels[id], allowClosing || state.acceptsIO else {
                throw SSHError.channelFailed
            }
            return state.channel
        case .streamLocal(let id):
            guard let state = streamLocalChannels[id], allowClosing || state.acceptsIO else {
                throw SSHError.channelFailed
            }
            return state.channel
        }
    }

    private func writeChannel(
        _ channel: OpaquePointer,
        data: Data,
        offset: Int
    ) -> Int {
        data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_channel_write_ex(
                channel,
                0,
                baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                data.count - offset)
        }
    }

    private func writeChannelOnce(
        identity: ChannelIdentity,
        data: Data,
        offset: Int
    ) -> Int32? {
        guard let channel = try? resolveChannel(identity) else { return nil }
        let written = writeChannel(channel, data: data, offset: offset)
        if written == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if written >= 0 { return 0 }
        return Int32(clamping: written)
    }

    private func readSFTPOnce(sftpID: UInt64, fileID: UInt64) -> Int32? {
        guard let file = sftpClients[sftpID]?.files[fileID] else { return nil }
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
        let read = scratch.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_sftp_read(
                file,
                baseAddress.assumingMemoryBound(to: CChar.self),
                bytes.count)
        }
        if read == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if read >= 0 { return 0 }
        return Int32(clamping: read)
    }

    private func writeSFTPOnce(
        sftpID: UInt64,
        fileID: UInt64,
        data: Data,
        offset: Int
    ) -> Int32? {
        guard let file = sftpClients[sftpID]?.files[fileID] else { return nil }
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_sftp_write(
                file,
                baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                data.count - offset)
        }
        if written == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if written >= 0 { return 0 }
        return Int32(clamping: written)
    }

    private func sampleTransportSendOwnerIfNeeded() {
#if DEBUG
        guard ownerSamplesForTesting != nil else { return }
        let outboundPending: Bool
        if let session {
            outboundPending = sessionReportsOutbound(session)
        } else {
            outboundPending = false
        }
        ownerSamplesForTesting?.append(
            TransportSendOwnerSample(
                hasOwner: transportSendOwner != nil,
                isValid: valid,
                outboundPending: outboundPending))
#endif
    }

#if DEBUG
    private func holdOutboundWriteParkForTestingIfNeeded() async {
        guard let hold = nextOutboundWriteParkHoldForTesting else { return }
        nextOutboundWriteParkHoldForTesting = nil
        await hold()
    }

    private func holdOneShotEstablishedForTestingIfNeeded() async throws {
        guard let hold = nextOneShotEstablishedHoldForTesting else { return }
        nextOneShotEstablishedHoldForTesting = nil
        try await hold()
    }
#endif

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
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        do {
            try await claimChannelOpenSlot(deadline: deadline, cancellable: true)
        } catch {
            throw ChannelOpenAdmissionError(underlying: normalize(error))
        }
        defer { releaseChannelOpenSlot() }
        let owner = allocateTransportSendOwner()
        while true {
            try checkProgress(deadline: deadline)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                throw error
            }
            let session = try requireSession()
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32 * 1024,
                nil,
                0)
            {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                return channel
            }
            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            guard error == LIBSSH2_ERROR_EAGAIN else {
                applyTransportSendOwnerDisposition(disposition)
                throw SSHError.channelFailed
            }
            do {
                try await waitForSession(session, deadline: deadline)
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                throw error
            }
        }
    }

    private func openStreamLocalChannel(
        socketPath: String,
        deadline: ContinuousClock.Instant
    ) async throws -> OpaquePointer {
        do {
            try await claimChannelOpenSlot(deadline: deadline, cancellable: true)
        } catch {
            throw ChannelOpenAdmissionError(underlying: normalize(error))
        }
        defer { releaseChannelOpenSlot() }
        let owner = allocateTransportSendOwner()
        while true {
            try checkProgress(deadline: deadline)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                throw error
            }
            let session = try requireSession()
            let channel = socketPath.withCString { socketPathPointer in
                libssh2_channel_direct_streamlocal_ex(
                    session,
                    socketPathPointer,
                    "127.0.0.1",
                    0)
            }
            if let channel {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                return channel
            }

            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                do {
                    try await waitForSession(session, deadline: deadline)
                } catch {
                    if transportSendOwner == owner { invalidateResources() }
                    throw error
                }
            } else {
                applyTransportSendOwnerDisposition(disposition)
                throw Self.mappedStreamLocalOpenError(error)
            }
        }
    }

    /// Two causes arrive on the same failure path and the errno is all that
    /// separates them. SSH forwarding policy or a stale socket refuses this one
    /// channel and leaves the session healthy, so the callers must spare it;
    /// a socket-level loss means there is no session left to spare, and
    /// reporting it as a refusal is what lets `isReusable` stay true on a dead
    /// connection. `mappedSFTPError` splits the same two cases the same way,
    /// down to the verdict it returns for the loss.
    ///
    /// `mapSessionError` is deliberately not consulted: it classifies
    /// handshake- and authentication-class codes and funnels everything else
    /// into `.connectionFailed`, which would erase the `.streamLocalOpenFailed`
    /// the socket diagnostic above this layer keys on.
    private static func mappedStreamLocalOpenError(_ code: Int32) -> SSHError {
        if isConnectionLoss(code) { return .connectionInvalidated }
        return .streamLocalOpenFailed
    }

    private func startExec(
        identity: ChannelIdentity,
        command: String,
        deadline: ContinuousClock.Instant
    ) async throws {
        let result = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity
        ) { channel in
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

    private func configurePTY(
        identity: ChannelIdentity,
        terminal: String,
        columns: Int,
        rows: Int,
        deadline: ContinuousClock.Instant
    ) async throws {
        let mergeChannel = try resolveChannel(identity)
        let mergeResult = libssh2_channel_handle_extended_data2(
            mergeChannel,
            LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE)
        guard mergeResult == 0 else { throw SSHError.channelFailed }

        let result = try await repeatUntilComplete(deadline: deadline) {
            guard let channel = try? resolveChannel(identity) else {
                return LIBSSH2_ERROR_CHANNEL_CLOSED
            }
            return terminal.withCString { terminalPointer in
                libssh2_channel_request_pty_ex(
                    channel,
                    terminalPointer,
                    UInt32(terminal.utf8.count),
                    nil,
                    0,
                    Int32(columns),
                    Int32(rows),
                    0,
                    0)
            }
        }
        guard result == 0 else { throw SSHError.channelFailed }
    }

    private func exchange(
        identity: ChannelIdentity,
        input: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> SSHExecResult {
        var inputOffset = 0
        var sentEOF = false
        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let writeOwner = allocateTransportSendOwner()
        let eofOwner = allocateTransportSendOwner()
        let stdoutOwner = allocateTransportSendOwner()
        let stderrOwner = allocateTransportSendOwner()

        func drainOwnedSends(inputOffset: Int) async {
            await finishOwnedSendIfNeeded(owner: writeOwner) {
                writeChannelOnce(identity: identity, data: input, offset: inputOffset)
            }
            await finishOwnedSendIfNeeded(owner: eofOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                return libssh2_channel_send_eof(channel)
            }
            await finishOwnedSendIfNeeded(owner: stdoutOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(channel: channel, stream: 0, buffer: &scratch)
            }
            await finishOwnedSendIfNeeded(owner: stderrOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(
                    channel: channel,
                    stream: Int32(SSH_EXTENDED_DATA_STDERR),
                    buffer: &scratch)
            }
        }

        while true {
            do {
                try checkProgress(deadline: deadline)
                var madeProgress = false
                var skipReads = false

                if inputOffset < input.count {
                    try await waitForTransportSendAdmission(
                        owner: writeOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let written = writeChannel(channel, data: input, offset: inputOffset)
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: writeOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if written > 0 {
                        inputOffset += written
                        madeProgress = true
                    } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == writeOwner {
                        skipReads = true
                    }
                } else if !sentEOF {
                    try await waitForTransportSendAdmission(
                        owner: eofOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let result = libssh2_channel_send_eof(channel)
                    let disposition = notePacketProducingResult(
                        result,
                        owner: eofOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if result == 0 {
                        sentEOF = true
                        madeProgress = true
                    } else if result != LIBSSH2_ERROR_EAGAIN {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == eofOwner {
                        skipReads = true
                    }
                }

                if !skipReads {
                    try await waitForTransportSendAdmission(
                        owner: stdoutOwner,
                        deadline: deadline,
                        cancellable: true)
                    let stdoutChannel = try resolveChannel(identity)
                    let session = try requireSession()
                    let stdoutRead = try readAvailableNoting(
                        channel: stdoutChannel,
                        stream: 0,
                        buffer: &buffer,
                        owner: stdoutOwner,
                        session: session)
                    if stdoutRead.count > 0 {
                        stdout.append(stdoutRead)
                        madeProgress = true
                    }
                    if transportSendOwner != stdoutOwner {
                        try await waitForTransportSendAdmission(
                            owner: stderrOwner,
                            deadline: deadline,
                            cancellable: true)
                        let stderrChannel = try resolveChannel(identity)
                        let stderrSession = try requireSession()
                        let stderrRead = try readAvailableNoting(
                            channel: stderrChannel,
                            stream: Int32(SSH_EXTENDED_DATA_STDERR),
                            buffer: &buffer,
                            owner: stderrOwner,
                            session: stderrSession)
                        if stderrRead.count > 0 {
                            stderr.append(stderrRead)
                            madeProgress = true
                        }
                    }
                }

                let eofChannel = try resolveChannel(identity)
                if libssh2_channel_eof(eofChannel) == 1 {
                    let exitStatus = try await exitStatusAfterChannelClose(
                        identity: identity,
                        deadline: deadline)
                    return SSHExecResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitStatus: exitStatus,
                        reachedEOF: true)
                }

                let plan = sessionWaitPlan(try requireSession())
                if madeProgress {
                    releaseOperation()
                    await Task.yield()
                    await acquireOperation()
                } else {
                    releaseOperation()
                    do {
                        try await awaitSessionProgress(plan, until: deadline)
                    } catch {
                        let drainInputOffset = inputOffset
                        await acquireOperation()
                        await drainOwnedSends(inputOffset: drainInputOffset)
                        throw error
                    }
                    await acquireOperation()
                }
            } catch {
                await drainOwnedSends(inputOffset: inputOffset)
                throw error
            }
        }
    }

    private func exchangeResponseLine(
        identity: ChannelIdentity,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant,
        beforeRequestWrite: (@Sendable () async throws -> Void)? = nil,
        onRequestWritten: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        var requestOffset = 0
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var didAnnounceWrite = false
        let writeOwner = allocateTransportSendOwner()
        let readOwner = allocateTransportSendOwner()

        try await beforeRequestWrite?()

        func drainOwnedSends(requestOffset: Int) async {
            await finishOwnedSendIfNeeded(owner: writeOwner) {
                writeChannelOnce(identity: identity, data: request, offset: requestOffset)
            }
            await finishOwnedSendIfNeeded(owner: readOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(channel: channel, stream: 0, buffer: &scratch)
            }
        }

        while true {
            do {
                try checkProgress(deadline: deadline)
                var madeProgress = false
                var skipRead = false

                if requestOffset < request.count {
                    try await waitForTransportSendAdmission(
                        owner: writeOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let written = writeChannel(channel, data: request, offset: requestOffset)
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: writeOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if written > 0 {
                        requestOffset += written
                        madeProgress = true
                    } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == writeOwner {
                        skipRead = true
                    }
                }
                if requestOffset == request.count, !didAnnounceWrite {
                    didAnnounceWrite = true
                    await onRequestWritten?()
                }

                if !skipRead {
                    try await waitForTransportSendAdmission(
                        owner: readOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let received = try readAvailableNoting(
                        channel: channel,
                        stream: 0,
                        buffer: &buffer,
                        owner: readOwner,
                        session: session)
                    if !received.isEmpty {
                        response.append(received)
                        madeProgress = true
                        if let newline = response.firstIndex(of: 0x0A) {
                            let lineLength = response.distance(
                                from: response.startIndex,
                                to: newline) + 1
                            guard lineLength <= maximumResponseBytes else {
                                throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                            }
                            return Data(response.prefix(lineLength))
                        }
                        guard response.count <= maximumResponseBytes else {
                            throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                        }
                    }
                }

                if libssh2_channel_eof(try resolveChannel(identity)) == 1 {
                    throw SSHError.unexpectedEOF
                }

                let plan = sessionWaitPlan(try requireSession())
                if madeProgress {
                    releaseOperation()
                    await Task.yield()
                    await acquireOperation()
                } else {
                    releaseOperation()
                    do {
                        try await awaitSessionProgress(plan, until: deadline)
                    } catch {
                        let drainRequestOffset = requestOffset
                        await acquireOperation()
                        await drainOwnedSends(requestOffset: drainRequestOffset)
                        throw error
                    }
                    await acquireOperation()
                }
            } catch {
                await drainOwnedSends(requestOffset: requestOffset)
                throw error
            }
        }
    }

    private func readAvailable(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) throws -> Data {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
        throw SSHError.channelFailed
    }

    private func readAvailableNoting(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8],
        owner: UInt64,
        session: OpaquePointer
    ) throws -> Data {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        let disposition = notePacketProducingWrite(
            count,
            owner: owner,
            session: session)
        applyTransportSendOwnerDisposition(disposition)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
        throw SSHError.channelFailed
    }

    private func readOnce(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) -> Int32 {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        if count == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if count >= 0 { return 0 }
        return Int32(clamping: count)
    }

    private func rawChannelRead(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) -> Int {
        buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_channel_read_ex(
                channel,
                stream,
                baseAddress.assumingMemoryBound(to: CChar.self),
                bytes.count)
        }
    }

    /// Close the remote channel, wait for the peer to acknowledge close, then
    /// read exit status. Remote EOF can precede the exit-status request, so
    /// status is only reliable after wait_closed.
    private func exitStatusAfterChannelClose(
        identity: ChannelIdentity,
        deadline: ContinuousClock.Instant,
        allowClosing: Bool = false
    ) async throws -> Int32 {
        let closeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_close($0)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }
        let waitResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_wait_closed($0)
        }
        guard waitResult == 0 || waitResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }
        return Int32(libssh2_channel_get_exit_status(
            try resolveChannel(identity, allowClosing: allowClosing)))
    }

    private func cleanChannel(
        identity: ChannelIdentity,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        allowClosing: Bool = false
    ) async throws {
        let eofResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            cancellable: cancellable,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_send_eof($0)
        }
        guard eofResult == 0
            || eofResult == LIBSSH2_ERROR_CHANNEL_EOF_SENT
            || eofResult == LIBSSH2_ERROR_CHANNEL_CLOSED
        else {
            throw SSHError.channelFailed
        }

        let closeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            cancellable: cancellable,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_close($0)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }

        let freeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            cancellable: cancellable,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_free($0)
        }
        guard freeResult == 0 else { throw SSHError.channelFailed }
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
        guard eofResult == 0
            || eofResult == LIBSSH2_ERROR_CHANNEL_EOF_SENT
            || eofResult == LIBSSH2_ERROR_CHANNEL_CLOSED
        else {
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

    private func beginSFTPUse(_ id: UInt64) throws {
        guard valid, sftpClients[id] != nil else {
            throw SSHError.connectionInvalidated
        }
        sftpUses[id, default: 0] += 1
    }

    private func endSFTPUse(_ id: UInt64) {
        guard let count = sftpUses[id] else { return }
        if count <= 1 {
            sftpUses.removeValue(forKey: id)
            wakeSFTPIdleWaiters()
        } else {
            sftpUses[id] = count - 1
        }
    }

    private func wakeSFTPIdleWaiters() {
        let ids = Array(sftpIdleWaiters.keys)
        for id in ids { resumeSFTPIdleWaiter(id: id, .success(())) }
    }

    private func waitUntilSFTPIdle(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        while (sftpUses[id] ?? 0) > 0 {
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
            nextSFTPIdleWaiterID &+= 1
            let waiterID = nextSFTPIdleWaiterID
            do {
                try await waitForSFTPIdleSignal(
                    id: waiterID,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw SSHError.timedOut
            }
            guard valid else { throw SSHError.connectionInvalidated }
        }
    }

    private func waitForSFTPIdleSignal(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        if cancellable {
            try await withTaskCancellationHandler {
                try await parkSFTPIdleWaiterUntilDeadline(
                    id: id,
                    deadline: deadline,
                    cancellable: true)
            } onCancel: {
                Task { await self.resumeSFTPIdleWaiter(id: id, .failure(SSHError.cancelled)) }
            }
        } else {
            try await parkSFTPIdleWaiterUntilDeadline(
                id: id,
                deadline: deadline,
                cancellable: false)
        }
    }

    private func parkSFTPIdleWaiterUntilDeadline(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            guard !cancellable || !Task.isCancelled else {
                releaseOperation()
                continuation.resume(throwing: SSHError.cancelled)
                return
            }
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumeSFTPIdleWaiter(id: id, .failure(SSHError.timedOut))
            }
            sftpIdleWaiters[id] = DriverWaiter(
                continuation: continuation,
                deadlineTask: deadlineTask)
            releaseOperation()
        }
    }

    private func resumeSFTPIdleWaiter(
        id: UInt64,
        _ result: Result<Void, any Error>
    ) {
        guard let waiter = sftpIdleWaiters.removeValue(forKey: id) else { return }
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(with: result)
    }

    private func withSFTPUse<T: Sendable>(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        _ body: () async throws -> T
    ) async throws -> T {
        await acquireOperation()
        do {
            try await waitUntilSFTPIdle(
                id: id,
                deadline: deadline,
                cancellable: true)
            try beginSFTPUse(id)
        } catch {
            releaseOperation()
            throw error
        }
        releaseOperation()
        do {
            let result = try await body()
            await acquireOperation()
            endSFTPUse(id)
            releaseOperation()
            return result
        } catch {
            await acquireOperation()
            endSFTPUse(id)
            releaseOperation()
            throw error
        }
    }

    private func holdOwnedLoopTopForTestingIfNeeded(owner: UInt64) async throws {
#if DEBUG
        guard transportSendOwner == owner, let hold = nextOwnedLoopTopHoldForTesting else {
            return
        }
        nextOwnedLoopTopHoldForTesting = nil
        try await hold()
#else
        _ = owner
#endif
    }

    private func checkProgressFinishingOwnedSend(
        owner: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        drive: () -> Int32?
    ) async throws {
        do {
            try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
        } catch {
            await finishOwnedSendIfNeeded(owner: owner, drive: drive)
            throw normalize(error)
        }
        let cancelled = cancellable && Task.isCancelled
        let timedOut = ContinuousClock.now >= deadline
        guard cancelled || timedOut else { return }
        await finishOwnedSendIfNeeded(owner: owner, drive: drive)
        if cancelled { throw SSHError.cancelled }
        throw SSHError.timedOut
    }

    @discardableResult
    private func repeatUntilCompleteHolding(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            let session = try requireSession()
            let result = operation()
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilCompleteHoldingSFTP(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: (OpaquePointer) -> Int32
    ) async throws -> PacketOperationResult {
        try await waitUntilSFTPIdle(
            id: id,
            deadline: deadline,
            cancellable: cancellable)
        try beginSFTPUse(id)
        defer { endSFTPUse(id) }
        let owner = allocateTransportSendOwner()
        func drive() -> Int32? {
            guard let sftp = sftpClients[id]?.handle else { return nil }
            return operation(sftp)
        }
        do {
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable)
        } catch {
            await finishOwnedSendIfNeeded(owner: owner, drive: drive)
            throw error
        }
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: drive)
            guard let sftp = sftpClients[id]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let session = try requireSession()
            let result = operation(sftp)
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                return PacketOperationResult(
                    code: result,
                    disposition: disposition)
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilComplete(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
            let session = try requireSession()
            let result = operation()
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilCompleteYielding(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        identity: ChannelIdentity,
        allowClosing: Bool = false,
        _ operation: (OpaquePointer) -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        func drive() -> Int32? {
            guard let channel = try? resolveChannel(identity, allowClosing: allowClosing) else {
                return nil
            }
            return operation(channel)
        }
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: drive)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
            let channel = try resolveChannel(identity, allowClosing: allowClosing)
            let session = try requireSession()
            let result = operation(channel)
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            let plan = sessionWaitPlan(session)
            releaseOperation()
            do {
                try await awaitSessionProgress(
                    plan,
                    until: deadline,
                    cancellable: cancellable)
            } catch {
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
            await acquireOperation()
        }
    }

    private func repeatCompensationOperation(
        phase: SFTPCompensationPhase,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        _ operation: () -> Int32
    ) async throws -> PacketOperationResult {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            let session = try requireSession()
            let result = operation()
#if DEBUG
            try await runCompensationPhaseHookForTestingIfNeeded(phase)
#endif
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                return PacketOperationResult(
                    code: result,
                    disposition: disposition)
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

#if DEBUG
    private func holdChannelOpenWaiterRegistrationForTestingIfNeeded() async {
        guard let hold = nextChannelOpenWaiterRegistrationHoldForTesting else { return }
        nextChannelOpenWaiterRegistrationHoldForTesting = nil
        await hold()
    }

    private func holdChannelTeardownForTestingIfNeeded() async {
        guard let hold = nextChannelTeardownHoldForTesting else { return }
        nextChannelTeardownHoldForTesting = nil
        releaseOperation()
        await hold()
        await acquireOperation()
    }

    private func holdExecChannelAllocationForTestingIfNeeded() async throws {
        guard let hold = nextExecChannelAllocatedHoldForTesting else { return }
        nextExecChannelAllocatedHoldForTesting = nil
        try await hold()
    }

    private func holdExecCleanupForTestingIfNeeded() async throws {
        guard let hold = nextExecCleanupHoldForTesting else { return }
        nextExecCleanupHoldForTesting = nil
        try await hold()
    }

    private func runCompensationPhaseHookForTestingIfNeeded(
        _ phase: SFTPCompensationPhase
    ) async throws {
        let hook: (@Sendable () async throws -> Void)?
        switch phase {
        case .unlink:
            hook = nextCompensationUnlinkPhaseHookForTesting
            nextCompensationUnlinkPhaseHookForTesting = nil
        case .stat:
            hook = nextCompensationStatPhaseHookForTesting
            nextCompensationStatPhaseHookForTesting = nil
        }
        try await hook?()
    }
#endif

    private func waitForSession(
        _ session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true
    ) async throws {
        try await awaitSessionProgress(
            sessionWaitPlan(session),
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
            LIBSSH2_ERROR_METHOD_NONE,
            LIBSSH2_ERROR_METHOD_NOT_SUPPORTED,
            LIBSSH2_ERROR_ALGO_UNSUPPORTED:
            return .algorithmNegotiationFailed
        // libssh2 emits KEY_EXCHANGE_FAILURE only after it has selected the
        // algorithms and entered the chosen method's exchange_keys callback.
        // That callback's transport, protocol, or crypto error is wrapped by
        // this code, so it is not evidence that the peers had no common method.
        case LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE:
            return .connectionFailed
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED,
            LIBSSH2_ERROR_PASSWORD_EXPIRED:
            return .authenticationFailed
        default:
            return .connectionFailed
        }
    }

    private func checkSFTPResult(
        _ result: Int32,
        sftp: OpaquePointer,
        session: OpaquePointer
    ) throws {
        guard result == 0 else {
            let error = mappedSFTPError(sftp: sftp, code: result)
            if error == .connectionInvalidated { invalidateResources() }
            throw error
        }
        guard valid, self.session == session else { throw SSHError.connectionInvalidated }
    }

    private func checkSFTPResult(_ result: Int32, sftpID: UInt64) throws {
        guard valid, let session, let sftp = sftpClients[sftpID]?.handle else {
            throw SSHError.connectionInvalidated
        }
        try checkSFTPResult(result, sftp: sftp, session: session)
    }

    private func checkSFTPResult(
        _ result: PacketOperationResult,
        sftpID: UInt64
    ) throws {
        do {
            try checkSFTPResult(result.code, sftpID: sftpID)
        } catch {
            applyTransportSendOwnerDisposition(result.disposition)
            throw error
        }
        applyTransportSendOwnerDisposition(result.disposition)
    }

    private func mappedSFTPError(sftp: OpaquePointer, code: Int32) -> SSHError {
        if Self.isConnectionLoss(code) { return .connectionInvalidated }
        return .sftpFailure(status: UInt64(libssh2_sftp_last_error(sftp)))
    }

    private static func isConnectionLoss(_ code: Int32) -> Bool {
        switch code {
        case LIBSSH2_ERROR_SOCKET_NONE,
            LIBSSH2_ERROR_SOCKET_SEND,
            LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT:
            true
        default:
            false
        }
    }

    private static func isValidSFTPPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.utf8.contains(0)
            && path.utf8.count <= Int(UInt32.max)
    }

    private static func isValidPermissions(_ permissions: UInt32) -> Bool {
        permissions & ~0o777 == 0
    }

    private func normalize(_ error: any Error) -> SSHError {
        if let error = error as? ChannelOpenAdmissionError { return error.underlying }
        if let error = error as? SSHError { return error }
        return .connectionFailed
    }

    /// The single verdict every `close*` teardown path takes on its own failure:
    /// `closePTY`, `closeStreamLocal`, `closeSFTP`, and `closeSFTPFile`.
    ///
    /// All four run on a budget their caller hands down, and every `deinit` in
    /// the package hands down the same `.seconds(2)` constant regardless of how
    /// fast the link is. Exhausting that budget arrives here as an ordinary
    /// `SSHError.timedOut` from `repeatUntilComplete`, which the shared
    /// `catch { invalidateResources() }` these four used to run could not tell
    /// from a genuine transport failure — so on a slow enough link, tearing down
    /// one abandoned upload took Events, Attach, and every other channel on the
    /// connection with it, and reported it as `.sshUnreachable` on whatever the
    /// user did next (#136).
    ///
    /// Running out of time is not evidence that the session is corrupt, so
    /// expiry spares it: the caller's own handle is already out of its map,
    /// which bounds the loss to the one channel that could not be drained.
    /// Every other failure still invalidates — a close that failed for a reason
    /// other than the clock says the session itself is no longer trustworthy.
    /// `mappedStreamLocalOpenError` and `mappedSFTPError` split their two causes
    /// on one signal the same way.
    private func teardownFailure(_ error: any Error) -> SSHError {
        let normalized = normalize(error)
        if normalized != .timedOut { invalidateResources() }
        return normalized
    }

    private func invalidateResources() {
        valid = false
        authenticated = false
        streamLocalChannels.removeAll()
        ptyChannels.removeAll()
        sftpClients.removeAll()
        sftpUses.removeAll()
        oneShotChannels.removeAll()
        channelOpenInProgress = false
        resumeAllChannelOpenWaiters()
        resumeAllPTYTeardownWaiters()
        wakeSFTPIdleWaiters()
        activity.releaseAllWaiters()
        InvalidatedSessionTeardown.reclaim(&session)
        transportSendOwner = nil
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
            sampleTransportSendOwnerIfNeeded()
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
        sampleTransportSendOwnerIfNeeded()
    }

    private func releaseOperation() {
        // Handing the session on is the first moment another operation can act
        // on what this one already pulled off the socket.
        activity.wakeStaleWaiters()
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

struct TransportSendOwnerSample: Sendable, Equatable {
    let hasOwner: Bool
    let isValid: Bool
    let outboundPending: Bool

    var isForbiddenClearWindow: Bool {
        !hasOwner && isValid && outboundPending
    }
}
#endif

enum NativeLibrary {
    static let initializationResult = libssh2_init(0)
}
