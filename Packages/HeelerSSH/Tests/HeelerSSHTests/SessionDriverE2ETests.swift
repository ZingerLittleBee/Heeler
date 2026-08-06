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
        var writer: RawTCPWriter?
        var primaryError: (any Error)?

        do {
            writer = try await RawTCPWriter.launch(
                directory: directory,
                payloadSize: payloadSize,
                using: observer)
            let launched = try #require(writer)

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

        // Always wait for cleanup (with or without a PID handle) before closing
        // the observer. Prefer the body error if cleanup also fails.
        // The current task may already be cancelled (timeout body); run remote
        // cleanup in a fresh unstructured context so execute is not short-circuited.
        do {
            let cleanupDirectory = directory
            let cleanupProcessID = writer?.processID
            let cleanupObserver = observer
            try await Task.detached {
                try await RawTCPWriter.cleanup(
                    directory: cleanupDirectory,
                    processID: cleanupProcessID,
                    using: cleanupObserver)
            }.value
        } catch {
            if primaryError == nil {
                primaryError = error
            }
        }

        try? await observer.close(timeout: .seconds(2))

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

    /// The four sites #149 actually owns are not the four `close*` sites above.
    /// Each abandons in-progress native state that no later Heeler operation can
    /// safely adopt: singular SFTP init/request state, or an allocated exec
    /// channel whose only pointer is about to leave scope. A deadline at these
    /// sites therefore remains connection-fatal even though #136 correctly
    /// spares a deadline at an ordinary `close*` teardown.
    @Test("issue 149 deadlines invalidate each operation with abandoned native state")
    func issue149DeadlinesInvalidateAbandonedNativeState() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for site in Issue149Site.allCases {
            let connection = try await environment.connect()
            let error = await site.expire(on: connection)

            #expect(error == .timedOut, "\(site.rawValue) reported \(String(describing: error))")
            #expect(
                await connection.isConnected == false,
                "\(site.rawValue) kept a session with abandoned native state reusable")
            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
            try? await connection.close(timeout: .seconds(1))
        }

        let cancelledConnection = try await environment.connect()
        let cancelledOpen = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await cancelledConnection.openSFTP(timeout: .seconds(5))
        }
        await #expect(throws: SSHError.cancelled) { _ = try await cancelledOpen.value }
        #expect(await cancelledConnection.isConnected == false)
        try? await cancelledConnection.close(timeout: .seconds(1))
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
            var operation: Task<SSHError?, Never>?
            let heldWait = site == .openSFTP ? SessionWaitHold() : nil
            if let heldWait {
                try await proxy.degrade()
                await connection.holdNextSessionWaitForTesting {
                    await heldWait.waitUntilReleased()
                }
                operation = Task { await body() }
                try await waitUntilTrue("openSFTP should reach EAGAIN") {
                    await heldWait.hasEntered
                }
            } else if site.startsBeforeSeverance {
                operation = Task { await body() }
                try await Task.sleep(for: .milliseconds(300))
            }
            #expect(try await proxy.cut() > 0)
            await heldWait?.release()
            try await Task.sleep(for: .milliseconds(500))
            let activeOperation = operation ?? Task { await body() }
            let error = await activeOperation.value

            #expect(error != nil, "\(site.rawValue) did not report the severed transport")
            #expect(
                await connection.isConnected == false,
                "\(site.rawValue) spared a session after genuine transport loss")
            try? await connection.close(timeout: .seconds(1))
        }
        try await proxy.reset()
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

    private func waitUntilTrue(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
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
    /// `processID` may be nil when launch failed before a handle was parsed;
    /// cleanup finds owned processes via the known writer path. A PID is owned
    /// only while its command is `/usr/bin/python3` with this exact path.
    static func cleanup(
        directory: String,
        processID: Int32?,
        using observer: SSHConnection
    ) async throws {
        _ = processID
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

            # Field 2 must be the interpreter; full line must contain exact path.
            # (A plain `read -r pid cmd` under /bin/sh puts the whole line in pid.)
            collect_owned() {
              ps -A -o pid= -o command= 2>/dev/null \\
                | awk -v needle="$writer_py" \\
                  '$2 == "/usr/bin/python3" && index($0, needle) { print $1 }'
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

    var startsBeforeSeverance: Bool {
        switch self {
        case .execute, .executeResponseLine: true
        case .openSFTP, .removeSFTPFileForCompensation: false
        }
    }

    func expire(on connection: SSHConnection) async -> SSHError? {
        do {
            switch self {
            case .execute:
                _ = try await connection.execute("sleep 30", timeout: .milliseconds(100))
            case .executeResponseLine:
                _ = try await connection.executeResponseLine(
                    "sleep 30",
                    input: Data("request\n".utf8),
                    maximumResponseBytes: 64,
                    timeout: .milliseconds(100))
            case .openSFTP:
                _ = try await connection.openSFTP(timeout: .zero)
            case .removeSFTPFileForCompensation:
                let sftp = try await connection.openSFTP(timeout: .seconds(5))
                try await sftp.removeFileForCompensation(
                    at: "/tmp/heeler-issue-149-\(UUID().uuidString)",
                    timeout: .zero)
            }
            return nil
        } catch {
            return error as? SSHError
        }
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
