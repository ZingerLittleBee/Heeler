import Foundation
import SwiftUI
import Synchronization
import Testing
import UIKit

@testable import Heeler

/// The store's notice that a terminal shows at a size another device set
/// (ADR 0052), over a hand-built session whose size reports and take the
/// test drives: when it shows, after the size settles; when it goes and
/// comes back; dismissing it; and how a tap's take ends. Ids are invented.
@MainActor
@Suite("Terminal size notice", .timeLimit(.minutes(1)))
struct TerminalSizeNoticeTests {
    nonisolated static let thisClient = "client:00000000-0000-7000-8000-000000000001"
    nonisolated static let otherDevice = "client:00000000-0000-7000-8000-0000000000aa"
    nonisolated static let thirdDevice = "client:00000000-0000-7000-8000-0000000000bb"
    typealias Grid = TerminalSizeReport.Grid

    /// Opens once, for every waiter so far and after.
    final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    if !state.open { state.waiters.append(continuation) }
                    return state.open
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state in
                state.open = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// The session's side: its reports, its output, and the take and give
    /// backs the store asks of it.
    final class Remote: Sendable {
        let reports: AsyncStream<TerminalSizeReport>
        let reportSink: AsyncStream<TerminalSizeReport>.Continuation
        let output: AsyncThrowingStream<Data, any Error>
        let outputSink: AsyncThrowingStream<Data, any Error>.Continuation
        private let state = Mutex<(takes: Int, viewerLefts: Int)>((0, 0))
        private let outcome = Mutex<TerminalSizeTake>(.taken)
        let takeGate = Gate()

        init() {
            let (reports, reportSink) = AsyncStream.makeStream(
                of: TerminalSizeReport.self, bufferingPolicy: .bufferingNewest(1))
            let (output, outputSink) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            self.reports = reports
            self.reportSink = reportSink
            self.output = output
            self.outputSink = outputSink
        }

        var takes: Int { state.withLock { $0.takes } }
        var viewerLefts: Int { state.withLock { $0.viewerLefts } }

        func answer(_ next: TerminalSizeTake) { outcome.withLock { $0 = next } }

        func report(server: Grid?, local: Grid = Grid(columns: 80, rows: 24), owner: String?) {
            reportSink.yield(
                TerminalSizeReport(server: server, local: local, owner: owner, client: TerminalSizeNoticeTests.thisClient))
        }

        func session(sizes: Bool = true) -> TerminalAttachSession {
            let ownership = TerminalSizeOwnership(
                take: { [self] in
                    state.withLock { $0.takes += 1 }
                    await takeGate.wait()
                    return outcome.withLock { $0 }
                },
                viewerLeft: { [self] in state.withLock { $0.viewerLefts += 1 } })
            return TerminalAttachSession(
                output: { [output] in output }, input: TerminalAttachInputQueue(),
                sizeReports: sizes ? reports : nil, sizeOwnership: sizes ? ownership : nil
            ) { [outputSink] in outputSink.finish() }
        }
    }

    private func store(_ remote: Remote, settle: Gate, sizes: Bool = true) -> AttachTerminalStore {
        let session = remote.session(sizes: sizes)
        return AttachTerminalStore(
            target: .terminal("session:studio/block:left"),
            settleSizeNotice: { await settle.wait() },
            runTerminal: { _, handler in try await handler.runEndingSession(session) })
    }

    private func goLive(_ store: AttachTerminalStore, _ remote: Remote) async throws {
        store.viewDidResize(cols: 80, rows: 24)
        remote.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live") { store.status == .live }
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Lets the store's tasks run, for a check that something did not happen.
    private func settleDown() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    private static let elsewhere = Grid(columns: 100, rows: 30)
    private static let here = Grid(columns: 80, rows: 24)

    // MARK: Showing

    /// A size another device set shows only once it has held for a moment.
    @Test func itWaitsForTheSizeToSettle() async throws {
        let remote = Remote()
        let settle = Gate()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.otherDevice }
        try await settleDown()
        #expect(store.sizeNotice == nil)
        settle.open()
        try await waitUntil("the notice") { store.sizeNotice != nil }
        #expect(store.sizeNotice == TerminalSizeNotice(server: Self.elsewhere, phase: .offered))
        await store.stop()
    }

