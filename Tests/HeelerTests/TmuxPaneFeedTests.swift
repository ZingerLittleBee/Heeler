import Foundation
import Testing

@testable import Heeler

/// What one Attach makes of its control client's events (ADR 0045): a first
/// paint that lines up with the Pane's `%output`, a new one after a pause, no
/// output from other Panes, and the window closed once only Heeler holds it.
@Suite("tmux pane feed")
struct TmuxPaneFeedTests {
    private let pane = "%3"
    private let window = "@2"
    private let session = "$7"

    private func feed(history: Bool = false) -> TmuxPaneFeed {
        TmuxPaneFeed(pane: pane, window: window, session: session, viewRows: 4, includingHistory: history)
    }

    private func reply(_ lines: [String] = [], succeeded: Bool = true) -> TmuxControlReply {
        TmuxControlReply(number: 1, fromClient: true, succeeded: succeeded, lines: lines.map { Data($0.utf8) })
    }

    private let modes = "%3 @2 20 4 0 1 0 1 0 0 0 0 3 0 0 0 0 0 0 0 0 1 0 0"
    private let screen = ["top", "", "", ""]

    /// The commands among `actions`, by line, with their tags.
    private func sent(_ actions: [TmuxPaneFeed.Action]) -> [(line: String, tag: UInt64)] {
        actions.compactMap {
            if case .send(let command, let tag) = $0 { return (command.line, tag) }
            return nil
        }
    }

    private func written(_ actions: [TmuxPaneFeed.Action]) -> [Data] {
        actions.compactMap {
            if case .write(let bytes) = $0 { return bytes }
            return nil
        }
    }

    private func output(_ text: String, pane: String? = nil) -> TmuxControlClient.Event {
        .output(pane: pane ?? self.pane, bytes: Data(text.utf8))
    }

    /// Answers a paint's commands, with `between` arriving after its first reply.
    private func answer(
        _ commands: [(line: String, tag: UInt64)], into feed: inout TmuxPaneFeed,
        between: [TmuxControlClient.Event] = [], screen: [String]? = nil
    ) -> [TmuxPaneFeed.Action] {
        var actions: [TmuxPaneFeed.Action] = []
        for (index, command) in commands.enumerated() {
            let lines: [String] =
                if command.line.hasPrefix("display-message") {
                    [modes]
                } else if command.line.contains("-a -q") {
                    []
                } else if command.line.contains("-S") {
                    ["history"]
                } else {
                    screen ?? self.screen
                }
            actions += feed.receive(.replied(tag: command.tag, reply(lines)))
            if index == 0 {
                for event in between { actions += feed.receive(event) }
            }
        }
        return actions
    }

    private func paint(_ screen: [String] = ["top", "", "", ""], history: [Data]? = nil) throws -> Data {
        TmuxPanePaint.bytes(
            modes: try #require(TmuxPaneModes(Data(modes.utf8))), history: history,
            screen: screen.map { Data($0.utf8) }, normalScreen: [], viewRows: 4)
    }

    // MARK: First paint

    @Test func theFirstPaintAsksForTheModesAndScreensWithHistoryWhenAsked() {
        var plain = feed()
        #expect(sent(plain.start()).map(\.line) == TmuxPanePaint.commands(pane: pane, includingHistory: false).map(\.line))
        var withHistory = feed(history: true)
        let commands = sent(withHistory.start())
        #expect(commands.map(\.line) == TmuxPanePaint.commands(pane: pane, includingHistory: true).map(\.line))
        #expect(Set(commands.map(\.tag)).count == commands.count)
    }

    @Test func outputBeforeThePaintIsInItsCaptureAndOutputAfterItFollowsIt() throws {
        var feed = feed()
        let commands = sent(feed.start())
        #expect(feed.receive(output("captured")).isEmpty)
        let painted = answer(commands, into: &feed)
        #expect(written(painted) == [try paint()])
        #expect(written(feed.receive(output("live"))) == [Data("live".utf8)])
    }

