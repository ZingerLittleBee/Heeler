import CryptoKit
import Darwin
import Foundation
import Testing

@testable import HeelerSSH

@Suite(
    "Session driver resource e2e",
    .enabled(
        if: SessionDriverTestEnvironment.current != nil
            || SessionDriverTestEnvironment.isRequired,
        "requires the disposable sshd fixture"),
    .serialized,
    // Every test here is bounded by its own deadline, so anything that has not
    // finished inside the limit is stalled and must fail rather than hang the
    // runner out to the xcodebuild timeout.
    .timeLimit(.minutes(2)))
struct SessionDriverE2ETests {
    @Test("public connection resolves localhost before authenticating")
    func publicConnectionResolvesLocalhost() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "localhost", port: environment.endpoint.port),
            timeout: .seconds(5))

        try await environment.authenticate(connection)
        let result = try await connection.execute(
            "printf resolved",
            timeout: .seconds(5))

        #expect(result.stdout == Data("resolved".utf8))
        #expect(result.exitStatus == 0)
        try await connection.close(timeout: .seconds(1))
    }

    @Test("bounded response-line exec closes channels on success and failure")
    func boundedResponseLineExec() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()

        let response = try await connection.executeResponseLine(
            "IFS= read -r line; printf 'accepted:%s\\n' \"$line\"",
            input: Data("device-key-line\n".utf8),
            maximumResponseBytes: 64,
            timeout: .seconds(5))
        #expect(response == Data("accepted:device-key-line\n".utf8))

        await #expect(throws: SSHError.responseTooLarge(limit: 64)) {
            _ = try await connection.executeResponseLine(
                "i=0; while [ \"$i\" -lt 65 ]; do printf x; i=$((i + 1)); done; printf '\\n'",
                input: Data("device-key-line\n".utf8),
                maximumResponseBytes: 64,
                timeout: .seconds(5))
        }
        let reuse = try await connection.execute(
            "printf reusable",
            timeout: .seconds(5))
        #expect(reuse.stdout == Data("reusable".utf8))
        #expect(reuse.exitStatus == 0)

        await #expect(throws: SSHError.timedOut) {
            _ = try await connection.executeResponseLine(
                "sleep 30",
                input: Data("device-key-line\n".utf8),
                maximumResponseBytes: 64,
                timeout: .milliseconds(100))
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await connection.execute(
                "printf unreachable",
                timeout: .seconds(5))
        }
    }

    @Test("remote transport loss reclaims every owned native resource")
    func remoteTransportLossReclaimsResources() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for _ in 0..<3 {
            let driver = SessionDriver()
            _ = try await driver.handshake(
                endpoint: environment.endpoint,
                timeout: .seconds(5))
            let privateKey = environment.privateKey
            try await driver.authenticate(
                username: environment.username,
                publicKey: environment.publicKeyBlob,
                signer: { try privateKey.signature(for: $0) },
                timeout: .seconds(5))

            await #expect(throws: SSHError.self) {
                _ = try await driver.execute(
                    command: "kill -9 $PPID; sleep 30",
                    input: Data(),
                    timeout: .seconds(5))
            }

            let state = await driver.resourceStateForTesting()
            #expect(state == SessionDriverResourceState(
                hasSession: false,
                descriptorIsOpen: false,
                isValid: false))
        }
    }

    /// The same reclamation property as above, but the loss arrives as a TCP
    /// reset on a degraded link rather than as a remote process exit, and it is
    /// repeated. The native session state is the per-driver instrument; the
    /// descriptor census is the process-wide one, and it is what would catch a
    /// leak the driver's own accounting cannot see.
    @Test("an abruptly severed weak link reclaims every owned native resource")
    func abruptWeakLinkLossReclaimsResources() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)
        // Five rounds rather than three, holding the tolerance at two: that
        // lifts the margin between "flat" and "leaking one per round" from one
        // descriptor to three, without spending any of the flake budget that
        // tightening the tolerance would. It also severs five sessions instead
        // of three, which is the assertion this test exists for.
        let rounds = 5

        try await withDegradedLink(proxy) {
            // One warm-up round: the first connection allocates caches that
            // never come back, and that is not what the census measures.
            try await severOneSession(
                environment: environment, endpoint: endpoint, proxy: proxy)
            let baseline = openFileDescriptorCount()
            for _ in 0..<rounds {
                try await severOneSession(
                    environment: environment, endpoint: endpoint, proxy: proxy)
            }
            let final = openFileDescriptorCount()
            print(
                "[weak-network] driver descriptors: baseline \(baseline), "
                    + "after \(rounds) severed sessions \(final)")
            #expect(
                final <= baseline + 2,
                "descriptors grew from \(baseline) to \(final) across \(rounds) sessions")
        }
    }

    /// The same transition as the app-level test in `WeakNetworkE2ETests`, one
    /// layer down and over the stream-local path specifically.
    ///
    /// The distinction is the whole point. Both callers skip
    /// `invalidateResources()` on `.streamLocalOpenFailed`, because a policy
    /// denial or a stale socket must not tear down a healthy session — so the
    /// only thing keeping a genuine socket loss from hiding behind that
    /// exemption is `openStreamLocalChannel` classifying the libssh2 errno
    /// instead of discarding it (#138). Discard it again and `isReusable` goes
    /// back to reporting true on a dead connection, which is what this test
    /// fails on.
    ///
    /// The app layer masks it: `classifyStreamLocalOpenFailure` probes with
    /// `test -S` over an *exec* channel, and exec does invalidate, so the
    /// diagnostic tears the session down as a side effect. Route this through
    /// `execute` instead of `exchangeStreamLocal` and it passes while proving
    /// nothing.
    @Test("a severed link makes a stream-local connection report itself disconnected")
    func severedLinkReportsTheStreamLocalConnectionDisconnected() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)

        try await withDegradedLink(proxy) {
            let connection = try await SSHConnection.connect(
                to: endpoint,
                timeout: .seconds(15))
            try await environment.authenticate(connection)
            // Anti-vacuity: true on arrival, and true again after a real
            // stream-local round trip, so the closing assertion cannot be
            // satisfied by a property that was never true.
            #expect(await connection.isConnected)
            let response = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(#"{"id":"probe","method":"ping"}\#n"#.utf8),
                timeout: .seconds(10))
            #expect(!response.isEmpty)
            #expect(await connection.isConnected)

            #expect(try await proxy.cut() > 0)
            await #expect(throws: (any Error).self) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: socketPath,
                    request: Data(#"{"id":"after","method":"ping"}\#n"#.utf8),
                    timeout: .seconds(10))
            }

            // No `close(timeout:)` above this line: the property must go false
            // because the link died, not because it was told to.
            //
            // `isConnected` is `driver.isReusable`, whose first term is `valid`,
            // so this fails on a missing `invalidateResources()`. Asserting the
            // driver state directly would localise it further but needs a test
            // hook on `SSHConnection` that production does not have, which is
            // not worth widening the public surface for.
            #expect(await connection.isConnected == false)
            try? await connection.close(timeout: .seconds(2))
        }
    }

    /// The direct-tcpip pump must stop replenishing the remote channel window
    /// once its one-megabyte inbound buffer is full. A nested SSH session
    /// cannot prove that: its own libssh2 channel window can stop the producer
    /// before this pump is the limiting layer.
    ///
    /// This uses the fixture connection only as an observer and launcher. The
    /// bytes themselves travel from a fast raw TCP writer on the Host, through
    /// a separate production `SessionDriver.openDirectTCPIP`, and into the
    /// exact `DirectTCPIPByteTransport` descriptor a nested session would use.
    @Test("direct TCP/IP pump backpressures a fast raw writer without losing bytes")
    func directTCPIPPumpBackpressuresFastRawWriter() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let observer = try await environment.connect()
        let payloadSize = 32 * 1_048_576
        // Known before launch so a timeout/cancel/parse failure can still clean
        // the remote process and temp dir without a parsed PID handle.
        let directory = "/tmp/heeler-raw-tcp-\(UUID().uuidString)"
        let driver = SessionDriver()
        var transport: DirectTCPIPByteTransport?
        var descriptor: Int32 = -1
        var primaryError: (any Error)?

        do {
            let launched = try await RawTCPWriter.launch(
                directory: directory,
                payloadSize: payloadSize,
                using: observer)

            _ = try await driver.handshake(
                endpoint: environment.endpoint,
                timeout: .seconds(5))
            let privateKey = environment.privateKey
            try await driver.authenticate(
                username: environment.username,
                publicKey: environment.publicKeyBlob,
                signer: { try privateKey.signature(for: $0) },
                timeout: .seconds(5))
            let opened = try await driver.openDirectTCPIP(
                endpoint: SSHEndpoint(host: "127.0.0.1", port: launched.port),
                timeout: .seconds(5))
            transport = opened
            descriptor = try opened.takeDescriptor()

            let preDrainState = try await launched.waitUntilStartedAndSettled(using: observer)
            #expect(
                preDrainState == .blocked,
                "the raw writer completed before the bounded pump was drained")

            var offset = 0
            var firstMismatch: String?
            var reachedEOF = false
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let readDeadline = ContinuousClock.now.advanced(by: .seconds(90))
            while ContinuousClock.now < readDeadline {
                let count = chunk.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    if firstMismatch == nil {
                        for index in 0..<count {
                            let expected = UInt8((offset + index) % 251)
                            if chunk[index] != expected {
                                firstMismatch =
                                    "byte \(offset + index) was \(chunk[index]), expected \(expected)"
                                break
                            }
                        }
                    }
                    offset += count
                    try await Task.sleep(for: .milliseconds(1))
                } else if count == 0 {
                    reachedEOF = true
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    try await Task.sleep(for: .milliseconds(1))
                } else {
                    throw RawTCPWriterError.readFailed(errno)
                }
            }

            #expect(firstMismatch == nil, Comment(rawValue: firstMismatch ?? "payload matched"))
            #expect(offset == payloadSize)
            #expect(reachedEOF)
            #expect(try await launched.completedByteCount(using: observer) == payloadSize)

            Darwin.close(descriptor)
            descriptor = -1
            try await opened.close(timeout: .seconds(5))
            transport = nil
            try await driver.close(timeout: .seconds(2))
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            transport?.abort()
            await driver.invalidate()
            primaryError = error
        }

        // Always wait for cleanup before closing the observer. Preserve the
        // first body or teardown error if a later teardown step also fails.
        // The current task may already be cancelled (timeout body); run remote
        // cleanup in a fresh unstructured context so execute is not short-circuited.
        do {
            let cleanupDirectory = directory
            let cleanupObserver = observer
            try await Task.detached {
                try await RawTCPWriter.cleanup(
                    directory: cleanupDirectory,
                    using: cleanupObserver)
            }.value
        } catch {
            if primaryError == nil {
                primaryError = error
            }
        }

        do {
            try await observer.close(timeout: .seconds(2))
        } catch {
            if primaryError == nil {
                primaryError = error
            }
        }

        if let primaryError {
            throw primaryError
        }
    }

    /// #136 at all four teardown sites, with no link involved in causing it.
    ///
    /// Every `deinit` in the package closes on the same hardcoded `.seconds(2)`,
    /// so on a link slow enough to exhaust it `repeatUntilComplete` throws
    /// `SSHError.timedOut` — and the shared teardown `catch` used to read that
    /// as evidence of a corrupt session, taking Events, Attach and every other
    /// channel on the connection down with the one abandoned transfer.
    ///
    /// A zero budget reaches that same throw deterministically: the deadline is
    /// already past at `repeatUntilComplete`'s first progress check, so it
    /// expires before libssh2 is called at all. That leaves the session provably
    /// healthy underneath, which is the state the old code could not tell from
    /// a dead one — and it needs no impairment proxy to reproduce.
    ///
    /// `isConnected` alone would not prove survival: it is a local flag, and a
    /// change that only stopped clearing it would satisfy it while leaving the
    /// session wedged. Every site is therefore followed by a real round trip.
    @Test("a teardown that only runs out of its budget spares the session")
    func expiredTeardownBudgetSparesTheSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let connection = try await environment.connect()
        let home = try await remoteHome(of: connection)

        for site in TeardownSite.allCases {
            let close = try await site.open(
                on: connection,
                socketPath: socketPath,
                stagePath: "\(home)/teardown-\(UUID().uuidString).part")
            await #expect(
                throws: SSHError.timedOut,
                "\(site.rawValue) did not report the expired budget"
            ) {
                try await close(.zero)
            }
            #expect(await connection.isConnected, "\(site.rawValue) invalidated the session")
            let echo = try await connection.execute("printf survived", timeout: .seconds(5))
            #expect(
                echo.stdout == Data("survived".utf8),
                "\(site.rawValue) left the session unusable")
        }

        try await connection.close(timeout: .seconds(2))
    }

    /// The other direction of #136, and the reason its fix classifies rather
    /// than exempts. A close that fails for a reason other than the clock has to
    /// keep invalidating: the session really is gone, and `isReusable` must say
    /// so or `EventsSession` resubscribes forever onto nothing. Make teardown
    /// unconditionally non-invalidating — the obvious wrong fix — and three of
    /// the four sites here go red.
    ///
    /// The fourth, `closeSFTP`, cannot be driven into that branch, and this
    /// asserts why rather than passing over it: measured on a severed link,
    /// `libssh2_sftp_shutdown` reports success, so `guard result == 0` never
    /// fires and a deadline expiry is the only failure that site has ever been
    /// able to report — which is also why sparing an expiry there gives up no
    /// protection that existed before. Should a libssh2 bump start surfacing
    /// the loss, this is the expectation that says so, and the site moves
    /// across.
    ///
    /// One connection per site: invalidation is one-way, so a shared connection
    /// would let site one satisfy sites two through four for free.
    @Test("a genuine transport failure during teardown still invalidates the session")
    func genuineTeardownFailureStillInvalidatesTheSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)

        for site in TeardownSite.allCases {
            let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(15))
            try await environment.authenticate(connection)
            let home = try await remoteHome(of: connection)
            let close = try await site.open(
                on: connection,
                socketPath: socketPath,
                stagePath: "\(home)/teardown-\(UUID().uuidString).part")
            // Anti-vacuity: a property that were false already would satisfy the
            // closing assertion without the severance proving anything.
            #expect(await connection.isConnected, "\(site.rawValue) started disconnected")

            #expect(try await proxy.cut() > 0)
            // The reset has to have landed before the close touches the socket,
            // or libssh2 queues into a connection that has not failed yet.
            try await Task.sleep(for: .milliseconds(500))
            var thrown: (any Error)?
            do {
                try await close(.seconds(10))
            } catch {
                thrown = error
            }

            guard site.reportsALostLinkFromTeardown else {
                if let thrown {
                    Issue.record(
                        """
                        \(site.rawValue) now reports a lost link as \(thrown). \
                        Move it across and assert the invalidation instead.
                        """)
                }
                try? await connection.close(timeout: .seconds(2))
                continue
            }
            #expect(
                thrown as? SSHError == .channelFailed,
                "\(site.rawValue) reported \(String(describing: thrown)) for a severed link")
            // No `close(timeout:)` above this line: the property must go false
            // because the link died during teardown, not because it was told to.
            #expect(
                await connection.isConnected == false,
                "\(site.rawValue) spared a session the link had already killed")
            try? await connection.close(timeout: .seconds(2))
        }
        try await proxy.reset()
    }

    /// One-shot hooks fail only after the exec channel is allocated and after
    /// catch cleanup owns it. The ordered phase record therefore proves both
    /// failures without racing either operation deadline.
    @Test("issue 149 exec cleanup expiry invalidates allocated channels")
    func issue149ExecCleanupExpiryInvalidatesAllocatedChannels() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for site in Issue149ExecSite.allCases {
            let connection = try await environment.connect()
            let phases = SessionFaultPhaseRecorder()
            await connection.holdNextExecChannelAllocationForTesting {
                await phases.record(.execChannelAllocated)
                throw SSHError.timedOut
            }
            await connection.holdNextExecCleanupForTesting {
                await phases.record(.execCleanup)
                throw SSHError.timedOut
            }

            let error = await site.injectTimeout(on: connection)

            #expect(error == .timedOut, "\(site.rawValue) reported \(String(describing: error))")
            #expect(await phases.recorded == [.execChannelAllocated, .execCleanup])
            #expect(
                await connection.isConnected == false,
                "\(site.rawValue) kept a session with abandoned native state reusable")
            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
            try? await connection.close(timeout: .seconds(1))
        }

    }

    /// No libssh2 init state exists before the first native call or before a
    /// non-EAGAIN native failure. These errors must not poison the SSH session.
    @Test("openSFTP pre-init failures spare the SSH session")
    func openSFTPPreInitFailuresSpareSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for failure in OpenSFTPPreInitFailure.allCases {
            let connection = try await environment.connect()
            let error = await failure.trigger(on: connection)

            #expect(error == failure.expectedError)
            #expect(await connection.isConnected, "\(failure.rawValue) invalidated pre-init")
            let echo = try await connection.execute("printf preinit", timeout: .seconds(5))
            #expect(echo.stdout == Data("preinit".utf8))
            try await connection.close(timeout: .seconds(2))
        }
    }

    /// Once init has returned EAGAIN, libssh2 owns singular session state. The
    /// same timeout/cancellation classifications become fatal after this gate.
    @Test("openSFTP pending init failures invalidate the SSH session")
    func openSFTPPendingInitFailuresInvalidateSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)

        for failure in OpenSFTPPendingFailure.allCases {
            try await proxy.reset()
            let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(15))
            try await environment.authenticate(connection)
            try await proxy.degrade()
            let wait = SessionWaitHold()
            await connection.holdNextSessionWaitForTesting { await wait.waitUntilReleased() }
            let opening = Task {
                try await connection.openSFTP(timeout: failure.timeout)
            }

            do {
                try await waitUntilTrue("\(failure.rawValue) should follow init EAGAIN") {
                    await wait.hasEntered
                }
                if failure == .cancelled {
                    opening.cancel()
                } else {
                    try await Task.sleep(for: .milliseconds(250))
                }
                await wait.release()

                await #expect(throws: failure.expectedError) { _ = try await opening.value }
                #expect(await connection.isConnected == false)
                try? await connection.close(timeout: .seconds(1))
            } catch {
                opening.cancel()
                await wait.release()
                try? await proxy.reset()
                _ = try? await opening.value
                try? await connection.close(timeout: .seconds(1))
                throw error
            }
            try await proxy.reset()
        }
    }

    /// libssh2 1.11.1 shutdown frees both the phase packet and the SFTP channel.
    /// A throwing phase barrier runs after unlink/stat first reaches libssh2.
    /// Successful driver-side shutdown must retain the subsystem ownership,
    /// unblock queued close, remove the staged path, and spare the SSH session.
    @Test("compensation expiry reclaims SFTP and spares the SSH session")
    func compensationExpiryReclaimsSFTPAndSparesSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for phase in CompensationFaultPhase.allCases {
            let connection = try await environment.connect()
            let home = try await remoteHome(of: connection)
            let path = "\(home)/compensation-\(phase.rawValue)-\(UUID().uuidString).part"
            try await phase.prepare(path: path, on: connection)
            let sftp = try await connection.openSFTP(timeout: .seconds(5))
            let phaseFailure = SessionPhaseFaultGate()
            let phases = SessionFaultPhaseRecorder()
            let closeProbe = SSHErrorCompletionProbe()
            await phase.installFailureHook(on: connection) {
                await phases.record(phase.recordedPhase)
                try await phaseFailure.enterThenThrow(.timedOut)
            }
            await connection.runNextCompensationShutdownHookForTesting {
                await phases.record(.compensationShutdown)
            }

            let removal = Task {
                do {
                    try await sftp.removeFileForCompensation(
                        at: path,
                        timeout: .seconds(5))
                    return nil as SSHError?
                } catch {
                    return error as? SSHError
                }
            }
            do {
                try await phaseFailure.waitUntilEntered(
                    timeout: SessionDriverE2ETests.phaseGateObservationBudget)
            } catch {
                await phaseFailure.release()
                _ = await removal.value
                throw error
            }
            let queuedClose = Task {
                do {
                    try await sftp.close(timeout: .zero)
                    await closeProbe.finish(error: nil)
                } catch {
                    await closeProbe.finish(error: error as? SSHError)
                }
            }
            do {
                try await waitUntilTrue("caller close should queue behind compensation") {
                    await connection.operationWaiterCountForTesting == 1
                }
            } catch {
                await phaseFailure.release()
                _ = await removal.value
                await queuedClose.value
                throw error
            }
            #expect(await closeProbe.completed == false)
            await phaseFailure.release()

            let removalError = await removal.value
            await queuedClose.value
            #expect(removalError == .timedOut)
            #expect(
                await phases.recorded == [phase.recordedPhase, .compensationShutdown],
                "\(phase.rawValue) did not reclaim its owned SFTP subsystem")
            #expect(await closeProbe.error == nil)
            try await sftp.close(timeout: .seconds(2))

            let replacementSFTP = try await connection.openSFTP(timeout: .seconds(5))
            #expect(
                try await replacementSFTP.readFileIfPresent(
                    at: path,
                    timeout: .seconds(5)) == nil)
            try await replacementSFTP.close(timeout: .seconds(2))
            #expect(await connection.isConnected)
            let echo = try await connection.execute("printf reclaimed", timeout: .seconds(5))
            #expect(echo.stdout == Data("reclaimed".utf8))
            try await connection.close(timeout: .seconds(2))
        }
    }

    /// The subsystem is removed from the client map before shutdown starts.
    /// If its bounded native shutdown cannot run to completion, only whole-
    /// session teardown can reclaim the handle that no client may adopt.
    @Test("compensation shutdown failure invalidates the SSH session")
    func compensationShutdownFailureInvalidatesSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let home = try await remoteHome(of: connection)
        let path = "\(home)/compensation-shutdown-\(UUID().uuidString).part"
        let sftp = try await connection.openSFTP(timeout: .seconds(5))
        let phases = SessionFaultPhaseRecorder()
        await connection.runNextCompensationUnlinkPhaseHookForTesting {
            await phases.record(.compensationUnlink)
            throw SSHError.timedOut
        }
        await connection.runNextCompensationShutdownHookForTesting {
            await phases.record(.compensationShutdown)
            throw SSHError.timedOut
        }

        let removalError: SSHError?
        do {
            try await sftp.removeFileForCompensation(
                at: path,
                timeout: .seconds(5))
            removalError = nil
        } catch {
            removalError = error as? SSHError
        }

        #expect(removalError == .timedOut)
        #expect(await phases.recorded == [.compensationUnlink, .compensationShutdown])
        #expect(await connection.isConnected == false)
        try await sftp.close(timeout: .seconds(2))
        try await sftp.close(timeout: .seconds(2))
        try? await connection.close(timeout: .seconds(1))
    }

    /// A real link loss takes the same per-site verdict for a different reason:
    /// there is no healthy transport left to preserve. One connection per site
    /// prevents the first one-way invalidation from satisfying the rest.
    @Test("issue 149 transport failures invalidate each tracked operation")
    func issue149TransportFailuresInvalidateTrackedOperations() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)

        for site in Issue149Site.allCases {
            try await proxy.reset()
            let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(15))
            try await environment.authenticate(connection)
            #expect(await connection.isConnected, "\(site.rawValue) started disconnected")

            let body = try await site.transportFailureOperation(on: connection)
            let operation: Task<SSHError?, Never>
            let operationGate = SessionWaitHold()
            let cleanupGate = SessionWaitHold()
            switch site {
            case .execute, .executeResponseLine:
                await connection.holdNextExecChannelAllocationForTesting {
                    await operationGate.waitUntilReleased()
                }
                await connection.holdNextExecCleanupForTesting {
                    await cleanupGate.waitUntilReleased()
                }
            case .openSFTP:
                try await proxy.degrade()
                await connection.holdNextSessionWaitForTesting {
                    await operationGate.waitUntilReleased()
                }
            case .removeSFTPFileForCompensation:
                try await proxy.degrade()
                await connection.runNextCompensationUnlinkPhaseHookForTesting {
                    await operationGate.waitUntilReleased()
                }
            }

            operation = Task { await body() }
            do {
                try await waitUntilTrue("\(site.rawValue) should reach its native wait") {
                    await operationGate.hasEntered
                }
                #expect(try await proxy.cut() > 0)
                await operationGate.release()
                if site.isExec {
                    try await waitUntilTrue("\(site.rawValue) should enter catch cleanup") {
                        await cleanupGate.hasEntered
                    }
                    await cleanupGate.release()
                }
                let error = await operation.value

                #expect(error != nil, "\(site.rawValue) did not report the severed transport")
                #expect(
                    await connection.isConnected == false,
                    "\(site.rawValue) spared a session after genuine transport loss")
                try? await connection.close(timeout: .seconds(1))
            } catch {
                operation.cancel()
                await operationGate.release()
                await cleanupGate.release()
                try? await proxy.reset()
                _ = await operation.value
                try? await connection.close(timeout: .seconds(1))
                throw error
            }
            try await proxy.reset()
        }
    }

    /// The fixture gives each session an isolated `HOME` inside its disposable
    /// directory, so anything staged there is cleaned up with the fixture —
    /// which matters here because half these connections are dead before they
    /// could unlink anything.
    private func remoteHome(of connection: SSHConnection) async throws -> String {
        let result = try await connection.execute(
            "printf %s \"$HOME\"",
            timeout: .seconds(15))
        let home = String(decoding: result.stdout, as: UTF8.self)
        #expect(home.hasPrefix("/"))
        return home
    }

    /// Runs `body` with the link degraded and always restores it afterwards.
    ///
    /// The proxy is process-wide and this suite is serialized, so a test that
    /// throws part-way through would otherwise leave the next one running on a
    /// degraded link — about the hardest cross-test contamination to diagnose.
    /// A `defer` cannot do this job: restoring is asynchronous, and a detached
    /// task might not have run by the time the next test starts.
    private func withDegradedLink(
        _ proxy: WeakNetworkProxyFixture,
        _ body: () async throws -> Void
    ) async throws {
        try await proxy.degrade()
        do {
            try await body()
        } catch {
            try? await proxy.reset()
            throw error
        }
        try await proxy.reset()
    }

    private func severOneSession(
        environment: SessionDriverTestEnvironment,
        endpoint: SSHEndpoint,
        proxy: WeakNetworkProxyFixture
    ) async throws {
        let driver = SessionDriver()
        _ = try await driver.handshake(endpoint: endpoint, timeout: .seconds(15))
        let privateKey = environment.privateKey
        try await driver.authenticate(
            username: environment.username,
            publicKey: environment.publicKeyBlob,
            signer: { try privateKey.signature(for: $0) },
            timeout: .seconds(15))

        let execution = Task {
            try await driver.execute(
                command: "sleep 30",
                input: Data(),
                timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await proxy.cut() > 0)
        await #expect(throws: SSHError.self) { _ = try await execution.value }

        let state = await driver.resourceStateForTesting()
        #expect(state == SessionDriverResourceState(
            hasSession: false,
            descriptorIsOpen: false,
            isValid: false))
    }

    /// How many descriptors this process holds open right now.
    private func openFileDescriptorCount() -> Int {
        var limit = rlimit()
        let ceiling = getrlimit(RLIMIT_NOFILE, &limit) == 0
            ? Int(min(limit.rlim_cur, 8_192))
            : 1_024
        var open = 0
        for descriptor in 0..<Int32(ceiling) where fcntl(descriptor, F_GETFD) != -1 {
            open += 1
        }
        return open
    }

    @Test("minimal SFTP surface creates, writes, attributes, renames, and removes")
    func minimalSFTPSurface() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let rootResult = try await connection.execute(
            "mktemp -d /tmp/heeler-sftp.XXXXXXXX",
            timeout: .seconds(5))
        let root = String(decoding: rootResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = "\(root)/private"
        let partial = "\(directory)/image.part"
        let final = "\(directory)/image.png"
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })

        let sftp = try await connection.openSFTP(timeout: .seconds(5))
        try await sftp.createDirectory(
            at: directory,
            permissions: 0o700,
            timeout: .seconds(5))
        try await sftp.setPermissions(0o700, at: directory, timeout: .seconds(5))
        #expect(try await sftp.attributes(at: directory, timeout: .seconds(5)).permissions == 0o700)

        let file = try await sftp.openFileForWriting(
            at: partial,
            permissions: 0o600,
            timeout: .seconds(5))
        try await file.write(bytes, timeout: .seconds(5))
        try await file.close(timeout: .seconds(5))
        try await sftp.setPermissions(0o600, at: partial, timeout: .seconds(5))
        let partialAttributes = try await sftp.attributes(at: partial, timeout: .seconds(5))
        #expect(partialAttributes.size == UInt64(bytes.count))
        #expect(partialAttributes.permissions == 0o600)

        try await sftp.renameFileAtomically(
            from: partial,
            to: final,
            timeout: .seconds(5))
        #expect(try await sftp.attributes(at: final, timeout: .seconds(5)).size == UInt64(bytes.count))
        #expect(
            try await sftp.readFileIfPresent(at: final, timeout: .seconds(5))
                == bytes)
        #expect(
            try await sftp.readFileIfPresent(
                at: "\(directory)/absent.json",
                timeout: .seconds(5)) == nil)
        try await sftp.removeFile(at: final, timeout: .seconds(5))
        await #expect(throws: SSHError.sftpFailure(status: 2)) {
            _ = try await sftp.attributes(at: final, timeout: .seconds(5))
        }
        try await sftp.removeFileForCompensation(
            at: final,
            timeout: .seconds(5))
        #expect(
            try await sftp.readFileIfPresent(
                at: final,
                timeout: .seconds(5)) == nil)

        try await sftp.close(timeout: .seconds(5))
        _ = try await connection.execute("rm -rf -- '\(root)'", timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    @Test("SFTP status errors never include remote paths")
    func sftpStatusErrorsArePathFree() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let sftp = try await connection.openSFTP(timeout: .seconds(5))
        let privatePath = "/tmp/heeler-private-\(UUID().uuidString)"

        do {
            _ = try await sftp.attributes(at: privatePath, timeout: .seconds(5))
            Issue.record("A missing remote path unexpectedly existed.")
        } catch {
            #expect(error as? SSHError == .sftpFailure(status: 2))
            #expect(!String(describing: error).contains(privatePath))
        }

        try await sftp.close(timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    /// The lost wakeup this guards against: one operation releases the session
    /// after EAGAIN, and before its socket watch is armed another operation
    /// takes the bytes it was waiting for off the shared socket. Nothing is
    /// left to signal, so a purely edge-triggered wait sleeps out its whole
    /// deadline on data that already arrived. The hold widens that window from
    /// a few instructions to something a test can drive.
    @Test("a wait armed after another operation drained the socket retries at once")
    func blockedReadSurvivesAConcurrentDrain() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let blocked = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let draining = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let hold = SessionWaitHold()

        await connection.holdNextSessionWaitForTesting { await hold.waitUntilReleased() }
        let read = Task { try await blocked.read(timeout: .seconds(6)) }
        try await waitUntilTrue("the read should reach the wait") { await hold.hasEntered }

        // The held channel's echo reaches the socket while that channel cannot
        // watch it, and the other channel's round trip is what consumes it.
        try await blocked.write(Data("held\n".utf8), timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        try await draining.write(Data("drain\n".utf8), timeout: .seconds(5))
        _ = try await draining.read(timeout: .seconds(5))

        await hold.release()
        let released = ContinuousClock.now
        let output = try #require(try await read.value)
        #expect(String(decoding: output, as: UTF8.self).contains("held"))
        #expect(released.duration(to: .now) < .seconds(2))

        try await blocked.close(timeout: .seconds(5))
        try await draining.close(timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    @Test("outbound backpressure does not livelock a channel open")
    func outboundBackpressureDoesNotLivelockAChannelOpen() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try await withDegradedLink(proxy) {
            let connection = try await connectThroughProxy(
                environment: environment,
                proxy: proxy)
            await connection.startSamplingTransportSendOwnerForTesting()
            try await connection.shrinkSendBufferForTesting(bytes: 2_048)
            let pty = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .seconds(15))
            let hold = SessionWaitHold()
            await connection.holdNextOutboundWriteParkForTesting {
                await hold.waitUntilReleased()
            }
            let write = Task {
                try await pty.write(
                    Data(repeating: 0x61, count: 32 * 1_024),
                    timeout: .seconds(10))
            }
            try await waitUntilTrue("the write should park on an outbound send") {
                await hold.hasEntered
            }
            let opened = Task {
                try await connection.execute("printf opened", timeout: .seconds(10))
            }
            await hold.release()
            try await write.value
            let result = try await opened.value
            #expect(result.stdout == Data("opened".utf8))
            #expect(result.exitStatus == 0)
            #expect(await connection.oneShotRegistryCountForTesting() == 0)
            let ownerSamples = await connection.transportSendOwnerSamplesForTesting()
            #expect(!ownerSamples.isEmpty)
            #expect(ownerSamples.allSatisfy { !$0.isForbiddenClearWindow })
            let ping = try await connection.execute("printf ping", timeout: .seconds(5))
            #expect(ping.stdout == Data("ping".utf8))
            #expect(await connection.isConnected)
            try await pty.close(timeout: .seconds(5))
            try await connection.close(timeout: .seconds(2))
        }
    }

    @Test("cancelling a transport-send owner drains")
    func cancellingATransportSendOwnerDrains() async throws {
        try await exerciseOwnedWriteInterruption(
            expected: .drained,
            expectedError: .cancelled
        ) { write, gates in
            try await waitForOwnedLoopTop(gates)
            write.cancel()
            await gates.loopTop.release()
        }
    }

    @Test("cancelling a transport-send owner invalidates")
    func cancellingATransportSendOwnerInvalidates() async throws {
        try await exerciseOwnedWriteInterruption(
            expected: .invalidated,
            expectedError: .cancelled,
            drainThrows: true
        ) { write, gates in
            try await waitForOwnedLoopTop(gates)
            write.cancel()
            await gates.loopTop.release()
        }
    }

    @Test("timing out a transport-send owner at loop-top drains")
    func timingOutATransportSendOwnerAtLoopTopDrains() async throws {
        try await exerciseOwnedWriteInterruption(
            expected: .drained,
            expectedError: .timedOut,
            loopTopThrows: .timedOut
        ) { _, gates in
            try await waitForOwnedLoopTop(gates)
            await gates.loopTop.release()
        }
    }

    @Test("timing out a transport-send owner at loop-top invalidates")
    func timingOutATransportSendOwnerAtLoopTopInvalidates() async throws {
        try await exerciseOwnedWriteInterruption(
            expected: .invalidated,
            expectedError: .timedOut,
            loopTopThrows: .timedOut,
            drainThrows: true
        ) { _, gates in
            try await waitForOwnedLoopTop(gates)
            await gates.loopTop.release()
        }
    }

    @Test("one-shot RPCs yield so a live PTY can progress")
    func oneShotRPCsYieldSoALivePTYCanProgress() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let connection = try await environment.connect()
        let pty = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))

        for site in OneShotYieldSite.allCases {
            let hold = SessionWaitHold()
            await connection.holdNextOneShotEstablishedForTesting {
                await connection.holdNextSessionWaitForTesting {
                    await hold.waitUntilReleased()
                }
            }
            let rpc = Task {
                try await site.run(on: connection, socketPath: socketPath)
            }
            try await waitUntilTrue("\(site.rawValue) should wait after establishment") {
                await hold.hasEntered
            }
            let marker = "yield-\(site.rawValue)"
            try await pty.write(Data("\(marker)\n".utf8), timeout: .seconds(5))
            let output = try #require(try await pty.read(timeout: .seconds(5)))
            #expect(
                String(decoding: output, as: UTF8.self).contains(marker),
                "\(site.rawValue) held the session while a live PTY was waiting")
            await hold.release()
            try await site.finish(rpc)
            #expect(await connection.oneShotRegistryCountForTesting() == 0)
        }

        try await pty.close(timeout: .seconds(5))
        #expect(await connection.isConnected)
        try await connection.close(timeout: .seconds(2))
    }

    @Test("cancelling a yielded one-shot distinguishes cleanup outcomes")
    func cancellingAYieldedOneShotDistinguishesCleanupOutcomes() async throws {
        for expected in TransportSendOwnerOutcome.allCases {
            try await exerciseYieldedOneShotInterruption(
                expected: expected,
                expectedError: .cancelled
            ) { rpc, hold in
                rpc.cancel()
                await hold.release()
            }
        }
    }

    @Test("timing out a yielded one-shot distinguishes cleanup outcomes")
    func timingOutAYieldedOneShotDistinguishesCleanupOutcomes() async throws {
        for expected in TransportSendOwnerOutcome.allCases {
            try await exerciseYieldedOneShotInterruption(
                expected: expected,
                expectedError: .timedOut,
                waitThrows: .timedOut
            ) { _, hold in
                await hold.release()
            }
        }
    }

    @Test("invalidation during a yielding wait does not touch a stale native pointer")
    func invalidationDuringAYieldingWaitDoesNotTouchAStaleNativePointer() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let hold = SessionWaitHold()
        await connection.holdNextOneShotEstablishedForTesting {
            await connection.holdNextSessionWaitForTesting {
                await hold.waitUntilReleased()
            }
        }
        let rpc = Task {
            try await connection.execute("sleep 20", timeout: .seconds(15))
        }
        try await waitUntilTrue("the one-shot should wait after establishment") {
            await hold.hasEntered
        }
        try await connection.close(timeout: .seconds(2))
        await hold.release()
        await #expect(throws: SSHError.self) { _ = try await rpc.value }
        #expect(await connection.oneShotRegistryCountForTesting() == 0)
        let state = await connection.resourceStateForTesting()
        #expect(state.isValid == false)
        #expect(state.descriptorIsOpen == false)
        #expect(state.hasSession == false)
    }

    @Test("yielded channel teardown rejects same-id I/O and preserves close")
    func yieldedChannelTeardownRejectsSameIDIOAndPreservesClose() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let connection = try await environment.connect()

        let pty = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let ptyTeardown = SessionWaitHold()
        await connection.holdNextChannelTeardownForTesting {
            await ptyTeardown.waitUntilReleased()
        }
        let closePTY = Task { try await pty.close(timeout: .seconds(5)) }
        try await waitUntilTrue("PTY teardown should yield after closing starts") {
            await ptyTeardown.hasEntered
        }
        await #expect(throws: SSHError.channelFailed) {
            try await pty.write(Data("x".utf8), timeout: .seconds(1))
        }
        await #expect(throws: SSHError.channelFailed) {
            _ = try await pty.read(timeout: .seconds(1))
        }
        await #expect(throws: SSHError.channelFailed) {
            try await pty.resize(columns: 81, rows: 24, timeout: .seconds(1))
        }
        await ptyTeardown.release()
        try await closePTY.value

        let exitingPTY = try await connection.openPTY(
            command: "sh -c 'exit 7'",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        while try await exitingPTY.read(timeout: .seconds(5)) != nil {}
        let exitStatusTeardown = SessionWaitHold()
        await connection.holdNextChannelTeardownForTesting {
            await exitStatusTeardown.waitUntilReleased()
        }
        let exitStatus = Task {
            try await exitingPTY.exitStatus(timeout: .seconds(5))
        }
        try await waitUntilTrue("exit status should suspend during teardown") {
            await exitStatusTeardown.hasEntered
        }
        let closeExitingPTY = Task {
            try await exitingPTY.close(timeout: .seconds(5))
        }
        try await waitUntilTrue("close should wait for exit-status teardown") {
            await connection.ptyTeardownWaiterCountForTesting() == 1
        }
        #expect(await connection.ptyChannelCountForTesting() == 1)
        await exitStatusTeardown.release()
        #expect(try await exitStatus.value == 7)
        try await closeExitingPTY.value
        #expect(await connection.ptyChannelCountForTesting() == 0)

        let retryablePTY = try await connection.openPTY(
            command: "sh -c 'exit 0'",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        while try await retryablePTY.read(timeout: .seconds(5)) != nil {}
        let failedExitStatusTeardown = SessionWaitHold()
        await connection.holdNextChannelTeardownForTesting {
            await failedExitStatusTeardown.waitUntilReleased()
        }
        let failedExitStatus = Task {
            try await retryablePTY.exitStatus(timeout: .milliseconds(50))
        }
        try await waitUntilTrue("the failing exit status should suspend") {
            await failedExitStatusTeardown.hasEntered
        }
        try await Task.sleep(for: .milliseconds(75))
        await failedExitStatusTeardown.release()
        await #expect(throws: SSHError.timedOut) {
            _ = try await failedExitStatus.value
        }
        #expect(await retryablePTY.acceptsIOForTesting())
        try await retryablePTY.close(timeout: .seconds(5))

        let stream = try await connection.openStreamLocal(
            socketPath: socketPath,
            timeout: .seconds(5))
        let streamTeardown = SessionWaitHold()
        await connection.holdNextChannelTeardownForTesting {
            await streamTeardown.waitUntilReleased()
        }
        let closeStream = Task { try await stream.close(timeout: .seconds(5)) }
        try await waitUntilTrue("stream-local teardown should yield after closing starts") {
            await streamTeardown.hasEntered
        }
        await #expect(throws: SSHError.channelFailed) {
            try await stream.write(Data("x".utf8), timeout: .seconds(1))
        }
        await #expect(throws: SSHError.channelFailed) {
            _ = try await stream.read(timeout: .seconds(1))
        }
        await streamTeardown.release()
        try await closeStream.value
        try await connection.close(timeout: .seconds(2))
    }

    @Test("repeated invalidation reclaims every file descriptor")
    func repeatedInvalidationReclaimsEveryFileDescriptor() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        try await invalidateOneYieldingSession(environment: environment)
        let baseline = openFileDescriptorCount()
        let rounds = 5
        for _ in 0..<rounds {
            try await invalidateOneYieldingSession(environment: environment)
        }
        let final = openFileDescriptorCount()
        print(
            "[issue-130] descriptors: baseline \(baseline), "
                + "after \(rounds) invalidated sessions \(final)")
        #expect(
            final <= baseline + 2,
            "descriptors grew from \(baseline) to \(final) across \(rounds) sessions")
    }

    /// Measurement only. The red regression guard for scheduling progress is
    /// `one-shot RPCs yield so a live PTY can progress`.
    @Test("measurement: Attach throughput with concurrent RPCs")
    func measureAttachThroughputWithConcurrentRPCs() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let pty = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let payload = Data("probe-bytes-0123456789\n".utf8)
        let rounds = 20

        func pump() async throws -> Double {
            let started = ContinuousClock.now
            var bytes = 0
            for _ in 0..<rounds {
                try await pty.write(payload, timeout: .seconds(5))
                let output = try #require(try await pty.read(timeout: .seconds(5)))
                bytes += payload.count + output.count
            }
            let seconds = durationSeconds(started.duration(to: .now))
            return seconds > 0 ? Double(bytes) / seconds : 0
        }

        let quiet = try await pump()
        let parked = CountingHold()
        await connection.holdEachSessionWaitForTesting {
            await parked.arriveAndWait()
        }
        let busy: Double
        do {
            busy = try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        let result = try await connection.execute(
                            "sleep 2; printf rpc\(index)",
                            timeout: .seconds(15))
                        #expect(!result.stdout.isEmpty)
                    }
                }
                try await waitUntilTrue("all eight RPCs should park during the pump") {
                    await parked.arrivedCount == 8
                }
                let measured = try await pump()
                await connection.clearEachSessionWaitForTesting()
                await parked.releaseAll()
                try await group.waitForAll()
                return measured
            }
        }
        print(
            "[issue-130] Attach throughput: \(Int(quiet)) B/s quiet, "
                + "\(Int(busy)) B/s with 8 parked RPCs")
        try await pty.close(timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    @Test("SFTP operations and close wait out an in-flight handle use")
    func sftpOperationsAndCloseWaitOutAnInFlightHandleUse() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try await withDegradedLink(proxy) {
            let connection = try await connectThroughProxy(
                environment: environment,
                proxy: proxy)
            try await connection.shrinkSendBufferForTesting(bytes: 2_048)
            let home = try await remoteHome(of: connection)
            let sftp = try await connection.openSFTP(timeout: .seconds(15))
            let pty = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .seconds(15))
            let park = SessionWaitHold()
            await connection.holdNextOutboundWriteParkForTesting {
                await park.waitUntilReleased()
            }
            let write = Task {
                try await pty.write(
                    Data(repeating: 0x61, count: 512 * 1_024),
                    timeout: .seconds(15))
            }
            try await waitUntilTrue("the PTY write should own the send") {
                await park.hasEntered
            }
            let stat = Task {
                _ = try await sftp.attributes(at: home, timeout: .seconds(15))
            }
            try await waitUntilTrue("the SFTP call should hold a handle lease") {
                await connection.sftpUseCountForTesting() == 1
            }
            let secondStat = Task {
                _ = try await sftp.attributes(at: home, timeout: .seconds(15))
            }
            try await waitUntilTrue("a second SFTP call should wait for the lease") {
                await connection.sftpIdleWaiterCountForTesting() == 1
            }
            #expect(await connection.sftpUseCountForTesting() == 1)
            await park.release()
            try await write.value
            _ = try await stat.value
            _ = try await secondStat.value

            let closePark = SessionWaitHold()
            await connection.holdNextOutboundWriteParkForTesting {
                await closePark.waitUntilReleased()
            }
            let closeWrite = Task {
                try await pty.write(
                    Data(repeating: 0x62, count: 512 * 1_024),
                    timeout: .seconds(15))
            }
            try await waitUntilTrue("the second PTY write should own the send") {
                await closePark.hasEntered
            }
            let closeStat = Task {
                _ = try await sftp.attributes(at: home, timeout: .seconds(15))
            }
            try await waitUntilTrue("the SFTP call should hold the close lease") {
                await connection.sftpUseCountForTesting() == 1
            }
            let closing = Task {
                try await sftp.close(timeout: .seconds(15))
            }
            try await waitUntilTrue("closeSFTP should wait for the lease") {
                await connection.sftpIdleWaiterCountForTesting() == 1
            }
            await closePark.release()
            try await closeWrite.value
            _ = try await closeStat.value
            try await closing.value
            #expect(await connection.sftpUseCountForTesting() == 0)
            #expect(await connection.isConnected)
            let ping = try await connection.execute("printf sftp-lease", timeout: .seconds(5))
            #expect(ping.stdout == Data("sftp-lease".utf8))
            try await pty.close(timeout: .seconds(5))
            try await connection.close(timeout: .seconds(2))
        }
    }

    @Test("a serialized channel-open wait honors deadline and cancellation")
    func serializedChannelOpenWaitHonorsDeadlineAndCancellation() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try await withDegradedLink(proxy) {
            let connection = try await connectThroughProxy(
                environment: environment,
                proxy: proxy)
            try await connection.shrinkSendBufferForTesting(bytes: 2_048)
            let pty = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .seconds(15))
            let park = SessionWaitHold()
            await connection.holdNextOutboundWriteParkForTesting {
                await park.waitUntilReleased()
            }
            let write = Task {
                try await pty.write(
                    Data(repeating: 0x61, count: 512 * 1_024),
                    timeout: .seconds(15))
            }
            try await waitUntilTrue("the PTY write should own the send") {
                await park.hasEntered
            }

            let slot = SessionWaitHold()
            await slot.release()
            await connection.holdNextChannelOpenSlotForTesting {
                await slot.waitUntilReleased()
            }
            let first = Task {
                try await connection.execute("printf first-open", timeout: .seconds(15))
            }
            try await waitUntilTrue("the first open should claim the slot") {
                await slot.hasEntered
            }
            let timedOut = Task {
                try await connection.execute("printf timed-out-open", timeout: .milliseconds(200))
            }
            try await waitUntilTrue("the timed-out open should park on the slot") {
                await connection.channelOpenWaiterCountForTesting() == 1
            }
            await #expect(throws: SSHError.timedOut) { _ = try await timedOut.value }
            #expect(await connection.isConnected)

            let cancelled = Task {
                try await connection.execute("printf cancelled-open", timeout: .seconds(15))
            }
            try await waitUntilTrue("the cancelled open should park on the slot") {
                await connection.channelOpenWaiterCountForTesting() == 1
            }
            cancelled.cancel()
            await #expect(throws: SSHError.cancelled) { _ = try await cancelled.value }
            #expect(await connection.isConnected)

            let registrationGuard = SessionWaitHold()
            await connection.holdNextChannelOpenWaiterRegistrationForTesting {
                await registrationGuard.waitUntilReleased()
            }
            let cancelledBeforeRegistration = Task {
                try await connection.execute(
                    "printf cancelled-before-registration",
                    timeout: .seconds(15))
            }
            try await waitUntilTrue("the waiter should reach its registration guard") {
                await registrationGuard.hasEntered
            }
            cancelledBeforeRegistration.cancel()
            await registrationGuard.release()
            await #expect(throws: SSHError.cancelled) {
                _ = try await cancelledBeforeRegistration.value
            }
            #expect(await connection.channelOpenWaiterCountForTesting() == 0)

            await connection.failNextResumedChannelOpenWaiterForTesting(.cancelled)
            let resumedHead = Task {
                try await connection.execute("printf resumed-head", timeout: .seconds(15))
            }
            let resumedFollower = Task {
                try await connection.execute("printf resumed-follower", timeout: .seconds(15))
            }
            try await waitUntilTrue("both channel-open waiters should park") {
                await connection.channelOpenWaiterCountForTesting() == 2
            }

            await park.release()
            try await write.value
            let firstResult = try await first.value
            #expect(firstResult.stdout == Data("first-open".utf8))
            let resumedHeadResult: Result<SSHExecResult, any Error>
            do {
                resumedHeadResult = .success(try await resumedHead.value)
            } catch {
                resumedHeadResult = .failure(error)
            }
            let resumedFollowerResult: Result<SSHExecResult, any Error>
            do {
                resumedFollowerResult = .success(try await resumedFollower.value)
            } catch {
                resumedFollowerResult = .failure(error)
            }
            let resumedResults = [resumedHeadResult, resumedFollowerResult]
            #expect(resumedResults.filter {
                if case .success = $0 { return true }
                return false
            }.count == 1)
            #expect(resumedResults.filter { result in
                guard case .failure(let error) = result else { return false }
                return error as? SSHError == .cancelled
            }.count == 1)
            let ping = try await connection.execute("printf after-open-wait", timeout: .seconds(5))
            #expect(ping.stdout == Data("after-open-wait".utf8))
            try await pty.close(timeout: .seconds(5))
            try await connection.close(timeout: .seconds(2))
        }
    }

    /// How long phase-gate probes may wait to observe a held path under CI load.
    /// This is a test-observation guard only; product operation timeouts
    /// (100ms / 200ms / 2s) are independent and must not be widened to match.
    private static let phaseGateObservationBudget: Duration = .seconds(15)

    private func waitUntilTrue(
        _ comment: Comment,
        timeout: Duration = SessionDriverE2ETests.phaseGateObservationBudget,
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    private func connectThroughProxy(
        environment: SessionDriverTestEnvironment,
        proxy: WeakNetworkProxyFixture
    ) async throws -> SSHConnection {
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)
        let connection = try await SSHConnection.connect(
            to: endpoint,
            timeout: .seconds(15))
        try await environment.authenticate(connection)
        return connection
    }

    private struct OwnedWriteGates: Sendable {
        let park: SessionWaitHold
        let wait: SessionWaitHold
        let loopTop: SessionWaitHold
    }

    private func waitForOwnedLoopTop(_ gates: OwnedWriteGates) async throws {
        try await waitUntilTrue("the write should own the send") {
            await gates.park.hasEntered
        }
        await gates.park.release()
        try await waitUntilTrue("the write should reach its session wait") {
            await gates.wait.hasEntered
        }
        await gates.wait.release()
        try await waitUntilTrue("the write should reach an owned loop-top") {
            await gates.loopTop.hasEntered
        }
    }

    private func exerciseOwnedWriteInterruption(
        expected: TransportSendOwnerOutcome,
        expectedError: SSHError,
        loopTopThrows: SSHError? = nil,
        drainThrows: Bool = false,
        interrupt: (Task<Void, any Error>, OwnedWriteGates) async throws -> Void
    ) async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try await withDegradedLink(proxy) {
            let connection = try await connectThroughProxy(
                environment: environment,
                proxy: proxy)
            await connection.startSamplingTransportSendOwnerForTesting()
            try await connection.shrinkSendBufferForTesting(bytes: 2_048)
            let pty = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .seconds(15))
            let gates = OwnedWriteGates(
                park: SessionWaitHold(),
                wait: SessionWaitHold(),
                loopTop: SessionWaitHold())
            await connection.holdNextOutboundWriteParkForTesting {
                await gates.park.waitUntilReleased()
            }
            await connection.holdNextSessionWaitForTesting {
                await gates.wait.waitUntilReleased()
            }
            await connection.holdNextOwnedLoopTopForTesting {
                await gates.loopTop.waitUntilReleased()
                if let loopTopThrows { throw loopTopThrows }
            }
            if drainThrows {
                await connection.holdNextOwnedDrainForTesting {
                    throw expectedError
                }
            }
            let write = Task {
                try await pty.write(
                    Data(repeating: 0x61, count: 512 * 1_024),
                    timeout: .seconds(15))
            }
            do {
                try await interrupt(write, gates)
                await #expect(throws: expectedError) { try await write.value }
            } catch {
                write.cancel()
                await gates.park.release()
                await gates.wait.release()
                await gates.loopTop.release()
                try? await pty.close(timeout: .seconds(2))
                throw error
            }
            let ownerSamples = await connection.transportSendOwnerSamplesForTesting()
            #expect(!ownerSamples.isEmpty)
            #expect(ownerSamples.allSatisfy { !$0.isForbiddenClearWindow })
            #expect(await connection.oneShotRegistryCountForTesting() == 0)
            let state = await connection.resourceStateForTesting()
            switch expected {
            case .drained:
                #expect(await connection.isConnected)
                #expect(state.isValid)
                #expect(state.descriptorIsOpen)
                #expect(state.hasSession)
                let descriptors = openFileDescriptorCount()
                let echo = try await connection.execute("printf drained", timeout: .seconds(5))
                #expect(echo.stdout == Data("drained".utf8))
                #expect(openFileDescriptorCount() <= descriptors + 2)
                print("[issue-130] owner interruption outcome: drained")
            case .invalidated:
                #expect(await connection.isConnected == false)
                #expect(state.isValid == false)
                #expect(state.descriptorIsOpen == false)
                #expect(state.hasSession == false)
                await #expect(throws: SSHError.connectionInvalidated) {
                    _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
                }
                print("[issue-130] owner interruption outcome: invalidated")
            }
            try? await pty.close(timeout: .seconds(2))
            try await connection.close(timeout: .seconds(2))
        }
    }

    private func exerciseYieldedOneShotInterruption(
        expected: TransportSendOwnerOutcome,
        expectedError: SSHError,
        waitThrows: SSHError? = nil,
        interrupt: (Task<SSHExecResult, any Error>, SessionWaitHold) async -> Void
    ) async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let hold = SessionWaitHold()
        await connection.holdNextOneShotEstablishedForTesting {
            await connection.holdNextSessionWaitForTesting {
                await hold.waitUntilReleased()
                if let waitThrows { throw waitThrows }
            }
        }
        if expected == .invalidated {
            await connection.holdNextExecCleanupForTesting {
                throw SSHError.channelFailed
            }
        }
        let rpc = Task {
            try await connection.execute("sleep 20", timeout: .seconds(15))
        }
        try await waitUntilTrue("the one-shot should yield after establishment") {
            await hold.hasEntered
        }
        await interrupt(rpc, hold)
        await #expect(throws: expectedError) { _ = try await rpc.value }
        #expect(await connection.oneShotRegistryCountForTesting() == 0)
        let state = await connection.resourceStateForTesting()
        switch expected {
        case .drained:
            #expect(await connection.isConnected)
            #expect(state.isValid)
            #expect(state.descriptorIsOpen)
            #expect(state.hasSession)
            let echo = try await connection.execute("printf reclaimed", timeout: .seconds(5))
            #expect(echo.stdout == Data("reclaimed".utf8))
        case .invalidated:
            #expect(await connection.isConnected == false)
            #expect(state.isValid == false)
            #expect(state.descriptorIsOpen == false)
            #expect(state.hasSession == false)
            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
        }
        try? await connection.close(timeout: .seconds(2))
    }

    private func invalidateOneYieldingSession(
        environment: SessionDriverTestEnvironment
    ) async throws {
        let connection = try await environment.connect()
        let hold = SessionWaitHold()
        await connection.holdNextOneShotEstablishedForTesting {
            await connection.holdNextSessionWaitForTesting {
                await hold.waitUntilReleased()
            }
        }
        let rpc = Task {
            try await connection.execute("sleep 20", timeout: .seconds(15))
        }
        try await waitUntilTrue("the one-shot should wait after establishment") {
            await hold.hasEntered
        }
        try? await connection.close(timeout: .seconds(2))
        await hold.release()
        _ = try? await rpc.value
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private enum TransportSendOwnerOutcome: String, CaseIterable, Equatable {
    case drained
    case invalidated
}

private enum OneShotYieldSite: String, CaseIterable {
    case execute
    case executeResponseLine
    case exchangeStreamLocal

    func run(on connection: SSHConnection, socketPath: String) async throws {
        switch self {
        case .execute:
            _ = try await connection.execute("sleep 8", timeout: .seconds(15))
        case .executeResponseLine:
            let response = try await connection.executeResponseLine(
                "IFS= read -r line; sleep 8; printf 'accepted:%s\\n' \"$line\"",
                input: Data("device-key-line\n".utf8),
                maximumResponseBytes: 64,
                timeout: .seconds(15))
            #expect(response == Data("accepted:device-key-line\n".utf8))
        case .exchangeStreamLocal:
            let token = UUID().uuidString
            let request = Data(
                #"{"id":"delay","method":"pane.read","params":{"pane_id":"fixture:delay:\#(token)"}}\#n"#
                    .utf8)
            let response = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: request,
                timeout: .seconds(15))
            #expect(!response.isEmpty)
        }
    }

    func finish(_ rpc: Task<Void, any Error>) async throws {
        try await rpc.value
    }
}

