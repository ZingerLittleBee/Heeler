import Foundation
import Synchronization
import Testing

@testable import Heeler

/// The store's notice that a terminal shows at a size another device set,
/// and the size a shown terminal takes on its own (ADR 0053), over
/// hand-built sessions whose size reports and takes the test drives: when
/// the notice shows, after the size settles; when it goes and comes back;
/// dismissing it; how a tap's take ends; and which showings take the size,
/// once each, without a tap. Ids are invented.
@MainActor
@Suite("Terminal size notice", .timeLimit(.minutes(1)))
struct TerminalSizeNoticeTests {
    nonisolated static let thisClient = "client:00000000-0000-7000-8000-000000000001"
    nonisolated static let otherDevice = "client:00000000-0000-7000-8000-0000000000aa"
    nonisolated static let thirdDevice = "client:00000000-0000-7000-8000-0000000000bb"
    typealias Grid = TerminalSizeReport.Grid

    /// Opens once, for every waiter so far and after.
    final class Gate: Sendable {
        private let state: Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>

        init(open: Bool = false) {
            state = Mutex((open, []))
        }

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

    /// One attach's side: its reports, its output, and the takes and give
    /// backs the store asks of it. A tap's take waits for `takeGate`; a take
    /// made on its own, for an open session or as the attach opened, waits
    /// for `fitGate`, open unless the test closes it.
    final class Remote: Sendable {
        struct Counts {
            var takes = 0
            var fits = 0
            var viewerLefts = 0
        }

        struct Outcomes {
            var take = TerminalSizeTake.taken
            var fit = TerminalSizeTake.taken
            /// How the take the attach made as it opened ended; nil when it
            /// made none.
            var opening: TerminalSizeTake?
        }

        let reports: AsyncStream<TerminalSizeReport>
        let reportSink: AsyncStream<TerminalSizeReport>.Continuation
        let output: AsyncThrowingStream<Data, any Error>
        let outputSink: AsyncThrowingStream<Data, any Error>.Continuation
        private let counts = Mutex(Counts())
        private let outcomes = Mutex(Outcomes())
        let takeGate = Gate()
        let fitGate: Gate

        init(fitsAtOnce: Bool = true) {
            let (reports, reportSink) = AsyncStream.makeStream(
                of: TerminalSizeReport.self, bufferingPolicy: .bufferingNewest(1))
            let (output, outputSink) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            self.reports = reports
            self.reportSink = reportSink
            self.output = output
            self.outputSink = outputSink
            fitGate = Gate(open: fitsAtOnce)
        }

        var takes: Int { counts.withLock { $0.takes } }
        var fits: Int { counts.withLock { $0.fits } }
        var viewerLefts: Int { counts.withLock { $0.viewerLefts } }

        func answer(_ next: TerminalSizeTake) { outcomes.withLock { $0.take = next } }
        func answerFit(_ next: TerminalSizeTake) { outcomes.withLock { $0.fit = next } }
        func openedTaking(_ outcome: TerminalSizeTake) { outcomes.withLock { $0.opening = outcome } }

        func report(
            server: Grid?, local: Grid = Grid(columns: 80, rows: 24), owner: String?, takenAway: Int = 0
        ) {
            var report = TerminalSizeReport(
                server: server, local: local, owner: owner, client: TerminalSizeNoticeTests.thisClient)
            report.takenAway = takenAway
            reportSink.yield(report)
        }

        func session(sizes: Bool = true) -> TerminalAttachSession {
            let ownership = TerminalSizeOwnership(
                take: { [self] in
                    counts.withLock { $0.takes += 1 }
                    await takeGate.wait()
                    return outcomes.withLock { $0.take }
                },
                fit: { [self] in
                    counts.withLock { $0.fits += 1 }
                    await fitGate.wait()
                    return outcomes.withLock { $0.fit }
                },
                opened: { [self] in
                    guard let opening = outcomes.withLock({ $0.opening }) else { return nil }
                    await fitGate.wait()
                    return opening
                },
                viewerLeft: { [self] in counts.withLock { $0.viewerLefts += 1 } })
            return TerminalAttachSession(
                output: { [output] in output }, input: TerminalAttachInputQueue(),
                sizeReports: sizes ? reports : nil, sizeOwnership: sizes ? ownership : nil
            ) { [outputSink] in outputSink.finish() }
        }
    }

