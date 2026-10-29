import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// An Agents list row's Changes totals: the line totals the Changes header
/// shows for the same read, and nothing when that read cannot vouch for them.
@MainActor
@Suite("Changes row totals")
struct ChangesBadgeTests {
    private static let english = Locale(identifier: "en_US")

    /// The tracking recording with `app.txt` counted as `added`/`removed`;
    /// its binary file and untracked note stay as recorded.
    static func read(added: Int, removed: Int) throws -> CheckoutChangesRead {
        let stdout = Data(
            String(decoding: GitProbeRecordings.tracking.stdout, as: UTF8.self)
                .replacingOccurrences(of: "3\t1\tapp.txt", with: "\(added)\t\(removed)\tapp.txt")
                .utf8)
        return try ChangesStoreTests.read((stdout, GitProbeRecordings.tracking.stderr))
    }

    private static func badge(_ changes: CheckoutChanges) -> ChangesBadge? {
        ChangesBadge(phase: .loaded(changes), timedOutKeepingContent: false)
    }

    /// The Changes header writes the same exact counts.
    private static func expectHeaderMatches(_ badge: ChangesBadge, _ changes: CheckoutChanges) {
        let header = ChangesLineCounts.texts(
            added: changes.totals.added, removed: changes.totals.removed)
        #expect(header.added == badge.addedText())
        #expect(header.removed == badge.removedText())
    }

    @Test func showsTheHeadersLineTotalsForALoadedDirtyCheckout() throws {
        let changes = try Self.read(added: 12, removed: 7).changes
        let badge = try #require(Self.badge(changes))
        #expect(badge.addedText(locale: Self.english) == "+12")
        #expect(badge.removedText(locale: Self.english) == "\u{2212}7")
        Self.expectHeaderMatches(badge, changes)
        #expect(badge.accessibilityValue == "12 lines added, 7 lines removed")
    }

