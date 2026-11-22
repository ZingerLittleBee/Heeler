import Foundation
import SwiftUI
import Testing

@testable import Heeler

@Suite("Antigravity CLI Swarm")
struct AgySwarmTests {
    private static let root = "/home/dev/.gemini/antigravity-cli"
    private static let coordinatorID = "48193a76-cd29-4463-9c08-1cf07508f016"
    private static let workerAID = "83ccc706-d98a-4c67-86d0-94f0b02dede6"
    private static let workerBID = "85fb0bbd-9028-4126-8326-a282415c0407"
    private static let narratorID = "99999999-9999-4000-8000-000000000009"
    private static let baseDate = Date(timeIntervalSince1970: 1_780_000_020)

    private static func line(_ json: String, offset: UInt64 = 0) -> ChatLine {
        ChatLine(offset: offset, data: Data(json.utf8))
    }

    // MARK: - Parser & Roster

    @Test func parsesRosterBoardChannelsMentionsAndExcludesRoleWorkersFromActiveCounts() {
        let rosterJSON = """
            {
              "title": "Auth Audit Swarm",
              "members": {
                "coordinator": {
                  "conversation_id": "\(Self.coordinatorID)",
                  "role": "coordinator",
                  "applied_model": "claude-opus-4-6-thinking-high",
                  "workspace_mode": "inherit",
                  "phase": "WAITING",
                  "wake_mode": "anything",
                  "wait_since": 2,
                  "last_read_seq": 3,
                  "killed": false
                },
                "worker-a": {
                  "conversation_id": "\(Self.workerAID)",
                  "role": "worker",
                  "model": "gemini-3-flash-preview",
                  "workspace_mode": "share",
                  "phase": "WORKING",
                  "wake_mode": "mentions",
                  "wait_since": 1,
                  "last_read_seq": 1,
                  "killed": false
                },
                "worker-b": {
                  "conversation_id": "\(Self.workerBID)",
                  "role": "worker",
                  "desired_model": "gemini-3-flash-preview",
                  "workspace_mode": "branch",
                  "phase": "WAITING",
                  "wake_mode": "mentions",
                  "wait_since": 3,
                  "last_read_seq": 3,
                  "killed": false
                },
                "narrator-1": {
                  "conversation_id": "\(Self.narratorID)",
                  "role": "worker",
                  "model": "gemini-3-flash-preview",
                  "workspace_mode": "inherit",
                  "phase": "WORKING",
                  "wake_mode": "anything",
                  "wait_since": 0,
                  "last_read_seq": 3,
                  "killed": false
                }
              }
            }
            """
        let roster = AgySwarmParser.parseRoster(Data(rosterJSON.utf8))
        #expect(roster?.title == "Auth Audit Swarm")
        #expect(roster?.members.count == 4)

        let boardRaw: [String] = [
            #"{"seq":1,"agent":"coordinator","text":"@worker-a @worker-b audit token validation.","time":"2026-11-17 13:57:05","kind":"brief"}"#,
            #"{"seq":2,"agent":"coordinator","text":"opened #security","time":"2026-11-17 13:57:06","control":{"op":"create","channel":"security","topic":"Auth findings","members":["worker-a","worker-b"]}}"#,
            #"{"seq":3,"agent":"worker-b","text":"@coordinator @#security [done] Verified refresh token expiry.","time":"2026-11-17 13:57:18","channel":"security"}"#,
        ]
        let parsedLines = boardRaw.compactMap { AgySwarmParser.parseBoardLine(Self.line($0)) }
        #expect(parsedLines.count == 3)

        var workerATranscript = AgySwarmMemberTranscript()
        workerATranscript.modificationDate = Self.baseDate
        workerATranscript.apply([
            Self.line(
                #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-17T05:57:10Z","thinking":"**Checking JWT Claims**\nInspecting verifier","tool_calls":[{"name":"read_file","args":{"Path":"\"/repo/Sources/JWT.swift\""}}]}"#
            ),
        ])

        var workerBTranscript = AgySwarmMemberTranscript()
        workerBTranscript.modificationDate = Self.baseDate
        workerBTranscript.apply([
            Self.line(
                #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-17T05:57:18Z","tool_calls":[{"name":"post_message","args":{"message":"\"done\""}},{"name":"swarm_wait","args":{"wake_on":"\"mentions\""}}]}"#
            ),
            Self.line(#"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Posted as #3"}"#),
            Self.line(#"{"step_index":4,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Parked"}"#),
        ])
        #expect(workerBTranscript.isTurnEnded)

        var narratorTranscript = AgySwarmMemberTranscript()
        narratorTranscript.modificationDate = Self.baseDate
        narratorTranscript.apply([
            Self.line(
                #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-17T05:57:19Z","tool_calls":[{"name":"write_file","args":{"Path":"\"/tmp/view.json\""}}]}"#
            ),
        ])
        #expect(!narratorTranscript.isTurnEnded)

        guard let roster else {
            Issue.record("Expected roster to parse")
            return
        }
        let snapshot = AgySwarmParser.buildSnapshot(
            id: Self.coordinatorID,
            roster: roster,
            rawLines: parsedLines,
            transcripts: [
                "worker-a": workerATranscript,
                "worker-b": workerBTranscript,
                "narrator-1": narratorTranscript,
            ],
            overview: nil,
            isLive: true,
            now: Self.baseDate)

        #expect(snapshot.displayTitle == "Auth Audit Swarm")
        #expect(snapshot.postCount == 2)
        #expect(snapshot.channels.map(\.name) == ["security"])
        #expect(snapshot.taskWorkers.map(\.name) == ["worker-a", "worker-b"])
        #expect(snapshot.activeTaskWorkers.map(\.name) == ["worker-a"])
        #expect(snapshot.waitingTaskWorkers.map(\.name) == ["worker-b"])
        #expect(snapshot.holdsActivePace)

        let workerA = snapshot.members.first { $0.name == "worker-a" }
        #expect(workerA?.activity == "Read JWT.swift")
        #expect(workerA?.unread == 1)

        let post3 = snapshot.boardPosts.last
        #expect(post3?.isMarkedDone == true)
        #expect(post3?.mentionsCoordinator == true)
        #expect(post3?.channelMentions == ["security"])
        #expect(snapshot.tickerText == "#3 worker-b → @coordinator @#security: [done] Verified refresh token expiry.")

        // Once worker-a finishes too, narrator-1 still working does NOT hold active pace!
        workerATranscript.apply([
            Self.line(#"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","content":"ok"}"#),
            Self.line(
                #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-17T05:57:22Z","content":"Finished review."}"#
            ),
        ])
        #expect(workerATranscript.isTurnEnded)
        let settled = AgySwarmParser.buildSnapshot(
            id: Self.coordinatorID,
            roster: roster,
            rawLines: parsedLines,
            transcripts: [
                "worker-a": workerATranscript,
                "worker-b": workerBTranscript,
                "narrator-1": narratorTranscript,
            ],
            overview: nil,
            isLive: true,
            now: Self.baseDate)
        #expect(settled.activeTaskWorkers.isEmpty)
        #expect(!settled.holdsActivePace)
    }

    @Test func detectsQuotaFailuresSettledErrorsAndStuckWorkers() {
        let rosterJSON = """
            {
              "title": "Swarm",
              "members": {
                "worker-quota": {
                  "conversation_id": "\(Self.workerAID)",
                  "role": "worker",
                  "phase": "WORKING",
                  "wake_mode": "mentions",
                  "killed": false
                },
                "worker-stuck": {
                  "conversation_id": "\(Self.workerBID)",
                  "role": "worker",
                  "phase": "WORKING",
                  "wake_mode": "mentions",
                  "killed": false
                }
              }
            }
            """
        guard let roster = AgySwarmParser.parseRoster(Data(rosterJSON.utf8)) else {
            Issue.record("Expected roster")
            return
        }

        var quotaTr = AgySwarmMemberTranscript()
        quotaTr.modificationDate = Self.baseDate
        quotaTr.apply([
            Self.line(
                #"{"step_index":2,"source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"429 RESOURCE_EXHAUSTED: You have exhausted your capacity on this model."}"#
            ),
        ])

        var stuckTr = AgySwarmMemberTranscript()
        stuckTr.modificationDate = Self.baseDate.addingTimeInterval(-601)
        stuckTr.apply([
            Self.line(
                #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command","args":{"toolSummary":"\"Long build\""}}]}"#
            ),
        ])

        let snapshot = AgySwarmParser.buildSnapshot(
            id: Self.coordinatorID,
            roster: roster,
            rawLines: [],
            transcripts: ["worker-quota": quotaTr, "worker-stuck": stuckTr],
            overview: nil,
            isLive: true,
            now: Self.baseDate)

        #expect(snapshot.systemAlerts.map(\.kind) == [.quota, .stuck])
        #expect(!snapshot.holdsActivePace)
    }

    @Test func parsesNarratorOverviewAndEnforcesSizeCap() {
        let valid = """
            {
              "as_of_seq": 7,
              "headline": "Both authentication patches passed unit tests.",
              "phase": { "label": "Verification", "index": 3, "total": 4 },
              "attention": [
                { "id": "a1", "kind": "decision", "severity": "high", "title": "Choose token TTL", "why": "15m vs 60m" }
              ],
              "workstreams": [
                { "id": "w1", "title": "JWT Verifier", "owners": ["worker-a"], "state": "done", "note": "Merged" }
              ],
              "milestones": [{ "id": "m1", "text": "Reproduced token replay" }],
              "risks": [{ "id": "r1", "text": "Clock skew on edge nodes" }]
            }
            """
        let overview = AgySwarmParser.parseOverview(Data(valid.utf8))
        #expect(overview?.headline == "Both authentication patches passed unit tests.")
        #expect(overview?.phase?.index == 3)
        #expect(overview?.phase?.total == 4)
        #expect(overview?.attention.count == 1)
        #expect(overview?.workstreams.first?.owners == ["worker-a"])
        #expect(overview?.milestones.count == 1)
        #expect(overview?.risks.count == 1)
        #expect(overview?.asOfSeq == 7)

        let oversized = Data(repeating: 0x20, count: AgySwarmParser.viewMaxBytes + 1)
        #expect(AgySwarmParser.parseOverview(oversized) == nil)
    }

    // MARK: - Locator, Screen, Send Rules & Step Stripping

    @Test func locatorWalksSwarmWorkerWithLeadingBoardWakeupBackToCoordinator() async throws {
        let files = VirtualHostFiles()
        let coordinatorPath = "\(Self.root)/brain/\(Self.coordinatorID)/.system_generated/logs/transcript_full.jsonl"
        let workerPath = "\(Self.root)/brain/\(Self.workerBID)/.system_generated/logs/transcript_full.jsonl"
        let coordinatorRootLine =
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nswarm\n</USER_REQUEST>"}"#
            + "\n"
        await files.write(coordinatorRootLine, at: coordinatorPath)

        // Step 0 is a sibling worker's long `[swarm] new board message` (> 5 KB),
        // and Step 1 is the spawner's `You have just started. Your assignment...`.
        let longBoardMsg = String(repeating: "m", count: 5_500)
        let step0 =
            #"{"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-17T05:57:08Z sender=\#(Self.workerAID) priority=MESSAGE_PRIORITY_LOW content=[swarm] new board message\n\#(longBoardMsg)"}"#
            + "\n"
        let step1 =
            #"{"step_index":1,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-17T05:57:08Z sender=\#(Self.coordinatorID) priority=MESSAGE_PRIORITY_HIGH content=You have just started. Your assignment is posted on the swarm message board:\n#1"}"#
            + "\n"
        await files.write(step0 + step1, at: workerPath)

        let located = try await AgyTranscriptLocator(files: files.hostFiles()).locate(sessionID: Self.workerBID)
        #expect(located == .success(coordinatorPath))
    }

    @Test func screenRecognizesSwarmStatusStripAndSwarmBoardOverlay() {
        let rule = String(repeating: "─", count: 80)
        let idleWithSwarmStrip = ScreenFixture.synthetic([
            "  ● Coordinator waiting for workers",
            rule,
            "> ",
            rule,
            "  ● Swarm(Auth Audit) running",
            "  ● Agent(worker-a) running",
            rule,
            "  ? for shortcuts                  Claude Opus 4.6 · high · 2 subagent(s)",
        ])

        let parsed = AgyScreen(idleWithSwarmStrip)
        #expect(!parsed.showsRunningTasks)
        #expect(parsed.runningTaskStripRows.isEmpty)
        #expect(parsed.below == nil)
        #expect(parsed.footerModel == AgyScreen.FooterModel(model: "Claude Opus 4.6", effort: "high"))
        #expect(!parsed.showsSwarmBoard)
        #expect(InputBoxStateDetector.detect(idleWithSwarmStrip, program: .agy) == .empty(placeholder: nil))

        let boardOpen = ScreenFixture.synthetic([
            "  Swarm board \"Auth Audit\" — 2 working · 1 waiting · #4",
            rule,
            "  #1 coordinator: @worker-a @worker-b investigate",
            "  tab switch pane · j/k scroll · esc back",
        ])
        #expect(AgyScreen(boardOpen).showsSwarmBoard)
        #expect(
            InputBoxStateDetector.detect(boardOpen, program: .agy)
                == .overlay("Antigravity CLI's swarm board is open in the terminal. Press Esc there first."))
    }

    @Test func builtinSkillsAndSwarmSlashSendRulesBehaveAsExpected() {
        let sources = SkillSourceCatalog.sources(for: .antigravity)
        #expect(
            sources.map { "\($0.scope.rawValue):\($0.relativePath)" } == [
                "project:.agents/skills",
                "project:.agents/skills",
                "global:.gemini/antigravity-cli/skills",
                "global:.gemini/config/skills",
                "global:.gemini/antigravity-cli/builtin/skills",
            ])

        let swarmSkill = AgentSkill(
            scope: .global, name: "swarm", description: "Run a swarm", commandPrefix: "/")
        let commands = ChatCommandMenu.commands(skills: [swarmSkill], agentIsIdle: true, program: .agy)
        let rules = ChatSendRules(program: .agy, commands: commands)

        #expect(rules.validate("/swarm audit the auth flow with two workers") == nil)
        guard case .commandUnavailable = rules.validate("/swarm") else {
            Issue.record("Bare /swarm should be refused without prompt text")
            return
        }
        guard case .commandUnavailable = rules.validate("/swarm board") else {
            Issue.record("/swarm board should be refused in Chat")
            return
        }
    }

    @Test func stripsRepeatedTimestampHeadersAndFormatsSwarmToolCalls() {
        let rawLine = Self.line(
            #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Created At: 2026-11-17T13:57:05+08:00\nCompleted At: 2026-11-17T13:57:05+08:00\nCreated At: 2026-11-17T13:57:05+08:00\nCompleted At: 2026-11-17T13:57:05+08:00\nSpawned worker-a (conv-1), posted brief as #1."}"#,
            offset: 200
        )
        let step = AgyStep.decode(rawLine)
        #expect(step?.resultBody == "Spawned worker-a (conv-1), posted brief as #1.")

        var reducer = AgyTranscriptReducer()
        reducer.append([
            Self.line(
                #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\n/swarm audit\n</USER_REQUEST>"}"#,
                offset: 0),
            Self.line(
                #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"swarm","args":{"action":"add","name":"worker-a","workspace":"share","brief":"Check JWT"}},{"name":"swarm_wait","args":{"wake_on":"anything"}}]}"#,
                offset: 100),
            rawLine,
            Self.line(
                #"{"step_index":4,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Parked"}"#,
                offset: 300),
            Self.line(
                #"{"step_index":5,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nFollow up\n</USER_REQUEST>"}"#,
                offset: 400),
        ])
        let transcript = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(transcript.hasSwarmActivity)
        // Parked on `swarm_wait` closes cleanly as `.completed` without a false "Interrupted" notice!
        let notices = transcript.entries.compactMap { entry -> String? in
            guard case .notice(let n) = entry.content else { return nil }
            return n.title
        }
        #expect(!notices.contains("Interrupted"))
    }

    // MARK: - End-to-End Store & Follower Lifecycle

    @MainActor
    @Test func storeFollowsSwarmPromotesWorkingAndLoadsWorkerTranscript() async throws {
        let files = VirtualHostFiles()
        let hostID = UUID(uuidString: "6F1D5C2A-0000-4000-8000-0000000000BB")!
        let coordinatorTranscript =
            "\(Self.root)/brain/\(Self.coordinatorID)/.system_generated/logs/transcript_full.jsonl"
        let swarmDir = "\(Self.root)/brain/\(Self.coordinatorID)/.system_generated/swarm"
        let workerCompact =
            "\(Self.root)/brain/\(Self.workerAID)/.system_generated/logs/transcript.jsonl"
        let workerFull =
            "\(Self.root)/brain/\(Self.workerAID)/.system_generated/logs/transcript_full.jsonl"

        await files.write(
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\n/swarm audit\n</USER_REQUEST>"}"#
                + "\n"
                + #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"swarm","args":{"action":"add","name":"worker-a","brief":"Inspect auth"}},{"name":"swarm_wait","args":{"wake_on":"anything"}}]}"#
                + "\n"
                + #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Spawned worker-a"}"#
                + "\n"
                + #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Parked"}"#
                + "\n",
            at: coordinatorTranscript)

        await files.write(
            """
            {
              "title": "Live Probe Swarm",
              "members": {
                "coordinator": {
                  "conversation_id": "\(Self.coordinatorID)",
                  "role": "coordinator",
                  "phase": "WAITING",
                  "wake_mode": "anything",
                  "killed": false
                },
                "worker-a": {
                  "conversation_id": "\(Self.workerAID)",
                  "role": "worker",
                  "model": "gemini-3-flash-preview",
                  "workspace_mode": "share",
                  "phase": "WORKING",
                  "wake_mode": "mentions",
                  "killed": false
                }
              }
            }
            """,
            at: "\(swarmDir)/members.json")

        await files.write(
            #"{"seq":1,"agent":"coordinator","text":"@worker-a Inspect auth","time":"2026-11-17 14:00:00","kind":"brief"}"#
                + "\n",
            at: "\(swarmDir)/board.jsonl")

        let workerRunningStep =
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command","args":{"toolSummary":"Running auth suite","CommandLine":"pytest auth"}}]}"#
            + "\n"
        await files.write(workerRunningStep, at: workerCompact)
        await files.write(workerRunningStep, at: workerFull)

        let agent = Agent(
            terminalID: "term-agy", kind: ChatProgram.agy.rawValue, title: "", status: .idle,
            workspaceID: "w1", tabID: "t1", paneID: "w1:p1", cwd: "/home/dev/proj", revision: 1,
            agentSession: AgentSessionInfo(
                agent: ChatProgram.agy.sessionNaming.agent, kind: .id,
                source: ChatProgram.agy.sessionNaming.source, value: Self.coordinatorID))

        var reportedRunningChanges: [Bool] = []
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID),
            agent: agent,
            program: .agy,
            source: AgentChatSource(
                hostID: hostID,
                socketLocation: .defaultSession,
                files: files.hostFiles(),
                agentInfo: { agent },
                cache: VolatileChatTranscriptCache(),
                adapter: .agy,
                onRunningBackgroundWorkChanged: { reportedRunningChanges.append($0) }),
            now: { Self.baseDate })

