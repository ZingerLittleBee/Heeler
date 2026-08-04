import Foundation
import Testing

@testable import Heeler

/// The product driven over a link the test degrades on purpose.
///
/// The merge gate runs unprivileged, which rules out `pfctl`/`dummynet` and the
/// machine-wide Network Link Conditioner. Instead the fixture puts an
/// unprivileged TCP proxy in front of the disposable sshd
/// (`scripts/fixtures/weak-network-proxy.py`) and these suites steer it: added
/// latency, a bandwidth cap, mid-stream fragmentation, and abrupt severance.
/// Every impairment is a fixed duration or a byte count, so a profile treats
/// the link the same way on every run and a failure here means a defect rather
/// than a bad draw.
///
/// `.timeLimit` is the deadlock instrument. Everything these tests exercise is
/// bounded by the product's own deadlines, so a run that has not finished
/// inside the limit is a stalled loop, and it must fail in bounded time rather
/// than hang the runner.
@Suite(
    "Weak network e2e",
    .enabled(
        if: RealSSHFixture.gate(HeelerSSHTransportBehaviorEnvironment.current != nil),
        "requires the disposable impairment proxy fixture"),
    .serialized,
    .timeLimit(.minutes(2)))
struct WeakNetworkE2ETests {
    @Test("concurrent RPCs survive latency, a bandwidth cap, and fragmentation")
    func concurrentRPCsSurviveADegradedLink() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)

        let transport = try await HeelerSSHTransport.connect(settings: fixture.settings())
        try await AsyncDeadline.run(for: .seconds(45)) {
            try await withThrowingTaskGroup(of: ServerInfo.self) { group in
                for _ in 0..<HeelerSSHTransport.maxConcurrentForwardingChannels {
                    group.addTask { try await transport.ping() }
                }
                for try await server in group {
                    #expect(server.protocolVersion == 17)
                }
            }
        }
        // The budget released every slot, so the connection is still usable.
        #expect(try await transport.ping().protocolVersion == 17)

        let stats = try await fixture.control.stats()
        #expect(stats.bytesToServer > 0)
        #expect(stats.bytesToClient > 0)
        try await transport.close()
    }

    @Test("Events and Attach stay live while SFTP stages over a degraded link")
    func eventsAndAttachStayLiveDuringDegradedStaging() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)

        let prepared = try makePreparedImage(byteCount: 256 * 1_024)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let transport = try await HeelerSSHTransport.connect(settings: fixture.settings())
        let events = try await transport.subscribeToEvents([.global(.paneCreated)])
        var eventIterator = events.events.makeAsyncIterator()
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:weak", cols: 80, rows: 24))
        var attachIterator = attach.output.makeAsyncIterator()

        let staging = Task { try await transport.stageImage(prepared.image) { _ in } }
        try await AsyncDeadline.run(for: .seconds(45)) {
            try await withThrowingTaskGroup(of: ServerInfo.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await transport.ping() }
                }
                for try await server in group {
                    #expect(server.protocolVersion == 17)
                }
            }
        }

        let staged = try await staging.value
        let parentDirectory = staged.fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        // A fragmented, rate-limited link must not corrupt or truncate SFTP.
        #expect(try Data(contentsOf: staged.fileURL) == prepared.bytes)

        let event = try await eventIterator.next()
        #expect(event?.kind == HerdrEventKind(name: "future_herdr_event"))
        attach.send(Data("probe-over-weak-link\n".utf8))
        var attachOutput = ""
        while !attachOutput.contains("GOT:probe-over-weak-link") {
            let chunk = try #require(try await attachIterator.next())
            attachOutput += String(decoding: chunk, as: UTF8.self)
        }

        await attach.end()
        await events.end()
        try await transport.close()
    }

    @Test("cancelling a rate-starved upload frees only its own channel")
    func cancellationUnderBackpressureKeepsTheConnectionUsable() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.severe)

        let prepared = try makePreparedImage(byteCount: 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let transport = try await HeelerSSHTransport.connect(settings: fixture.settings())
        let progressed = ProgressGate()
        let staging = Task {
            try await transport.stageImage(prepared.image) { value in
                if value.transferredBytes > 0 { await progressed.record() }
            }
        }
        // Cancel while the upload is genuinely blocked on link backpressure,
        // not before it has written anything.
        try await waitUntil("the upload should report a transferred chunk") {
            await progressed.count > 0
        }
        // Cancellation itself is honoured promptly even while the write is
        // blocked on the link, and "promptly" is asserted rather than asserted
        // in prose: the compensation path spends at most its two two-second
        // SFTP closes, so anything approaching ten seconds means the cancel is
        // waiting on the link instead of abandoning it.
        let cancelledAt = ContinuousClock.now
        staging.cancel()
        await #expect(throws: ImageStagingError.cancelled) { _ = try await staging.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(10))

        try await fixture.control.apply(.degraded)
        // The reuse property is what a cancelled upload owes the rest of the
        // Host: Events and Attach share this connection. It does not hold on a
        // slow link, and the assertion stays as written so the day it starts
        // holding this test says so.
        //
        // Mechanism: the compensation path closes the SFTP client and file with
        // hardcoded two-second budgets (`cancelImageStage`, `streamImage`'s
        // catch), while `SessionDriver.closeSFTP`/`closeSFTPFile` treat any
        // error from that close — a mere deadline expiry included — as grounds
        // for `invalidateResources()`. Below roughly 256 KiB/s the SFTP
        // shutdown cannot drain the partially written chunk inside two seconds,
        // so the whole SSH session is torn down; `cancelImageStage` swallows
        // the throw with `try?`, so the next RPC is the first sign of it.
        // Deterministic in the link speed, not racy: fails 3/3 at 16 KiB/s,
        // passes 2/2 at 256 KiB/s, and passes 2/2 at 16 KiB/s when the link is
        // restored immediately before the cancel.
        //
        // The matcher admits only the invalidation itself. Without it the block
        // would absorb any failure inside it — a ping that succeeded while
        // reporting the wrong protocol version would go green as "the known
        // issue", which is the opposite of what this records.
        try await withKnownIssue(
            "cancelling a rate-starved upload invalidates the whole SSH session"
        ) {
            let server = try await transport.ping()
            #expect(server.protocolVersion == 17)
        } matching: { issue in
            guard
                let error = issue.error as? TransportError,
                case .sshUnreachable = error
            else { return false }
            return true
        }
        try? await transport.close()
    }

    @Test("bandwidth starvation times out instead of wedging the connection")
    func starvedLinkTimesOutAndRecovers() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)

        var settings = fixture.settings()
        settings.requestTimeout = .seconds(4)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        #expect(try await transport.ping().protocolVersion == 17)

        // 64 bytes per second cannot carry a request, so the product's own
        // per-request deadline is what must end this — not a hung channel.
        try await fixture.control.apply(.starved)
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) { _ = try await transport.ping() }
        #expect(started.duration(to: .now) < .seconds(20))

        try await fixture.control.apply(.degraded)
        #expect(try await transport.ping().protocolVersion == 17)
        try await transport.close()
    }

    @Test("an abruptly severed link surfaces and a fresh connection recovers")
    func abruptLinkLossSurfacesAndRecovers() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)

        var settings = fixture.settings()
        settings.requestTimeout = .seconds(10)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        #expect(try await transport.ping().protocolVersion == 17)

        #expect(try await fixture.control.cut() > 0)
        await #expect(throws: (any Error).self) { _ = try await transport.ping() }
        try? await transport.close()

        let recovered = try await HeelerSSHTransport.connect(settings: settings)
        #expect(try await recovered.ping().protocolVersion == 17)
        try await recovered.close()
    }

    @Test("the events session survives a cut and a background round trip")
    func eventsSessionRecoversAcrossBackgroundingOnADegradedLink() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)

        var settings = fixture.settings()
        settings.requestTimeout = .seconds(10)
        let capturedSettings = settings
        let session = EventsSession(
            subscriptions: [.global(.paneCreated)],
            connect: { try await HeelerSSHTransport.connect(settings: capturedSettings) })
        let recorder = StatusRecorder()
        let consumer = Task {
            for await update in session.updates {
                if case .status(let status) = update { await recorder.record(status) }
            }
        }
        defer { consumer.cancel() }

        await session.resume()
        try await waitUntil("the degraded link should connect", timeout: .seconds(30)) {
            await recorder.count(of: .connected) >= 1
        }

        // The link dies mid-session, exactly as a mobile network does.
        #expect(try await fixture.control.cut() > 0)
        try await waitUntil("the loss should surface as a reconnect", timeout: .seconds(30)) {
            await recorder.hasReconnected
        }
        try await waitUntil("the session should reconnect itself", timeout: .seconds(60)) {
            await recorder.count(of: .connected) >= 2
        }

        // Backgrounding past the grace period, then foregrounding again.
        // `suspend()` returning means the teardown is done, not that the
        // consumer draining `updates` has been scheduled yet, so the terminal
        // status is asserted through a bounded wait like every other one here.
        await session.suspend()
        try await waitUntil("backgrounding should suspend the session") {
            await recorder.statuses.last == .suspended
        }
        await session.resume()
        try await waitUntil("foregrounding should reconnect", timeout: .seconds(30)) {
            await recorder.count(of: .connected) >= 3
        }

        await session.end()
        try await waitUntil("the session should end") {
            await recorder.statuses.last == .ended
        }
    }

    /// The leak instrument. Every round takes a connection through the whole
    /// channel repertoire and gives it back; a session, channel, or socket that
    /// is not reclaimed shows up as descriptor growth proportional to the round
    /// count, which one-off warm-up allocation cannot imitate.
    @Test("repeated degraded rounds reclaim every file descriptor")
    func degradedStressRoundsReclaimEveryDescriptor() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        try await fixture.control.apply(.degraded)
        let rounds = 5

        // One warm-up round first: the first connection on a fresh process
        // allocates caches and resolver state that never come back, and that
        // is not what this measures.
        try await exerciseOneRound(fixture: fixture)
        let baseline = OpenFileDescriptorCount.current
        let before = try await fixture.control.stats()
        for _ in 0..<rounds {
            try await exerciseOneRound(fixture: fixture)
        }
        let final = OpenFileDescriptorCount.current
        print(
            "[weak-network] open descriptors: baseline \(baseline), "
                + "after \(rounds) rounds \(final)")

        // A per-round leak of even one descriptor would be `rounds` of growth.
        #expect(
            final <= baseline + 2,
            "descriptors grew from \(baseline) to \(final) across \(rounds) rounds")
        // A census over rounds that never opened anything would also be flat,
        // so count the connections the proxy actually accepted: one per round,
        // since every channel a round opens rides the same TCP connection.
        let after = try await fixture.control.stats()
        #expect(after.acceptedConnections - before.acceptedConnections == rounds)
    }

    private func exerciseOneRound(fixture: WeakNetworkFixture) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: fixture.settings())
        try await AsyncDeadline.run(for: .seconds(45)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask { _ = try await transport.ping() }
                }
                try await group.waitForAll()
            }
        }
        let events = try await transport.subscribeToEvents([.global(.paneCreated)])
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:weak-round", cols: 80, rows: 24))
        await attach.end()
        await events.end()
        try await transport.close()
        // The proxy tears its half down asynchronously once both directions
        // see EOF; wait for it so the descriptor census is not racing it.
        try await waitUntil("the proxy should release the severed links") {
            (try? await fixture.control.stats().liveConnections) == 0
        }
    }

    private func makePreparedImage(byteCount: Int) throws -> (image: PreparedImage, bytes: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-weak-\(UUID().uuidString).png")
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: url)
        return (
            PreparedImage(
                fileURL: url,
                format: .png,
                pixelWidth: 2_048,
                pixelHeight: 1_024,
                byteCount: Int64(bytes.count)),
            bytes)
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(15),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await condition(), comment)
    }

    private actor ProgressGate {
        private(set) var count = 0

        func record() { count += 1 }
    }

    private actor StatusRecorder {
        private(set) var statuses: [EventsSessionStatus] = []

        func record(_ status: EventsSessionStatus) { statuses.append(status) }

        func count(of status: EventsSessionStatus) -> Int {
            statuses.filter { $0 == status }.count
        }

        var hasReconnected: Bool {
            statuses.contains { if case .reconnecting = $0 { true } else { false } }
        }
    }
}

/// The impairment proxy the merge fixture stands up, plus the settings that
/// route the product through it.
struct WeakNetworkFixture: Sendable {
    let environment: HeelerSSHTransportBehaviorEnvironment
    let port: UInt16
    let control: WeakNetworkProxyControl

    static var current: WeakNetworkFixture? {
        guard
            let environment = HeelerSSHTransportBehaviorEnvironment.current,
            let port = environment.weakNetworkPort,
            let controlPort = environment.weakNetworkControlPort
        else { return nil }
        return WeakNetworkFixture(
            environment: environment,
            port: port,
            control: WeakNetworkProxyControl(host: environment.host, port: controlPort))
    }

    func settings() -> SSHTransportSettings {
        environment.weakNetworkSettings(port: port)
    }
}