    /// Nothing to say while nobody owns the block, this client does, or the
    /// sizes agree.
    @Test func itSaysNothingWhileTheSizeIsTheViews() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        for (server, owner) in [
            (Self.elsewhere, nil), (Self.elsewhere, Self.thisClient), (Self.here, Self.otherDevice),
        ] as [(Grid, String?)] {
            remote.report(server: server, owner: owner)
            try await waitUntil("the report") { store.sizeReport?.server == server && store.sizeReport?.owner == owner }
            try await settleDown()
            #expect(store.sizeNotice == nil)
        }
        await store.stop()
    }

    /// The notice sits away from where the output ends, which is where the
    /// prompt and cursor usually are: over the blank rows under a short
    /// screen of output, over the top rows of a full one.
    @Test func itSitsAwayFromWhereTheOutputEnds() {
        let blank = Array(repeating: "", count: 10)
        let short = ["row1", "row2", "$ echo hi", "hi", "$ "] + Array(repeating: "   ", count: 15)
        let full = (1...20).map { "line \($0)" }
        let lowerHalf = Array(repeating: "", count: 10) + ["$ "] + Array(repeating: "", count: 9)
        #expect(TerminalSizeNotice.edge(forViewport: blank.joined(separator: "\n")) == .bottom)
        #expect(TerminalSizeNotice.edge(forViewport: short.joined(separator: "\n")) == .bottom)
        #expect(TerminalSizeNotice.edge(forViewport: full.joined(separator: "\n")) == .top)
        #expect(TerminalSizeNotice.edge(forViewport: lowerHalf.joined(separator: "\n")) == .top)
    }

    /// What one screen hears of its terminal's viewport.
    final class ViewportReports {
        var texts: [String] = []
    }

    /// A screen of a terminal the pool keeps, as a shell terminal's is.
    struct KeptScreen: View {
        let feed: TerminalByteFeed
        let retention: TerminalSurfaceRetention
        let reports: ViewportReports

        var body: some View {
            var screen = TerminalScreenView(feed: feed)
            screen.retention = retention
            screen.onViewportTextChanged = { reports.texts.append($0) }
            return screen
        }
    }

    private func report(
        in reports: ViewportReports, containing marker: String
    ) async throws -> String {
        var budget = PollBudget(.seconds(5))
        while !reports.texts.contains(where: { $0.contains(marker) }), budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        return try #require(
            reports.texts.last { $0.contains(marker) },
            "the screen never heard a viewport showing \(marker)")
    }

    /// A kept terminal shown again shows what it showed, and nothing new may
    /// come for it: the server sends output only when something changes.
    /// Its new screen hears where the output ends all the same, or the notice
    /// starts at the top, over a prompt and cursor in the upper half.
    @Test func aKeptTerminalShownAgainKnowsWhereTheOutputEnds() async throws {
        let feed = TerminalByteFeed()
        let retention = TerminalSurfaceRetention()
        defer { retention.clear() }
        let first = ViewportReports()
        let controller = UIHostingController(
            rootView: AnyView(KeptScreen(feed: feed, retention: retention, reports: first)))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        feed.write(Data("row1\r\nrow2\r\nrow3\r\n$ ".utf8))
        _ = try await report(in: first, containing: "row3")

        // The screen goes, and the pool takes the surface's callbacks back.
        // Output while it is away reaches the surface and no one else.
        controller.rootView = AnyView(Color.clear)
        controller.view.layoutIfNeeded()
        retention.detachCallbacks()
        feed.write(Data("row4\r\nrow5\r\n$ ".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!first.texts.contains { $0.contains("row5") })

        // Shown again, with nothing new from the server.
        let second = ViewportReports()
        controller.rootView = AnyView(KeptScreen(feed: feed, retention: retention, reports: second))
        controller.view.layoutIfNeeded()
        let shown = try await report(in: second, containing: "row5")
        #expect(TerminalSizeNotice.edge(forViewport: shown) == .bottom)
    }

    /// The keyboard, a rotation or a pinch changes the terminal's grid while
    /// a server that keeps its own size sends nothing for it. The screen
    /// hears where the output ends now: here a prompt in the upper half ends
    /// up on the last row once the grid loses rows.
    @Test func aGridChangeWithoutOutputMovesWhereTheOutputEnds() async throws {
        let reports = ViewportReports()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onViewportTextChanged: { reports.texts.append($0) },
            notificationCenter: NotificationCenter())
        terminal.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        try await waitForGhosttyContentLayer(in: terminal)
        terminal.layoutIfNeeded()
        var budget = PollBudget(.seconds(5))
        while terminal.viewportRows == nil, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        let tallRows = try #require(terminal.viewportRows)
        let lines = tallRows / 2 - 2
        try #require(lines > 4, "a grid of \(tallRows) rows is too short for this test")
        terminal.receive(Data(((1...lines).map { "row\($0)\r\n" }.joined() + "$ ").utf8))
        let before = try await report(in: reports, containing: "row\(lines)")
        #expect(TerminalSizeNotice.edge(forViewport: before) == .bottom)
        reports.texts.removeAll()

        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874 * 0.3)
        window.layoutIfNeeded()
        let after = try await report(in: reports, containing: "row\(lines)")
        #expect((terminal.viewportRows ?? tallRows) <= lines)
        #expect(TerminalSizeNotice.edge(forViewport: after) == .top)
    }

    /// The notice goes as soon as the sizes agree or this client sets the
    /// size, and comes back when another device takes it again.
    @Test func itGoesAndComesBackWithTheSize() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice") { store.sizeNotice != nil }
        remote.report(server: Self.here, owner: Self.otherDevice)
        try await waitUntil("the notice to go") { store.sizeNotice == nil }

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice again") { store.sizeNotice != nil }
        remote.report(server: Self.elsewhere, owner: Self.thisClient)
        try await waitUntil("the notice to go") { store.sizeNotice == nil }

        remote.report(server: Self.elsewhere, owner: Self.thirdDevice)
        try await waitUntil("the notice for another device") { store.sizeNotice != nil }
        #expect(store.sizeNotice?.phase == .offered)
        await store.stop()
    }

    /// Dismissed, it stays away while the same device sets the size, and
    /// comes back once another one takes it.
    @Test func dismissingKeepsItAwayUntilAnotherDeviceTakesTheSize() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice") { store.sizeNotice != nil }
        store.dismissSizeNotice()
        #expect(store.sizeNotice == nil)
        remote.report(server: Grid(columns: 120, rows: 40), owner: Self.otherDevice)
        try await waitUntil("the report") { store.sizeReport?.server?.columns == 120 }
        try await settleDown()
        #expect(store.sizeNotice == nil)

        remote.report(server: Self.elsewhere, owner: Self.thirdDevice)
        try await waitUntil("the notice for another device") { store.sizeNotice != nil }
        #expect(remote.takes == 0)
        await store.stop()
    }

    /// The notice goes with the session, and never shows for one that is
    /// not live.
    @Test func itGoesWithTheSession() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        store.viewDidResize(cols: 80, rows: 24)
        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await settleDown()
        #expect(store.sizeNotice == nil)

        remote.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("the notice once live") { store.sizeNotice != nil }
        remote.outputSink.finish()
        try await waitUntil("the end") { store.status != .live }
        #expect(store.sizeNotice == nil)
    }

    // MARK: Taking

    /// A tap takes the size once, shows that it is at it, and says how a
    /// take that did not go through ended; one that did needs no notice.
    @Test(arguments: [TerminalSizeTake.taken, .refused, .notSent, .unknown])
    func aTapTakesTheSizeOnce(_ outcome: TerminalSizeTake) async throws {
        let remote = Remote()
        remote.answer(outcome)
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)
        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice") { store.sizeNotice != nil }

        store.takeSize()
        #expect(store.sizeNotice?.phase == .taking)
        store.takeSize()
        try await waitUntil("the take") { remote.takes == 1 }
        remote.takeGate.open()
        if let failure = AttachTerminalStore.sizeTakeFailure(outcome) {
            try await waitUntil("the failure") { store.sizeNotice?.phase == .failed(failure) }
        } else {
            try await waitUntil("the notice to go") { store.sizeNotice == nil }
        }
        try await settleDown()
        #expect(remote.takes == 1)
        await store.stop()
    }

    @Test func eachFailureHasItsOwnWords() {
        let failures = [TerminalSizeTake.refused, .notSent, .unknown].compactMap(AttachTerminalStore.sizeTakeFailure)
        #expect(Set(failures).count == 3)
        #expect(AttachTerminalStore.sizeTakeFailure(.taken) == nil)
    }

    // MARK: Giving back

    /// Leaving the view or the scene going to the background tells the
    /// session; coming back asks for nothing.
    @Test func leavingTellsTheSessionAndComingBackTakesNothing() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        store.setViewed(false)
        #expect(remote.viewerLefts == 1)
        store.setViewed(true)
        store.didBecomeActive()
        store.sceneDidEnterBackground()
        #expect(remote.viewerLefts == 2)
        try await settleDown()
        #expect(remote.takes == 0)
        await store.stop()
    }

    /// A Server Kind that sizes to the view has nothing to say or take.
    @Test func aServerThatSizesToTheViewHasNoNotice() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle, sizes: false)
        try await goLive(store, remote)

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await settleDown()
        #expect(store.sizeNotice == nil)
        store.takeSize()
        store.setViewed(false)
        store.sceneDidEnterBackground()
        #expect(remote.takes == 0 && remote.viewerLefts == 0)
        await store.stop()
    }
}
