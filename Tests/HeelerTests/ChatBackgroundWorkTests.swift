import Foundation
import Testing

@testable import Heeler

/// Journal lines in the shape Claude Code 2.1.29x writes them.
private enum Journal {
    static let path = "/home/dev/.claude/projects/-home-dev-docs/s1/subagents/workflows/wf_0a1b2c3d-4e5/journal.jsonl"

    static let launched = #"{"type":"launched"}"# + "\n"

    static func started(_ key: String, label: String, phase: String = "Audit") -> String {
        #"{"type":"started","key":"v2:\#(key)","agentId":"a-\#(key)","label":"\#(label)","phase":"\#(phase)"}"# + "\n"
    }

    static func result(_ key: String, _ text: String = "Looks right.") -> String {
        #"{"type":"result","key":"v2:\#(key)","agentId":"a-\#(key)","result":"\#(text)"}"# + "\n"
    }

    static func failed(_ key: String) -> String {
        #"{"type":"failed","key":"v2:\#(key)","agentId":"a-\#(key)"}"# + "\n"
    }

    static func lines(_ text: String) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data(text.utf8))
    }
}

@Suite("Workflow journal follower")
struct WorkflowJournalFollowerTests {
    private static let limits = WorkflowJournalFollower.Limits(
        readChunk: 256, anchorLength: 8, lineCap: 4_096, prefixCap: 1_024, maximumBytes: 4_096)

    private static func texts(_ change: WorkflowJournalFollower.Change) -> [String] {
        switch change {
        case .appended(let lines), .restarted(let lines):
            lines.map { String(decoding: $0.data, as: UTF8.self) }
        case .unchanged, .missing, .tooLarge:
            []
        }
    }

    @Test func readsFromTheFirstByteWithinItsBudget() async throws {
        let files = VirtualHostFiles()
        let text = Journal.launched + Journal.started("1", label: "audit:pairing") + Journal.started("2", label: "audit:hosts")
        await files.write(text, at: Journal.path)
        var follower = WorkflowJournalFollower(path: Journal.path, limits: Self.limits)

        let first = try await follower.poll(files.hostFiles(), budget: 100)
        #expect(Self.texts(first) == [#"{"type":"launched"}"#])
        #expect(!follower.isCaughtUp)

        let rest = try await follower.poll(files.hostFiles(), budget: 1_000)
        #expect(Self.texts(rest).count == 2)
        #expect(follower.isCaughtUp)
        #expect(follower.readOffset == UInt64(text.utf8.count))
    }

    @Test func aQuietJournalCostsOneStatAndAnAppendOneRead() async throws {
        let files = VirtualHostFiles()
        await files.write(Journal.launched + Journal.started("1", label: "audit:pairing"), at: Journal.path)
        var follower = WorkflowJournalFollower(path: Journal.path, limits: Self.limits)
        _ = try await follower.poll(files.hostFiles(), budget: 4_096)
        await files.clearRecords()

        #expect(try await follower.poll(files.hostFiles(), budget: 4_096) == .unchanged)
        #expect(await files.statuses == [Journal.path])
        #expect(await files.reads.isEmpty)

        await files.append(Journal.result("1"), to: Journal.path)
        await files.clearRecords()
        let appended = try await follower.poll(files.hostFiles(), budget: 4_096)
        #expect(Self.texts(appended) == [Journal.result("1").trimmingCharacters(in: .newlines)])
        // The anchor and the new bytes come in one read.
        let reads = await files.reads
        #expect(reads.count == 1)
        #expect(reads.first?.offset == follower.readOffset - UInt64(Journal.result("1").utf8.count) - 8)
    }

    @Test func aJournalThatNoLongerContinuesStartsOver() async throws {
        let files = VirtualHostFiles()
        let first = Journal.launched + Journal.started("1", label: "audit:pairing") + Journal.result("1")
        await files.write(first, at: Journal.path)
        var follower = WorkflowJournalFollower(path: Journal.path, limits: Self.limits)
        _ = try await follower.poll(files.hostFiles(), budget: 4_096)

        // Shorter: read again from the start.
        let shorter = Journal.launched + Journal.started("2", label: "audit:hosts")
        await files.write(shorter, at: Journal.path)
        let shrunk = try await follower.poll(files.hostFiles(), budget: 4_096)
        #expect(shrunk == .restarted(Journal.lines(shorter)))

        // Longer, but not a continuation of what was read.
        let rewritten = Journal.launched + Journal.started("3", label: "audit:keys") + Journal.result("3", "Rewritten")
        await files.write(rewritten, at: Journal.path)
        #expect(try await follower.poll(files.hostFiles(), budget: 4_096) == .restarted(Journal.lines(rewritten)))

        // The same length, written again in a later second.
        let same = rewritten.replacingOccurrences(of: "Rewritten", with: "Rewrote!!")
        await files.write(same, at: Journal.path)
        #expect(try await follower.poll(files.hostFiles(), budget: 4_096) == .restarted(Journal.lines(same)))
        #expect(follower.isCaughtUp)
    }

