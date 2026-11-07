import Foundation
import Testing

@testable import Heeler

/// Changes over a cellular-like link (#395): the calibration of the git
/// deadline and the Host-side caps, and an overrun that must stay a Changes
/// failure rather than become a link failure.
extension WeakNetworkE2ETests {
    /// A Checkout whose status overflows the status cap, and one file whose
    /// patch overflows the Load More cap, read over loopback for reference and
    /// then over the cellular-like profile, directly and behind the Jump Host.
    /// The link's part of every read must finish inside the production git
    /// deadline: a read that overruns it shows no Changes at all. The Host's
    /// own git time is the runner's, not the link's, so it is left out.
    @Test("a status past its cap and a 1 MiB patch read inside the git deadline over the cellular-like profile")
    func largeChangesReadsFitTheGitDeadlineOverACellularLink() async throws {
        let rawIterations = ProcessInfo.processInfo.environment["HEELER_WEAK_CHANGES_ITERATIONS"] ?? "1"
        guard let iterations = Int(rawIterations), (1...100).contains(iterations) else {
            Issue.record("HEELER_WEAK_CHANGES_ITERATIONS must be an integer between 1 and 100")
            return
        }
        for iteration in 1...iterations {
            print("[changes-field] iteration=\(iteration)/\(iterations)")
            try await calibrateLargeChangesRead()
        }
        print("[weak-changes-test] completed \(iterations) iterations")
    }