        await store.step()

        #expect(store.agySwarm?.displayTitle == "Live Probe Swarm")
        #expect(store.agySwarm?.activeTaskWorkers.map(\.name) == ["worker-a"])
        #expect(store.hasRunningBackgroundWork)
        #expect(reportedRunningChanges == [true])

        // Verify worker full transcript peek loads cleanly (fork divider + tool step)!
        let peek = await store.loadSwarmWorkerTranscript(conversationID: Self.workerAID, isWorking: true)
        guard case .success(let workerTranscript) = peek else {
            Issue.record("Expected worker transcript to load, got \(peek)")
            return
        }
        #expect(workerTranscript.entries.count == 2)

        // Worker finishes its turn on `swarm_wait` (`DONE`): active pace clears!
        let workerParked =
            workerRunningStep
            + #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Command exited with code 0.\nCommand output:\nOK"}"#
            + "\n"
            + #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"swarm_wait","args":{"wake_on":"mentions"}}]}"#
            + "\n"
            + #"{"step_index":5,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Parked"}"#
            + "\n"
        await files.write(workerParked, at: workerCompact)

        await store.step()

        #expect(store.agySwarm?.activeTaskWorkers.isEmpty == true)
        #expect(store.agySwarm?.waitingTaskWorkers.map(\.name) == ["worker-a"])
        #expect(!store.hasRunningBackgroundWork)
        #expect(reportedRunningChanges == [true, false])
    }

    @Test func boardDoneAndStallTagsRequireLeadingPositionAndNonBrief() throws {
        let rawLines = [
            #"{"seq":1,"agent":"coordinator","kind":"brief","text":"@worker-a [done] Reply starting with '@coordinator [done]'."}"#,
            #"{"seq":2,"agent":"coordinator","text":"Please reply starting with '@coordinator [done]' once finished."}"#,
            #"{"seq":3,"agent":"worker-a","text":"@coordinator [done] Audit finished cleanly."}"#,
            #"{"seq":4,"agent":"coordinator","text":"[DONE] All workers finished."}"#,
            #"{"seq":5,"agent":"monitor","text":"@worker-b [stall] No post since #1."}"#,
        ].compactMap { AgySwarmParser.parseBoardLine(Self.line($0)) }

        let roster = try #require(AgySwarmParser.parseRoster(Data(#"{"title":"Tag Test","members":{}}"#.utf8)))
        let snapshot = AgySwarmParser.buildSnapshot(
            id: Self.coordinatorID,
            roster: roster,
            rawLines: rawLines,
            transcripts: [:],
            overview: nil,
            isLive: true,
            now: Self.baseDate)
        let messages = snapshot.messages
        #expect(messages.count == 5)
        #expect(!messages[0].isMarkedDone)
        #expect(!messages[1].isMarkedDone)
        #expect(messages[2].isMarkedDone)
        #expect(messages[3].isMarkedDone)
        #expect(messages[4].isMarkedStall)
    }

    // MARK: - Large Swarm Board Recycling & Incremental Updates

    @Test func followerKeepsBoardRevisionStableAcrossWorkerTicksAndAppendsIncrementally() async throws {
        let files = VirtualHostFiles()
        let swarmDir = "\(Self.root)/brain/\(Self.coordinatorID)/.system_generated/swarm"
        let workerCompact = "\(Self.root)/brain/\(Self.workerAID)/.system_generated/logs/transcript.jsonl"

        await files.write(
            """
            {
              "title": "Large Design Swarm",
              "members": {
                "coordinator": { "conversation_id": "\(Self.coordinatorID)", "role": "coordinator", "wake_mode": "anything" },
                "worker-1": { "conversation_id": "\(Self.workerAID)", "role": "worker", "wake_mode": "mentions", "last_read_seq": 1 },
                "worker-2": { "conversation_id": "\(Self.workerBID)", "role": "worker", "wake_mode": "mentions", "last_read_seq": 2 }
              }
            }
            """,
            at: "\(swarmDir)/members.json")

        let initialBoard = (1...30).map { seq in
            #"{"seq":\#(seq),"agent":"worker-\#((seq % 2) + 1)","text":"@coordinator @worker-1 Verified module \#(seq) after #\#(max(1, seq - 1)).","time":"2026-11-18 11:57:\#(String(format: "%02d", seq % 60))"}"#
        }.joined(separator: "\n") + "\n"
        await files.write(initialBoard, at: "\(swarmDir)/board.jsonl")
        await files.write(
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"read_file","args":{"Path":"\"/repo/A.swift\""}}]}"#
                + "\n",
            at: workerCompact)

        var follower = AgySwarmFollower()
        let snap1 = try #require(
            await follower.poll(
                root: Self.root,
                coordinatorID: Self.coordinatorID,
                hasSwarmHint: true,
                files: files.hostFiles(),
                at: Self.baseDate,
                isCancellation: { _ in false }))
        #expect(snap1.postCount == 30)
        #expect(snap1.boardPosts.last?.citedSeqs(in: snap1.knownPostSeqs) == [29])
        #expect(snap1.boardPosts.last?.displayTime == "11:57")
        #expect(snap1.boardPosts.last?.timestamp != nil)
        let initialRev = snap1.boardRevision

        // Worker advances steps without touching `board.jsonl`: `boardRevision` must not bump!
        await files.write(
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"read_file","args":{"Path":"\"/repo/A.swift\""}}]}"#
                + "\n"
                + #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"read_file","args":{"Path":"\"/repo/B.swift\""}}]}"#
                + "\n",
            at: workerCompact)
        let snap2 = try #require(
            await follower.poll(
                root: Self.root,
                coordinatorID: Self.coordinatorID,
                hasSwarmHint: true,
                files: files.hostFiles(),
                at: Self.baseDate.addingTimeInterval(1),
                isCancellation: { _ in false }))
        #expect(snap2.boardRevision == initialRev)
        #expect(snap2.members.first(where: { $0.name == "worker-1" })?.steps == 3)

        // Append post #31: `boardRevision` advances cleanly and unread counts update!
        let appended = initialBoard
            + #"{"seq":31,"agent":"coordinator","text":"@worker [done] Consolidated #30 findings.","time":"2026-11-18 12:01:09"}"#
            + "\n"
        await files.write(appended, at: "\(swarmDir)/board.jsonl")
        let snap3 = try #require(
            await follower.poll(
                root: Self.root,
                coordinatorID: Self.coordinatorID,
                hasSwarmHint: true,
                files: files.hostFiles(),
                at: Self.baseDate.addingTimeInterval(2),
                isCancellation: { _ in false }))
        #expect(snap3.boardRevision > initialRev)
        #expect(snap3.postCount == 31)
        #expect(snap3.boardPosts.last?.mentions == ["worker-1", "worker-2"])
        #expect(snap3.boardPosts.last?.isMarkedDone == true)
    }

    // MARK: - Compact Directory & Post Detail Presentation

    @Test func boardMessageComputesLineCountAndCompactPreviewThresholds() {
        let shortSingle = AgySwarmSnapshot.BoardMessage(
            seq: 1, agent: "worker-a", text: "确认一下：CAP_TAILSCALE 用 bit 11 对吗？",
            time: "2026-11-21 18:38:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(shortSingle.lineCount == 1)
        #expect(!shortSingle.isLongPost)

        let shortTwoLines = AgySwarmSnapshot.BoardMessage(
            seq: 2, agent: "coordinator", text: "收到。\n请同步更新文档。\n",
            time: "2026-11-21 18:39:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(shortTwoLines.lineCount == 2)
        #expect(!shortTwoLines.isLongPost)

        let threeLineList = AgySwarmSnapshot.BoardMessage(
            seq: 3, agent: "worker-a", text: "- item 1\n- item 2\n- item 3",
            time: "2026-11-21 18:40:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(threeLineList.lineCount == 3)
        #expect(threeLineList.isLongPost)

        let longSingleLine = AgySwarmSnapshot.BoardMessage(
            seq: 4, agent: "worker-a",
            text: String(repeating: "a", count: 140),
            time: "2026-11-21 18:41:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(longSingleLine.lineCount == 1)
        #expect(longSingleLine.isLongPost)

        let fencedCode = AgySwarmSnapshot.BoardMessage(
            seq: 5, agent: "worker-a", text: "```sh\nls\n```",
            time: "2026-11-21 18:42:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(fencedCode.isLongPost)

        let empty = AgySwarmSnapshot.BoardMessage(
            seq: 6, agent: "worker-a", text: "",
            time: "2026-11-21 18:43:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        #expect(empty.lineCount == 0)
        #expect(!empty.isLongPost)
    }

    @Test func boardFilterOptionsAndMatchingCoverChannelsStatusAndAuthors() throws {
        let rosterJSON = """
            {
              "title": "Tailscale Support",
              "members": {
                "coordinator": { "conversation_id": "\(Self.coordinatorID)", "role": "coordinator", "wake_mode": "anything" },
                "backend-worker": { "conversation_id": "\(Self.workerAID)", "role": "worker", "wake_mode": "mentions" },
                "docs-worker": { "conversation_id": "\(Self.workerBID)", "role": "worker" }
              }
            }
            """
        let roster = try #require(AgySwarmParser.parseRoster(Data(rosterJSON.utf8)))
        let rawLines = [
            #"{"seq":1,"agent":"coordinator","kind":"brief","text":"@backend-worker Implement Tailscale socket support."}"#,
            #"{"seq":2,"agent":"coordinator","text":"opened #docs","control":{"op":"create","channel":"docs","topic":"Bilingual guides","members":["docs-worker"]}}"#,
            #"{"seq":3,"agent":"backend-worker","text":"@coordinator [done] Socket auth implemented."}"#,
            #"{"seq":4,"agent":"docs-worker","channel":"docs","text":"@coordinator [stall] Waiting on env var list."}"#,
        ].compactMap { AgySwarmParser.parseBoardLine(Self.line($0)) }

        let snapshot = AgySwarmParser.buildSnapshot(
            id: Self.coordinatorID,
            roster: roster,
            rawLines: rawLines,
            transcripts: [:],
            overview: nil,
            isLive: true,
            now: Self.baseDate)

        let options = ChatSwarmBoardFilter.options(in: snapshot)
        #expect(
            options.map(\.filter) == [
                .all,
                .channel("main"),
                .channel("docs"),
                .done,
                .stall,
                .author("coordinator"),
                .author("docs-worker"),
                .author("backend-worker"),
            ])
        #expect(options.first(where: { $0.filter == .done })?.count == 1)
        #expect(options.first(where: { $0.filter == .stall })?.count == 1)

        #expect(snapshot.boardPosts.filter { ChatSwarmBoardFilter.done.matches($0) }.map(\.seq) == [3])
        #expect(snapshot.boardPosts.filter { ChatSwarmBoardFilter.stall.matches($0) }.map(\.seq) == [4])
        #expect(snapshot.boardPosts.filter { ChatSwarmBoardFilter.channel("docs").matches($0) }.map(\.seq) == [4])
        #expect(snapshot.boardPosts.filter { ChatSwarmBoardFilter.author("backend-worker").matches($0) }.map(\.seq) == [3])
    }

    @MainActor
    @Test func boardModelBuildsCompactDirectoryRowsAndParsesDetailBlocksOnDemand() async {
        let shortPost = AgySwarmSnapshot.BoardMessage(
            seq: 1, agent: "coordinator", text: "Short question?",
            time: "2026-11-21 18:40:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        let citedShortPost = AgySwarmSnapshot.BoardMessage(
            seq: 2, agent: "worker-a", text: "See #1 for context.",
            time: "2026-11-21 18:41:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)
        let longPost = AgySwarmSnapshot.BoardMessage(
            seq: 3, agent: "worker-b", text: "- Line 1\n- Line 2\n- Line 3\n- Line 4",
            time: "2026-11-21 18:42:00", timestamp: nil, channel: "main",
            isBrief: false, isControl: false, mentions: [], channelMentions: [], mentionsAll: false)

        let model = ChatSwarmBoardModel()
        let state = model.buildState(
            swarmID: Self.coordinatorID,
            filter: .all,
            posts: [shortPost, citedShortPost, longPost],
            knownSeqs: [1, 2, 3],
            highlightedSeq: 3)

        #expect(state.items.count == 3)
        #expect(state.items[0].payload.isFirst)
        #expect(!state.items[0].payload.isLast)
        #expect(!state.items[0].payload.opensDetail)

        #expect(!state.items[1].payload.isFirst)
        #expect(!state.items[1].payload.isLast)
        #expect(state.items[1].payload.opensDetail)
        #expect(state.items[1].payload.citedSeqs == [1])

        #expect(!state.items[2].payload.isFirst)
        #expect(state.items[2].payload.isLast)
        #expect(state.items[2].payload.opensDetail)
        #expect(state.items[2].payload.isHighlighted)

        #expect(model.parsedBlocks(for: 3, text: longPost.text) == nil)
        model.ensureBlocks(swarmID: Self.coordinatorID, posts: [longPost])
        await model.settled()
        #expect(model.parsedBlocks(for: 3, text: longPost.text)?.isEmpty == false)
    }

    @MainActor
    @Test func workerModelCollapsesLongRepliesAndParsesMarkdownOnlyWhenExpanded() async {
        let shortReply = ChatEntry(
            id: ChatEntryID("short-assistant"),
            sourceOffset: 100,
            content: .assistant(ChatAssistantMessage(text: "Done in 2 lines.\nTests pass.")))
        let longText = (1...12).map { "- Changed module \($0)" }.joined(separator: "\n")
        let longReply = ChatEntry(
            id: ChatEntryID("long-assistant"),
            sourceOffset: 200,
            content: .assistant(ChatAssistantMessage(text: longText)))
        let longUser = ChatEntry(
            id: ChatEntryID("long-user"),
            sourceOffset: 0,
            content: .user(ChatUserMessage(text: (1...8).map { "Line \($0)" }.joined(separator: "\n"))))

        let entries = [longUser, shortReply, longReply]
        let model = ChatSwarmWorkerModel()
        model.ensureBlocks(
            memberName: "docs-worker",
            assignment: nil,
            isAssignmentExpanded: false,
            entries: entries,
            expandedEntries: [])
        await model.settled()

        let collapsedState = model.buildState(
            memberName: "docs-worker",
            member: nil,
            assignment: nil,
            isAssignmentExpanded: false,
            isLoading: false,
            failureMessage: nil,
            entries: entries,
            expandedEntries: [])

        #expect(collapsedState.items.count == 3)
        if case .entry(_, let isCollapsible, let lines, let isExpanded, _) = collapsedState.items[0].payload {
            #expect(isCollapsible)
            #expect(lines == 8)
            #expect(!isExpanded)
        } else {
            Issue.record("Expected long user entry")
        }
        if case .entry(_, let isCollapsible, _, _, let blocks) = collapsedState.items[1].payload {
            #expect(!isCollapsible)
            #expect(blocks?.isEmpty == false)
        } else {
            Issue.record("Expected short assistant entry")
        }
        if case .entry(_, let isCollapsible, let lines, let isExpanded, let blocks) = collapsedState.items[2].payload {
            #expect(isCollapsible)
            #expect(lines == 12)
            #expect(!isExpanded)
            #expect(blocks == nil)
        } else {
            Issue.record("Expected collapsed long assistant entry")
        }

        // Expanding the long reply triggers off-main-actor Markdown parsing.
        let expanded: Set<ChatEntryID> = [longReply.id]
        model.ensureBlocks(
            memberName: "docs-worker",
            assignment: nil,
            isAssignmentExpanded: false,
            entries: entries,
            expandedEntries: expanded)
        await model.settled()

        let expandedState = model.buildState(
            memberName: "docs-worker",
            member: nil,
            assignment: nil,
            isAssignmentExpanded: false,
            isLoading: false,
            failureMessage: nil,
            entries: entries,
            expandedEntries: expanded)
        if case .entry(_, let isCollapsible, _, let isExpanded, let blocks) = expandedState.items[2].payload {
            #expect(isCollapsible)
            #expect(isExpanded)
            #expect(blocks?.isEmpty == false)
        } else {
            Issue.record("Expected expanded long assistant entry")
        }
    }
}