private enum RawTCPWriterState: Equatable {
    case blocked
    case completed
}

private enum RawTCPWriterError: Error {
    case invalidLaunchResponse(String)
    case markerFailed(String)
    case cleanupFailed(String)
    case readFailed(Int32)
}

/// A disposable raw producer launched through the existing real-SSH fixture.
/// The caller chooses a unique `/tmp/heeler-raw-tcp-<UUID>` path before launch
/// so start failures can still clean the remote process without a parsed PID.
private struct RawTCPWriter {
    let directory: String
    let processID: Int32
    let port: UInt16

    static func launch(
        directory: String,
        payloadSize: Int,
        using observer: SSHConnection
    ) async throws -> RawTCPWriter {
        let quotedDirectory = shellQuote(directory)
        let command = """
            set -eu
            directory=\(quotedDirectory)
            mkdir "$directory"
            /bin/cat >"$directory/writer.py"
            /usr/bin/python3 "$directory/writer.py" "$directory" '\(payloadSize)' </dev/null >"$directory/stdout" 2>"$directory/stderr" &
            writer_pid=$!
            attempts=0
            while [ ! -s "$directory/port" ] && kill -0 "$writer_pid" 2>/dev/null; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 500 ] || break
                sleep 0.01
            done
            if [ ! -s "$directory/port" ]; then
                cat "$directory/stderr" >&2
                exit 1
            fi
            printf '%s\n%s\n' "$directory" "$writer_pid"
            cat "$directory/port"
            """
        let result = try await observer.execute(
            command,
            input: Data(pythonSource.utf8),
            timeout: .seconds(10))
        let response = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard
            result.exitStatus == 0,
            response.count == 3,
            response[0] == directory,
            let processID = Int32(response[1]),
            let port = UInt16(response[2])
        else {
            throw RawTCPWriterError.invalidLaunchResponse(
                String(decoding: result.stderr, as: UTF8.self))
        }
        return RawTCPWriter(directory: directory, processID: processID, port: port)
    }