    @Test func historyIsPaintedOnceAsked() throws {
        var feed = feed(history: true)
        let painted = answer(sent(feed.start()), into: &feed)
        let modes = try #require(TmuxPaneModes(Data(modes.utf8)))
        #expect(modes.historySize == 0)
        #expect(written(painted) == [try paint(history: [Data("history".utf8)])])
    }

    /// Output read between the modes and the screens is in the screens but
    /// not in the cursor: the paint is asked for again.
    @Test func outputDuringAPaintAsksForItAgain() throws {
        var feed = feed()
        let first = answer(sent(feed.start()), into: &feed, between: [output("moved")])
        #expect(written(first).isEmpty)
        let again = sent(first)
        #expect(again.map(\.line) == TmuxPanePaint.commands(pane: pane, includingHistory: false).map(\.line))
        let second = answer(again, into: &feed, screen: ["moved", "", "", ""])
        #expect(written(second) == [try paint(["moved", "", "", ""])])
    }

    /// A Pane that never stops printing gets the last paint asked for.
    @Test func aPaneThatKeepsPrintingIsPaintedAfterThreeTries() throws {
        var feed = feed()
        var actions = feed.start()
        for _ in 0..<2 {
            actions = answer(sent(actions), into: &feed, between: [output("busy")])
            #expect(written(actions).isEmpty)
        }
        actions = answer(sent(actions), into: &feed, between: [output("busy")])
        #expect(written(actions) == [try paint()])
        #expect(sent(actions).isEmpty)
    }

