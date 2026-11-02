import Foundation
import Testing

@testable import Heeler

/// A `heeler.chat` label against what a check of the Agent's process finds
/// (ADR 0034), for each program whose exact evidence can be missing.
@Suite("herdr-core Chat pick, binder")
struct HerdrCoreChatPickBinderTests {
    private static let uuid = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let other = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let openCodeID = "ses_e6a000000001Abcdefghijklmn"
    private static let home = "/home/dev"
    private static let pid = 40
    private static let start = "145585"

    private static func label(session: String = uuid, file: String? = nil, pid: Int = pid, start: String = start) -> String {
        HerdrCoreSessionHint.pickLabelValue(session: session, file: file, pid: pid, start: start) ?? ""
    }

    private static func record(_ program: ChatProgram, labels: [String: String]) throws -> HerdrCoreTerminalRecord {
        let name = JSONValue.string(program.rawValue)
        let value = JSONValue.object([
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([name]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(Double(pid)),
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(Double(pid)), "name": name, "argv": .array([name]), "cwd": .string("/work/app"),
            ]),
        ])
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(value))
    }

    private actor LabelLog {
        var cleared: [String] = []
        func clear(_ names: [String]) { cleared += names }
    }

    private struct Rig {
        let program: ChatProgram
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: home)
        let log = LabelLog()
        var droppedPicks: Set<String> = []

        init(_ program: ChatProgram) async {
            self.program = program
            await table.add(
                ScriptedProcessTable.Process(
                    pid: HerdrCoreChatPickBinderTests.pid, name: program.rawValue, start: HerdrCoreChatPickBinderTests.start,
                    environment: ["HC_SCOPE": "scope", "HOME": home]))
        }

        var binder: HerdrCoreSessionBinder {
            let table = table
            let log = log
            let droppedPicks = droppedPicks
            return HerdrCoreSessionBinder(
                program: program,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { await log.clear($0.keys.sorted()) },
                isDroppedPick: { droppedPicks.contains($0) })
        }
    }

    private static func root(_ program: ChatProgram) -> String? {
        switch program {
        case .claude: "\(home)/.claude"
        case .codex: "\(home)/.codex"
        case .grok: "\(home)/.grok"
        case .pi: "\(home)/.pi/agent/sessions"
        case .omp: "\(home)/.omp/agent/sessions"
        case .opencode: nil
        }
    }

    private nonisolated static let programs: [ChatProgram] = [.claude, .codex, .grok, .opencode, .pi, .omp]

    private static func conversation(_ program: ChatProgram) -> String {
        program == .opencode ? openCodeID : uuid
    }

    // MARK: Adopting

    @Test(arguments: programs)
    func aLabelForThisProcessBindsAsAPick(_ program: ChatProgram) async throws {
        let rig = await Rig(program)
        let labels = ["heeler.chat": Self.label(session: Self.conversation(program))]

        let evidence = try await rig.binder.check(try Self.record(program, labels: labels))

        #expect(evidence == .picked(sessionID: Self.conversation(program), transcriptRoot: Self.root(program)))
        #expect(await rig.log.cleared.isEmpty)
    }

    @Test func aPiLabelWithAFileBindsThatFile() async throws {
        let rig = await Rig(.pi)
        let file = "\(Self.home)/.pi/agent/sessions/--work-app--/2026-11-01T07-19-26-219Z_\(Self.uuid).jsonl"

        let evidence = try await rig.binder.check(
            try Self.record(.pi, labels: ["heeler.chat": Self.label(file: file)]))

        #expect(evidence == .picked(sessionID: file, transcriptRoot: Self.root(.pi)))
    }

    // MARK: Dropping

    @Test(arguments: programs)
    func aLabelLeftByAnEarlierProcessIsIgnoredAndCleared(_ program: ChatProgram) async throws {
        for label in [
            Self.label(session: Self.conversation(program), pid: 9),
            Self.label(session: Self.conversation(program), start: "111"),
        ] {
            let rig = await Rig(program)

            let evidence = try await rig.binder.check(try Self.record(program, labels: ["heeler.chat": label]))

            #expect(evidence == .unavailable(.cannotTellSession(program)))
            #expect(await rig.log.cleared == ["heeler.chat"])
        }
    }

    /// Pi and Oh My Pi find no agent under a shell, so the label's own process is
    /// what says it left.
    @Test func aPiLabelIsClearedOnceAShellHasTheForeground() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(
                pid: Self.pid, name: "bash", start: "999", environment: ["HC_SCOPE": "scope", "HOME": Self.home]))
        let log = LabelLog()
        let binder = HerdrCoreSessionBinder(
            program: .pi, processes: { try await table.read($0) }, files: VirtualHostFiles(home: Self.home).hostFiles(),
            clearLabels: { await log.clear($0.keys.sorted()) })

        let evidence = try await binder.check(try Self.record(.pi, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
        #expect(await log.cleared == ["heeler.chat"])
    }

    /// The projection says which values these are, for as long as the core may hold them.
    @Test func aPickStillMarkedDroppedIsClearedAgainAndNotAdopted() async throws {
        var rig = await Rig(.grok)
        rig.droppedPicks = [Self.label()]

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    @Test func aSessionLabelFromThisProcessDropsThePickAndBinds() async throws {
        let rig = await Rig(.opencode)
        let session = #"{"session":"ses_e6a000000002Abcdefghijklmn","pid":40,"start":"145585"}"#

        let evidence = try await rig.binder.check(
            try Self.record(
                .opencode, labels: ["heeler.chat": Self.label(session: Self.openCodeID), "heeler.session": session]))

        #expect(evidence == .bound(sessionID: "ses_e6a000000002Abcdefghijklmn", transcriptRoot: nil, directory: nil))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    /// Grok Build reads no session label as evidence, and the signal still counts.
    @Test func aSessionLabelDropsThePickOfAProgramThatDoesNotBindFromIt() async throws {
        let rig = await Rig(.grok)
        let session = #"{"session":"\#(Self.other)","pid":40,"start":"145585"}"#

        let evidence = try await rig.binder.check(
            try Self.record(.grok, labels: ["heeler.chat": Self.label(), "heeler.session": session]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    /// A label for an earlier process says nothing about this one.
    @Test func aSessionLabelFromAnotherProcessKeepsThePick() async throws {
        let rig = await Rig(.opencode)
        let session = #"{"session":"ses_e6a000000002Abcdefghijklmn","pid":9,"start":"1"}"#

        let evidence = try await rig.binder.check(
            try Self.record(
                .opencode, labels: ["heeler.chat": Self.label(session: Self.openCodeID), "heeler.session": session]))

        #expect(evidence == .picked(sessionID: Self.openCodeID, transcriptRoot: nil))
        #expect(await rig.log.cleared == ["heeler.session"])
    }

    @Test func exactEvidenceTakesOverFromAPick() async throws {
        let rig = await Rig(.grok)
        await rig.files.write(
            #"[{"session_id":"\#(Self.other)","pid":40,"pid_start":145585,"cwd":"/work/app"}]"#,
            at: "\(Self.home)/.grok/active_sessions.json")

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .bound(sessionID: Self.other, transcriptRoot: "\(Self.home)/.grok", directory: "/work/app"))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    /// Codex on its shared daemon gets no binding of its own, pick included.
    @Test func aPickDoesNotBindACodexOnTheSharedDaemon() async throws {
        let rig = await Rig(.codex)
        await rig.table.add(
            ScriptedProcessTable.Process(
                pid: 41, parent: Self.pid, name: "codex", start: "2",
                environment: ["HC_SCOPE": "scope", "HOME": Self.home], argv: ["app-server", "--managed-daemon"]))

        let evidence = try await rig.binder.check(try Self.record(.codex, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .unavailable(.codexSharedDaemon))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    @Test(arguments: ["not json", #"{"session":"\#(uuid)","pid":40}"#])
    func aLabelThatIsNoPickIsCleared(_ value: String) async throws {
        let rig = await Rig(.grok)

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: ["heeler.chat": value]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    @Test(arguments: [ChatProgram.grok, .opencode, .claude, .pi])
    func aLabelWhoseSessionIsNoIdForThisProgramIsCleared(_ program: ChatProgram) async throws {
        let rig = await Rig(program)

        let evidence = try await rig.binder.check(
            try Self.record(program, labels: ["heeler.chat": Self.label(session: "../../etc/passwd")]))

        #expect(evidence == .unavailable(.cannotTellSession(program)))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    // MARK: A check that cannot say

    /// Nothing here says the pick is wrong, so its label stays and a Chat following it
    /// keeps the conversation.
    @Test func aPickWithNoScopeToFollowIsUnconfirmedAndKept() async throws {
        let rig = await Rig(.grok)
        await rig.table.remove(Self.pid)

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared.isEmpty)
    }

    @Test func noPickWithNoScopeToFollowIsPlainCannotTell() async throws {
        let rig = await Rig(.grok)
        await rig.table.remove(Self.pid)

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: [:]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
    }

    /// A value a guard dropped does not stand, whatever the check can see.
    @Test func aDroppedPickWithNoScopeToFollowIsPlainCannotTell() async throws {
        var rig = await Rig(.grok)
        rig.droppedPicks = [Self.label()]
        await rig.table.remove(Self.pid)

        let evidence = try await rig.binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
    }

    @Test func aPickWhoseAgentCannotBeToldIsUnconfirmedAndKept() async throws {
        let table = ScriptedProcessTable()
        let scope = ["HC_SCOPE": "scope", "HOME": Self.home]
        await table.add(ScriptedProcessTable.Process(pid: Self.pid, name: "bash", start: Self.start, environment: scope))
        for pid in [41, 42] {
            await table.add(
                ScriptedProcessTable.Process(pid: pid, parent: Self.pid, name: "grok", start: "2", environment: scope))
        }
        let log = LabelLog()
        let binder = HerdrCoreSessionBinder(
            program: .grok, processes: { try await table.read($0) },
            files: VirtualHostFiles(home: Self.home).hostFiles(), clearLabels: { await log.clear($0.keys.sorted()) })

        let evidence = try await binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(.grok)))
        #expect(await log.cleared.isEmpty)
    }

    @Test func aPickWhoseProcessCannotSayWhereItsTranscriptsAreIsUnconfirmedAndKept() async throws {
        let table = ScriptedProcessTable()
        await table.add(
            ScriptedProcessTable.Process(pid: Self.pid, name: "grok", start: Self.start, environment: ["HC_SCOPE": "scope"]))
        let log = LabelLog()
        let binder = HerdrCoreSessionBinder(
            program: .grok, processes: { try await table.read($0) },
            files: VirtualHostFiles(home: Self.home).hostFiles(), clearLabels: { await log.clear($0.keys.sorted()) })

        let evidence = try await binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(.grok)))
        #expect(await log.cleared.isEmpty)
    }

    /// The exec's answer when the foreground has more descendants than the walk
    /// lists: `W <root> -` and no `T` lines, so the requested processes alone and
    /// none of their names.
    private static func readPastTheWalkCap(
        _ request: HostProcessReader.Request, start: String = start
    ) throws -> [String: HostProcessReader.Facts] {
        func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
        let nonce = "0123456789abcdef01234567"
        let values = ["HC_SCOPE": "scope", "HOME": home]
        var lines = ["__HEELER_PROC_BEGIN_\(nonce)"]
        for pid in request.pids {
            lines += ["S \(pid) \(start)", "E \(pid) ok", "O \(pid) ok", "B \(pid) ok"]
            lines += request.valuesOf.compactMap { name in values[name].map { "V \(pid) \(name) \(hex($0))" } }
        }
        lines += ["W \(request.descendantsOf ?? "") -", "__HEELER_PROC_END_\(nonce)", ""]
        return try HostProcessReader.parse(
            stdout: Data(lines.joined(separator: "\n").utf8), nonce: nonce, request: request)
    }

    /// An Agent behind a launcher is out of a walk past its cap's sight, not gone.
    @Test(arguments: programs)
    func aPickBehindALauncherStandsWhenTheWalkIsPastItsCap(_ program: ChatProgram) async throws {
        let rig = await Rig(program)
        var binder = rig.binder
        binder.processes = { try Self.readPastTheWalkCap($0) }
        let label = Self.label(session: Self.conversation(program), pid: 41, start: "2")

        let evidence = try await binder.check(try Self.record(program, labels: ["heeler.chat": label]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(program)))
        #expect(await rig.log.cleared.isEmpty)
    }

    /// The walk says nothing about the processes the exec names itself.
    @Test func aForegroundOfAnotherStartDropsThePickWhenTheWalkIsPastItsCap() async throws {
        let rig = await Rig(.grok)
        var binder = rig.binder
        binder.processes = { try Self.readPastTheWalkCap($0, start: "999") }

        let evidence = try await binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .unavailable(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    @Test func aPickOnTheForegroundBindsWhenTheWalkIsPastItsCap() async throws {
        let rig = await Rig(.grok)
        var binder = rig.binder
        binder.processes = { try Self.readPastTheWalkCap($0) }

        let evidence = try await binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .picked(sessionID: Self.uuid, transcriptRoot: "\(Self.home)/.grok"))
        #expect(await rig.log.cleared.isEmpty)
    }

    /// A process whose start cannot be read may have changed or may not.
    @Test func aPickWhoseStartCannotBeReadIsUnconfirmedAndKept() async throws {
        let rig = await Rig(.grok)
        var binder = rig.binder
        let table = rig.table
        binder.processes = { request in
            var facts = try await table.read(request)
            facts[String(Self.pid)]?.start = .unavailable
            return facts
        }

        let evidence = try await binder.check(try Self.record(.grok, labels: ["heeler.chat": Self.label()]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(.grok)))
        #expect(await rig.log.cleared.isEmpty)
    }

    /// The label is read after the exec, as session labels are.
    @Test func aPickWrittenDuringTheExecBinds() async throws {
        let rig = await Rig(.grok)
        var binder = rig.binder
        let label = Self.label()
        binder.currentLabels = { ["heeler.chat": label] }

        let evidence = try await binder.check(try Self.record(.grok, labels: [:]))

        #expect(evidence == .picked(sessionID: Self.uuid, transcriptRoot: "\(Self.home)/.grok"))
    }

    @Test func aCheckWithAPickCostsOneExec() async throws {
        let rig = await Rig(.opencode)

        _ = try await rig.binder.check(
            try Self.record(.opencode, labels: ["heeler.chat": Self.label(session: Self.openCodeID)]))

        #expect(await rig.table.requests.count == 1)
    }

    // MARK: Candidates of each program

    private static func list(_ rig: Rig, record: HerdrCoreTerminalRecord? = nil) async throws -> ChatSessionCandidates {
        var binder = rig.binder
        binder.now = { Date(timeIntervalSince1970: 1_791_288_000) }
        let answer = try await binder.candidates(of: try record ?? Self.record(rig.program, labels: [:]))
        guard case .listed(let list) = answer else {
            Issue.record("expected a list, read \(answer)")
            throw CancellationError()
        }
        return list
    }

    private static func holding(_ rig: Rig, _ files: [String]) async {
        await rig.table.add(
            ScriptedProcessTable.Process(
                pid: pid, name: rig.program.rawValue, start: start,
                environment: ["HC_SCOPE": "scope", "HOME": home], openFiles: files))
    }

    @Test func claudeCodeListsItsHeldAndRecentTranscripts() async throws {
        let rig = await Rig(.claude)
        let folder = "\(Self.home)/.claude/projects/-work-app"
        await rig.files.write("{}\n", at: "\(folder)/\(Self.other).jsonl")
        await rig.files.write("{}\n", at: "\(folder)/\(Self.uuid).jsonl")
        await rig.files.write("", at: "\(folder)/11111111-1111-4111-8111-111111111111.jsonl")
        await Self.holding(rig, ["\(folder)/\(Self.other).jsonl", "\(folder)/\(Self.other)/subagents/agent-1.jsonl"])

        let list = try await Self.list(rig)

        #expect(list.transcriptRoot == "\(Self.home)/.claude")
        #expect(list.candidates.map(\.sessionID) == [Self.other, Self.uuid])
        #expect(list.candidates.map(\.origins) == [[.heldOpen, .recentTranscript], [.recentTranscript]])
        #expect(list.candidates.allSatisfy { $0.file == nil })
    }

    /// A long directory's folder ends in a hash that differs by how Claude Code was
    /// built, so its folder goes by the key's prefix, as when a Transcript is read.
    @Test func claudeCodeListsTheRecentTranscriptsOfALongDirectoryWhateverItsHash() async throws {
        let rig = await Rig(.claude)
        let directory = "/work/" + String(repeating: "a", count: 250)
        let prefix = try #require(ClaudeProjectKey.longKeyPrefix(forDirectory: directory))
        await rig.files.write("{}\n", at: "\(Self.home)/.claude/projects/\(prefix)bunhash1/\(Self.uuid).jsonl")
        let name = JSONValue.string("claude")
        let record = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self,
            from: try JSONEncoder().encode(
                JSONValue.object([
                    "address": .string("t1"), "cwd": .string(directory), "state": .string("live"),
                    "argv": .array([name]), "keep": .bool(false), "title": .string(""),
                    "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
                    "pid": .number(Double(Self.pid)),
                    "foreground": .object([
                        "pid": .number(Double(Self.pid)), "name": name, "argv": .array([name]), "cwd": .string(directory),
                    ]),
                ])))

        let list = try await Self.list(rig, record: record)

        #expect(list.candidates.map(\.sessionID) == [Self.uuid])
        #expect(list.candidates.first?.origins == [.recentTranscript])
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func thePiFamilyListsSessionFilesByTheirFile(_ program: ChatProgram) async throws {
        let rig = await Rig(program)
        let root = try #require(Self.root(program))
        let file = "\(root)/--work-app--/2026-11-01T07-19-26-219Z_\(Self.uuid).jsonl"
        await rig.files.write("{}\n", at: file)

        let list = try await Self.list(rig)

        let candidate = try #require(list.candidates.first)
        #expect(list.candidates.count == 1)
        #expect(candidate.sessionID == Self.uuid)
        #expect(candidate.file == file)
        #expect(candidate.conversationID == file)
    }

    /// A confirmed file is what the next check reads, so the label names it.
    @Test func aPiCandidatesLabelBindsItsFile() async throws {
        let rig = await Rig(.pi)
        let file = "\(Self.home)/.pi/agent/sessions/--work-app--/2026-11-01T07-19-26-219Z_\(Self.uuid).jsonl"
        await rig.files.write("{}\n", at: file)
        let list = try await Self.list(rig)
        let candidate = try #require(list.candidates.first)

        let label = HerdrCoreSessionHint.pickLabelValue(
            session: candidate.sessionID, file: candidate.file, pid: list.pid, start: list.start)
        let evidence = try await rig.binder.check(
            try Self.record(.pi, labels: ["heeler.chat": try #require(label)]))

        #expect(evidence == .picked(sessionID: file, transcriptRoot: Self.root(.pi)))
    }

    /// Codex files rollouts by day, and only its head says where one started.
    @Test func codexListsRolloutsThatStartedInTheDirectory() async throws {
        let fixture = try ChatFixture.text("codex/probe1-rollout.jsonl")
        let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
        #expect(fixture.contains(thread))
        let rig = await Rig(.codex)
        let folder = "\(Self.home)/.codex/sessions/2026/10/06"
        let name = "rollout-2026-10-06T12-45-25-\(thread).jsonl"
        await rig.files.write(fixture, at: "\(folder)/\(name)")
        let directory = try #require(
            fixture.split(separator: "\n").first.flatMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["payload"]?["cwd"]?.stringValue
            })
        let record = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self,
            from: try JSONEncoder().encode(
                JSONValue.object([
                    "address": .string("t1"), "cwd": .string(directory), "state": .string("live"),
                    "argv": .array([.string("codex")]), "keep": .bool(false), "title": .string(""),
                    "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
                    "pid": .number(Double(Self.pid)),
                    "foreground": .object([
                        "pid": .number(Double(Self.pid)), "name": .string("codex"),
                        "argv": .array([.string("codex"), .string("--no-daemon")]), "cwd": .string(directory),
                    ]),
                ])))

        let elsewhere = try await Self.list(rig)
        let here = try await Self.list(rig, record: record)

        #expect(elsewhere.candidates.isEmpty)
        #expect(here.candidates.map(\.sessionID) == [thread])
        #expect(here.candidates.first?.origins == [.recentTranscript])
    }

    /// The Agent's process is what a confirmation binds to, so no process, no list.
    @Test func noResolvedProcessListsNothing() async throws {
        let rig = await Rig(.grok)
        await rig.table.remove(Self.pid)

        let answer = try await rig.binder.candidates(of: try Self.record(.grok, labels: [:]))

        #expect(answer == .noProcess)
    }

    /// Past the walk's cap a launcher looks like the Agent, so a confirmation would
    /// store the launcher's pid and start, and a Codex daemon under it is out of sight.
    @Test(arguments: programs)
    func aWalkPastItsCapListsNothing(_ program: ChatProgram) async throws {
        let rig = await Rig(program)
        var binder = rig.binder
        binder.processes = { try Self.readPastTheWalkCap($0) }

        let answer = try await binder.candidates(of: try Self.record(program, labels: [:]))

        #expect(answer == .noProcess)
        #expect(await rig.files.listings.isEmpty)
    }
}