    func waitUntilStartedAndSettled(
        using observer: SSHConnection
    ) async throws -> RawTCPWriterState {
        let path = Self.shellQuote(directory)
        let command = """
            attempts=0
            while [ ! -f \(path)/started ]; do
                kill -0 \(processID) 2>/dev/null || exit 1
                attempts=$((attempts + 1))
                [ "$attempts" -lt 1500 ] || exit 1
                sleep 0.01
            done
            printf 'started\n'
            attempts=0
            while [ ! -f \(path)/blocked ] && [ ! -f \(path)/completed ]; do
                kill -0 \(processID) 2>/dev/null || exit 1
                attempts=$((attempts + 1))
                [ "$attempts" -lt 1500 ] || exit 1
                sleep 0.01
            done
            if [ -f \(path)/completed ]; then
                printf 'completed\n'
            else
                printf 'blocked\n'
            fi
            """
        let result = try await observer.execute(command, timeout: .seconds(20))
        let markers = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        guard result.exitStatus == 0, markers.first == "started" else {
            throw RawTCPWriterError.markerFailed(
                String(decoding: result.stderr, as: UTF8.self))
        }
        switch markers.last {
        case "blocked": return .blocked
        case "completed": return .completed
        default:
            throw RawTCPWriterError.markerFailed(markers.joined(separator: "\n"))
        }
    }