    /// The attaches a store opens, one remote each in turn, and what its
    /// runner heard when it asked whether an attach takes the size as it
    /// opens, as a Rex runner asks. One that does not ask, as no other
    /// Server Kind's does, hears nothing.
    final class Runs: Sendable {
        let remotes: [Remote]
        let asksOnOpen: Bool
        /// The runner waits here after it asks, before the attach opens.
        let opening: Gate
        private let state = Mutex<(next: Int, heard: [Bool])>((0, []))

        init(_ remotes: [Remote], asksOnOpen: Bool, opensAtOnce: Bool) {
            self.remotes = remotes
            self.asksOnOpen = asksOnOpen
            opening = Gate(open: opensAtOnce)
        }

        var heard: [Bool] { state.withLock { $0.heard } }

        func run(_ handler: TerminalSessionHandler, sizes: Bool) async throws {
            let remote = state.withLock { state in
                defer { state.next += 1 }
                return remotes[min(state.next, remotes.count - 1)]
            }
            if asksOnOpen {
                let fits = await handler.takesSizeOnOpen()
                state.withLock { $0.heard.append(fits) }
            }
            await opening.wait()
            try await handler.runEndingSession(remote.session(sizes: sizes))
        }
    }

    private func store(
        _ remote: Remote, settle: Gate, sizes: Bool = true, viewed: Bool = true
    ) -> AttachTerminalStore {
        store(Runs([remote], asksOnOpen: false, opensAtOnce: true), settle: settle, sizes: sizes, viewed: viewed)
    }

    private func store(
        _ runs: Runs, settle: Gate, sizes: Bool = true, viewed: Bool = true
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: .terminal("session:studio/block:left"), isViewed: viewed,
            settleSizeNotice: { await settle.wait() },
            runTerminal: { _, handler in try await runs.run(handler, sizes: sizes) })
    }

    private func goLive(_ store: AttachTerminalStore, _ remote: Remote) async throws {
        store.viewDidResize(cols: 80, rows: 24)
        remote.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live") { store.status == .live }
    }

    /// Ends the remote's attach from its side and opens the next one, in
    /// the same showing.
    private func reattach(_ store: AttachTerminalStore, from remote: Remote, to next: Remote) async throws {
        remote.outputSink.finish()
        try await waitUntil("the end") {
            if case .ended = store.status { return true }
            return false
        }
        store.retry()
        next.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live again") { store.status == .live }
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

        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
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

    /// The notice goes as soon as the sizes agree or this client sets the
    /// size, and comes back when another device takes it again.
    @Test func itGoesAndComesBackWithTheSize() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)

        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice") { store.sizeNotice != nil }
        remote.report(server: Self.here, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice to go") { store.sizeNotice == nil }

        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice again") { store.sizeNotice != nil }
        remote.report(server: Self.elsewhere, owner: Self.thisClient, takenAway: 1)
        try await waitUntil("the notice to go") { store.sizeNotice == nil }

        remote.report(server: Self.elsewhere, owner: Self.thirdDevice, takenAway: 2)
        try await waitUntil("the notice for another device") { store.sizeNotice != nil }
        #expect(store.sizeNotice?.phase == .offered)
        #expect(remote.fits == 1)
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

        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice") { store.sizeNotice != nil }
        store.dismissSizeNotice()
        #expect(store.sizeNotice == nil)
        remote.report(server: Grid(columns: 120, rows: 40), owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the report") { store.sizeReport?.server?.columns == 120 }
        try await settleDown()
        #expect(store.sizeNotice == nil)

        remote.report(server: Self.elsewhere, owner: Self.thirdDevice, takenAway: 2)
        try await waitUntil("the notice for another device") { store.sizeNotice != nil }
        #expect(remote.takes == 0 && remote.fits == 1)
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
        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
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
        remote.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
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
        #expect(remote.takes == 1 && remote.fits == 1)
        await store.stop()
    }

    @Test func eachFailureHasItsOwnWords() {
        let failures = [TerminalSizeTake.refused, .notSent, .unknown].compactMap(AttachTerminalStore.sizeTakeFailure)
        #expect(Set(failures).count == 3)
        #expect(AttachTerminalStore.sizeTakeFailure(.taken) == nil)
    }

    // MARK: Giving back

    /// Leaving the view or the scene going to the background gives the size
    /// back; coming back is a new showing, which takes it again. The app
    /// coming back alone, with the scene never gone, is no new showing.
    @Test func leavingGivesItBackAndComingBackTakesItAgain() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)
        try await waitUntil("the showing's take") { remote.fits == 1 }

