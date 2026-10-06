import Foundation
import Testing

@testable import Heeler

@Suite("Claude transcript reducer")
struct ClaudeTranscriptReducerTests {
    private static let probe = "claude/probe2-transcript.jsonl"
    private static let planPath = "/Users/developer/.claude/plans/spicy-dazzling-crescent.md"

    private static func transcript(
        _ path: String = probe, role: ClaudeTranscriptReducer.Role = .main, activity: ChatAgentActivity = .idle,
        where include: (ChatLine) -> Bool = { _ in true }
    ) throws -> ChatTranscript {
        let lines = try ChatFixture.lines(path).filter(include)
        return ClaudeSample.reducer(lines, role: role).transcript(ChatProjectionContext(activity: activity))
    }

    /// The probe's options, each described by its own label.
    private static func selfDescribed(_ labels: String...) -> [ChatQuestion.Option] {
        labels.map { ChatQuestion.Option(label: $0, detail: $0) }
    }

    private static func tool(_ id: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        guard case .tool(let row) = ClaudeSample.entry(id, in: transcript) else { return nil }
        return row
    }

    private static func plan(_ id: String, in transcript: ChatTranscript) -> ChatPlan? {
        guard case .plan(let plan) = ClaudeSample.entry(id, in: transcript) else { return nil }
        return plan
    }

    // MARK: - Second probe

    private static let entryIDs = [
        "user:e6fda38c-45bf-49c6-b0a2-5e1cf39cbef9", "tool:toolu_01TbgUciZNfX5qWyWVahrgJY",
        "text:bcb7adf8-2aa5-40f6-be4a-0c8c923f467d", "user:5d423244-b34c-41d2-b8a3-3f1d2bba1c80",
        "tool:toolu_01MeeQvgf3XPxg1YaDJAepsS", "text:1e29107a-3a32-4658-9763-5074aa05a664",
        "user:3c89eafa-7685-463f-b393-6003ba74e8a1", "tool:toolu_019oBhnhaxeeZbkHonqnhwsE",
        "text:095f5d72-9140-4722-a76f-a413c6d84152", "user:63c62d22-2742-493c-94d4-f261e6b4fd17",
        "tool:toolu_016LdTk3u4K7FUZvvLzmrnVf", "tool:toolu_01XHCp1Pv9D7MCDGutRwM9Rn",
        "text:8ed60b0d-8e2f-4f1e-9d82-7ef6f92bb633", "user:d86a9ffa-a0e7-4235-b495-6120f91de634",
        "tool:toolu_01RQqSDbAi69XVjZCC3iKvkW", "tool:toolu_01CvrauoyjXruqKHXuaL4Uan",
        "tool:toolu_01Jo6GQL3LtcDFwu86aPKGMu", "tool:toolu_016tHGwRUTqRPf2oeX8UFd1d",
        "tool:toolu_01CV6HHFQmyxCu6gXqLc4vgE", "tool:toolu_01VAL7noTGaKa2T9YSi4fdXT",
        "text:84e508c9-2985-4d12-b413-2120e70ff03c", "user:d26638ad-4d4a-4f14-aaa1-9efe8d823dfd",
        "think:a29effa7-ab51-4a43-8194-a956e93f004f", "tool:toolu_01GFcLu9bmnScxtbjouBiMXN",
        "user:c76d88d5-7bd1-44fa-88b4-4da41ae53d8d", "tool:toolu_017n16vurPjJeEhYsvYRrCPc",
        "tool:toolu_016mt3K66Rc6NSsp342MeEre", "user:f08414f2-99f7-4b63-bf9f-e17b0de76a15",
        "tool:toolu_01VzSQ5ZYf8MrC735NBTyJQ5", "text:13cb6ba2-2b33-42b3-9ac1-ec306b5cb313",
        "notice:6d0ceb41-779d-4bde-a308-858b33b73a13", "text:281025a2-a2a1-4c55-8925-e73cacb3c672",
        "user:5f97b4a9-198c-402f-8972-030fdd75a7d2", "tool:toolu_017YLtPr2eaYAgmF9dBt4S7d",
        "text:25adc54c-d82a-4d34-a9f3-44aeafa055cd", "user:69815460-9420-40ba-9b8e-da8ed41b3f74",
        "tool:toolu_011Zep7Auvwg7vjBKuggC45D", "text:82476e9d-fc84-476f-9b14-f6ef2b3b8981",
        "user:9575a22b-9085-43ba-9e3a-220010bc6694", "tool:toolu_017sdMHyeBcArbuhQrzRWq4Z",
        "tool:toolu_013hiiWMz6hQ12LZqVBhV5yu", "text:fb1b2513-838c-477a-bf91-3660ff9e7d84",
    ]