    @Test func otherPanesOutputIsDropped() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        #expect(feed.receive(output("elsewhere", pane: "%4")).isEmpty)
    }

    @Test func aFailedModesReplyChecksThePaneBeforeTryingAgain() {
        var feed = feed()
        let commands = sent(feed.start())
        let actions = feed.receive(.replied(tag: commands[0].tag, reply(["can't find pane: %3"], succeeded: false)))
        let check = sent(actions)
        #expect(check.map(\.line) == [TmuxPaneFeed.checkCommand(pane: pane).line])
        for command in commands.dropFirst() { _ = feed.receive(.replied(tag: command.tag, reply())) }
        let again = feed.receive(.replied(tag: check[0].tag, reply(["$1 @2 0", "$7 @2 1"])))
        #expect(sent(again).map(\.line) == TmuxPanePaint.commands(pane: pane, includingHistory: false).map(\.line))
    }

    // MARK: Pause

    @Test func aPausedPaneContinuesWithANewPaintWithoutHistory() throws {
        var feed = feed(history: true)
        _ = answer(sent(feed.start()), into: &feed)
        let actions = feed.receive(.notification(.paused(pane: pane)))
        #expect(
            sent(actions).map { ScriptedTmuxHost.words(of: $0.line) }
                == [["refresh-client", "-A", "%3:continue"]]
                + TmuxPanePaint.commands(pane: pane, includingHistory: false).map { ScriptedTmuxHost.words(of: $0.line) })
        #expect(feed.receive(output("while it continues")).isEmpty)
        let painted = answer(Array(sent(actions).dropFirst()), into: &feed)
        #expect(written(painted) == [try paint()])
    }

    @Test func anotherPanesPauseIsLeftAsItIs() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        #expect(feed.receive(.notification(.paused(pane: "%4"))).isEmpty)
    }

    /// A pause during a paint asks for a new one; the old one's replies count for nothing.
    @Test func aPauseDuringAPaintReplacesIt() throws {
        var feed = feed()
        let old = sent(feed.start())
        let resumed = sent(feed.receive(.notification(.paused(pane: pane))))
        #expect(written(answer(old, into: &feed)).isEmpty)
        let painted = answer(Array(resumed.dropFirst()), into: &feed)
        #expect(written(painted) == [try paint()])
    }

    // MARK: The window's links

    @Test func aSessionChangeChecksWhereThePanesWindowIsLinked() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        #expect(
            sent(feed.receive(.notification(.sessionsChanged))).map { ScriptedTmuxHost.words(of: $0.line) }
                == [["list-panes", "-a", "-F", "#{session_id} #{window_id} #{?@heeler-attach,1,0}", "-f", "#{==:#{pane_id},%3}"]])
    }

    @Test func onlyThisWindowsCloseOrLayoutChangeChecksIt() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        #expect(feed.receive(.notification(.windowClosed(window: "@9"))).isEmpty)
        #expect(feed.receive(.notification(.layoutChanged(window: "@9"))).isEmpty)
        #expect(sent(feed.receive(.notification(.layoutChanged(window: window)))).count == 1)
    }

    @Test func changesDuringACheckAreCheckedOnceMoreAfterIt() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        let check = sent(feed.receive(.notification(.sessionsChanged)))
        #expect(feed.receive(.notification(.windowClosed(window: window))).isEmpty)
        #expect(feed.receive(.notification(.sessionsChanged)).isEmpty)
        let next = feed.receive(.replied(tag: check[0].tag, reply(["$1 @2 0", "$7 @2 1"])))
        #expect(sent(next).map(\.line) == [TmuxPaneFeed.checkCommand(pane: pane).line])
    }

    @Test func aWindowAUserSessionStillHoldsStaysOpen() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        let check = sent(feed.receive(.notification(.sessionsChanged)))
        #expect(feed.receive(.replied(tag: check[0].tag, reply(["$1 @2 0", "$7 @2 1"]))).isEmpty)
    }

    /// Once the user ended every other session holding the window, Heeler's
    /// sessions would keep it, and its program, alive: Heeler closes it.
    @Test func aWindowOnlyHeelersSessionsHoldIsClosed() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        let check = sent(feed.receive(.notification(.sessionsChanged)))
        let close = sent(feed.receive(.replied(tag: check[0].tag, reply(["$7 @2 1", "$9 @2 1"]))))
        #expect(close.map { ScriptedTmuxHost.words(of: $0.line) } == [["kill-window", "-t", "@2"]])
        #expect(feed.receive(.replied(tag: close[0].tag, reply())) == [.end(.paneGone)])
    }

    @Test func aPaneNoSessionListsIsGone() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        let check = sent(feed.receive(.notification(.sessionsChanged)))
        #expect(feed.receive(.replied(tag: check[0].tag, reply())) == [.end(.paneGone)])
    }

    /// The Pane went to another window, or the window left this session.
    @Test func aPaneThisSessionNoLongerHoldsEndsTheAttach() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        let check = sent(feed.receive(.notification(.sessionsChanged)))
        #expect(feed.receive(.replied(tag: check[0].tag, reply(["$1 @5 0"]))) == [.end(.sessionLeft)])
    }

    @Test func movingTheClientToAnotherSessionEndsTheAttach() {
        var feed = feed()
        _ = answer(sent(feed.start()), into: &feed)
        #expect(feed.receive(.notification(.sessionChanged(session: "$1"))) == [.end(.sessionLeft)])
        #expect(feed.receive(output("after")).isEmpty)
    }

    @Test func aRepaintUpdatesTheViewRowsWithoutRepeatingHistory() throws {
        var feed = feed(history: true)
        _ = answer(sent(feed.start()), into: &feed)
        feed.updateViewRows(8)
        let actions = feed.repaint()
        #expect(sent(actions).map(\.line) == TmuxPanePaint.commands(pane: pane, includingHistory: false).map(\.line))
        let repainted = answer(sent(actions), into: &feed, screen: ["resized", "", "", ""])
        let expected = TmuxPanePaint.bytes(
            modes: try #require(TmuxPaneModes(Data(modes.utf8))),
            history: nil,
            screen: ["resized", "", "", ""].map { Data($0.utf8) },
            normalScreen: [],
            viewRows: 8)
        #expect(written(repainted) == [expected])
    }
}