    /// Diagnostic repetition uses a fresh Checkout and closed transports each
    /// time. Ordinary merge CI runs the original single calibration.
    private func calibrateLargeChangesRead() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        let environment = fixture.environment
        // Seeding writes thousands of files, which is not what the deadline
        // bounds, so the seeding connection gets a generous one of its own.
        var seederSettings = environment.directSettings()
        seederSettings.gitExecTimeout = .seconds(90)
        let seeder = try await HeelerSSHTransport.connect(settings: seederSettings)
        let root = "\"$HOME\"/changes-large-" + UUID().uuidString
        let cleanup = Data("{ rm -rf \(root); } </dev/null\n".utf8)
        do {
            let seeded = try await seeder.runGitScript(Self.largeCheckoutScript(root: root))
            try #require(
                seeded.exitStatus == 0,
                "seed failed: \(String(decoding: seeded.stderr, as: UTF8.self))")
            let topLevel = try #require(
                Self.markedValue("TOP", in: seeded.stdout), "the seed printed no top level")
            try await Self.reportOutputSizes(on: seeder, topLevel: topLevel)
            let routes = [
                LinkRoute(label: "loopback-direct", settings: environment.directSettings()),
                LinkRoute(label: "loopback-jump", settings: environment.jumpSettings()),
                LinkRoute(label: "cellular-direct", settings: fixture.settings(), profile: .degraded),
                LinkRoute(label: "cellular-jump", settings: fixture.jumpSettings(), profile: .degraded),
            ]
            for route in routes {
                try await readLargeChanges(over: route, fixture: fixture, topLevel: topLevel)
            }
            try await fixture.control.reset()
            #expect(try await seeder.runGitScript(cleanup).exitStatus == 0)
            try await seeder.close()
        } catch {
            try? await fixture.control.reset()
            _ = try? await seeder.runGitScript(cleanup)
            try? await seeder.close()
            throw error
        }
    }

    /// The overrun comes from the Host, not the link: the Checkout's clean
    /// filter, the path git-lfs takes, outlasts the git deadline. Events and
    /// the attached terminal share the connection and must not notice.
    @MainActor
    @Test("a git overrun shows timed out without redialing the Host or rebuilding its terminal")
    func gitOverrunKeepsTheHostConnectionAndItsTerminal() async throws {
        let fixture = try #require(WeakNetworkFixture.current)
        try await fixture.control.reset()
        let environment = fixture.environment
        let seeder = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await seeder.close() } }
        let root = "\"$HOME\"/changes-overrun-" + UUID().uuidString
        let cleanup = Data("{ rm -rf \(root); } </dev/null\n".utf8)
        let seeded = try await seeder.runGitScript(Self.slowFilterCheckoutScript(root: root))
        guard seeded.exitStatus == 0, let topLevel = Self.markedValue("TOP", in: seeded.stdout) else {
            _ = try? await seeder.runGitScript(cleanup)
            Issue.record("seed failed: \(String(decoding: seeded.stderr, as: UTF8.self))")
            return
        }

        try await fixture.control.apply(.degraded)
        let settings = fixture.settings()
        let dials = DialCounter()
        let session = EventsSession(
            subscriptions: [.global(.paneCreated)],
            connect: {
                await dials.record()
                return try await HeelerSSHTransport.connect(settings: settings)
            })
        let statuses = SessionStatusLog()
        let consumer = Task {
            for await update in session.updates {
                if case .status(let status) = update { await statuses.append(status) }
            }
        }
        defer { consumer.cancel() }
        await session.resume()
        try await Self.waitUntil("the degraded link should connect", timeout: .seconds(30)) {
            await statuses.contains(.connected)
        }
        let acceptedBefore = try await fixture.control.stats().acceptedConnections
        let generationBefore = await session.transportGeneration
        let terminal = try await session.withTransport { transport in
            try await transport.attachTerminal(
                TerminalAttachRequest(target: "fixture:git-overrun", cols: 80, rows: 24))
        }
        var terminalOutput = terminal.output.makeAsyncIterator()

        let store = ChangesStore(
            directory: { topLevel },
            read: { request in
                try await session.withTransport { try await $0.readChanges(request) }
            },
            gate: GitExecGate())
        let deadline = SSHTransportSettings.defaultGitExecTimeout
        let started = ContinuousClock.now
        await store.appear()
        let elapsed = started.duration(to: .now)
        #expect(store.phase == .timedOut)
        #expect(elapsed >= deadline && elapsed < deadline + .seconds(5), "timed out after \(elapsed)")
        print("[changes-field] overrun deadline=\(deadline) timed-out-after=\(ChangesFieldCheckout.milliseconds(elapsed))")

        // Stay idle past the remote watchdog and the package's cleanup window
        // before looking: an early request can mask a late invalidation.
        try await Task.sleep(for: .seconds(3))
        let openExecs = try await session.withTransport { transport in
            await (transport as? HeelerSSHTransport)?.ordinarySessionChannelCountForTesting()
        }
        #expect(openExecs == 0, "the watchdog should have ended the git exec")
        #expect(await dials.count == 1, "the Host was redialed")
        #expect(await session.transportGeneration == generationBefore)
        #expect(try await fixture.control.stats().acceptedConnections == acceptedBefore)
        #expect(await !statuses.hasReconnected)

        // The terminal attached before the overrun still carries bytes both ways.
        terminal.send(Data("after-git-overrun\n".utf8))
        var echoed = ""
        while !echoed.contains("GOT:after-git-overrun") {
            let chunk = try #require(try await terminalOutput.next())
            echoed += String(decoding: chunk, as: UTF8.self)
        }
        #expect(try await session.withTransport { try await $0.ping() }.protocolVersion == 17)
        #expect(await dials.count == 1)

        await terminal.end()
        await session.end()
        try await fixture.control.reset()
        #expect(try await seeder.runGitScript(cleanup).exitStatus == 0)
    }

    // MARK: Large Checkout

    static let largeCheckoutFileCount = 5_000
    static let largePatchLineCount = 20_000

    /// One route from the device to the fixture Host.
    struct LinkRoute: Sendable {
        let label: String
        let settings: SSHTransportSettings
        var profile: WeakNetworkProfile? = nil
    }

    /// The reads run with headroom past the git deadline, so a slow read is
    /// measured rather than cut off, and the production deadline is then
    /// asserted on the measured time less the Host's own run of the script.
    /// Admission and the exec are timed from the caller's side, exactly what
    /// the deadline bounds.
    private func readLargeChanges(
        over route: LinkRoute, fixture: WeakNetworkFixture, topLevel: String
    ) async throws {
        try await fixture.control.reset()
        if let profile = route.profile { try await fixture.control.apply(profile) }
        var settings = route.settings
        settings.gitExecTimeout = .seconds(60)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        do {
            try await measureLargeChangesRead(
                using: transport, over: route, fixture: fixture, topLevel: topLevel)
            try await transport.close()
        } catch {
            try? await transport.close()
            throw error
        }
    }

    private func measureLargeChangesRead(
        using transport: HeelerSSHTransport, over route: LinkRoute,
        fixture: WeakNetworkFixture, topLevel: String
    ) async throws {
        let deadline = SSHTransportSettings.defaultGitExecTimeout
        let isImpaired = route.profile != nil

        let beforeChanges = try await fixture.control.stats()
        let changes = try await Self.hostTimedRead(on: transport) { nonce in
            GitProbe.changesScript(directory: topLevel, nonce: nonce)
        } parse: { stdout, stderr, nonce in
            try GitProbe.parseChanges(stdout: stdout, stderr: stderr, nonce: nonce)
        }
        let read = changes.value
        let changesWire = try await fixture.control.stats().bytesToClient
            - beforeChanges.bytesToClient
        #expect(read.changes.isStatusTruncated, "\(route.label): the status should hit its cap")
        #expect(read.changes.listedFiles.count == CheckoutChanges.displayLimit, "\(route.label)")
        #expect(
            changes.elapsed - changes.host < deadline,
            "\(route.label): the Changes read took \(changes.elapsed), \(changes.host) of it the Host's own run, leaving more than the \(deadline) git deadline")
        print(
            "[changes-field] route=\(route.label) read=changes"
                + " elapsed=\(ChangesFieldCheckout.milliseconds(changes.elapsed))"
                + " host=\(ChangesFieldCheckout.milliseconds(changes.host))"
                + " wire-bytes=\(isImpaired ? String(changesWire) : "-")"
                + " files=\(read.changes.files.count)")

        let request = FilePatchRequest(
            topLevel: Data(topLevel.utf8), path: Data("large.txt".utf8),
            isUntracked: false, limit: .extended)
        let beforePatch = try await fixture.control.stats()
        let patchRead = try await Self.hostTimedRead(on: transport) { nonce in
            GitProbe.patchScript(request, nonce: nonce)
        } parse: { stdout, stderr, nonce in
            try GitProbe.parsePatch(stdout: stdout, stderr: stderr, nonce: nonce, request: request)
        }
        let patch = patchRead.value
        let patchWire = try await fixture.control.stats().bytesToClient - beforePatch.bytesToClient
        #expect(patch.isTruncated, "\(route.label): the patch should hit the Load More cap")
        #expect(
            patchRead.elapsed - patchRead.host < deadline,
            "\(route.label): the patch read took \(patchRead.elapsed), \(patchRead.host) of it the Host's own run, leaving more than the \(deadline) git deadline")
        print(
            "[changes-field] route=\(route.label) read=patch-extended"
                + " elapsed=\(ChangesFieldCheckout.milliseconds(patchRead.elapsed))"
                + " host=\(ChangesFieldCheckout.milliseconds(patchRead.host))"
                + " wire-bytes=\(isImpaired ? String(patchWire) : "-")"
                + " lines=\(patch.files.flatMap(\.hunks).flatMap(\.lines).count)")
    }

    /// One read made the way `readChanges` and `readFilePatch` make it, a
    /// GitProbe script in one bounded git exec parsed under its nonce, with
    /// the Host's clock read around the script inside that same exec. On a
    /// loaded runner the Host's process for one loopback Changes exec lived
    /// about 15 s, past the deadline with no link at all (#634). That share
    /// is the runner's; the rest is what the link and the transport added.
    ///
    /// The split holds while the script never waits on the link: its output
    /// (under 1.1 MB at today's GitProbe caps) fits the 2 MiB receive window
    /// the exec channel opens with. Output past that window would block the
    /// script on the link and count the wait as the Host's.
    private static func hostTimedRead<Value>(
        on transport: HeelerSSHTransport,
        script: (_ nonce: String) -> Data,
        parse: (_ stdout: Data, _ stderr: Data, _ nonce: String) throws -> Value
    ) async throws -> (value: Value, elapsed: Duration, host: Duration) {
        let nonce = GitProbe.makeNonce()
        let timed = Data("__heeler_field_t0=$(\(hostClock))\n".utf8)
            + script(nonce)
            + Data("""
                __heeler_field_t1=$(\(hostClock))
                printf '\\n%s%s,%s\\n' '\(hostTimeMarker)' "$__heeler_field_t0" "$__heeler_field_t1" >&2

                """.utf8)
        let (result, elapsed) = try await ChangesFieldCheckout.timed {
            try await transport.runGitScript(timed)
        }
        let marker = try #require(
            result.stderr.range(of: Data("\n\(hostTimeMarker)".utf8), options: .backwards),
            "the Host reported no run time")
        let clocks = String(decoding: result.stderr[marker.upperBound...], as: UTF8.self)
            .split(separator: "\n").first?.split(separator: ",").compactMap { Int64($0) } ?? []
        let started = try #require(clocks.first, "the Host's start clock was unreadable")
        let ended = try #require(clocks.dropFirst().first, "the Host's end clock was unreadable")
        let host = Duration.milliseconds(ended - started)
        let stderr = result.stderr[..<marker.lowerBound]
        return (try parse(result.stdout, Data(stderr), nonce), elapsed, host)
    }

    /// Milliseconds since the epoch. The fixture Host is macOS, whose sh has
    /// no sub-second clock of its own.
    private static let hostClock =
        "/usr/bin/perl -MTime::HiRes=time -e 'printf \"%d\", time * 1000'"
    private static let hostTimeMarker = "__FIELD_HOST_CLOCKS__="

    /// The bytes each read's script prints, which is what crosses the link.
    private static func reportOutputSizes(
        on transport: HeelerSSHTransport, topLevel: String
    ) async throws {
        let changes = try await transport.runGitScript(
            GitProbe.changesScript(directory: topLevel, nonce: GitProbe.makeNonce()))
        let patch = try await transport.runGitScript(
            GitProbe.patchScript(
                FilePatchRequest(
                    topLevel: Data(topLevel.utf8), path: Data("large.txt".utf8),
                    isUntracked: false, limit: .extended),
                nonce: GitProbe.makeNonce()))
        print(
            "[changes-field] sizes files=\(largeCheckoutFileCount + 1)"
                + " changes-output-bytes=\(changes.stdout.count)"
                + " patch-extended-output-bytes=\(patch.stdout.count)"
                + " status-cap=\(GitProbe.Cap.status) numstat-cap=\(GitProbe.Cap.numstat)"
                + " patch-extended-cap=\(GitProbe.Cap.patchExtended)")
    }

    /// Every file modified by one line, each status record about 160 bytes,
    /// so the status alone prints about 800 KB, past the 512 KiB cap;
    /// `large.txt` is rewritten wholesale, so its patch overflows the 1 MiB
    /// Load More cap. No more files than that: the Host's own git time grows
    /// with every one, and a CI runner took 6.5 s over 14,000 on loopback,
    /// which measures the runner rather than the link.
    private static func largeCheckoutScript(root: String) -> Data {
        Data(
            """
            {
            set -e
            r=\(root)
            mkdir -p "$r/repo"
            cd "$r/repo"
            git init -q .
            git symbolic-ref HEAD refs/heads/main
            awk 'BEGIN { for (d = 0; d < 50; d++) printf "d%02d\\n", d }' | xargs mkdir -p
            fill() {
              awk -v n=\(largeCheckoutFileCount) -v text="$1" 'BEGIN {
                for (i = 0; i < n; i++) {
                  f = sprintf("d%02d/changed-file-with-a-realistic-name-%05d.txt", i % 50, i)
                  print text > f
                  close(f)
                }
              }'
              awk -v n=\(largePatchLineCount) -v text="$1" 'BEGIN {
                for (i = 0; i < n; i++) printf "%s line %06d of the generated patch measurement file\\n", text, i
              }' > large.txt
            }
            fill original
            git add -A
            git -c user.name=Heeler -c user.email=fixture@heeler.invalid commit -q -m 'Seed the large Checkout'
            fill changed
            printf '__FIELD_TOP__=%s\\n' "$(pwd -P)"
            } </dev/null

            """.utf8)
    }

    // MARK: Slow Checkout

    /// `slow.dat` is stat-dirty but unchanged, so status re-hashes it through
    /// its clean filter, which sleeps far past any git deadline.
    private static func slowFilterCheckoutScript(root: String) -> Data {
        Data(
            """
            {
            set -e
            r=\(root)
            mkdir -p "$r/repo"
            cd "$r/repo"
            git init -q .
            git symbolic-ref HEAD refs/heads/main
            printf 'content behind a clean filter\\n' > slow.dat
            git add slow.dat
            git -c user.name=Heeler -c user.email=fixture@heeler.invalid commit -q -m 'Seed the slow Checkout'
            printf 'slow.dat filter=slow\\n' > .gitattributes
            git config filter.slow.clean 'sleep 600; cat'
            touch -t 203001010000 slow.dat
            printf '__FIELD_TOP__=%s\\n' "$(pwd -P)"
            } </dev/null

            """.utf8)
    }

    // MARK: Helpers

    private static func markedValue(_ key: String, in output: Data) -> String? {
        let prefix = "__FIELD_\(key)__="
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(15),
        condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await condition(), comment)
    }

    private actor DialCounter {
        private(set) var count = 0

        func record() { count += 1 }
    }

    private actor SessionStatusLog {
        private var statuses: [EventsSessionStatus] = []

        func append(_ status: EventsSessionStatus) { statuses.append(status) }

        func contains(_ status: EventsSessionStatus) -> Bool { statuses.contains(status) }

        var hasReconnected: Bool {
            statuses.contains { if case .reconnecting = $0 { true } else { false } }
        }
    }
}