    private static let entryOffsets: [UInt64] = [
        391, 5822, 9837, 11745, 12721, 15446, 17354, 18588, 22206, 24199, 25189, 28129, 32206, 34346,
        35529, 38558, 41634, 45030, 46821, 53133, 56208, 58245, 60118, 61559, 65421, 66472, 69464, 73282,
        74431, 78841, 82019, 83619, 85786, 86798, 90221, 92248, 93261, 95973, 98000, 99072, 100605, 104202,
    ]

    @Test("The second probe projects to 42 entries in file order")
    func entries() throws {
        let transcript = try Self.transcript()
        #expect(transcript.entries.map(\.id.rawValue) == Self.entryIDs)
        #expect(transcript.entries.map(\.sourceOffset) == Self.entryOffsets)
        #expect(transcript.title == "create-and-verify-probe-file")
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.pendingRequests.isEmpty)
        #expect(transcript.links == ChatTranscriptLinks())
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("A decline with feedback keeps it, and the turn goes on (M L25-L34)")
    func declineWithFeedback() throws {
        let transcript = try Self.transcript()
        #expect(
            Self.tool("tool:toolu_01TbgUciZNfX5qWyWVahrgJY", in: transcript)
                == ChatToolActivity(
                    kind: .command, name: "Bash", title: "Create empty file c1.txt", subtitle: "touch c1.txt",
                    status: .declined, note: "Do not create it; reply with the single word skipped",
                    callID: "toolu_01TbgUciZNfX5qWyWVahrgJY", output: ChatOutputReference(offset: 7319, length: 1328)))
        let index = try #require(transcript.entries.firstIndex { $0.id.rawValue == "tool:toolu_01TbgUciZNfX5qWyWVahrgJY" })
        #expect(transcript.entries[index + 1].content == .assistant(ChatAssistantMessage(text: "skipped")))
    }

    @Test("An approval with a note succeeds and keeps the note (M L39-L40)")
    func approveWithNote() throws {
        #expect(
            Self.tool("tool:toolu_01MeeQvgf3XPxg1YaDJAepsS", in: try Self.transcript())
                == ChatToolActivity(
                    kind: .command, name: "Bash", title: "Create empty file c2.txt", subtitle: "touch c2.txt",
                    status: .succeeded, note: "after it succeeds, reply with the single word created",
                    callID: "toolu_01MeeQvgf3XPxg1YaDJAepsS", output: ChatOutputReference(offset: 14212, length: 925)))
    }

    @Test("AskUserQuestion carries both questions with their answers (M L47-L48)")
    func askUserQuestion() throws {
        #expect(
            Self.tool("tool:toolu_019oBhnhaxeeZbkHonqnhwsE", in: try Self.transcript())
                == ChatToolActivity(
                    kind: .question, name: "AskUserQuestion", title: "Which colors? · Which size?",
                    status: .succeeded,
                    questions: [
                        ChatQuestion(
                            header: "Colors", text: "Which colors?",
                            options: Self.selfDescribed("Red", "Green", "Blue"), isMultiSelect: true,
                            answer: "Red, Blue"),
                        ChatQuestion(
                            header: "Size", text: "Which size?", options: Self.selfDescribed("Small", "Large"),
                            answer: "Medium"),
                    ],
                    callID: "toolu_019oBhnhaxeeZbkHonqnhwsE", output: ChatOutputReference(offset: 20502, length: 1395)))
    }

    @Test("Entering plan mode reads as a notice (M L59-L65)")
    func planModeEnter() throws {
        let transcript = try Self.transcript()
        #expect(
            transcript.entries.first { $0.id.rawValue == "tool:toolu_01XHCp1Pv9D7MCDGutRwM9Rn" }
                == ChatEntry(
                    id: ChatEntryID("tool:toolu_01XHCp1Pv9D7MCDGutRwM9Rn"), sourceOffset: 28129,
                    content: .notice(ChatNotice(kind: .planMode, title: "Entered plan mode"))))
    }

    @Test("A declined plan keeps the feedback (M L80-L81)")
    func exitPlanDeclined() throws {
        #expect(
            Self.plan("tool:toolu_01Jo6GQL3LtcDFwu86aPKGMu", in: try Self.transcript())
                == ChatPlan(
                    text: "1. Create p.txt in /private/tmp/heeler-tmp-chat2/probe-claude containing the single word \"probe\".\n2. Verify by reading p.txt back and confirming its content is \"probe\".\n",
                    filePath: Self.planPath, status: .declined, note: "Name the file q.txt instead",
                    callID: "toolu_01Jo6GQL3LtcDFwu86aPKGMu"))
    }

    @Test("An approved plan shows the plan as approved, not the stale input (M L83-L87)")
    func exitPlanApproved() throws {
        let transcript = try Self.transcript()
        let write = try #require(Self.tool("tool:toolu_016tHGwRUTqRPf2oeX8UFd1d", in: transcript))
        #expect(write.status == .succeeded)
        #expect(write.diff == ChatDiffStats(added: 2, removed: 2))
        #expect(write.output == ChatOutputReference(offset: 48619, length: 1853))
        #expect(
            Self.plan("tool:toolu_01CV6HHFQmyxCu6gXqLc4vgE", in: transcript)
                == ChatPlan(
                    text: "1. Create q.txt in /private/tmp/heeler-tmp-chat2/probe-claude containing the single word \"probe\".\n2. Verify by reading q.txt back and confirming its content is \"probe\".\n",
                    filePath: Self.planPath, status: .succeeded, note: "Also reply with the word done at the end",
                    callID: "toolu_01CV6HHFQmyxCu6gXqLc4vgE"))
    }

    @Test("Creating a file counts its lines (M L91-L93)")
    func writeCreate() throws {
        #expect(
            Self.tool("tool:toolu_01VAL7noTGaKa2T9YSi4fdXT", in: try Self.transcript())
                == ChatToolActivity(
                    kind: .fileWrite, name: "Write", title: "/private/tmp/heeler-tmp-chat2/probe-claude/q.txt",
                    status: .succeeded, diff: ChatDiffStats(added: 1, removed: 0),
                    callID: "toolu_01VAL7noTGaKa2T9YSi4fdXT",
                    preview: ChatToolPreview(text: "probe\n", isTruncated: false),
                    output: ChatOutputReference(offset: 54848, length: 1051)))
    }

    @Test("Declines without feedback absorb the interrupt markers after them (M L106-L120)")
    func declineAbortFolds() throws {
        let transcript = try Self.transcript()
        #expect(
            ClaudeSample.entry("think:a29effa7-ab51-4a43-8194-a956e93f004f", in: transcript)
                == .reasoning(ChatReasoning(text: "<redacted>", durationMilliseconds: 647)))
        let edit = try #require(Self.tool("tool:toolu_01GFcLu9bmnScxtbjouBiMXN", in: transcript))
        #expect(edit.status == .declined)
        #expect(edit.note == nil)
        #expect(edit.preview == nil)
        let fetch = try #require(Self.tool("tool:toolu_016mt3K66Rc6NSsp342MeEre", in: transcript))
        #expect(fetch.kind == .web)
        #expect(fetch.title == "https://example.com")
        #expect(fetch.status == .declined)
        #expect(fetch.note == nil)
        let markers = ["b06ca78e-04d3-4496-843b-9a168301b9c2", "e0917cb7-19f7-4712-9daf-0dc547eff614"]
        #expect(!transcript.entries.contains { entry in markers.contains { entry.id.rawValue.hasSuffix($0) } })
        #expect(!transcript.entries.contains { if case .notice(let notice) = $0.content { notice.kind == .interrupted } else { false } })
    }

    @Test("A background agent runs until its notification, which also shows as a row (M L125-L132)")
    func agentAndNotification() throws {
        let report = "成功了。`touch sub.txt` 在 /private/tmp/heeler-tmp-chat2/probe-claude 下执行完毕,没有报错,输出了 \"ok\"。"
        let launched = ChatToolActivity(
            kind: .agent, name: "Agent", title: "Run touch sub.txt", subtitle: "general-purpose", status: .running,
            callID: "toolu_01VzSQ5ZYf8MrC735NBTyJQ5", output: ChatOutputReference(offset: 76158, length: 2374))

        let before = try Self.transcript(activity: .idle) { $0.offset < 82019 }
        #expect(Self.tool("tool:toolu_01VzSQ5ZYf8MrC735NBTyJQ5", in: before) == launched)
        #expect(ClaudeSample.entry("notice:6d0ceb41-779d-4bde-a308-858b33b73a13", in: before) == nil)
        #expect(before.pendingRequests.isEmpty)

        let after = try Self.transcript()
        var finished = launched
        finished.status = .succeeded
        finished.preview = ChatToolPreview(text: report, isTruncated: false)
        #expect(Self.tool("tool:toolu_01VzSQ5ZYf8MrC735NBTyJQ5", in: after) == finished)
        #expect(
            ClaudeSample.entry("notice:6d0ceb41-779d-4bde-a308-858b33b73a13", in: after)
                == .notice(
                    ChatNotice(kind: .taskNotification, title: "Agent \"Run touch sub.txt\" finished", detail: report)))
    }

    @Test("Parallel Bash calls both resolve, the dead-end result included (M L160-L163)")
    func parallelBash() throws {
        let transcript = try Self.transcript()
        let first = try #require(Self.tool("tool:toolu_017sdMHyeBcArbuhQrzRWq4Z", in: transcript))
        let second = try #require(Self.tool("tool:toolu_013hiiWMz6hQ12LZqVBhV5yu", in: transcript))
        #expect(first.title == "Create empty file par-a.txt")
        #expect(second.title == "Create empty file par-b.txt")
        #expect(first.status == .succeeded)
        #expect(second.status == .succeeded)
        #expect(first.output == ChatOutputReference(offset: 102138, length: 877))
        #expect(second.output == ChatOutputReference(offset: 103016, length: 877))
    }

    // MARK: - Open turns

    private struct ActivityCase: Sendable, CustomTestStringConvertible {
        let activity: ChatAgentActivity
        let status: ChatToolActivity.Status
        var testDescription: String { "\(activity) shows \(status)" }
    }

    @Test(
        "A call without a result follows the Agent's activity while its turn is open",
        arguments: [
            ActivityCase(activity: .blocked, status: .awaitingApproval),
            ActivityCase(activity: .working, status: .running),
            ActivityCase(activity: .unknown, status: .running),
            ActivityCase(activity: .idle, status: .noResult),
        ])
    private func openCall(_ testCase: ActivityCase) throws {
        let transcript = try Self.transcript(activity: testCase.activity) { $0.offset < 7319 }
        #expect(Self.tool("tool:toolu_01TbgUciZNfX5qWyWVahrgJY", in: transcript)?.status == testCase.status)
        #expect(transcript.pendingRequests == [
            ChatPendingRequest(
                entryID: ChatEntryID("tool:toolu_01TbgUciZNfX5qWyWVahrgJY"), callID: "toolu_01TbgUciZNfX5qWyWVahrgJY",
                kind: .command, toolName: "Bash", summary: "touch c1.txt", detail: "Create empty file c1.txt")
        ])
    }

    @Test("Pending questions and plans carry what a Blocked card shows")
    func pendingQuestionsAndPlans() throws {
        let questions = try Self.transcript(activity: .blocked) { $0.offset < 20502 }
        #expect(questions.pendingRequests == [
            ChatPendingRequest(
                entryID: ChatEntryID("tool:toolu_019oBhnhaxeeZbkHonqnhwsE"), callID: "toolu_019oBhnhaxeeZbkHonqnhwsE",
                kind: .question, toolName: "AskUserQuestion", summary: "Which colors?\nWhich size?",
                questions: [
                    ChatQuestion(
                        header: "Colors", text: "Which colors?", options: Self.selfDescribed("Red", "Green", "Blue"),
                        isMultiSelect: true),
                    ChatQuestion(header: "Size", text: "Which size?", options: Self.selfDescribed("Small", "Large")),
                ])
        ])

        let plan = try Self.transcript(activity: .blocked) { $0.offset < 43433 }
        let text =
            "1. Create p.txt in /private/tmp/heeler-tmp-chat2/probe-claude containing the single word \"probe\".\n2. Verify by reading p.txt back and confirming its content is \"probe\".\n"
        #expect(plan.pendingRequests == [
            ChatPendingRequest(
                entryID: ChatEntryID("tool:toolu_01Jo6GQL3LtcDFwu86aPKGMu"), callID: "toolu_01Jo6GQL3LtcDFwu86aPKGMu",
                kind: .other, toolName: "ExitPlanMode", summary: text, detail: Self.planPath,
                planFilePath: Self.planPath)
        ])
        #expect(Self.plan("tool:toolu_01Jo6GQL3LtcDFwu86aPKGMu", in: plan)?.status == .awaitingApproval)
    }

    // MARK: - Windows and feeding

    @Test("A tail window shows what the whole file shows from there, and prepending converges")
    func appendPrependInvariance() throws {
        let lines = try ChatFixture.lines(Self.probe)
        let context = ChatProjectionContext(activity: .idle)
        let whole = ClaudeSample.reducer(lines).transcript(context)

        var reducer = ClaudeSample.reducer(lines.filter { $0.offset >= 58245 })
        let window = reducer.transcript(ChatProjectionContext(windowStart: 58245, activity: .idle))
        #expect(window.needsOlderHistory)
        #expect(window.entries == whole.entries.filter { $0.sourceOffset >= 58245 })
        #expect(window.recordedPrompts == whole.recordedPrompts.filter { $0.offset >= 58245 })
        #expect(window.title == whole.title)

        reducer.prepend(lines.filter { $0.offset < 58245 })
        #expect(reducer.transcript(context) == whole)
    }

    private struct Batch: Sendable, CustomTestStringConvertible {
        let size: Int
        var testDescription: String { "batches of \(size) lines" }
    }

    @Test("Batches of any size, and re-fed lines, give the same transcript", arguments: [1, 7, 40].map(Batch.init))
    private func splitInvariance(_ batch: Batch) throws {
        let lines = try ChatFixture.lines(Self.probe)
        let context = ChatProjectionContext(activity: .working)
        let whole = ClaudeSample.reducer(lines).transcript(context)
        var reducer = ClaudeTranscriptReducer()
        for start in stride(from: 0, to: lines.count, by: batch.size) {
            reducer.append(Array(lines[start..<min(lines.count, start + batch.size)]))
        }
        #expect(reducer.transcript(context) == whole)
        reducer.append(Array(lines.suffix(batch.size)))
        #expect(reducer.transcript(context) == whole)
    }

    // MARK: - Echo matching

    @Test("Recorded prompts are the typed ones; a sent prompt matches its echo (M L5), notifications never")
    func echoMatch() throws {
        let transcript = try Self.transcript()
        #expect(transcript.recordedPrompts.map(\.offset) == [
            391, 11745, 17354, 24199, 34346, 58245, 65421, 73282, 85786, 92248, 98000,
        ])
        #expect(transcript.recordedPrompts.allSatisfy { $0.entryID?.rawValue.hasPrefix("user:") == true })
        #expect(!transcript.recordedPrompts.contains { $0.text.contains("<task-notification>") })

        // Sent with Heeler's trailing space while the file ended after L4.
        let sent = ClaudeTranscriptReducer.echoKey("Use the Bash tool to run: touch c1.txt ")
        let echo = transcript.recordedPrompts.first { $0.offset >= 391 && ClaudeTranscriptReducer.echoKey($0.text) == sent }
        #expect(echo == ChatRecordedPrompt(
            offset: 391, text: "Use the Bash tool to run: touch c1.txt",
            entryID: ChatEntryID("user:e6fda38c-45bf-49c6-b0a2-5e1cf39cbef9")))
    }

    // MARK: - Subagent and first probe

    private struct SubagentMeta: Decodable {
        var toolUseId: String
        var description: String
    }

    @Test("A subagent file projects on its own and links to the call that launched it")
    func subagent() throws {
        let transcript = try Self.transcript("claude/probe2-subagent.jsonl", role: .subagent)
        #expect(transcript.entries.map(\.id.rawValue) == [
            "user:8f6936f5-8d74-4614-9d04-817d15c9aa6c", "tool:toolu_01NU1YhGEUWFr6hC9FPxWXwB",
            "text:82723790-3667-4f64-ae54-79504aea2337",
        ])
        let bash = try #require(Self.tool("tool:toolu_01NU1YhGEUWFr6hC9FPxWXwB", in: transcript))
        #expect(bash.title == "Create empty file sub.txt")
        #expect(bash.subtitle == "touch sub.txt && echo ok")
        #expect(bash.status == .succeeded)
        #expect(bash.preview == ChatToolPreview(text: "ok", isTruncated: false))
        #expect(transcript.recordedPrompts.isEmpty)

        let meta = try JSONDecoder().decode(SubagentMeta.self, from: try ChatFixture.data("claude/probe2-subagent.meta.json"))
        let main = try Self.transcript()
        #expect(Self.tool("tool:\(meta.toolUseId)", in: main)?.title == meta.description)
    }

    @Test("Only a session's own transcript passes its identity check")
    func fileIdentity() throws {
        let parent = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
        let subagent = ClaudeFileIdentity(lines: try ChatFixture.lines("claude/probe2-subagent.jsonl"))
        #expect(subagent == ClaudeFileIdentity(sessionID: parent, isSubagent: true))
        #expect(!subagent.accepts(sessionID: parent))

        let main = ClaudeFileIdentity(lines: Array(try ChatFixture.lines(Self.probe).prefix(8)))
        #expect(main == ClaudeFileIdentity(sessionID: parent, isSubagent: false))
        #expect(main.accepts(sessionID: parent))
        #expect(!main.accepts(sessionID: "faf3ddf8-b1aa-44b1-8285-b062ad473e0d"))

        // Metadata alone: no chain record yet, accepted on the id.
        let early = ClaudeFileIdentity(lines: Array(try ChatFixture.lines(Self.probe).prefix(3)))
        #expect(early == ClaudeFileIdentity(sessionID: parent, isSubagent: nil))
        #expect(early.accepts(sessionID: parent))
    }

    @Test("The first probe: a folded decline, a recovered dead-end write and an approved plan")
    func firstProbe() throws {
        let transcript = try Self.transcript("claude/probe1-transcript.jsonl")
        #expect(transcript.title == "create-probe-file")
        #expect(transcript.entries.map(\.id.rawValue) == [
            "user:d5b467c5-72ff-4591-b050-a05405730f99", "tool:toolu_016DENbtYUxXC43Q156uCBnp",
            "text:67f6f758-fc0e-4c7c-83cc-7e519bbcc8b1", "user:1608a7f0-bdc5-4bb3-a178-dd7acdf03602",
            "tool:toolu_016cJ6ZzKTvdtJxgTnq1F8Hb", "text:9295f0f3-80ba-4aa1-b5bf-a1b810efdcb4",
            "user:4f88b1a0-6bb7-4376-9fb9-70fbfa99789f", "tool:toolu_01KqwEagr2pAtAz7G4UxDGLa",
            "user:6e491639-58e7-422d-88db-d974b8894744", "tool:toolu_01L2Jps7RPw1kkecazPkfmnJ",
            "text:1636495e-ea3f-4bf8-b248-080c206df7cf", "user:e2041414-9b2e-4b0a-af85-d072d68ab239",
            "think:5ffb0011-cd0c-4104-9f69-a1198c1f411b", "tool:toolu_01N3CaaVqChqSL3YfiV2P7do",
            "tool:toolu_01Q21y7RTXQFSWqz7F7Q8rbB", "tool:toolu_01KMWNja9zpXhUjZLwoiQziJ",
            "tool:toolu_01GU22x86gFdzqAnU4CjTcjy", "text:31d21c52-117c-48b5-9aea-e1e174fa3ea8",
        ])
        #expect(Self.tool("tool:toolu_01KqwEagr2pAtAz7G4UxDGLa", in: transcript)?.status == .declined)
        #expect(!transcript.entries.contains { if case .notice = $0.content { true } else { false } })
        #expect(
            Self.tool("tool:toolu_01L2Jps7RPw1kkecazPkfmnJ", in: transcript)?.questions == [
                ChatQuestion(
                    header: "选择", text: "请选择 A 或 B？",
                    options: [.init(label: "A", detail: "选择 A"), .init(label: "B", detail: "选择 B")], answer: "B")
            ])
        #expect(
            ClaudeSample.entry("think:5ffb0011-cd0c-4104-9f69-a1198c1f411b", in: transcript)
                == .reasoning(ChatReasoning(text: "<redacted>", durationMilliseconds: 661)))
        let write = try #require(Self.tool("tool:toolu_01N3CaaVqChqSL3YfiV2P7do", in: transcript))
        #expect(write.status == .succeeded)
        #expect(write.output == ChatOutputReference(offset: 33942, length: 1236))
        let plan = try #require(Self.plan("tool:toolu_01KMWNja9zpXhUjZLwoiQziJ", in: transcript))
        #expect(plan.status == .succeeded)
        #expect(plan.filePath == "/Users/developer/.claude/plans/plan-creating-a-file-elegant-glade.md")
    }
}