    func completedByteCount(using observer: SSHConnection) async throws -> Int {
        let result = try await observer.execute(
            "cat \(Self.shellQuote(directory))/completed",
            timeout: .seconds(5))
        guard
            result.exitStatus == 0,
            let count = Int(String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw RawTCPWriterError.markerFailed(
                String(decoding: result.stderr, as: UTF8.self))
        }
        return count
    }

    /// Kill only processes currently owned by this fixture's `writer.py`, then
    /// remove and verify the directory is gone.
    ///
    /// Cleanup finds owned processes via the known writer path even when launch
    /// failed before a handle was parsed. A PID is owned only while its command
    /// is `/usr/bin/python3` with this exact path as its first argument.
    static func cleanup(
        directory: String,
        using observer: SSHConnection
    ) async throws {
        let quotedDirectory = shellQuote(directory)
        // Single remote script: recompute ownership before every TERM/KILL and
        // during polls so a reused PID is never signaled. Final check is a
        // fresh ownership scan plus path absence.
        let command = """
            set -eu
            directory=\(quotedDirectory)
            writer_py="$directory/writer.py"

            case "$directory" in
              /tmp/heeler-raw-tcp-*) ;;
              *)
                printf 'refusing unexpected cleanup path: %s\\n' "$directory" >&2
                exit 1
                ;;
            esac

            # Fields 2 and 3 must be the exact interpreter and script path.
            # This excludes suffix matches and the path appearing in later args.
            collect_owned() {
              ps -A -o pid= -o command= 2>/dev/null \\
                | awk -v needle="$writer_py" \\
                  '$2 == "/usr/bin/python3" && $3 == needle { print $1 }'
            }

            for pid in $(collect_owned); do
              kill -TERM "$pid" 2>/dev/null || true
            done

            attempts=0
            while [ "$attempts" -lt 40 ]; do
              owned=$(collect_owned)
              [ -z "$owned" ] && break
              attempts=$((attempts + 1))
              sleep 0.05
            done

            for pid in $(collect_owned); do
              kill -KILL "$pid" 2>/dev/null || true
            done

            attempts=0
            while [ "$attempts" -lt 20 ]; do
              owned=$(collect_owned)
              [ -z "$owned" ] && break
              attempts=$((attempts + 1))
              sleep 0.05
            done

            leftover=$(collect_owned)
            if [ -n "$leftover" ]; then
              printf 'writer process(es) still alive: %s\\n' \\
                "$(printf '%s' "$leftover" | tr '\\n' ' ')" >&2
              exit 1
            fi

            rm -rf -- "$directory"

            if [ -e "$directory" ]; then
              printf 'directory still present: %s\\n' "$directory" >&2
              exit 1
            fi

            leftover=$(collect_owned)
            if [ -n "$leftover" ]; then
              printf 'writer process still present after cleanup: %s\\n' \\
                "$(printf '%s' "$leftover" | tr '\\n' ' ')" >&2
              exit 1
            fi
            """
        let result = try await observer.execute(command, timeout: .seconds(10))
        guard result.exitStatus == 0 else {
            let detail = [
                String(decoding: result.stderr, as: UTF8.self),
                String(decoding: result.stdout, as: UTF8.self),
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
            throw RawTCPWriterError.cleanupFailed(
                detail.isEmpty ? "exit status \(result.exitStatus)" : detail)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let pythonSource = #"""
import os
import select
import socket
import sys

directory = sys.argv[1]
payload_size = int(sys.argv[2])
pattern = bytes(range(251)) * 263

def publish(name, value):
    temporary = os.path.join(directory, name + ".tmp")
    with open(temporary, "w", encoding="ascii") as marker:
        marker.write(str(value))
        marker.flush()
        os.fsync(marker.fileno())
    os.replace(temporary, os.path.join(directory, name))

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
publish("port", listener.getsockname()[1])

connection, _ = listener.accept()
listener.close()
publish("started", 1)
connection.setblocking(False)
sent = 0
reported_block = False
while sent < payload_size:
    length = min(65_536, payload_size - sent)
    start = sent % 251
    data = pattern[start:start + length]
    try:
        written = connection.send(data)
        if written == 0:
            raise RuntimeError("raw writer socket closed")
        sent += written
    except BlockingIOError:
        _, writable, _ = select.select([], [connection], [], 1.0)
        if writable:
            continue
        if not reported_block:
            publish("blocked", sent)
            reported_block = True
        connection.setblocking(True)

connection.shutdown(socket.SHUT_WR)
connection.close()
publish("completed", sent)
"""#
}

/// The four `close*` paths that share one teardown verdict in `SessionDriver`.
///
/// Naming them as data is what keeps the two directions of #136 from drifting
/// apart: both tests walk this list, so neither can end up covering three sites
/// while the other covers four, and a fifth site added to the driver without a
/// case here is a visible omission rather than a silent one.
private enum TeardownSite: String, CaseIterable {
    case pty = "closePTY"
    case streamLocal = "closeStreamLocal"
    case sftpFile = "closeSFTPFile"
    case sftp = "closeSFTP"

    /// Whether severing the link is enough to make this site's close fail.
    ///
    /// Three of the four reach libssh2's transport and report the loss. The
    /// exception is `closeSFTP`: measured against this fixture,
    /// `libssh2_sftp_shutdown` returns success on a link that is already gone,
    /// so `guard result == 0` never fires there and the clock is the only
    /// failure that site can report.
    var reportsALostLinkFromTeardown: Bool {
        switch self {
        case .pty, .streamLocal, .sftpFile: true
        case .sftp: false
        }
    }

    /// Opens this site's resource and hands back the close under test, so the
    /// caller decides the budget and when it runs.
    func open(
        on connection: SSHConnection,
        socketPath: String,
        stagePath: String
    ) async throws -> @Sendable (Duration) async throws -> Void {
        switch self {
        case .pty:
            let channel = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .seconds(15))
            return { try await channel.close(timeout: $0) }
        case .streamLocal:
            let channel = try await connection.openStreamLocal(
                socketPath: socketPath,
                timeout: .seconds(15))
            return { try await channel.close(timeout: $0) }
        case .sftpFile:
            let client = try await connection.openSFTP(timeout: .seconds(15))
            let file = try await client.openFileForWriting(
                at: stagePath,
                permissions: 0o600,
                timeout: .seconds(15))
            // The client has to outlive the close under test, and only the body
            // referencing it will do that — a bare `[client]` capture list is
            // not enough. Release it early and `SSHSFTPClient.deinit` shuts the
            // whole subsystem down first, taking this file out of the driver's
            // map, and the close under test returns having done nothing.
            return { budget in
                defer { withExtendedLifetime(client) {} }
                try await file.close(timeout: budget)
            }
        case .sftp:
            let client = try await connection.openSFTP(timeout: .seconds(15))
            return { try await client.close(timeout: $0) }
        }
    }
}

/// The exact four sites named by #149. Similar cleanup catches elsewhere in
/// `SessionDriver` are deliberately absent because the issue does not own them.
private enum Issue149Site: String, CaseIterable {
    case execute
    case executeResponseLine
    case openSFTP
    case removeSFTPFileForCompensation

    var isExec: Bool {
        self == .execute || self == .executeResponseLine
    }

    func transportFailureOperation(
        on connection: SSHConnection
    ) async throws -> @Sendable () async -> SSHError? {
        let sftp: SSHSFTPClient? = switch self {
        case .removeSFTPFileForCompensation:
            try await connection.openSFTP(timeout: .seconds(5))
        case .execute, .executeResponseLine, .openSFTP:
            nil
        }
        return {
            do {
                switch self {
                case .execute:
                    _ = try await connection.execute("sleep 30", timeout: .seconds(10))
                case .executeResponseLine:
                    _ = try await connection.executeResponseLine(
                        "sleep 30",
                        input: Data("request\n".utf8),
                        maximumResponseBytes: 64,
                        timeout: .seconds(10))
                case .openSFTP:
                    _ = try await connection.openSFTP(timeout: .seconds(10))
                case .removeSFTPFileForCompensation:
                    guard let sftp else { return .connectionFailed }
                    try await sftp.removeFileForCompensation(
                        at: "/tmp/heeler-issue-149-\(UUID().uuidString)",
                        timeout: .seconds(10))
                }
                return nil
            } catch {
                return error as? SSHError
            }
        }
    }
}

private enum Issue149ExecSite: String, CaseIterable {
    case execute
    case executeResponseLine

    func injectTimeout(on connection: SSHConnection) async -> SSHError? {
        do {
            switch self {
            case .execute:
                _ = try await connection.execute("printf unused", timeout: .seconds(5))
            case .executeResponseLine:
                _ = try await connection.executeResponseLine(
                    "printf unused",
                    input: Data("request\n".utf8),
                    maximumResponseBytes: 64,
                    timeout: .seconds(5))
            }
            return nil
        } catch {
            return error as? SSHError
        }
    }
}

private enum OpenSFTPPreInitFailure: String, CaseIterable {
    case timedOut
    case cancelled
    case sftpUnavailable

    var expectedError: SSHError {
        switch self {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .sftpUnavailable: .sftpUnavailable
        }
    }

    func trigger(on connection: SSHConnection) async -> SSHError? {
        do {
            switch self {
            case .timedOut:
                _ = try await connection.openSFTP(timeout: .zero)
            case .cancelled:
                let opening = Task {
                    withUnsafeCurrentTask { task in task?.cancel() }
                    return try await connection.openSFTP(timeout: .seconds(5))
                }
                _ = try await opening.value
            case .sftpUnavailable:
                await connection.failNextSFTPInitBeforeEAGAINForTesting()
                _ = try await connection.openSFTP(timeout: .seconds(5))
            }
            return nil
        } catch {
            return error as? SSHError
        }
    }
}

private enum OpenSFTPPendingFailure: String, CaseIterable {
    case timedOut
    case cancelled

    var timeout: Duration {
        switch self {
        case .timedOut: .milliseconds(200)
        case .cancelled: .seconds(5)
        }
    }

    var expectedError: SSHError {
        switch self {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }
}

private enum CompensationFaultPhase: String, CaseIterable {
    case unlink
    case stat

    var recordedPhase: SessionFaultPhase {
        switch self {
        case .unlink: .compensationUnlink
        case .stat: .compensationStat
        }
    }

    func prepare(path: String, on connection: SSHConnection) async throws {
        _ = try await connection.execute(
            "printf staged > '\(path)'",
            timeout: .seconds(5))
    }

    func installFailureHook(
        on connection: SSHConnection,
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        switch self {
        case .unlink:
            await connection.runNextCompensationUnlinkPhaseHookForTesting(hook)
        case .stat:
            await connection.runNextCompensationStatPhaseHookForTesting(hook)
        }
    }
}

private enum SessionFaultPhase: Sendable, Equatable {
    case execChannelAllocated
    case execCleanup
    case compensationUnlink
    case compensationStat
    case compensationShutdown
}

private actor SessionFaultPhaseRecorder {
    private(set) var recorded: [SessionFaultPhase] = []

    func record(_ phase: SessionFaultPhase) {
        recorded.append(phase)
    }
}

private enum SessionPhaseFaultGateError: Error {
    case didNotEnter
}

/// A one-shot continuation barrier that throws only after the test releases
/// the operation from a confirmed resource-owning phase.
private actor SessionPhaseFaultGate {
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiter: CheckedContinuation<Void, any Error>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterThenThrow(_ error: SSHError) async throws {
        hasEntered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if !isReleased {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        throw error
    }

    func waitUntilEntered(timeout: Duration) async throws {
        guard !hasEntered else { return }
        try await withCheckedThrowingContinuation { continuation in
            entryWaiter = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.expireEntryWaiter()
            }
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func expireEntryWaiter() {
        entryWaiter?.resume(throwing: SessionPhaseFaultGateError.didNotEnter)
        entryWaiter = nil
    }
}

/// A one-shot gate the driver parks in, so the test controls exactly what runs
/// while an operation sits between releasing the session and watching it.
private actor SessionWaitHold {
    private(set) var hasEntered = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        hasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

private actor CountingHold {
    private(set) var arrivedCount = 0
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivedCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        isReleased = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

private actor SSHErrorCompletionProbe {
    private(set) var completed = false
    private(set) var error: SSHError?

    func finish(error: SSHError?) {
        self.error = error
        completed = true
    }
}

/// Minimal control client for `scripts/fixtures/weak-network-proxy.py`: the
/// unprivileged TCP proxy the merge fixture puts in front of the disposable
/// sshd. Only the two commands this suite needs are wired up — the app test
/// target drives the full surface.
private struct WeakNetworkProxyFixture: Sendable {
    let port: UInt16
    let controlPort: UInt16

    static let current: WeakNetworkProxyFixture? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let portText = environment["HEELER_SSH_E2E_WEAK_PORT"],
            let port = UInt16(portText),
            let controlText = environment["HEELER_SSH_E2E_WEAK_CONTROL_PORT"],
            let controlPort = UInt16(controlText)
        else { return nil }
        return WeakNetworkProxyFixture(port: port, controlPort: controlPort)
    }()

    /// Latency plus heavy fragmentation, so the severance below lands on a
    /// session that is genuinely mid-stream rather than idle. Both knobs are
    /// fixed values, so the treatment repeats exactly.
    func degrade() async throws {
        _ = try await send(
            #"{"command":"profile","profile":{"latencyMillis":30,"segmentBytes":256}}"#)
    }

    func reset() async throws {
        _ = try await send(#"{"command":"reset"}"#)
    }

    /// Severs every live proxied connection abruptly; the peer sees RST.
    func cut() async throws -> Int {
        let response = try await send(#"{"command":"cut"}"#)
        guard
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let count = object["cutConnections"] as? Int
        else { return 0 }
        return count
    }

    private func send(_ request: String) async throws -> Data {
        let controlPort = self.controlPort
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try Self.exchange(Data((request + "\n").utf8), port: controlPort)
                })
            }
        }
    }

    private static let queue = DispatchQueue(label: "heelerssh.weak-network-control")

    private static func exchange(_ payload: Data, port: UInt16) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WeakNetworkProxyFixtureError.unreachable }
        defer { close(descriptor) }

        // Bound the blocking calls: a control thread that never returns would
        // leave a continuation un-resumed, which no test time limit can
        // interrupt, hanging the run instead of failing it.
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        let limitSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, limitSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, limitSize)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw WeakNetworkProxyFixtureError.unreachable
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw WeakNetworkProxyFixtureError.unreachable }

        var sent = 0
        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = write(descriptor, base + sent, buffer.count - sent)
                guard written > 0 else { throw WeakNetworkProxyFixtureError.unreachable }
                sent += written
            }
        }

        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !line.contains(UInt8(ascii: "\n")) {
            let received = read(descriptor, &buffer, buffer.count)
            guard received > 0 else { throw WeakNetworkProxyFixtureError.unreachable }
            line.append(contentsOf: buffer[0..<received])
        }
        return line
    }
}

private enum WeakNetworkProxyFixtureError: Error {
    case unreachable
}

private struct SessionDriverTestEnvironment: Sendable {
    let endpoint: SSHEndpoint
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey

    /// Merge CI demands real SSH coverage. When the flag is set the suite stays
    /// enabled even without a decodable fixture, so a missing fixture fails at
    /// the per-test `#require` instead of skipping green.
    static var isRequired: Bool {
        ProcessInfo.processInfo.environment["HEELER_SSH_E2E_REQUIRED"] == "1"
    }

    /// The fixture's forwarded herdr socket, needed by the stream-local path.
    static let streamLocalSocketPath: String? =
        ProcessInfo.processInfo.environment["HEELER_SSH_E2E_STREAMLOCAL_SOCKET"]

    static let current: SessionDriverTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let host = environment["HEELER_SSH_E2E_HOST"],
            let portText = environment["HEELER_SSH_E2E_PORT"],
            let port = UInt16(portText),
            let username = environment["HEELER_SSH_E2E_USERNAME"],
            let seed = environment["HEELER_SSH_E2E_DEVICE_KEY_SEED"],
            let seedData = Data(base64Encoded: seed),
            let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
        else {
            return nil
        }
        return SessionDriverTestEnvironment(
            endpoint: SSHEndpoint(host: host, port: port),
            username: username,
            privateKey: privateKey)
    }()

    /// SSH wire-format public key blob (RFC 4253 §6.6).
    var publicKeyBlob: Data {
        var blob = Data()
        for field in [Data("ssh-ed25519".utf8), privateKey.publicKey.rawRepresentation] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return blob
    }

    func connect() async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(
            to: endpoint,
            timeout: .seconds(5))
        try await authenticate(connection)
        return connection
    }

    func authenticate(_ connection: SSHConnection) async throws {
        let privateKey = self.privateKey
        try await connection.authenticate(
            username: username,
            publicKey: publicKeyBlob,
            signer: { try privateKey.signature(for: $0) },
            timeout: .seconds(5))
    }
}