        store.setViewed(false)
        #expect(remote.viewerLefts == 1)
        store.setViewed(true)
        try await waitUntil("the next showing's take") { remote.fits == 2 }
        store.didBecomeActive()
        store.sceneDidBecomeActive()
        store.sceneDidEnterBackground()
        #expect(remote.viewerLefts == 2)
        try await settleDown()
        #expect(remote.fits == 2)
        store.sceneDidBecomeActive()
        try await waitUntil("the take back in the foreground") { remote.fits == 3 }
        try await settleDown()
        #expect(remote.fits == 3 && remote.takes == 0 && remote.viewerLefts == 2)
        await store.stop()
    }

    /// A showing that ends while its attach opens gives back what the attach
    /// took as it opened, as soon as the attach is in hand.
    @Test func aShowingThatEndsAsItOpensGivesBackWhatItTook() async throws {
        let remote = Remote()
        remote.openedTaking(.taken)
        let runs = Runs([remote], asksOnOpen: true, opensAtOnce: false)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the runner's question") { runs.heard == [true] }

        store.setViewed(false)
        runs.opening.open()
        try await waitUntil("the size given back") { remote.viewerLefts == 1 }
        remote.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live") { store.status == .live }
        try await settleDown()
        #expect(remote.fits == 0 && remote.viewerLefts == 1)
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
        store.setViewed(true)
        store.sceneDidEnterBackground()
        store.sceneDidBecomeActive()
        #expect(remote.takes == 0 && remote.fits == 0 && remote.viewerLefts == 0)
        await store.stop()
    }

    // MARK: Shown means fitted

    /// A terminal on screen takes its size once, with no tap and no notice
    /// while the take is out, even though the size until then is another
    /// device's. Later sizes and reports in the showing take nothing more.
    @Test func showingItTakesTheSizeOnceWithoutANotice() async throws {
        let remote = Remote(fitsAtOnce: false)
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)
        try await waitUntil("the showing's take") { remote.fits == 1 }

        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.otherDevice }
        try await settleDown()
        #expect(store.sizeNotice == nil)

        remote.fitGate.open()
        remote.report(server: Self.here, owner: Self.thisClient)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.thisClient }
        store.viewDidResize(cols: 90, rows: 30)
        remote.report(server: Grid(columns: 90, rows: 30), owner: Self.thisClient)
        try await settleDown()
        #expect(store.sizeNotice == nil)
        #expect(remote.fits == 1 && remote.takes == 0)
        await store.stop()
    }

    /// An attach that took the size as it opened made the showing's take:
    /// nothing is taken again for it.
    @Test func anAttachThatTookTheSizeAsItOpenedIsTheShowingsTake() async throws {
        let remote = Remote()
        remote.openedTaking(.taken)
        let runs = Runs([remote], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        try await goLive(store, remote)
        remote.report(server: Self.here, owner: Self.thisClient)
        try await waitUntil("the report") { store.sizeReport != nil }
        try await settleDown()
        #expect(runs.heard == [true])
        #expect(remote.fits == 0 && remote.takes == 0)
        #expect(store.sizeNotice == nil)
        await store.stop()
    }

    /// A take made on its own that did not go through, as the attach opened
    /// or for one open, is never made again on its own in that showing, a
    /// reattach included: the notice offers it, and a tap still takes it.
    @Test(arguments: [TerminalSizeTake.refused, .notSent, .unknown], [false, true])
    func aTakeOfItsOwnThatFailedIsNotMadeAgain(_ outcome: TerminalSizeTake, asItOpened: Bool) async throws {
        let first = Remote()
        let second = Remote()
        if asItOpened { first.openedTaking(outcome) } else { first.answerFit(outcome) }
        let runs = Runs([first, second], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        try await goLive(store, first)
        first.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        store.viewDidResize(cols: 90, rows: 30)
        first.report(server: Self.elsewhere, local: Grid(columns: 90, rows: 30), owner: Self.otherDevice)
        try await settleDown()
        #expect(first.fits == (asItOpened ? 0 : 1))

        try await reattach(store, from: first, to: second)
        second.report(server: Self.elsewhere, local: Grid(columns: 90, rows: 30), owner: Self.otherDevice)
        try await waitUntil("the notice for the new attach") { store.sizeNotice?.phase == .offered }
        #expect(runs.heard == [true, false])
        #expect(second.fits == 0)

        second.takeGate.open()
        store.takeSize()
        try await waitUntil("the tap's take") { store.sizeNotice == nil }
        #expect(second.takes == 1)
        await store.stop()
    }

    /// Another client that takes the size while this showing has it keeps
    /// it: the notice offers it back, a reattach in the showing takes
    /// nothing, and only the next showing takes it on its own again.
    @Test func anotherClientsTakeHoldsForTheRestOfTheShowing() async throws {
        let first = Remote()
        let second = Remote()
        let runs = Runs([first, second], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        try await goLive(store, first)
        try await waitUntil("the showing's take") { first.fits == 1 }

        first.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        try await settleDown()
        #expect(first.fits == 1)

        try await reattach(store, from: first, to: second)
        second.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the notice for the new attach") { store.sizeNotice?.phase == .offered }
        #expect(runs.heard == [true, false])
        #expect(second.fits == 0)

        store.setViewed(false)
        store.setViewed(true)
        try await waitUntil("the next showing's take") { second.fits == 1 }
        #expect(second.takes == 0)
        await store.stop()
    }

    /// After a tap takes the size back, the showing takes it on its own
    /// again, so a reattach opens fitted, though the take's owner change,
    /// which Rex sends before its answer, hid the notice first. Another
    /// client's take after the tap's keeps the size theirs for the showing.
    @Test(arguments: [false, true])
    func aTapTakesItBackForTheShowing(takenAfterTheTap: Bool) async throws {
        let first = Remote()
        let second = Remote()
        let runs = Runs([first, second], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        try await goLive(store, first)
        first.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 1)
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }

        store.takeSize()
        try await waitUntil("the tap's take") { first.takes == 1 }
        first.report(server: Self.here, owner: Self.thisClient, takenAway: 1)
        try await waitUntil("the notice to go") { store.sizeNotice == nil }
        if takenAfterTheTap {
            first.report(server: Self.elsewhere, owner: Self.otherDevice, takenAway: 2)
            try await waitUntil("the other device's take") { store.sizeReport?.takenAway == 2 }
        }
        first.takeGate.open()
        try await settleDown()
        try await reattach(store, from: first, to: second)
        #expect(runs.heard == [true, !takenAfterTheTap])
        await store.stop()
    }

    /// Kept off screen, as the pool keeps a terminal, an attach takes
    /// nothing; coming on screen takes the size, unless its scene is in the
    /// background, which waits for the scene to come back.
    @Test func anOffScreenAttachTakesNothing() async throws {
        let remote = Remote()
        let runs = Runs([remote], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle, viewed: false)
        try await goLive(store, remote)
        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await settleDown()
        #expect(runs.heard == [false])
        #expect(remote.fits == 0)

        store.sceneDidEnterBackground()
        store.setViewed(true)
        try await settleDown()
        #expect(remote.fits == 0)
        store.sceneDidBecomeActive()
        try await waitUntil("the take on screen") { remote.fits == 1 }
        await store.stop()
    }

    /// The size given back as the scene goes to the background is another
    /// device's, yet the scene says nothing about it while it is away: the
    /// notice would greet the user on the way back, just before the showing
    /// that begins then takes the size again.
    @Test func aSceneInTheBackgroundShowsNoNotice() async throws {
        let remote = Remote()
        let settle = Gate()
        settle.open()
        let store = store(remote, settle: settle)
        try await goLive(store, remote)
        try await waitUntil("the showing's take") { remote.fits == 1 }
        remote.report(server: Self.here, owner: Self.thisClient)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.thisClient }

        store.sceneDidEnterBackground()
        #expect(remote.viewerLefts == 1)
        remote.report(server: Self.elsewhere, owner: Self.otherDevice)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.otherDevice }
        try await settleDown()
        #expect(store.sizeNotice == nil)

        store.sceneDidBecomeActive()
        #expect(store.sizeNotice == nil)
        try await waitUntil("the take in the foreground") { remote.fits == 2 }
        remote.report(server: Self.here, owner: Self.thisClient)
        try await waitUntil("the report") { store.sizeReport?.owner == Self.thisClient }
        try await settleDown()
        #expect(store.sizeNotice == nil)
        await store.stop()
    }

    /// A showing that begins just as the screen replaces its pipeline, as a
    /// possible suspension does when the scene comes back or the pool hands a
    /// kept terminal back, asks nothing of the attach on its way out, which
    /// would give the size straight back as it stops: the attach that
    /// replaces it takes the size as it opens.
    @Test(arguments: [false, true])
    func aShowingAsItsPipelineIsReplacedTakesOnlyForTheNewAttach(backOnScreen: Bool) async throws {
        let first = Remote()
        let second = Remote()
        first.openedTaking(.taken)
        second.openedTaking(.taken)
        let runs = Runs([first, second], asksOnOpen: true, opensAtOnce: true)
        let shell = ShellTerminalStore(
            identity: ShellTerminalIdentity(paneID: "block:left", tabID: "block:left", terminalID: "block:left"),
            transportGeneration: nil, isOnStage: { true },
            runTerminal: { _, handler in try await runs.run(handler, sizes: true) })
        shell.viewDidResize(cols: 80, rows: 24)
        first.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live") { shell.terminal.status == .live }

        if backOnScreen { shell.setTerminalViewed(false) } else { shell.sceneDidEnterBackground() }
        #expect(first.viewerLefts == 1)
        let old = shell.terminal
        if backOnScreen { shell.setTerminalViewed(true) } else { shell.sceneDidBecomeActive() }
        shell.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("the replacement") { shell.terminal !== old }
        shell.viewDidResize(cols: 80, rows: 24)
        second.outputSink.yield(Data("prompt$ ".utf8))
        try await waitUntil("live again") { shell.terminal.status == .live }
        try await settleDown()
        #expect(first.fits == 0 && first.takes == 0)
        #expect(runs.heard == [true, true])
        #expect(second.fits == 0 && shell.sizeNotice == nil)
        await shell.leave().value
    }

    /// A screen that appears in a scene in the background takes nothing,
    /// as it opens or after, until the scene comes back.
    @Test func aSceneInTheBackgroundTakesNothing() async throws {
        let remote = Remote()
        let runs = Runs([remote], asksOnOpen: true, opensAtOnce: true)
        let settle = Gate()
        settle.open()
        let store = store(runs, settle: settle)
        store.sceneDidEnterBackground()
        try await goLive(store, remote)
        try await settleDown()
        #expect(runs.heard == [false])
        #expect(remote.fits == 0 && remote.viewerLefts == 0)

        store.sceneDidBecomeActive()
        try await waitUntil("the take in the foreground") { remote.fits == 1 }
        await store.stop()
    }
}