    @Test func hidesWhenNothingIsReadCleanOrFailed() throws {
        let clean = try ChangesStoreTests.read(GitProbeRecordings.clean).changes
        #expect(clean.isClean)
        let phases: [ChangesStore.Phase] = [
            .loading, .loaded(clean), .notAGitWorkingTree, .failed("fatal: broken"), .gitMissing,
            .gitTooOld("2.10.0"), .notOwnedByAccount, .directoryMissing, .incomplete, .timedOut,
        ]
        for phase in phases {
            #expect(
                ChangesBadge(phase: phase, timedOutKeepingContent: false) == nil,
                "a badge for \(phase)")
        }
    }

    @Test func hidesWhenARefreshTimedOutKeepingTheOldDocument() throws {
        let changes = try Self.read(added: 12, removed: 7).changes
        #expect(ChangesBadge(phase: .loaded(changes), timedOutKeepingContent: true) == nil)
    }

    @Test func hidesWhenLineCountsAreUnavailable() throws {
        var changes = try Self.read(added: 12, removed: 7).changes
        changes.totals.linesAreAvailable = false
        #expect(Self.badge(changes) == nil)
    }

    /// Untracked, binary, and mode-only changes have no line delta, yet the
    /// Checkout is not clean: the badge says +0 −0 as the header does, and
    /// VoiceOver hears what did change.
    /// "+0 −0" would read as clean; a dirty Checkout without a line delta
    /// shows Tide's file counts instead, as the Tide git item does.
    @Test func showsTidesFileCountsWhenFilesChangedWithoutALineDelta() throws {
        var changes = TideGitItemTests.changes(files: [
            TideGitItemTests.file("logo.png", staging: .unstaged),
            TideGitItemTests.file("old.bin", kind: .deleted, staging: .staged),
            TideGitItemTests.file("a.swift", kind: .conflicted, staging: nil),
            TideGitItemTests.file("b.png", staging: .staged),
            TideGitItemTests.file("notes/", kind: .untracked, staging: nil),
        ], untracked: 2)
        changes.totals.added = 0
        changes.totals.removed = 0
        let badge = try #require(Self.badge(changes))
        #expect(badge.showsFiles)
        #expect(badge.fileCounts.map { badge.fileCountText($0, locale: Self.english) }
            == ["~1", "+2", "!1", "?2"])
        #expect(badge.fileCounts == TideGitItem.fileCounts(changes))
        #expect(badge.accessibilityValue == "4 files changed, 2 untracked items")

        let untrackedOnly = try #require(Self.badge(
            TideGitItemTests.changes(files: [
                TideGitItemTests.file("new.txt", kind: .untracked, staging: nil),
            ], untracked: 1)))
        #expect(untrackedOnly.fileCounts.map { untrackedOnly.fileCountText($0) } == ["?1"])
        #expect(untrackedOnly.accessibilityValue == "1 untracked item")

        let lines = try #require(Self.badge(try Self.read(added: 12, removed: 0).changes))
        #expect(!lines.showsFiles)
        #expect(lines.showsAdded && !lines.showsRemoved)
        let removals = try #require(Self.badge(try Self.read(added: 0, removed: 7).changes))
        #expect(!removals.showsFiles)
        #expect(!removals.showsAdded && removals.showsRemoved)
    }

    /// SwiftUI can build the file-count cells on its async render thread, as
    /// it did in #471. A cell closure isolated to the main actor traps there,
    /// so a regression crashes this test rather than failing it.
    @Test func buildsFileCountsOffTheMainThread() async throws {
        let badge = try #require(Self.badge(TideGitItemTests.changes(files: [
            TideGitItemTests.file("app.swift", staging: .unstaged),
            TideGitItemTests.file("notes/", kind: .untracked, staging: nil),
        ], untracked: 1)))
        try #require(badge.showsFiles)
        let totals = ChangesRowTotals(source: .sample(badge))
        for style in ChangesBadge.Style.allCases {
            let cell = UncheckedSendable(value: totals.fileCounts(badge, style: style).content)
            let counts = badge.fileCounts
            await Task.detached {
                for count in counts {
                    _ = cell.value(count)
                }
            }.value
        }
    }

    @Test func aTruncatedCountReadsAsALowerBound() throws {
        var changes = try Self.read(added: 12, removed: 7).changes
        changes.totals.linesAreComplete = false
        let badge = try #require(Self.badge(changes))
        #expect(badge.addedText(locale: Self.english) == "+12")
        #expect(badge.removedText(locale: Self.english) == "\u{2212}7")
        #expect(badge.accessibilityValue == "At least 12 lines added, 7 lines removed")
    }

    /// Below 10,000 the short form keeps two digits: a third would make it
    /// no shorter than the exact count, and the row would drop the badge
    /// where the short form fits.
    @Test(arguments: [
        (0, "0"), (999, "999"), (1_000, "1K"), (1_050, "1K"), (1_234, "1.2K"), (9_999, "9.9K"),
        (10_000, "10K"), (12_345, "12.3K"), (99_999, "99.9K"), (123_456, "123K"),
        (999_999, "999K"), (1_000_000, "1M"), (1_050_000, "1.05M"), (1_234_567, "1.23M"),
        (999_999_999, "999M"), (Int.max, "999T+"),
    ])
    func compactCountsShortenFromOneThousandWithoutOverstating(value: Int, expected: String) {
        #expect(ChangesBadge.count(value, style: .compact, locale: Self.english) == expected)
        #expect(
            ChangesBadge.count(value, style: .exact, locale: Self.english)
                == value.formatted(.number.locale(Self.english)))
    }

    @Test func compactCountsUseTheLocalesDecimalSeparator() {
        let german = Locale(identifier: "de_DE")
        #expect(ChangesBadge.count(12_345, style: .compact, locale: german) == "12,3K")
        #expect(ChangesBadge.count(1_234, style: .compact, locale: german) == "1,2K")
        #expect(ChangesBadge.count(999, style: .compact, locale: german) == "999")
    }

    /// The badge prefers the header's exact numbers; the short form is only
    /// for a row without room, and VoiceOver always hears them exactly.
    @Test func largeTotalsStayExactUntilTheRowAsksForTheShortForm() throws {
        let changes = try Self.read(added: 12_345, removed: 7).changes
        let badge = try #require(Self.badge(changes))
        #expect(badge.addedText(locale: Self.english) == "+12,345")
        #expect(badge.addedText(.compact, locale: Self.english) == "+12.3K")
        #expect(badge.removedText(.compact, locale: Self.english) == "\u{2212}7")
        #expect(badge.accessibilityValue.hasPrefix("\(12_345.formatted()) lines added"))
    }

    /// The Agents list's grounds: the phone's plain list, the iPad sidebar,
    /// and either with the sidebar's selected-row fill over it.
    @Test func inksMeetTextContrastOnTheListInEveryAppearance() {
        let appearances: [(String, UITraitCollection)] = [
            ("light", UITraitCollection(userInterfaceStyle: .light)),
            ("dark", UITraitCollection(userInterfaceStyle: .dark)),
            (
                "dark elevated",
                UITraitCollection { traits in
                    traits.userInterfaceStyle = .dark
                    traits.userInterfaceLevel = .elevated
                }
            ),
        ]
        for (name, traits) in appearances {
            for (groundName, groundColor) in [
                ("list", UIColor.systemBackground), ("sidebar", .secondarySystemBackground),
            ] {
                let ground = Self.rgb(groundColor, traits)
                let selected = Self.over(Self.rgba(.tertiarySystemFill, traits), ground)
                for (role, ink) in [
                    ("added", ChangesBadgePalette.addedInk), ("removed", ChangesBadgePalette.removedInk),
                ] {
                    for (state, fill) in [("", ground), (" selected", selected)] {
                        let ratio = Self.contrastRatio(Self.rgb(ink, traits), fill)
                        #expect(ratio >= 4.5, "\(role) ink on the \(name) \(groundName)\(state): \(ratio)")
                    }
                }
            }
        }
    }

    private static func rgba(_ color: UIColor, _ traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    /// Source-over compositing of a translucent fill on an opaque ground.
    private static func over(_ fill: [CGFloat], _ ground: [CGFloat]) -> [CGFloat] {
        (0..<3).map { fill[$0] * fill[3] + ground[$0] * (1 - fill[3]) }
    }

    private static func rgb(_ color: UIColor, _ traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue]
    }

    /// WCAG 2 contrast ratio from sRGB components.
    private static func contrastRatio(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let (lighter, darker) = luminance(a) > luminance(b)
            ? (luminance(a), luminance(b)) : (luminance(b), luminance(a))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.map { channel in
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

/// The Agents list's reads for its rows' totals, and the handoff with
/// Changes opened from Agent detail, every read through the Host's gate.
@MainActor
@Suite("Agents list Changes", .timeLimit(.minutes(1)))
struct AgentRowChangesTests {
    /// An Agent's status stream per store, as the Console hands them out: a
    /// fresh stream whose first value is the current status.
    @MainActor
    final class StatusFeed {
        private var current: AgentStatus?
        private var continuations: [AsyncStream<ConsoleStore.AgentStatusUpdate>.Continuation] = []

        init(_ status: AgentStatus?) { current = status }

        func stream() -> AsyncStream<ConsoleStore.AgentStatusUpdate> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: ConsoleStore.AgentStatusUpdate.self)
            continuation.yield(.init(status: current, liveUpdatesAvailable: true))
            continuations.append(continuation)
            return stream
        }

        func send(_ status: AgentStatus?) {
            current = status
            for continuation in continuations {
                continuation.yield(.init(status: status, liveUpdatesAvailable: true))
            }
        }

        func finish() {
            for continuation in continuations { continuation.finish() }
        }
    }

    /// Answers each Changes read by its directory, so stores reading
    /// different Checkouts get their own documents in either order.
    @MainActor
    final class DirectoryReads {
        private var outcomes: [String: [CheckoutChangesRead]]
        private(set) var requests: [String] = []

        init(_ outcomes: [String: [CheckoutChangesRead]]) { self.outcomes = outcomes }

        func read(_ request: ChangesReadRequest) throws -> CheckoutChangesRead {
            requests.append(request.directory)
            guard var queue = outcomes[request.directory], !queue.isEmpty else {
                throw ChangesReadError.unavailable
            }
            let next = queue.removeFirst()
            outcomes[request.directory] = queue
            return next
        }
    }

    /// Where the test's Agent is, and what the clock reads.
    @MainActor
    final class World {
        var directory = AgentRowChangesTests.trackingDirectory
        var now = Date(timeIntervalSince1970: 1_000)
        var announcements: [String] = []
    }

    /// The tracking recording's top level, where the Agent starts.
    static let trackingDirectory = "/home/dev/src/tracking"
    /// The worktree recording's top level, another Checkout.
    static let otherCheckoutDirectory = "/home/dev/src/app-wt"

    /// The list's rows and the detail's Changes for one Agent, sharing a
    /// Host gate, a clock, a status feed, and one source of reads.
    struct Fixture {
        let rows: AgentRowChanges
        let agent: ConsoleAgent
        let changes: AgentChangesPresentation
    }

    static func fixture(
        read: @escaping @Sendable (ChangesReadRequest) async throws -> CheckoutChangesRead,
        gate: GitExecGate = GitExecGate(),
        clock: ChangesManualSleeper,
        feed: StatusFeed,
        world: World = World(),
        directory: String? = trackingDirectory
    ) -> Fixture {
        func store(_ fixed: String?) -> ChangesStore {
            ChangesStore(
                directory: { fixed ?? world.directory },
                read: read,
                gate: gate,
                agentStatus: { feed.stream() },
                sleep: { try await clock.sleep($0) },
                now: { world.now },
                announce: { world.announcements.append($0) })
        }
        let rows = AgentRowChanges { _ in store(nil) }
        let agent = Self.agent(directory: directory)
        let changes = AgentChangesPresentation(row: (rows, agent.id)) { store($0) }
        return Fixture(rows: rows, agent: agent, changes: changes)
    }

    static func fixture(
        transport: ScriptedTransport,
        gate: GitExecGate = GitExecGate(),
        clock: ChangesManualSleeper,
        feed: StatusFeed,
        world: World = World()
    ) -> Fixture {
        fixture(
            read: { try await transport.readChanges($0) }, gate: gate, clock: clock, feed: feed,
            world: world)
    }

    static func fixture(
        reads: DirectoryReads, clock: ChangesManualSleeper, feed: StatusFeed, world: World
    ) -> Fixture {
        fixture(
            read: { request in try await MainActor.run { try reads.read(request) } },
            clock: clock, feed: feed, world: world)
    }

    static let host = UUID()

    static func agent(pane: String = "w1:p1", directory: String?) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: .idle, workspaceID: "w1", tabID: "w1:t1", paneID: pane,
                cwd: directory ?? "", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil,
            lastOutputSnippet: nil)
    }

    private static func badge(_ store: ChangesStore?) -> ChangesBadge? {
        store.flatMap {
            ChangesBadge(phase: $0.phase, timedOutKeepingContent: $0.timedOutKeepingContent)
        }
    }

    private static func texts(_ store: ChangesStore?) -> String? {
        badge(store).map { "\($0.addedText()) \($0.removedText())" }
    }

    /// Shows the row, lets it settle, and waits for its first read.
    private static func showSettledRow(
        _ fixture: Fixture, clock: ChangesManualSleeper, landing phase: ChangesStore.Phase
    ) async throws -> ChangesStore {
        fixture.rows.rowAppeared(fixture.agent)
        await drain()
        await clock.fireAll()
        let store = try #require(fixture.rows.store(for: fixture.agent))
        await waitUntilSettled(store, phase)
        return store
    }

    /// The Agent finishes a turn and the debounce elapses.
    private static func exitWorking(_ feed: StatusFeed, clock: ChangesManualSleeper) async {
        feed.send(.working)
        feed.send(.done)
        await drain()
        await clock.fireAll()
        await drain()
    }

    @Test func aRowReadsOnceItHasSettledAndNotAgainWithoutATrigger() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesBadgeTests.read(added: 12, removed: 7)
        await transport.scriptChangesReads([.success(read), .success(read)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        fixture.rows.rowAppeared(fixture.agent)
        await Self.drain()
        #expect(await clock.durations == [.milliseconds(300)])
        #expect(await transport.changesReadRequests.isEmpty)
        let store = try #require(fixture.rows.store(for: fixture.agent))
        #expect(Self.badge(store) == nil)

        await clock.fireAll()
        await Self.waitUntilSettled(store, .loaded(read.changes))
        #expect(Self.texts(store) == "+12 \u{2212}7")
        for _ in 0..<5 {
            await Self.drain()
            await clock.fireAll()
        }
        #expect(await transport.changesReadRequests.count == 1)
        #expect(await clock.durations == [.milliseconds(300)])
    }

    @Test func aRowGoneBeforeItSettledReadsWhenItComesBack() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesBadgeTests.read(added: 12, removed: 7)
        await transport.scriptChangesReads([.success(read)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        fixture.rows.rowAppeared(fixture.agent)
        await Self.drain()
        fixture.rows.rowDisappeared(fixture.agent.id)
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.isEmpty)
        let store = try #require(fixture.rows.store(for: fixture.agent))
        #expect(store.phase == .loading)

        fixture.rows.rowAppeared(fixture.agent)
        await Self.waitUntilSettled(store, .loaded(read.changes))
        #expect(await transport.changesReadRequests.count == 1)
    }

    /// A row that showed before its Agent reported a directory has nothing
    /// to read; the directory arriving starts it as an appearance would.
    @Test func aRowShownBeforeItsDirectoryReadsOnceOneArrives() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesBadgeTests.read(added: 12, removed: 7)
        await transport.scriptChangesReads([.success(read)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let fixture = Self.fixture(
            read: { try await transport.readChanges($0) }, clock: clock, feed: feed,
            directory: nil)
        defer { fixture.rows.retain { _ in false } }
        fixture.rows.rowAppeared(fixture.agent)
        #expect(fixture.rows.store(for: fixture.agent) == nil)

        let located = Self.agent(directory: Self.trackingDirectory)
        fixture.rows.agentReportedDirectory(located)
        await Self.drain()
        await clock.fireAll()
        let store = try #require(fixture.rows.store(for: located))
        await Self.waitUntilSettled(store, .loaded(read.changes))
        // Reported again, it keeps the one following.
        fixture.rows.agentReportedDirectory(located)
        await Self.drain()
        #expect(await clock.durations == [.milliseconds(300)])
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func leavingWorkingRereadsTheRowThroughTheHostGate() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        let third = try ChangesBadgeTests.read(added: 2, removed: 0)
        await transport.scriptChangesReads([.success(first), .success(second), .success(third)])
        let gate = GitExecGate()
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, gate: gate, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(first.changes))

        // Another git exec on this Host, such as open Changes, holds the gate.
        let other = ScriptedTransportCallGate()
        let holder = Task { try await gate.run { await other.waitUntilOpen() } }
        await other.waitForEntry()
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 1)
        // A second exit while that read waits merges into one follow-up.
        await Self.exitWorking(feed, clock: clock)
        #expect(await transport.changesReadRequests.count == 1)
        #expect(Self.texts(store) == "+12 \u{2212}7")

        await other.open()
        try await holder.value
        await Self.waitUntilSettled(store, .loaded(third.changes))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)
        #expect(Self.texts(store) == "+2 \u{2212}0")
    }

    /// With nothing on screen showing the Agent, as on iPhone while another
    /// tab shows, an exit from Working costs the Host nothing until a row
    /// comes back.
    @Test func anExitWhileNoRowShowsTheAgentReadsWhenARowReturns() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([.success(first), .success(second)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(first.changes))

        fixture.rows.rowDisappeared(fixture.agent.id)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.exitWorking(feed, clock: clock)
        #expect(await transport.changesReadRequests.count == 1)

        fixture.rows.rowAppeared(fixture.agent)
        await Self.waitUntilSettled(store, .loaded(second.changes))
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
    }

    /// Two windows' rows share one store: one read, and the Agent stays on
    /// screen until the last row goes.
    @Test func rowsInTwoWindowsShareOneStore() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([.success(first), .success(second)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        fixture.rows.rowAppeared(fixture.agent)
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(first.changes))
        #expect(await transport.changesReadRequests.count == 1)

        fixture.rows.rowDisappeared(fixture.agent.id)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(store, .loaded(second.changes))
        #expect(await transport.changesReadRequests.count == 2)
        #expect(fixture.rows.store(for: fixture.agent) === store)
    }

    /// Agent detail's status line shows the row's totals just before the
    /// Host's latency, past a hairline, at that line's size, and counts as a row while it
    /// shows: with no list row on screen, as on iPhone, an exit from Working
    /// still rereads, and stops once the line goes.
    @Test func theDetailStatusLineShowsTheTotalsAndCountsAsARow() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([.success(first), .success(second)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        let controller = UIHostingController(
            rootView: AnyView(
                AgentDetailStatusChrome(
                    status: .idle,
                    hostTelemetry: HostTelemetryPresentation(
                        status: .connected, latency: .milliseconds(12)),
                    changes: AgentDetailChanges(rows: fixture.rows, agent: fixture.agent),
                    chromeColorScheme: .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 80), rootViewController: controller)
        defer { window.isHidden = true }
        // The line appears on a later hosting pass; its row then settles.
        for _ in 0..<100 {
            if await !clock.durations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await clock.durations == [.milliseconds(300)])
        await Self.drain()
        await clock.fireAll()
        let store = try #require(fixture.rows.store(for: fixture.agent))
        await Self.waitUntilSettled(store, .loaded(first.changes))

        let root: UIView = controller.view
        let totals = try #require(await Self.frame(
            labeled: "Changes: 12 lines added, 7 lines removed", in: root))
        let latency = try #require(AccessibilityProbe.frame(
            labeled: "Host API connection latency", in: root))
        #expect(abs(totals.midY - latency.midY) <= 1, "\(totals) and \(latency) sit on different lines")
        #expect(abs(totals.height - latency.height) <= 1, "\(totals) and \(latency) differ in size")
        #expect(totals.maxX <= latency.minX, "\(totals) overlaps \(latency)")
        // Two spacings and the hairline between them.
        #expect(latency.minX - totals.maxX <= 11.5, "\(totals) sits apart from \(latency)")
        // Tide's git item follows the Agent status, on the same line.
        let git = try #require(AccessibilityProbe.frame(labeled: "Git", in: root))
        let status = try #require(AccessibilityProbe.frame(labeled: "Agent status", in: root))
        #expect(abs(git.midY - totals.midY) <= 1, "\(git) and \(totals) sit on different lines")
        #expect(git.minX >= status.maxX, "\(git) overlaps \(status)")
        #expect(git.maxX <= totals.minX, "\(git) overlaps \(totals)")

        await Self.exitWorking(feed, clock: clock)
        await Self.waitUntilSettled(store, .loaded(second.changes))
        #expect(await transport.changesReadRequests.count == 2)

        controller.rootView = AnyView(EmptyView())
        controller.view.layoutIfNeeded()
        await Self.drain()
        await Self.exitWorking(feed, clock: clock)
        #expect(await transport.changesReadRequests.count == 2)
    }

    /// On a narrow iPhone, a long branch shortens so the whole line fits:
    /// the status, Tide's counts, the totals, and the latency stay whole.
    @Test func aLongBranchGivesWayOnANarrowStatusLine() async throws {
        var changes = TideGitItemTests.changes(
            branch: .named("feature/checkout-retry-keeps-the-cart"),
            files: (0..<27).map { TideGitItemTests.file("f\($0).swift", staging: .both) },
            untracked: 9, upstream: .tracking(ahead: 12, behind: 3))
        changes.totals.added = 1_234
        changes.totals.removed = 567
        let read = CheckoutChangesRead(changes: changes, directoryPrefix: Data())
        let clock = ChangesManualSleeper()
        let store = ChangesStore(
            directory: { Self.trackingDirectory }, read: { _ in read },
            sleep: { try await clock.sleep($0) })
        await store.refresh()
        let rows = AgentRowChanges { _ in store }
        defer { rows.retain { _ in false } }
        let width: CGFloat = 375
        let controller = UIHostingController(
            rootView: AnyView(
                AgentDetailStatusChrome(
                    status: .working,
                    hostTelemetry: HostTelemetryPresentation(
                        status: .connected, latency: .milliseconds(120)),
                    changes: AgentDetailChanges(
                        rows: rows, agent: Self.agent(directory: Self.trackingDirectory)),
                    chromeColorScheme: .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 80), rootViewController: controller)
        defer { window.isHidden = true }

        let root: UIView = controller.view
        let totals = try #require(await Self.frame(
            labeled: "Changes: 1,234 lines added, 567 lines removed", in: root))
        let frames = [
            try #require(AccessibilityProbe.frame(labeled: "Agent status", in: root)),
            try #require(AccessibilityProbe.frame(labeled: "Git", in: root)),
            totals,
            try #require(AccessibilityProbe.frame(labeled: "Host API connection latency", in: root)),
        ]
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "\(left) overlaps \(right)")
            #expect(abs(left.midY - right.midY) <= 1, "\(left) and \(right) sit on different lines")
        }
        #expect(frames[0].minX >= 0 && frames[3].maxX <= width + 0.5)
        // Exact totals still fit beside the shortened branch.
        let element = try #require(AccessibilityProbe.elements(
            labeled: "Changes: 1,234 lines added, 567 lines removed", in: root).first)
        #expect(AgentCardChangesTotalsTests.identifier(of: element) == "agent-status-changes.exact")
    }

    /// The git item and the totals open Changes, each as its own button;
    /// the status and the latency do not.
    @Test func theStatusLineOpensChanges() async throws {
        var changes = TideGitItemTests.changes(
            branch: .named("main"),
            files: [TideGitItemTests.file("a.swift", staging: .unstaged)],
            untracked: 0, upstream: nil)
        changes.totals.added = 12
        changes.totals.removed = 7
        let read = CheckoutChangesRead(changes: changes, directoryPrefix: Data())
        let clock = ChangesManualSleeper()
        let store = ChangesStore(
            directory: { Self.trackingDirectory }, read: { _ in read },
            sleep: { try await clock.sleep($0) })
        await store.refresh()
        let rows = AgentRowChanges { _ in store }
        defer { rows.retain { _ in false } }
        var opened = 0
        let controller = UIHostingController(
            rootView: AnyView(
                AgentDetailStatusChrome(
                    status: .idle,
                    hostTelemetry: HostTelemetryPresentation(
                        status: .connected, latency: .milliseconds(12)),
                    changes: AgentDetailChanges(
                        rows: rows, agent: Self.agent(directory: Self.trackingDirectory),
                        open: { opened += 1 }),
                    chromeColorScheme: .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 80), rootViewController: controller)
        defer { window.isHidden = true }

        let root: UIView = controller.view
        _ = try #require(await Self.frame(
            labeled: "Changes: 12 lines added, 7 lines removed", in: root))
        for label in ["Git", "Changes: 12 lines added, 7 lines removed"] {
            let element = try #require(AccessibilityProbe.elements(labeled: label, in: root).first)
            #expect(element.accessibilityTraits.contains(.button), "\(label) is not a button")
            #expect(element.accessibilityActivate(), "\(label) did not activate")
        }
        #expect(opened == 2)
        for label in ["Agent status", "Host API connection latency"] {
            let element = try #require(AccessibilityProbe.elements(labeled: label, in: root).first)
            #expect(!element.accessibilityTraits.contains(.button), "\(label) is a button")
        }
    }

    /// The totals publish after the read settles; the hosted line lays
    /// them out on its next pass.
    private static func frame(labeled label: String, in root: UIView) async -> CGRect? {
        for _ in 0..<50 {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            if let frame = AccessibilityProbe.frame(labeled: label, in: root) { return frame }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func aTimedOutRefreshHidesTheTotalsAndTheNextSuccessRestoresThem() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesBadgeTests.read(added: 12, removed: 7)
        await transport.scriptChangesReads([
            .success(read), .failure(TransportError.gitTimedOut), .success(read),
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(read.changes))
        #expect(Self.badge(store) != nil)

        await Self.exitWorking(feed, clock: clock)
        await Self.waitUntil { store.timedOutKeepingContent && store.activeRead == nil }
        #expect(Self.badge(store) == nil)
        await Self.exitWorking(feed, clock: clock)
        await Self.waitUntil { !store.timedOutKeepingContent && store.activeRead == nil }
        #expect(Self.texts(store) == "+12 \u{2212}7")
    }

    /// The row's reads never announce; VoiceOver reads the totals with the
    /// row. Open Changes still say when an exit from Working changed them.
    @Test func onlyOpenChangesAnnounceAnAutomaticUpdate() async throws {
        let transport = ScriptedTransport()
        // One Checkout throughout, so the open Changes read in the row's place.
        let dirty = try ChangesBadgeTests.read(added: 12, removed: 7)
        let clean = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([
            .success(dirty), .success(clean), .success(clean), .success(dirty),
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(dirty.changes))

        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(store, .loaded(clean.changes))
        #expect(world.announcements.isEmpty)

        fixture.changes.open()
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        #expect(shown.phase == .loaded(clean.changes))
        await Self.exitWorking(feed, clock: clock)
        await Self.waitUntilSettled(shown, .loaded(dirty.changes))
        #expect(world.announcements == ["Checkout Changes updated."])
        fixture.changes.close()
        shown.cancel()
    }

    /// The Agent's own Changes open on the row's read while reading again,
    /// and Back hands that newer read to the row.
    @Test func theAgentsChangesOpenOnTheRowsReadAndHandTheirsBack() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([.success(first), .success(second)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(first.changes))

        let hold = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: hold)
        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open()
        let shown = try #require(fixture.changes.store)
        #expect(shown !== store)
        #expect(shown.phase == .loaded(first.changes))
        let appearing = Task { await shown.appear() }
        await hold.waitForEntry()
        #expect(shown.isRefreshing)
        await hold.open()
        await appearing.value
        #expect(shown.phase == .loaded(second.changes))

        fixture.changes.close()
        shown.cancel()
        #expect(fixture.changes.store == nil)
        #expect(Self.texts(store) == "+1 \u{2212}1")
        #expect(store.readAt == Date(timeIntervalSince1970: 2_000))
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 2)
    }

    /// Worktree Changes, which may show another Checkout, start empty.
    @Test func worktreeChangesStartFromTheirOwnRead() async throws {
        let transport = ScriptedTransport()
        let read = try ChangesBadgeTests.read(added: 12, removed: 7)
        await transport.scriptChangesReads([.success(read)])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        _ = try await Self.showSettledRow(fixture, clock: clock, landing: .loaded(read.changes))
        fixture.changes.open(directory: "/home/dev/src/wt")
        #expect(fixture.changes.store?.phase == .loading)
        fixture.changes.close()
    }

    /// Open Changes of the Checkout the row reads follow the same Agent, so
    /// an exit from Working reads that Checkout once, in the open Changes,
    /// and Back hands that read over without the row reading again.
    @Test(arguments: [nil, "/home/dev/src/tracking"])
    func openChangesOfTheRowsCheckoutReadOncePerWorkingExit(worktree: String?) async throws {
        let transport = ScriptedTransport()
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let opened = try ChangesBadgeTests.read(added: 15, removed: 9)
        let exited = try ChangesBadgeTests.read(added: 2, removed: 0)
        let spare = try ChangesBadgeTests.read(added: 3, removed: 3)
        await transport.scriptChangesReads([
            .success(rowRead), .success(opened), .success(exited), .success(spare),
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open(directory: worktree)
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        #expect(shown.phase == .loaded(opened.changes))
        let following = Task { await shown.followAgentStatus() }
        await Self.drain()

        world.now = Date(timeIntervalSince1970: 3_000)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(shown, .loaded(exited.changes))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)
        #expect(Self.texts(store) == "+12 \u{2212}7")

        fixture.changes.close()
        following.cancel()
        shown.cancel()
        #expect(Self.texts(store) == "+2 \u{2212}0")
        #expect(store.readAt == Date(timeIntervalSince1970: 3_000))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)
        #expect(store.activeRead == nil)
    }

    /// Back before open Changes answered an exit from Working leaves the
    /// row's Checkout unread since that exit, so the row reads it.
    @Test func backBeforeOpenChangesAnswerAnExitRereadsTheRow() async throws {
        let transport = ScriptedTransport()
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let opened = try ChangesBadgeTests.read(added: 15, removed: 9)
        let unanswered = try ChangesBadgeTests.read(added: 1, removed: 1)
        let refreshed = try ChangesBadgeTests.read(added: 2, removed: 0)
        await transport.scriptChangesReads([
            .success(rowRead), .success(opened), .success(unanswered), .success(refreshed),
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        fixture.changes.open()
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        let following = Task { await shown.followAgentStatus() }
        await Self.drain()

        let hold = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: hold)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await hold.waitForEntry()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 3)

        // Back, and the view's teardown cancels the open Changes' read.
        fixture.changes.close()
        following.cancel()
        shown.cancel()
        await hold.open()
        await Self.waitUntilSettled(store, .loaded(refreshed.changes))
        #expect(await transport.changesReadRequests.count == 4)
        #expect(Self.texts(store) == "+2 \u{2212}0")
    }

    /// Worktree Changes of another Checkout never stand in for the row, and
    /// their read is not the row's to take.
    @Test func worktreeChangesOfAnotherCheckoutLeaveTheRowReading() async throws {
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let exited = try ChangesBadgeTests.read(added: 2, removed: 0)
        let elsewhere = try ChangesStoreTests.read(GitProbeRecordings.worktree)
        let reads = DirectoryReads([
            Self.trackingDirectory: [rowRead, exited],
            Self.otherCheckoutDirectory: [elsewhere],
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(reads: reads, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open(directory: Self.otherCheckoutDirectory)
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        #expect(shown.phase == .loaded(elsewhere.changes))
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(store, .loaded(exited.changes))
        await Self.waitUntil { shown.activeRead == nil }

        fixture.changes.close()
        shown.cancel()
        #expect(store.phase == .loaded(exited.changes))
        // Each read its own Checkout for the exit.
        #expect(reads.requests.filter { $0 == Self.trackingDirectory }.count == 2)
        #expect(reads.requests.filter { $0 == Self.otherCheckoutDirectory }.count == 2)
    }

    /// An Agent in a repository nested inside a Worktree lies under that
    /// Worktree's path but not in its Checkout: the Worktree's Changes
    /// neither stand in for the row nor hand it their read.
    @Test func worktreeChangesAroundANestedRepositoryLeaveTheRowItsOwn() async throws {
        let nested = Self.trackingDirectory + "/vendor/lib"
        let rowRead = try ChangesStoreTests.read(GitProbeRecordings.worktree)
        let exited = try ChangesStoreTests.read(GitProbeRecordings.worktree)
        let around = try ChangesBadgeTests.read(added: 10, removed: 0)
        #expect(rowRead.changes.checkout != around.changes.checkout)
        let reads = DirectoryReads([
            nested: [rowRead, exited], Self.trackingDirectory: [around, around, around],
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        world.directory = nested
        let fixture = Self.fixture(reads: reads, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open(directory: Self.trackingDirectory)
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        #expect(shown.phase == .loaded(around.changes))
        // The row reads its own Checkout on an exit while they show.
        world.now = Date(timeIntervalSince1970: 3_000)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        await Self.waitUntilSettled(store, .loaded(exited.changes))
        await Self.waitUntil { shown.activeRead == nil }
        #expect(reads.requests.filter { $0 == nested }.count == 2)

        // Back after a newer read of the Worktree keeps the row's own.
        world.now = Date(timeIntervalSince1970: 4_000)
        await shown.refresh()
        #expect(shown.readAt == Date(timeIntervalSince1970: 4_000))
        fixture.changes.close()
        shown.cancel()
        #expect(store.phase == .loaded(exited.changes))
        #expect(store.readAt == Date(timeIntervalSince1970: 3_000))
    }

    /// Open Changes stand in for the row only while the Agent is in their
    /// Checkout. An Agent that moved elsewhere while Working has its row
    /// read where it is now on its exit, and Back keeps that read.
    @Test func anAgentThatLeftTheOpenChangesCheckoutWhileWorkingReadsWhereItIsNow() async throws {
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let opened = try ChangesBadgeTests.read(added: 15, removed: 9)
        let exited = try ChangesBadgeTests.read(added: 2, removed: 0)
        let moved = try ChangesStoreTests.read(GitProbeRecordings.worktree)
        #expect(moved.changes.checkout.topLevel == Data(Self.otherCheckoutDirectory.utf8))
        let reads = DirectoryReads([
            Self.trackingDirectory: [rowRead, opened, exited],
            Self.otherCheckoutDirectory: [moved],
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(reads: reads, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open(directory: Self.trackingDirectory)
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        #expect(shown.phase == .loaded(opened.changes))
        let following = Task { await shown.followAgentStatus() }
        await Self.drain()

        world.directory = Self.otherCheckoutDirectory
        world.now = Date(timeIntervalSince1970: 3_000)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(shown, .loaded(exited.changes))
        await Self.waitUntilSettled(store, .loaded(moved.changes))

        fixture.changes.close()
        following.cancel()
        shown.cancel()
        #expect(store.phase == .loaded(moved.changes))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(reads.requests.count == 4)
        #expect(reads.requests.filter { $0 == Self.otherCheckoutDirectory }.count == 1)
    }

    /// Open Changes answered the exit from Working while the Agent was still
    /// in their Checkout, but the Agent moved before Back: Back does not
    /// hand their read to the row, which reads where the Agent is now.
    @Test func backAfterTheAgentLeftTheOpenChangesCheckoutReadsWhereItIsNow() async throws {
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let opened = try ChangesBadgeTests.read(added: 15, removed: 9)
        let exited = try ChangesBadgeTests.read(added: 2, removed: 0)
        let moved = try ChangesStoreTests.read(GitProbeRecordings.worktree)
        let reads = DirectoryReads([
            Self.trackingDirectory: [rowRead, opened, exited],
            Self.otherCheckoutDirectory: [moved],
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(reads: reads, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open(directory: Self.trackingDirectory)
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        let following = Task { await shown.followAgentStatus() }
        await Self.drain()

        world.now = Date(timeIntervalSince1970: 3_000)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(shown, .loaded(exited.changes))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(reads.requests.count == 3)
        #expect(Self.texts(store) == "+12 \u{2212}7")

        world.directory = Self.otherCheckoutDirectory
        fixture.changes.close()
        following.cancel()
        shown.cancel()
        await Self.waitUntilSettled(store, .loaded(moved.changes))
        #expect(
            reads.requests
                == [
                    Self.trackingDirectory, Self.trackingDirectory, Self.trackingDirectory,
                    Self.otherCheckoutDirectory,
                ])
    }

    /// Agent detail leaving the screen with Changes open, as selecting
    /// another Agent does, hands their read back at once and the row reads
    /// for itself again; detail returning stands them in again.
    @Test func agentDetailLeavingWithChangesOpenHandsTheirReadBack() async throws {
        let transport = ScriptedTransport()
        let rowRead = try ChangesBadgeTests.read(added: 12, removed: 7)
        let opened = try ChangesBadgeTests.read(added: 15, removed: 9)
        let exited = try ChangesBadgeTests.read(added: 2, removed: 0)
        let returned = try ChangesBadgeTests.read(added: 3, removed: 3)
        await transport.scriptChangesReads([
            .success(rowRead), .success(opened), .success(exited), .success(returned),
        ])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.working)
        defer { feed.finish() }
        let world = World()
        let fixture = Self.fixture(transport: transport, clock: clock, feed: feed, world: world)
        defer { fixture.rows.retain { _ in false } }
        let store = try await Self.showSettledRow(
            fixture, clock: clock, landing: .loaded(rowRead.changes))

        world.now = Date(timeIntervalSince1970: 2_000)
        fixture.changes.open()
        let shown = try #require(fixture.changes.store)
        await shown.appear()
        fixture.changes.detailDisappeared()
        // The view's teardown ends the open Changes' following.
        shown.cancel()
        #expect(Self.texts(store) == "+15 \u{2212}9")
        #expect(fixture.changes.store === shown)

        world.now = Date(timeIntervalSince1970: 3_000)
        feed.send(.done)
        await Self.drain()
        await clock.fireAll()
        await Self.waitUntilSettled(store, .loaded(exited.changes))
        #expect(await transport.changesReadRequests.count == 3)

        fixture.changes.detailAppeared()
        let following = Task { await shown.followAgentStatus() }
        await Self.drain()
        world.now = Date(timeIntervalSince1970: 4_000)
        await Self.exitWorking(feed, clock: clock)
        await Self.waitUntilSettled(shown, .loaded(returned.changes))
        #expect(store.phase == .loaded(exited.changes))
        fixture.changes.close()
        following.cancel()
        #expect(store.phase == .loaded(returned.changes))
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 4)
    }

    /// An Agent leaving the catalog drops a read still queued at the Host
    /// gate, but a read git is already running keeps the gate until it
    /// answers, so exiting Agents never stack git processes on one Host.
    @Test func anAgentLeavingTheCatalogKeepsARunningReadAndDropsAQueuedOne() async throws {
        let transport = ScriptedTransport()
        let first = try ChangesBadgeTests.read(added: 12, removed: 7)
        let second = try ChangesBadgeTests.read(added: 1, removed: 1)
        await transport.scriptChangesReads([.success(first), .success(second)])
        let hold = ScriptedTransportCallGate()
        await transport.gateNextChangesRead(using: hold)
        let gate = GitExecGate()
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        let a = Self.fixture(transport: transport, gate: gate, clock: clock, feed: feed)
        let b = Self.fixture(transport: transport, gate: gate, clock: clock, feed: feed)
        defer {
            a.rows.retain { _ in false }
            b.rows.retain { _ in false }
        }
        a.rows.rowAppeared(a.agent)
        await Self.drain()
        await clock.fireAll()
        await hold.waitForEntry()
        let aStore = try #require(a.rows.store(for: a.agent))
        a.rows.retain { _ in false }

        b.rows.rowAppeared(b.agent)
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        let bStore = try #require(b.rows.store(for: b.agent))
        #expect(await transport.changesReadRequests.count == 1)
        b.rows.retain { _ in false }
        await Self.drain()

        await hold.open()
        await Self.waitUntilSettled(aStore, .loaded(first.changes))
        await Self.drain()
        #expect(await transport.changesReadRequests.count == 1)
        #expect(bStore.phase == .loading)

        // Back in the catalog, the Agent reads afresh.
        b.rows.rowDisappeared(b.agent.id)
        b.rows.rowAppeared(b.agent)
        await Self.drain()
        await clock.fireAll()
        let fresh = try #require(b.rows.store(for: b.agent))
        #expect(fresh !== bStore)
        await Self.waitUntilSettled(fresh, .loaded(second.changes))
        #expect(await transport.changesReadRequests.count == 2)
    }

    @Test func theListsReadsEndWhenItGoesAway() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(try ChangesBadgeTests.read(added: 12, removed: 7))])
        let clock = ChangesManualSleeper()
        let feed = StatusFeed(.idle)
        defer { feed.finish() }
        var fixture: Fixture? = Self.fixture(transport: transport, clock: clock, feed: feed)
        if let fixture { fixture.rows.rowAppeared(fixture.agent) }
        weak let weakStore = fixture.flatMap { $0.rows.store(for: $0.agent) }
        await Self.drain()
        #expect(weakStore != nil)
        fixture = nil
        await Self.drain()
        await clock.fireAll()
        await Self.drain()
        #expect(weakStore == nil)
        #expect(await transport.changesReadRequests.isEmpty)
    }

    static func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// The document is published inside the Host gate, a hop before the
    /// read ends; the next read can start only once it has.
    static func waitUntilSettled(
        _ store: ChangesStore, _ phase: ChangesStore.Phase,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<2_000 {
            if store.phase == phase, store.activeRead == nil { return }
            await Task.yield()
        }
        #expect(
            store.phase == phase && store.activeRead == nil,
            "settled at \(store.phase), reading: \(store.activeRead != nil)",
            sourceLocation: sourceLocation)
    }

    static func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}

/// Hosted accessibility lookups for the list row tests: every
/// visible element with a label, and where it sits.
@MainActor
enum AccessibilityProbe {
    static func elements(labeled label: String, in root: UIView) -> [NSObject] {
        root.layoutIfNeeded()
        var visited = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                !node.accessibilityElementsHidden
            else { return }
            if node.accessibilityLabel == label, frame(of: node, in: root).width > 0 {
                found.append(node)
            }
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return found
    }

    static func frame(of node: NSObject, in root: UIView) -> CGRect {
        if let view = node as? UIView {
            return view.convert(view.bounds, to: root)
        }
        return root.convert(node.accessibilityFrame, from: nil)
    }

    /// Every visible element's label, including rows that combine their
    /// children into one.
    static func labels(in root: UIView) -> [String] {
        root.layoutIfNeeded()
        var visited = Set<ObjectIdentifier>()
        var found: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                !node.accessibilityElementsHidden
            else { return }
            if let label = node.accessibilityLabel, !label.isEmpty { found.append(label) }
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return found
    }

    static func frame(labeled label: String, in root: UIView) -> CGRect? {
        elements(labeled: label, in: root).first.map { frame(of: $0, in: root) }
    }
}

/// The totals as an Agents list card lays them out.
@MainActor
@Suite("Agent card Changes totals", .timeLimit(.minutes(1)))
struct AgentCardChangesTotalsTests {
    private static let agent = ConsoleAgent(
        hostID: UUID(),
        hostName: "devbox",
        agent: Agent(
            terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
            status: .idle, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
            cwd: "/work/proj", revision: 3),
        workspaceLabel: "proj",
        repositoryCheckout: nil)

    private static func store(added: Int, removed: Int) async throws -> ChangesStore {
        let read = try ChangesBadgeTests.read(added: added, removed: removed)
        let store = ChangesStore(directory: { "/home/dev/src/tracking" }) { _ in read }
        await store.refresh()
        return store
    }

    private static func host(
        _ store: ChangesStore?, width: CGFloat, layout: AgentRowLayout = .heelerDefault
    ) async throws -> (UIHostingController<AnyView>, UIWindow) {
        let controller = UIHostingController(
            rootView: AnyView(
                AgentCardView(agent: agent, layout: layout, changes: store)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 400), rootViewController: controller)
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    static func identifier(of node: NSObject) -> String? {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard node.responds(to: getter) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }

    /// Row 1 ends in the status. With one row after it, as here, the totals
    /// end that row just after the Host, on the Host's line.
    @Test func theTotalsFollowTheHostOnItsLine() async throws {
        let store = try await Self.store(added: 12, removed: 7)
        let (controller, window) = try await Self.host(store, width: 402)
        defer { window.isHidden = true }
        let root: UIView = controller.view
        let label = "Changes: 12 lines added, 7 lines removed"
        let totals = try #require(AccessibilityProbe.frame(labeled: label, in: root))
        let host = try #require(AccessibilityProbe.frame(labeled: "devbox", in: root))
        let status = try #require(AccessibilityProbe.frame(labeled: "Idle", in: root))
        #expect(abs(totals.midY - host.midY) <= 1, "\(totals) and \(host) sit on different lines")
        #expect(host.maxX <= totals.minX, "\(totals) overlaps \(host)")
        #expect(totals.minX - host.maxX <= 8.5, "\(totals) sits apart from \(host)")
        #expect(totals.minY >= status.maxY - 0.5, "\(totals) overlaps \(status)")
        let element = try #require(AccessibilityProbe.elements(labeled: label, in: root).first)
        #expect(Self.identifier(of: element) == "agent-row-changes.exact")
    }

    /// SwiftUI can build the card's rows on its async render thread, as it
    /// built the file counts in #471. A row closure isolated to the main
    /// actor traps there, so a regression crashes this test.
    @Test func buildsAdditionalRowsOffTheMainThread() async throws {
        let card = AgentCardView(agent: Self.agent, layout: .consoleDefault)
        let lines = AgentCardLines(
            presentation: AgentCardPresentation(agent: Self.agent, layout: .consoleDefault),
            headingTakesTitle: false, showsHost: true, showsTotals: true).details
        try #require(lines.count > 1)
        let line = UncheckedSendable(value: card.detailLineViews(lines).content)
        let lineElements = Array(lines.enumerated())
        let entries: [AgentCardTrailing] = [.fields([.separator]), .host, .changes]
        let entry = UncheckedSendable(value: card.trailingEntryViews(entries).content)
        let entryElements = Array(entries.enumerated())
        await Task.detached {
            for element in lineElements {
                _ = line.value(element)
            }
            for element in entryElements {
                _ = entry.value(element)
            }
        }.value
    }

    /// A layout that leaves its right side to the list keeps today's
    /// places: the Host ends the first line under the title and the totals
    /// the last, both on a line of their own under a title alone, and
    /// Row 1's line under a heading.
    @Test func theListPlacesTheRightSideNoLayoutChose() {
        let presentation = AgentCardPresentation(agent: Self.agent, layout: .consoleDefault)
        let lines = AgentCardLines(
            presentation: presentation, headingTakesTitle: false, showsHost: true, showsTotals: true)
        #expect(lines.title.isEmpty)
        #expect(lines.details.map(\.leading) == Array(presentation.rows.dropFirst()))
        #expect(lines.details.map(\.trailing) == [[.host], [.changes]])

        let titleOnly = AgentCardPresentation(agent: Self.agent, layout: AgentRowLayout(rows: [[.init(.workspace)]]))
        func details(heading: Bool, host: Bool, totals: Bool) -> [AgentCardLines.Line] {
            AgentCardLines(
                presentation: titleOnly, headingTakesTitle: heading, showsHost: host, showsTotals: totals
            ).details
        }
        #expect(details(heading: false, host: true, totals: true) == [.init(leading: [], trailing: [.host, .changes])])
        #expect(details(heading: false, host: false, totals: true) == [.init(leading: [], trailing: [.changes])])
        #expect(details(heading: false, host: false, totals: false).isEmpty)
        #expect(details(heading: true, host: true, totals: true)
            == [.init(leading: titleOnly.rows[0], trailing: [.host, .changes])])
    }

    /// Each row slot's chosen right side ends its own line: one whose left
    /// side shows nothing still gets a line, and one before the title's slot
    /// joins the title's line.
    @Test func eachRowEndsWithTheRightSideItChose() throws {
        let layout = AgentRowLayout(
            rows: [[], [.init(.workspace)], []],
            trailing: [[.init(.status)], [.init(.host)], [.init(.changes)]])
        let presentation = AgentCardPresentation(agent: Self.agent, layout: layout)
        #expect(presentation.slots == [1])
        let status = try #require(presentation.trailing?[0].first)
        #expect(status == .fields([RenderedToken(token: .status, text: "Idle", fg: nil, bold: nil, dim: nil)]))
        func lines(heading: Bool = false, shows: Bool = true) -> AgentCardLines {
            AgentCardLines(
                presentation: presentation, headingTakesTitle: heading, showsHost: shows, showsTotals: shows)
        }
        #expect(lines().title == [status, .host])
        #expect(lines().details == [.init(leading: [], trailing: [.changes])])
        #expect(lines(shows: false).title == [status])
        #expect(lines(shows: false).details.isEmpty)
        #expect(lines(heading: true).title.isEmpty)
        #expect(lines(heading: true).details == [
            .init(leading: [], trailing: [status]),
            .init(leading: presentation.rows[0], trailing: [.host]),
            .init(leading: [], trailing: [.changes]),
        ])
    }

    /// An Agent field on a right side names the Agent on the card, so rows
    /// sharing a title get no program name for it.
    @Test func anAgentFieldOnTheRightNamesTheAgentOnTheCard() {
        let agent = ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "term_b", kind: "aider", title: "Fix the flaky test",
                status: .idle, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p2",
                cwd: "/work/proj", revision: 3),
            workspaceLabel: "proj", repositoryCheckout: nil)
        let left = AgentRowLayout(rows: [[.init(.workspace)]])
        #expect(!AgentCardPresentation(agent: agent, layout: left, leadsWithMark: true).cardNamesAgent)
        var right = left
        right.trailing = [[.init(.agent)]]
        let presentation = AgentCardPresentation(agent: agent, layout: right, leadsWithMark: true)
        #expect(presentation.cardNamesAgent)
        #expect(!presentation.namesAgent(inFirst: 1))
    }

    /// A saved entry keeps its Host, whose tone stands in for a status,
    /// where its layout's right side leaves the Host out.
    @Test func aSavedEntryKeepsItsHostWhereTheRightSideLeavesItOut() {
        let layout = AgentRowLayout(
            rows: [[.init(.workspace)], [.init(.agent)]], trailing: [[], [], [.init(.changes)]])
        let presentation = AgentCardPresentation(agent: Self.agent, layout: layout)
        let lines = AgentCardLines(
            presentation: presentation, headingTakesTitle: false, showsHost: true, showsTotals: true,
            requiresHost: true)
        #expect(lines.details == [
            .init(leading: presentation.rows[1], trailing: [.host]),
            .init(leading: [], trailing: [.changes]),
        ])
    }

    /// The Host chosen for Row 1's right side ends the title's line, before
    /// the status, and the totals end Row 3's line of their own.
    @Test func aHostOnRowOnesRightSideEndsTheTitlesLine() async throws {
        let store = try await Self.store(added: 12, removed: 7)
        let layout = AgentRowLayout(
            rows: [[.init(.workspace)], [.init(.agent)]], trailing: [[.init(.host)], [], [.init(.changes)]])
        let (controller, window) = try await Self.host(store, width: 402, layout: layout)
        defer { window.isHidden = true }
        let root: UIView = controller.view
        let host = try #require(AccessibilityProbe.frame(labeled: "devbox", in: root))
        let status = try #require(AccessibilityProbe.frame(labeled: "Idle", in: root))
        let totals = try #require(AccessibilityProbe.frame(
            labeled: "Changes: 12 lines added, 7 lines removed", in: root))
        #expect(abs(host.midY - status.midY) <= 2, "\(host) and \(status) sit on different lines")
        #expect(host.maxX <= status.minX, "\(host) overlaps \(status)")
        #expect(totals.minY >= host.maxY - 0.5, "\(totals) does not sit below \(host)")
    }

    /// With more rows, the Host ends the first one after Row 1 and the
    /// totals end the last.
    @Test func theHostEndsTheFirstDetailLineAndTheTotalsTheLast() async throws {
        let store = try await Self.store(added: 12, removed: 7)
        let (controller, window) = try await Self.host(
            store, width: 402, layout: .consoleDefault)
        defer { window.isHidden = true }
        let root: UIView = controller.view
        let totals = try #require(AccessibilityProbe.frame(
            labeled: "Changes: 12 lines added, 7 lines removed", in: root))
        let host = try #require(AccessibilityProbe.frame(labeled: "devbox", in: root))
        let status = try #require(AccessibilityProbe.frame(labeled: "Idle", in: root))
        #expect(host.minY >= status.maxY - 0.5, "\(host) does not sit below \(status)")
        #expect(totals.minY >= host.maxY - 0.5, "\(totals) does not sit below \(host)")
    }

    /// A card too narrow for the exact totals shows the shortened ones, and
    /// VoiceOver still hears them exactly. The narrow card's text is 170
    /// points wide, past its 30-point tile and the 12-point gap.
    @Test(arguments: [(CGFloat(402), "agent-row-changes.exact"), (212, "agent-row-changes.compact")])
    func largeTotalsShortenOnlyWhereTheExactOnesDoNotFit(width: CGFloat, form: String) async throws {
        let store = try await Self.store(added: 1_234_567, removed: 1_234_567)
        let (controller, window) = try await Self.host(store, width: width)
        defer { window.isHidden = true }
        let label = "Changes: 1,234,567 lines added, 1,234,567 lines removed"
        let elements = AccessibilityProbe.elements(labeled: label, in: controller.view)
        #expect(elements.count == 1)
        let element = try #require(elements.first)
        #expect(Self.identifier(of: element) == form)
        let frame = AccessibilityProbe.frame(of: element, in: controller.view)
        #expect(frame.maxX <= width + 0.5)
    }

    /// A Checkout changed without a line delta shows its file count, not
    /// "+0 −0".
    @Test func aCardWithoutALineDeltaCountsFiles() async throws {
        let store = try await Self.store(added: 0, removed: 0)
        let (controller, window) = try await Self.host(store, width: 402)
        defer { window.isHidden = true }
        let labels = AccessibilityProbe.labels(in: controller.view)
        let changes = labels.filter { $0.hasPrefix("Changes") }
        #expect(changes.count == 1, "\(labels)")
        #expect(changes.allSatisfy { !$0.contains("lines") }, "\(changes)")
    }

    /// Nothing to vouch for, nothing shown; a preview card has no store.
    @Test func aCardWithoutTotalsShowsNone() async throws {
        let unread = ChangesStore(directory: { "/home/dev/src/tracking" }) { _ in
            throw ChangesReadError.notAGitWorkingTree
        }
        for store in [nil, unread] {
            let (controller, window) = try await Self.host(store, width: 402)
            defer { window.isHidden = true }
            let labels = AccessibilityProbe.labels(in: controller.view)
            #expect(!labels.contains { $0.hasPrefix("Changes") }, "\(labels)")
            #expect(labels.contains("devbox"))
        }
    }
}

/// Hands a closure SwiftUI never marks Sendable to another thread, as
/// SwiftUI's async renderer does.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