    @Test func aMissingOrOversizedJournalIsReported() async throws {
        let files = VirtualHostFiles()
        var follower = WorkflowJournalFollower(path: Journal.path, limits: Self.limits)
        #expect(try await follower.poll(files.hostFiles(), budget: 4_096) == .missing)

        await files.write(String(repeating: Journal.started("1", label: "audit:pairing"), count: 60), at: Journal.path)
        #expect(try await follower.poll(files.hostFiles(), budget: 4_096) == .tooLarge)
    }

    @Test func aFailedReadKeepsTheLastGoodPosition() async throws {
        let files = VirtualHostFiles()
        await files.write(Journal.launched, at: Journal.path)
        var follower = WorkflowJournalFollower(path: Journal.path, limits: Self.limits)
        _ = try await follower.poll(files.hostFiles(), budget: 4_096)
        await files.append(Journal.started("1", label: "audit:pairing"), to: Journal.path)
        await files.failNext(.read, path: Journal.path, with: TransportError.hostFileTimedOut)

        let before = follower
        await #expect(throws: TransportError.hostFileTimedOut) {
            var attempt = before
            _ = try await attempt.poll(files.hostFiles(), budget: 4_096)
        }
        let appended = try await follower.poll(files.hostFiles(), budget: 4_096)
        #expect(Self.texts(appended).count == 1)
    }
}

@Suite("Claude workflow journal")
struct ClaudeWorkflowJournalTests {
    @Test func agentsRunUntilTheirResultOrFailure() {
        var journal = ClaudeWorkflowJournal()
        journal.apply(
            Journal.lines(
                Journal.launched + Journal.started("1", label: "audit:pairing") + Journal.started("2", label: "audit:hosts")
                    + Journal.result("1") + Journal.started("3", label: "verify:hosts", phase: "Verify")
                    + Journal.failed("2") + #"{"type":"restoring"}"# + "\n"))
        let progress = journal.progress(updatedAt: nil)
        #expect(
            progress.agents == [
                ChatWorkflowProgress.Agent(id: "v2:1", label: "audit:pairing", phase: "Audit", state: .done),
                ChatWorkflowProgress.Agent(id: "v2:2", label: "audit:hosts", phase: "Audit", state: .failed),
                ChatWorkflowProgress.Agent(id: "v2:3", label: "verify:hosts", phase: "Verify", state: .running),
            ])
        #expect(progress.done == 1)
        #expect(progress.failed == 1)
        #expect(progress.started == 3)
        #expect(journal.unreadableLines == 0)
    }

    @Test func anAgentStartedAgainIsTheSameAgent() {
        var journal = ClaudeWorkflowJournal()
        journal.apply(Journal.lines(Journal.started("1", label: "audit:pairing") + Journal.failed("1")))
        journal.apply(Journal.lines(Journal.started("1", label: "audit:pairing")))
        #expect(journal.progress(updatedAt: nil).agents.map(\.state) == [.running])
    }

    @Test func aResultLineCutToItsStartStillCounts() {
        let long = Journal.result("1", String(repeating: "x", count: 6_000))
        let lines = JSONLLineFramer.lines(
            in: Data((Journal.started("1", label: "audit:pairing") + long + "{not json}\n").utf8), lineCap: 4_096,
            prefixCap: 1_024)
        #expect(lines[1].isTruncated)
        var journal = ClaudeWorkflowJournal()
        journal.apply(lines)
        #expect(journal.progress(updatedAt: nil).done == 1)
        #expect(journal.unreadableLines == 1)
    }
}

@Suite("Chat background work")
struct ChatBackgroundWorkTests {
    private static let now = Date(timeIntervalSince1970: 1_791_300_000)

