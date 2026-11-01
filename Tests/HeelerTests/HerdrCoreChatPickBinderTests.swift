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

    @Test func aPickADropAlreadyRemovedIsClearedAgainAndNotAdopted() async throws {
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
}