    private static func item(
        _ id: String, kind: ChatBackgroundWorkItem.Kind = .subagent, state: ChatBackgroundWorkItem.State = .running,
        launchedAgo: TimeInterval = 60, at offset: UInt64, endedAt endOffset: UInt64? = nil
    ) -> ChatBackgroundWorkItem {
        ChatBackgroundWorkItem(
            id: id, kind: kind, title: id, state: state, launchOffset: offset, endOffset: endOffset,
            launchedAt: now.addingTimeInterval(-launchedAgo))
    }

    @Test func runningWorkComesFirstAndEachPartKeepsLaunchOrder() {
        let transcript = ChatTranscript(
            backgroundWork: [
                Self.item("a", state: .completed, at: 10, endedAt: 50),
                Self.item("b", at: 20),
                Self.item("c", state: .failed, at: 30, endedAt: 60),
                Self.item("d", kind: .workflow, at: 40),
                Self.item("e", state: .completed, at: 1, endedAt: 5),
            ],
            latestPromptOffset: 8)
        let work = ChatBackgroundWork(transcript: transcript, progress: [:], isLive: true, now: Self.now)
        // `e` ended before the latest prompt.
        #expect(work.rows.map(\.id) == ["b", "d", "a", "c"])
        #expect(work.holdsActivePace)
    }

    @Test func runningWorkWithNoSignForTooLongIsStale() {
        let staleness = ChatBackgroundWork.Staleness(workflowQuiet: 100, subagentRun: 200)
        let transcript = ChatTranscript(backgroundWork: [
            Self.item("quiet", kind: .workflow, launchedAgo: 150, at: 1),
            Self.item("written", kind: .workflow, launchedAgo: 150, at: 2),
            Self.item("long", launchedAgo: 250, at: 3),
            Self.item("short", launchedAgo: 150, at: 4),
        ])
        let progress = ["written": ChatWorkflowProgress(updatedAt: Self.now.addingTimeInterval(-30))]
        let work = ChatBackgroundWork(
            transcript: transcript, progress: progress, isLive: true, now: Self.now, staleness: staleness)
        #expect(work.rows.map(\.isStale) == [true, false, true, false])
        #expect(work.rows[1].lastActivity == Self.now.addingTimeInterval(-30))
        #expect(work.holdsActivePace)

        let allStale = ChatBackgroundWork(
            transcript: ChatTranscript(backgroundWork: [Self.item("long", launchedAgo: 250, at: 3)]), progress: [:],
            isLive: true, now: Self.now, staleness: staleness)
        #expect(!allStale.holdsActivePace)
    }

    @Test func workAnEarlierReadListedCarriesIntoALaterWindow() {
        var transcript = ChatTranscript(
            backgroundWork: [Self.item("loaded", at: 50)],
            backgroundWorkEnds: ["ends": ChatBackgroundWorkEnd(state: .failed, offset: 60)],
            backgroundWorkStop: ChatBackgroundWorkEnd(state: .stopped, offset: 70))
        transcript.carryBackgroundWork(
            [
                Self.item("ends", at: 5), Self.item("stops", at: 6),
                Self.item("done", state: .completed, at: 7, endedAt: 45),
                // Its launch is loaded again, as the window shows it.
                Self.item("loaded", state: .completed, at: 50, endedAt: 55),
            ],
            launchedBefore: 40, latestPromptOffset: 30)

        #expect(transcript.backgroundWork.map(\.id) == ["ends", "stops", "done", "loaded"])
        #expect(transcript.backgroundWork.map(\.state) == [.failed, .stopped, .completed, .running])
        #expect(transcript.backgroundWork.map(\.endOffset) == [60, 70, 45, nil])
        // No message is loaded, so the earlier read's latest stands.
        #expect(transcript.latestPromptOffset == 30)
    }

    @Test func onlyALiveReadHoldsTheActivePace() {
        let transcript = ChatTranscript(backgroundWork: [Self.item("b", at: 20)])
        #expect(!ChatBackgroundWork(transcript: transcript, progress: [:], isLive: false, now: Self.now).holdsActivePace)
        let finished = ChatTranscript(backgroundWork: [Self.item("b", state: .completed, at: 20, endedAt: 30)])
        #expect(!ChatBackgroundWork(transcript: finished, progress: [:], isLive: true, now: Self.now).holdsActivePace)
    }
}
